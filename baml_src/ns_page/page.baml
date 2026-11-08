// The page: ui/index.html (PAGE_HTML, written into page_html.baml by
// scripts/page-html.mjs), and the state it reads (flow.baml: each supervisor's
// STATE/view.json, the config, systemd). It acts on a bead only by leaving mail in the
// repo's inbox, which the supervisor carries out on its next tick; its one power of its
// own is the loop's systemd units. Every POST carries this run's token and comes from the
// page's own origin, so another site open in the same browser cannot pull a lever.

class BeadView {
    id: string,
    place: string,
    failures: int,
    rounds: int,
    hold: string,
    note: string,
    pr: string,
    /// A parked bead's question; a pushed branch's compare link.
    question: string,
}

class Snapshot {
    beads: BeadView[],
}

function place_name(p: root.machine.Place) -> string throws never {
    match (p) {
        let x: root.machine.Ready => "ready",
        let x: root.machine.Researching => "researching",
        let x: root.machine.Working => "working",
        let x: root.machine.InReview => "in_review",
        let x: root.machine.Reviewing => "reviewing",
        let x: root.machine.Publishable => "publishable",
        let x: root.machine.Merging => "merging",
        let x: root.machine.Parked => "parked",
        let x: root.machine.Closed => "closed",
    }
}

function question_of(p: root.machine.Place) -> string throws never {
    if let x: root.machine.Parked = p {
        x.question
    } else if let y: root.machine.Publishable = p {
        y.compare_url
    } else {
        ""
    }
}

function view_of(b: root.machine.Bead) -> BeadView throws never {
    BeadView {
        id: b.id,
        place: place_name(b.place),
        failures: b.failures,
        rounds: b.rounds,
        hold: b.hold?.words ?? "",
        note: b.last_note ?? "",
        pr: b.pr ?? "",
        question: question_of(b.place),
    }
}

/// The bench's view of a supervisor: each bead and where it is.
function snapshot_of(s: root.supervisor.Supervisor) -> Snapshot throws never {
    Snapshot {
        beads: s.beads.map((b) -> {
            view_of(b)
        }),
    }
}

function snapshot_json(s: root.supervisor.Supervisor) -> string throws never {
    baml.json.stringify(snapshot_of(s)) catch_all (e) {
        _ => "{}",
    }
}

/// Each repo the file names, and each of their targets, as a config.
function configs_of(config_file: string) -> root.supervisor.LoopConfig[] {
    let text = root.supervisor.read_or_empty(config_file);
    let home = root.supervisor.home_dir();
    let listed = root.supervisor.repos_in(text, home);
    let files = if (listed.length() > 0) {
        listed.map((r) -> {
            `${r}/.bead-loop.toml`
        })
    } else {
        [config_file]
    };
    let out: root.supervisor.LoopConfig[] = [];
    for (let f in files) {
        let c = root.supervisor.load_config(f);
        out.push(c);
        for (let t in root.supervisor.targets_of(root.supervisor.read_or_empty(f), c, home)) {
            out.push(t);
        }
    }
    out
}

function name_of(c: root.supervisor.LoopConfig) -> string throws never {
    if (c.only.length() > 0) {
        `${root.supervisor.repo_name(c.beads)} → ${root.supervisor.repo_name(c.repo)}`
    } else {
        root.supervisor.repo_name(c.repo)
    }
}

class PageReply {
    status: int,
    content_type: string,
    body: string,
}

function path_of(url: string) -> string throws never {
    let path = url.split("?").at(0) ?? url;
    if (path.length() == 0) {
        "/"
    } else {
        path
    }
}

/// One query parameter, decoded: `+` and the `%XX` a browser writes in a state path and
/// a log file name are enough.
function query_param(url: string, name: string) -> string throws never {
    let q = url.split("?").at(1) ?? "";
    for (let pair in q.split("&")) {
        let kv = pair.split("=");
        if ((kv.at(0) ?? "") == name) {
            return (kv.at(1) ?? "").replace_all("+", " ")
                .replace_all("%2F", "/")
                .replace_all("%2f", "/")
                .replace_all("%20", " ")
                .replace_all("%3A", ":")
                .replace_all("%3a", ":");
        }
    }
    ""
}

function json_error(status: int, what: string) -> PageReply throws never {
    let body = baml.json.stringify({ "error": what }) catch_all (e) {
        _ => "{}",
    };
    PageReply { status: status, content_type: "application/json", body: body }
}

