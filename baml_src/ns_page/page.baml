// The page: a fold of the log as JSON, and a small HTML view of it. Each request
// recovers, so what it shows is the beads as of now. The live Rust page's event
// stream and levers are not ported; this is the skeleton that serves them later.

class BeadView {
    id: string,
    place: string,
    failures: int,
    hold: string,
    note: string,
    pr: string,
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

function view_of(b: root.machine.Bead) -> BeadView throws never {
    BeadView {
        id: b.id,
        place: place_name(b.place),
        failures: b.failures,
        hold: b.hold?.words ?? "",
        note: b.last_note ?? "",
        pr: b.pr ?? "",
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

class PageReply {
    status: int,
    content_type: string,
    body: string,
}

const PAGE_HTML: string = "<!doctype html><html lang=\"en\"><head><meta charset=\"utf-8\"><title>bead-loop</title><style>body{font:14px/1.45 system-ui;background:#002b36;color:#839496;margin:24px}h1{color:#eee8d5;font-size:16px}pre{background:#073642;padding:12px;border-radius:8px;overflow:auto}</style></head><body><h1>bead-loop</h1><p>The beads as of this request. Poll <code>/api/status</code>.</p><pre id=\"s\"></pre><script>async function t(){const r=await fetch('/api/status');document.getElementById('s').textContent=JSON.stringify(await r.json(),null,2)}t();setInterval(t,3000)</script></body></html>";

function path_of(url: string) -> string throws never {
    let path = url.split("?").at(0) ?? url;
    if (path.length() == 0) {
        "/"
    } else {
        path
    }
}

function page_body(url: string, status: string) -> PageReply throws never {
    let path = path_of(url);
    if (path == "/api/status") {
        PageReply { status: 200, content_type: "application/json", body: status }
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

/// `bead-loop page --config_file PATH --addr 127.0.0.1:4097`. Recovers on every
/// request so a restart of the supervisor is visible here without shared memory.
function page(config_file: string, addr: string = "127.0.0.1:4097") -> never {
    let c = root.supervisor.load_config(config_file);
    let world = root.world.LiveWorld {
        repo: c.repo,
        state: c.state,
        base: c.base,
        remote: c.remote,
        label: c.label,
        gate: c.gate,
        agent_bin: c.agent_bin,
        merge: root.machine.merge_name(c.policy.merge),
    };
    let server = baml.http.Server.bind(addr);
    server.serve((req) -> {
        let s = root.supervisor.recover(world, root.supervisor.FileLog { state: c.state }, c.policy);
        let reply = page_body(req.url, snapshot_json(s));
        response_of(reply)
    })
}

test "the status path is json, the rest is the page or 404" {
    assert.equal(page_body("/api/status", "{\"beads\":[]}").status, 200);
    assert.equal(page_body("/api/status", "{}").content_type, "application/json");
    assert.contains(page_body("/", "{}").body, "bead-loop");
    assert.equal(page_body("/nope", "{}").status, 404)
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
