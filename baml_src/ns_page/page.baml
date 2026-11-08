// The page: every repo's beads, folded from their logs on each request, and the three
// levers a parked bead takes. It only reads the logs and writes to an inbox: it never
// asks the world, so it cannot take a round's result from the loop or start anything.

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

class RepoView {
    name: string,
    state: string,
    beads: BeadView[],
    closed: int,
}

class Status {
    repos: RepoView[],
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

/// One repo's beads from its log alone: a fold, with no call to the world.
function repo_view(
    name: string,
    state: string,
    log: root.supervisor.Log,
    policy: root.machine.Policy,
) -> RepoView throws never {
    let open: BeadView[] = [];
    let closed = 0;
    for (let id in log.ids()) {
        let b = root.machine.fold(id, log.load(id), policy);
        if (b.place is root.machine.Closed) {
            closed = closed + 1;
        } else {
            open.push(view_of(b));
        }
    }
    RepoView { name: name, state: state, beads: open, closed: closed }
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

function status_of(configs: root.supervisor.LoopConfig[]) -> Status throws never {
    Status {
        repos: configs.map((c) -> {
            let name = if (c.only.length() > 0) {
                `${root.supervisor.repo_name(c.beads)} → ${root.supervisor.repo_name(c.repo)}`
            } else {
                root.supervisor.repo_name(c.repo)
            };
            repo_view(name, c.state, root.supervisor.FileLog { state: c.state }, c.policy)
        }),
    }
}

class TellRequest {
    state: string,
    id: string,
    what: string,
    text: string,
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

/// A tell from the page, for one of the states the page shows and no other.
function tell_from_page(body: string, states: string[]) -> PageReply throws never {
    let req = baml.json.decode<TellRequest>(body) catch_all (e) {
        _ => {
            return PageReply { status: 400, content_type: "text/plain", body: "bad request" };
        },
    };
    if (!states.includes(req.state)) {
        return PageReply { status: 403, content_type: "text/plain", body: "not a repo this page shows" };
    }
    let event = root.supervisor.told(req.what, req.text);
    if let e: root.machine.Event = event {
        let written = root.supervisor.mail_to(req.state, req.id, e) catch_all (x) {
            _ => {
                return PageReply { status: 500, content_type: "text/plain", body: `${x}` };
            },
        };
        PageReply {
            status: 200,
            content_type: "text/plain",
            body: "told: the loop takes it on its next tick",
        }
    } else {
        PageReply { status: 400, content_type: "text/plain", body: "answer, reopen or escalate" }
    }
}

function page_body(
    method: string,
    url: string,
    body: string,
    status: string,
    states: string[],
) -> PageReply throws never {
    let path = path_of(url);
    if (path == "/api/status") {
        PageReply { status: 200, content_type: "application/json", body: status }
    } else if (path == "/api/tell" && method == "POST") {
        tell_from_page(body, states)
    } else if (path == "/" || path == "/index.html") {
        PageReply { status: 200, content_type: "text/html; charset=utf-8", body: PAGE_HTML }
    } else {
        PageReply { status: 404, content_type: "text/plain", body: "not found" }
    }
}

function response_of(reply: PageReply) -> baml.http.Response throws never {
    baml.http.Response.new(
        reply.status,
        { "content-type": reply.content_type },
        reply.body.to_utf8(),
    )
}

/// `bead-supervisor page --config_file ~/.config/bead-loop/config.toml --addr 127.0.0.1:4097`.
/// Reads the configs once; every request folds the logs afresh.
function page(config_file: string, addr: string = "127.0.0.1:4097") -> never {
    let configs = configs_of(config_file);
    let states = configs.map((c) -> {
        c.state
    });
    let server = baml.http.Server.bind(addr);
    server.serve((req) -> {
        let status = if (path_of(req.url) == "/api/status") {
            baml.json.stringify(status_of(configs)) catch_all (e) {
                _ => "{}",
            }
        } else {
            ""
        };
        response_of(page_body(req.method, req.url, req.body, status, states))
    })
}

// No `${` and no backtick inside: this is a BAML backtick string, so the script below
// joins its strings with `+`. No backslash either: the string eats it (`\/` became `/`
// and broke the script).
const PAGE_HTML: string = `
    <!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>bead-loop</title>
    <style>
    :root{--bg:#fdf6e3;--panel:#eee8d5;--fg:#586e75;--head:#073642;--muted:#93a1a1;--accent:#268bd2;--warn:#b58900;--bad:#dc322f;--ok:#859900}
    @media (prefers-color-scheme:dark){:root{--bg:#002b36;--panel:#073642;--fg:#93a1a1;--head:#eee8d5;--muted:#586e75}}
    body{font:14px/1.45 system-ui,sans-serif;background:var(--bg);color:var(--fg);margin:0;padding:16px;max-width:1100px}
    h1{color:var(--head);font-size:18px;margin:0 0 4px}h2{color:var(--head);font-size:15px;margin:20px 0 6px}
    .muted{color:var(--muted)}table{width:100%;border-collapse:collapse}td,th{text-align:left;padding:6px 8px;border-bottom:1px solid var(--panel);vertical-align:top}
    th{font-weight:600;color:var(--muted);font-size:12px}.place{font-weight:600}.parked{color:var(--bad)}.merging{color:var(--ok)}.working,.reviewing,.researching{color:var(--accent)}
    .hold{color:var(--warn)}textarea{width:100%;min-height:48px;background:var(--panel);color:var(--fg);border:1px solid var(--muted);border-radius:6px;font:inherit}
    button{margin:4px 4px 0 0;padding:4px 10px;border-radius:6px;border:1px solid var(--muted);background:var(--panel);color:var(--head);cursor:pointer}
    .wrap{overflow-x:auto}a{color:var(--accent)}pre{white-space:pre-wrap;margin:0}
    </style></head><body>
    <h1>bead-loop</h1><div class="muted" id="when">loading...</div><div id="repos"></div>
    <script>
    var MAP={'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'};
    function esc(s){return String(s==null?'':s).replace(/[&<>"']/g,function(c){return MAP[c];});}
    function link(u){return u&&u.indexOf('http')===0?'<a href="'+esc(u)+'" target="_blank" rel="noopener">'+esc(u.split('https://github.com/').join(''))+'</a>':esc(u);}
    async function tell(state,id,what){var t=document.getElementById('t-'+id);var r=await fetch('/api/tell',{method:'POST',body:JSON.stringify({state:state,id:id,what:what,text:t?t.value:''})});alert(await r.text());load();}
    function button(r,b,what,label){return '<button data-state="'+esc(r.state)+'" data-id="'+esc(b.id)+'" data-what="'+what+'">'+label+'</button>';}
    function row(r,b){
      var extra='';
      if(b.place==='parked'){extra='<pre>'+esc(b.question)+'</pre><textarea id="t-'+esc(b.id)+'" placeholder="your answer"></textarea>'+button(r,b,'answer','Answer')+button(r,b,'reopen','Reopen')+button(r,b,'escalate','Escalate');}
      else if(b.place==='publishable'){extra='open the PR: '+link(b.question);}
      var hold=b.hold?'<div class="hold">held: '+esc(b.hold)+'</div>':'';
      return '<tr><td>'+esc(b.id)+'</td><td class="place '+esc(b.place)+'">'+esc(b.place)+'</td><td>'+b.failures+' / '+b.rounds+'</td><td>'+link(b.pr)+hold+extra+'</td></tr>';
    }
    function repo(r){
      var head='<h2>'+esc(r.name)+' <span class="muted">'+r.beads.length+' open, '+r.closed+' closed</span></h2>';
      if(!r.beads.length)return head;
      return head+'<div class="wrap"><table><tr><th>bead</th><th>place</th><th>failures / rounds</th><th>PR, hold, question</th></tr>'+r.beads.map(function(b){return row(r,b);}).join('')+'</table></div>';
    }
    async function load(){
      var s=await (await fetch('/api/status')).json();
      document.getElementById('when').textContent='as of '+new Date().toLocaleTimeString();
      document.getElementById('repos').innerHTML=s.repos.map(repo).join('');
    }
    document.addEventListener('click',function(e){var d=e.target.dataset;if(d&&d.what)tell(d.state,d.id,d.what);});
    load();setInterval(function(){var a=document.activeElement;if(!a||a.tagName!=='TEXTAREA')load();},5000);
    </script></body></html>
`;

test "the status path is json, tell is a POST, the rest is the page or 404" {
    assert.equal(page_body("GET", "/api/status", "", "{\"repos\":[]}", []).status, 200);
    assert.equal(page_body("GET", "/api/status", "", "{}", []).content_type, "application/json");
    assert.contains(page_body("GET", "/", "", "{}", []).body, "bead-loop");
    assert.equal(page_body("GET", "/nope", "", "{}", []).status, 404);
    assert.equal(page_body("GET", "/api/tell", "", "{}", []).status, 404)
}

test "the page tells only the states it shows" {
    let body = "{\"state\":\"/elsewhere\",\"id\":\"t-1\",\"what\":\"reopen\",\"text\":\"\"}";
    assert.equal(tell_from_page(body, ["/state"]).status, 403);
    assert.equal(tell_from_page("not json", ["/state"]).status, 400);
    let bad = "{\"state\":\"/state\",\"id\":\"t-1\",\"what\":\"merge\",\"text\":\"\"}";
    assert.equal(tell_from_page(bad, ["/state"]).status, 400)
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

test "a repo's view is a fold of its log, closed beads counted not listed" {
    let w = root.world.FakeWorld.new(
        [root.world.Ticket { id: "t-1", title: "t", description: "d", acceptance: "a" }],
        [],
    );
    let log = root.supervisor.MemoryLog.new();
    let s = root.supervisor.Supervisor.new(w, log, root.supervisor.policy());
    root.supervisor.tick(s);
    log.append("t-2", root.machine.PrAdopted { kind: "pr_adopted", url: "u" });
    log.append("t-2", root.machine.PrMerged { kind: "pr_merged", url: "u" });
    let v = repo_view("r", "/state", log, root.supervisor.policy());
    assert.equal(v.beads.length(), 1);
    assert.equal(v.beads.at(0)?.place, "working");
    assert.equal(v.closed, 1)
}

test "the page's script parses as served" {
    let parts = PAGE_HTML.split("<script>");
    let script = (parts.at(1) ?? "").split("</script>").at(0) ?? "";
    let path = "/tmp/bead-loop-page-script.js";
    baml.fs.write(path, script);
    let out = baml.sys.run("node", args = ["--check", path], capture_output = true);
    assert.equal(out.stderr.to_string(), "");
    assert.equal(out.exit_code, 0)
}