function json_ok(said: string) -> PageReply throws never {
    let body = baml.json.stringify({ "ok": true, "said": said }) catch_all (e) {
        _ => "{}",
    };
    PageReply { status: 200, content_type: "application/json", body: body }
}

/// A lever's body: which bead, in which repo (its state dir), and what you wrote.
class Lever {
    repo: string?,
    id: string?,
    text: string?,
    title: string?,
    body: string?,
    on: bool?,
}

/// The levers that are a word told to the loop, and that word.
function word_of(lever: string) -> string? throws never {
    match (lever) {
        "answer" => "answer",
        "reopen" => "reopen",
        "escalate" => "escalate",
        "ready" => "publish",
        "publish" => "open_pr",
        _ => null,
    }
}

/// What the systemd levers run; null for any other.
function unit_command(lever: string, on: bool) -> string? throws never {
    if (lever == "stop") {
        return "systemctl --user stop bead-supervisor.service";
    }
    if (lever == "loop") {
        return if (on) {
            "systemctl --user start bead-supervisor.timer bead-supervisor.service"
        } else {
            "systemctl --user stop bead-supervisor.timer bead-supervisor.service"
        };
    }
    if (lever == "timer") {
        return if (on) {
            "systemctl --user start bead-supervisor.timer"
        } else {
            "systemctl --user stop bead-supervisor.timer"
        };
    }
    null
}

/// One lever: POST /api/NAME with a JSON body, for the repos this page shows. Each is mail
/// for the supervisor, or one of the loop's units.
function pull(
    lever: string,
    body: string,
    configs: root.supervisor.LoopConfig[],
) -> PageReply throws never {
    let l = baml.json.decode<Lever>(body) catch_all (e) {
        _ => {
            return json_error(400, "bad request");
        },
    };
    let systemd = unit_command(lever, l.on ?? false);
    if let command: string = systemd {
        let _ = shell_out(command);
        return json_ok(command);
    }
    let found: root.supervisor.LoopConfig[] = configs.filter((c) -> {
        c.state == (l.repo ?? "")
    });
    if (found.length() == 0) {
        return json_error(403, "not a repo this page shows");
    }
    let state = found.at(0)?.state ?? "";
    let id = l.id ?? "";
    if (id.length() == 0 || id.includes("/") || id.includes(" ")) {
        return json_error(400, "which bead?");
    }
    let order: root.world.Order? = if (lever == "abort") {
        root.world.AbortOrder { kind: "abort" }
    } else if (lever == "note") {
        root.world.NoteOrder { kind: "note", text: (l.text ?? "").trim() }
    } else {
        null
    };
    if let o: root.world.Order = order {
        if let n: root.world.NoteOrder = o {
            if (n.text.length() == 0) {
                return json_error(400, "write the note first");
            }
        }
        let sent = root.supervisor.order_to(state, id, o) catch_all (x) {
            _ => {
                return json_error(500, `${x}`);
            },
        };
        return json_ok(await_loop(state, id, sent));
    }
    let word = word_of(lever);
    if let w: string = word {
        let text = if (w == "open_pr") {
            l.body ?? ""
        } else {
            l.text ?? ""
        };
        if (w == "answer" && text.trim().length() == 0) {
            return json_error(400, "write the answer first");
        }
        let event = root.supervisor.told(w, text, title = l.title ?? "");
        if let e: root.machine.Event = event {
            let sent = root.supervisor.mail_to(state, id, e) catch_all (x) {
                _ => {
                    return json_error(500, `${x}`);
                },
            };
            return json_ok(await_loop(state, id, sent));
        }
    }
    json_error(404, `no lever ${lever} in the BAML loop`)
}

/// Waits for the supervisor to take the mail at `sent` and write its next view, then says
/// what became of the bead: its newest event (`pr_opened: https://...`), so a lever comes
/// back with what the loop did, not a promise. The loop wakes for mail within a second; a
/// tick that runs rounds or asks GitHub can take longer, so this waits up to a minute.
function await_loop(state: string, id: string, sent: string) -> string throws never {
    let start = root.supervisor.unix_seconds();
    let taken = false;
    let waited = 0;
    while (waited < 120) {
        let there = baml.fs.exists(sent) catch_all (e) {
            _ => false,
        };
        if (!there) {
            taken = true;
        }
        if (taken) {
            let v = view_at(state);
            if (v.at >= start) {
                let found = v.beads.filter((b) -> {
                    b.id == id
                });
                if let b: root.supervisor.FBead = found.at(0) {
                    return `${id}: ${b.last}`;
                }
                return `${id}: done (it is no longer in a queue)`;
            }
        }
        baml.sys.sleep(baml.time.Duration.from_milliseconds(500));
        waited = waited + 1;
    }
    if (taken) {
        `${id}: taken; the loop is still on its tick`
    } else {
        `${id}: waiting for the loop (is it running?)`
    }
}

/// A POST comes from the page itself: this run's token, and no Origin but the page's own
/// (a browser sends Origin on every cross-site POST, and another site cannot read the
/// token out of the page).
function trusted(headers: map<string, string>, token: string, addr: string) -> bool throws never {
    let given = headers.get("x-bead-loop-token") ?? headers.get("X-Bead-Loop-Token") ?? "";
    if (token.length() == 0 || given != token) {
        return false;
    }
    let origin = headers.get("origin") ?? headers.get("Origin") ?? "";
    let port = addr.split(":").at(1) ?? "";
    origin.length() == 0
        || origin == `http://${addr}`
        || origin == `http://127.0.0.1:${port}`
        || origin == `http://localhost:${port}`
}

/// GET /api/log?repo=STATE&file=NAME: one round's log as it is on disk.
function log_text(url: string, configs: root.supervisor.LoopConfig[]) -> PageReply throws never {
    let state = query_param(url, "repo");
    let file = query_param(url, "file");
    let known = configs
        .filter((c) -> {
            c.state == state
        })
        .length()
        > 0;
    if (!known) {
        return json_error(403, "not a repo this page shows");
    }
    if (file.includes("/") || file.includes("..") || file.length() == 0) {
        return json_error(400, "a log file name");
    }
    PageReply {
        status: 200,
        content_type: "text/plain; charset=utf-8",
        body: read_or_empty(`${state}/logs/${file}`),
    }
}

/// Every request: the page, the state, a log, or a lever.
function route(
    req_method: string,
    url: string,
    body: string,
    headers: map<string, string>,
    configs: root.supervisor.LoopConfig[],
    token: string,
    addr: string,
) -> PageReply throws never {
    let path = path_of(url);
    if (path == "/" || path == "/index.html") {
        let html = PAGE_HTML.replace("</head>", `<meta name="bead-loop-token" content="${token}">\n</head>`);
        return PageReply { status: 200, content_type: "text/html; charset=utf-8", body: html };
    }
    if (path == "/favicon.svg") {
        return PageReply { status: 200, content_type: "image/svg+xml", body: FAVICON_SVG };
    }
    if (path == "/api/status") {
        let s = baml.json.stringify(flow_status(configs)) catch_all (e) {
            _ => {
                return json_error(500, `${e}`);
            },
        };
        return PageReply { status: 200, content_type: "application/json", body: s };
    }
    if (path == "/api/log") {
        return log_text(url, configs);
    }
    if (path.starts_with("/api/")) {
        if (req_method != "POST") {
            return json_error(405, "POST");
        }
        if (!trusted(headers, token, addr)) {
            return json_error(403, "not from this page");
        }
        return pull(path.slice(5, path.length()), body, configs);
    }
    PageReply { status: 404, content_type: "text/plain", body: "not found" }
}

function response_of(reply: PageReply) -> baml.http.Response throws never {
    baml.http.Response.new(
        reply.status,
        { "content-type": reply.content_type },
        reply.body.to_utf8(),
    )
}

/// /api/insights: the insights, rebuilt when the last are five minutes old. `cached` holds
/// the last answer and the second it was built.
function insights_reply(
    configs: root.supervisor.LoopConfig[],
    cached: string[],
) -> PageReply throws never {
    let now = root.supervisor.unix_seconds();
    let built = baml.json.decode<int>(cached.at(1) ?? "0") catch_all (e) {
        _ => 0,
    };
    if ((cached.at(0) ?? "").length() == 0 || now - built > 300) {
        let text = baml.json.stringify(insights_of(configs)) catch_all (e) {
            _ => "{}",
        };
        cached[0] = text;
        cached[1] = `${now}`;
    }
    PageReply { status: 200, content_type: "application/json", body: cached.at(0) ?? "{}" }
}

/// `bead-supervisor page --config_file ~/.config/bead-loop/config.toml --addr 127.0.0.1:4097`.
/// Reads the configs once, and makes a token for this run that the page it serves carries.
function page(config_file: string, addr: string = "127.0.0.1:4097") -> never {
    let configs = configs_of(config_file);
    let token = read_or_empty("/proc/sys/kernel/random/uuid").trim();
    let cached: string[] = ["", "0"];
    let server = baml.http.Server.bind(addr);
    server.serve((req) -> {
        if (path_of(req.url) == "/api/insights") {
            return response_of(insights_reply(configs, cached));
        }
        response_of(route(req.method, req.url, req.body, req.headers, configs, token, addr))
    })
}

test "a snapshot names a bead's place" {
    let w = root.world.FakeWorld.new(
        [root.world.Ticket { id: "t-1", title: "t", description: "d", acceptance: "a" }],
        [],
    );
    let s = root.supervisor.Supervisor.new(w, root.supervisor.MemoryLog.new(), root.supervisor.policy());
    root.supervisor.tick(s);
    let snap = snapshot_of(s);
    assert.equal(snap.beads.at(0)?.id, "t-1");
    assert.equal(snap.beads.at(0)?.place, "working")
}

test "the page is ui/index.html, served whole, with this run's token" {
    let none: root.supervisor.LoopConfig[] = [];
    let h: map<string, string> = {};
    let r = route("GET", "/", "", h, none, "tok", "127.0.0.1:4097");
    assert.contains(r.body, "function flowGraph(");
    assert.contains(r.body, "content=\"tok\"");
    assert.equal(route("GET", "/nope", "", h, none, "tok", "127.0.0.1:4097").status, 404);
    assert.equal(route("GET", "/api/answer", "", h, none, "tok", "127.0.0.1:4097").status, 405)
}

test "a lever from anywhere but the page is refused" {
    let none: root.supervisor.LoopConfig[] = [];
    let no: map<string, string> = {};
    assert.equal(route("POST", "/api/stop", "{}", no, none, "tok", "127.0.0.1:4097").status, 403);
    let other: map<string, string> = { "x-bead-loop-token": "tok", "origin": "https://evil.example" };
    assert.equal(trusted(other, "tok", "127.0.0.1:4097"), false);
    let own: map<string, string> = { "x-bead-loop-token": "tok", "origin": "http://127.0.0.1:4097" };
    assert.equal(trusted(own, "tok", "127.0.0.1:4097"), true);
    let wrong: map<string, string> = { "x-bead-loop-token": "nope" };
    assert.equal(trusted(wrong, "tok", "127.0.0.1:4097"), false)
}

test "the page's script parses as served" {
    let path = root.tools.scratch("page.js");
    let script = (PAGE_HTML.split("<script>").at(1) ?? "").split("</script>").at(0) ?? "";
    let _ = baml.fs.write(path, script);
    let out = baml.sys.run("node", args = ["--check", path], capture_output = true) catch_all (e) {
        _ => {
            let _ = baml.fs.remove(path);
            return;
        },
    };
    assert.equal(out.exit_code, 0);
    let _ = baml.fs.remove(path);
}

test "a lever is mail for the supervisor or one of the loop's units; nothing else" {
    assert.equal(word_of("ready"), "publish");
    assert.equal(word_of("publish"), "open_pr");
    assert.equal(word_of("decide") == null, true);
    assert.contains(unit_command("loop", false) ?? "", "stop bead-supervisor.timer");
    assert.equal(unit_command("rm", true) == null, true);
    let none: root.supervisor.LoopConfig[] = [];
    assert.equal(
        pull("answer", "{\"repo\":\"/elsewhere\",\"id\":\"t-1\",\"text\":\"x\"}", none).status,
        403,
    )
}

test "a log is asked for by its repo and file name" {
    assert.equal(query_param("/api/log?repo=%2Fs%2Fb&file=t-1.9.Work.jsonl", "repo"), "/s/b");
    assert.equal(
        query_param("/api/log?repo=%2Fs%2Fb&file=t-1.9.Work.jsonl", "file"),
        "t-1.9.Work.jsonl",
    )
}

test "a lever comes back with what the loop did" {
    let state = root.tools.scratch("await");
    let _ = baml.sys.run("mkdir", args = ["-p", state]);
    let b = root.supervisor.fbead("t-1", "t", 0, 1);
    b.last = "pr_opened: https://github.com/o/r/pull/1";
    let v = root.supervisor.View { at: root.supervisor.unix_seconds() + 5, beads: [b], tallies: [] };
    baml.fs.write(`${state}/view.json`, baml.json.stringify(v));
    assert.equal(
        await_loop(state, "t-1", `${state}/inbox/gone.json`),
        "t-1: pr_opened: https://github.com/o/r/pull/1",
    );
    assert.contains(await_loop(state, "t-2", `${state}/inbox/gone.json`), "done")
}
