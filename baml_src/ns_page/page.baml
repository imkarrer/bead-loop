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
    /// The stage its failure count puts it on, by name; "" when the stages are used up.
    stage: string,
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

class StageView {
    name: string,
    worker: string,
    reviewer: string,
    attempts: int,
}

class Status {
    now: int,
    /// The stages, in order, as the global config names them.
    stages: StageView[],
    repos: RepoView[],
    lanes: LaneView[],
    scores: Score[],
    loop: LoopView,
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
        stage: "",
    }
}

/// A stage's name: its own, or its 1-based place in the list.
function stage_name(p: root.machine.Policy, failures: int) -> string throws never {
    let s = root.machine.stage_for(p, failures);
    if let st: root.machine.Stage = s {
        if (st.name.length() > 0) {
            return st.name;
        }
        let i = 0;
        for (let x in p.stages) {
            i = i + 1;
            if (x.worker == st.worker && x.reviewer == st.reviewer && x.attempts == st.attempts) {
                return `${i}`;
            }
        }
    }
    ""
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
            let v = view_of(b);
            v.stage = stage_name(policy, b.failures);
            open.push(v);
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

function name_of(c: root.supervisor.LoopConfig) -> string throws never {
    if (c.only.length() > 0) {
        `${root.supervisor.repo_name(c.beads)} → ${root.supervisor.repo_name(c.repo)}`
    } else {
        root.supervisor.repo_name(c.repo)
    }
}

function status_of(configs: root.supervisor.LoopConfig[]) -> Status throws never {
    let now = root.supervisor.unix_seconds();
    let names = configs.map((c) -> {
        name_of(c)
    });
    let policy = configs.at(0)?.policy;
    let stages: StageView[] = [];
    if let pol: root.machine.Policy = policy {
        let i = 0;
        for (let s in pol.stages) {
            i = i + 1;
            stages.push(
                StageView {
                    name: if (s.name.length() > 0) {
                        s.name
                    } else {
                        `${i}`
                    },
                    worker: s.worker,
                    reviewer: s.reviewer,
                    attempts: s.attempts,
                },
            );
        }
    }
    Status {
        now: now,
        stages: stages,
        repos: configs.map((c) -> {
            repo_view(name_of(c), c.state, root.supervisor.FileLog { state: c.state }, c.policy)
        }),
        lanes: lanes_of(configs, names, now),
        scores: scoreboard(configs, now),
        loop: loop_view(),
    }
}

class ActRequest {
    state: string?,
    id: string?,
    file: string?,
    what: string?,
}

function json_reply(body: string) -> PageReply throws never {
    PageReply { status: 200, content_type: "application/json", body: body }
}

function text_reply(status: int, body: string) -> PageReply throws never {
    PageReply { status: status, content_type: "text/plain", body: body }
}

/// The page's other requests, each a POST with a JSON body: one bead's history, one
/// round's log, aborting a round, and starting or stopping the loop. Only for the states
/// the page shows. Null: not one of these.
function act(
    method: string,
    path: string,
    body: string,
    states: string[],
) -> PageReply? throws never {
    let known = ["/api/bead", "/api/log", "/api/abort", "/api/loop"];
    if (!known.includes(path)) {
        return null;
    }
    if (method != "POST") {
        return text_reply(405, "POST");
    }
    let req = baml.json.decode<ActRequest>(body) catch_all (e) {
        _ => {
            return text_reply(400, "bad request");
        },
    };
    if (path == "/api/loop") {
        let command = loop_command(req.what ?? "");
        if let c: string = command {
            let _ = shell_out(c);
            return text_reply(200, `${req.what ?? ""}: done`);
        }
        return text_reply(400, "start, stop or restart");
    }
    let state = req.state ?? "";
    if (!states.includes(state)) {
        return text_reply(403, "not a repo this page shows");
    }
    if (path == "/api/bead") {
        return json_reply(
            baml.json.stringify(bead_detail(state, req.id ?? "")) catch_all (e) {
                _ => "{}",
            },
        );
    }
    if (path == "/api/log") {
        return json_reply(
            baml.json.stringify(round_log(state, req.file ?? "")) catch_all (e) {
                _ => "[]",
            },
        );
    }
    text_reply(200, abort_round(state, req.id ?? ""))
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
        let acted = act(req.method, path_of(req.url), req.body, states);
        if let a: PageReply = acted {
            return response_of(a);
        }
        response_of(page_body(req.method, req.url, req.body, status, states))
    })
}

// No `${` and no backtick inside: this is a BAML backtick string, so the script below
// joins its strings with `+`. No backslash either: the string eats it (`\/` became `/`
// and broke the script).
const PAGE_HTML: string = `
        <!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>bead-loop</title>
        <style>
        :root{--bg:#fdf6e3;--panel:#eee8d5;--line:#e4dcc6;--fg:#586e75;--head:#073642;--muted:#93a1a1;--accent:#268bd2;--warn:#b58900;--bad:#dc322f;--ok:#859900;--violet:#6c71c4}
        @media (prefers-color-scheme:dark){:root{--bg:#002b36;--panel:#073642;--line:#0d4250;--fg:#93a1a1;--head:#eee8d5;--muted:#657b83}}
        *{box-sizing:border-box}
        body{font:14px/1.45 system-ui,sans-serif;background:var(--bg);color:var(--fg);margin:0;padding:16px;max-width:1280px}
        h1{color:var(--head);font-size:18px;margin:0}h2{color:var(--head);font-size:15px;margin:22px 0 8px}h3{color:var(--head);font-size:13px;margin:12px 0 4px}
        .muted{color:var(--muted)}.mono,pre{font:12px/1.4 ui-monospace,SFMono-Regular,Menlo,monospace}
        pre{white-space:pre-wrap;word-break:break-word;margin:0}
        header{display:flex;flex-wrap:wrap;align-items:center;gap:10px;margin-bottom:6px}
        .pill{border-radius:999px;padding:2px 10px;font-size:12px;font-weight:600;background:var(--panel)}
        .pill.active{color:var(--ok)}.pill.inactive,.pill.failed{color:var(--bad)}
        button{padding:4px 10px;border-radius:6px;border:1px solid var(--muted);background:var(--panel);color:var(--head);cursor:pointer;font:inherit;font-size:13px}
        button:hover{border-color:var(--accent)}
        .grid{display:grid;gap:10px;grid-template-columns:repeat(auto-fill,minmax(300px,1fr))}
        .card{background:var(--panel);border-radius:8px;padding:10px 12px}
        .slot{border-top:1px solid var(--line);padding-top:6px;margin-top:6px}
        table{width:100%;border-collapse:collapse}td,th{text-align:left;padding:5px 8px;border-bottom:1px solid var(--line);vertical-align:top}
        th{font-weight:600;color:var(--muted);font-size:12px}
        tr.bead{cursor:pointer}tr.bead:hover td{background:var(--panel)}
        .place{font-weight:600}.parked{color:var(--bad)}.merging,.publishable{color:var(--ok)}.working,.reviewing,.researching{color:var(--accent)}.in_review{color:var(--violet)}
        .hold{color:var(--warn)}
        .wrap{overflow-x:auto}a{color:var(--accent)}
        textarea{width:100%;min-height:52px;background:var(--bg);color:var(--fg);border:1px solid var(--muted);border-radius:6px;font:inherit}
        #panel{position:fixed;top:0;right:0;width:min(640px,100%);height:100%;overflow:auto;background:var(--bg);border-left:1px solid var(--line);padding:16px;box-shadow:-8px 0 24px rgba(0,0,0,.15);display:none}
        #panel.open{display:block}
        .ev{border-bottom:1px solid var(--line);padding:6px 0}.ev b{color:var(--head)}
        .sb td,.sb th{text-align:right}.sb td:first-child,.sb th:first-child{text-align:left}
        details summary{cursor:pointer;color:var(--head);font-weight:600}
    .flow th,.flow td{border:1px solid var(--line);min-width:110px}.flow td.stage{min-width:170px;background:var(--panel)}
    .chip{display:inline-block;margin:2px 4px 2px 0;padding:1px 8px;border-radius:999px;background:var(--panel);border:1px solid var(--line);cursor:pointer;font-size:12px}
    .chip:hover{border-color:var(--accent)}.chip.held{border-color:var(--warn);color:var(--warn)}.chip .r{color:var(--muted)}
        </style></head><body>
        <header><h1>bead-loop</h1><span id="loop" class="pill">...</span><span id="since" class="muted"></span>
        <button data-loop="start">Start</button><button data-loop="stop">Stop</button><button data-loop="restart">Restart</button>
        <span class="muted" id="when"></span></header>
        <h2>Flow</h2><div class="wrap"><table class="flow" id="flow"></table></div><div class="muted" id="landed"></div>
    <h2>Lanes</h2><div id="lanes" class="grid"></div>
        <div id="needs"></div>
        <h2>Scoreboard</h2><div class="wrap"><table class="sb" id="scores"></table></div>
        <div id="repos"></div>
        <h2>Supervisor log</h2><details><summary>the last lines of the loop's journal</summary><pre id="journal" class="mono"></pre></details>
        <div id="panel"></div>
        <script>
        var NL=String.fromCharCode(10);
        var MAP={'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'};
        var LAST=null;
        function esc(s){return String(s==null?'':s).replace(/[&<>"']/g,function(c){return MAP[c];});}
        function link(u){return u&&u.indexOf('http')===0?'<a href="'+esc(u)+'" target="_blank" rel="noopener">'+esc(u.split('https://github.com/').join(''))+'</a>':esc(u);}
        function dur(s){if(s<60)return s+'s';if(s<3600)return Math.floor(s/60)+'m';return Math.floor(s/3600)+'h '+Math.floor(s%3600/60)+'m';}
        function ago(at,now){return at>0?dur(Math.max(0,now-at))+' ago':'';}
        function clock(at){return at>0?new Date(at*1000).toLocaleString():'(before times were kept)';}
        async function post(path,body){var r=await fetch(path,{method:'POST',body:JSON.stringify(body)});return r;}
        async function tell(state,id,what){var t=document.getElementById('t-'+id);var r=await post('/api/tell',{state:state,id:id,what:what,text:t?t.value:''});alert(await r.text());load();}
        var COLS=[['ready','Ready'],['researching','Research'],['working','Working'],['in_review','Review queue'],['reviewing','Reviewing'],['merge','Merge']];
    function chip(r,b){return '<span class="chip'+(b.hold?' held':'')+'" data-bead="'+esc(b.id)+'" data-state="'+esc(r.state)+'" title="'+esc(r.name+(b.hold?' held: '+b.hold:''))+'">'+esc(b.id)+(b.failures?' <span class="r">'+b.failures+'</span>':'')+'</span>';}
    function col_of(b){return (b.place==='merging'||b.place==='publishable')?'merge':b.place;}
    function flow(s){
      var cells={};
      s.repos.forEach(function(r){r.beads.forEach(function(b){var row=b.place==='parked'||!b.stage?'(parked)':b.stage;var k=row+'/'+col_of(b);(cells[k]=cells[k]||[]).push(chip(r,b));});});
      var h='<tr><th>stage</th>'+COLS.map(function(c){return '<th>'+c[1]+'</th>';}).join('')+'</tr>';
      s.stages.forEach(function(st){
        h+='<tr><td class="stage"><b>'+esc(st.name)+'</b><div class="muted">'+esc(st.worker)+(st.reviewer?' then '+esc(st.reviewer):'')+'</div><div class="muted">'+st.attempts+' failure'+(st.attempts===1?'':'s')+' here</div></td>';
        COLS.forEach(function(c){h+='<td>'+(cells[st.name+'/'+c[0]]||[]).join('')+'</td>';});
        h+='</tr>';
      });
      var parked=[];Object.keys(cells).forEach(function(k){if(k.indexOf('(parked)/')===0)parked=parked.concat(cells[k]);});
      h+='<tr><td class="stage"><b>parked</b><div class="muted">yours: answer, reopen, escalate</div></td><td colspan="'+COLS.length+'">'+parked.join('')+'</td></tr>';
      return h;
    }
    function lane(l){
          var h='<div class="card"><b>'+esc(l.provider)+'</b> <span class="muted">'+l.rounds.length+' / '+l.slots+' busy</span>';
          if(!l.rounds.length)h+='<div class="slot muted">idle</div>';
          l.rounds.forEach(function(r){
            h+='<div class="slot"><b>'+esc(r.id)+'</b> <span class="muted">'+esc(r.repo)+'</span> &middot; '+esc(r.kind)+' on '+esc(r.model)+' &middot; '+dur(r.seconds)+
              ' <button data-abort="'+esc(r.id)+'" data-state="'+esc(r.state)+'">Abort</button>'+
              '<pre class="muted">'+esc(r.last.join(NL))+'</pre></div>';
          });
          return h+'</div>';
        }
        function scores(list){
          var kinds={};list.forEach(function(s){Object.keys(s.send_backs).forEach(function(k){kinds[k]=1;});});
          var h='<tr><th></th>'+list.map(function(s){return '<th>'+esc(s.window)+'</th>';}).join('')+'</tr>';
          function row(label,f){return '<tr><td>'+label+'</td>'+list.map(function(s){return '<td>'+f(s)+'</td>';}).join('')+'</tr>';}
          h+=row('Landed',function(s){return s.landed;});
          h+=row('First try',function(s){return s.landed?s.first_try+' ('+Math.round(100*s.first_try/s.landed)+'%)':'0';});
          h+=row('Without Claude',function(s){return s.landed?s.without_claude+' ('+Math.round(100*s.without_claude/s.landed)+'%)':'0';});
          h+=row('Parked',function(s){return s.parked;});
          Object.keys(kinds).sort().forEach(function(k){h+=row('<span class="muted">sent back: '+esc(k.split('_').join(' '))+'</span>',function(s){return s.send_backs[k]||0;});});
          return h;
        }
        function needs(repos){
          var items=[];
          repos.forEach(function(r){r.beads.forEach(function(b){
            if(b.place==='parked'){items.push('<div class="card"><b>'+esc(b.id)+'</b> <span class="muted">'+esc(r.name)+'</span> <span class="place parked">parked</span><pre>'+esc(b.question)+'</pre>'+
              '<textarea id="t-'+esc(b.id)+'" placeholder="your answer"></textarea>'+
              '<button data-tell="answer" data-id="'+esc(b.id)+'" data-state="'+esc(r.state)+'">Answer</button> '+
              '<button data-tell="reopen" data-id="'+esc(b.id)+'" data-state="'+esc(r.state)+'">Reopen</button> '+
              '<button data-tell="escalate" data-id="'+esc(b.id)+'" data-state="'+esc(r.state)+'">Escalate</button></div>');}
            else if(b.place==='publishable'){items.push('<div class="card"><b>'+esc(b.id)+'</b> <span class="muted">'+esc(r.name)+'</span> pushed, yours to open: '+link(b.question)+'</div>');}
            else if(b.hold){items.push('<div class="card"><b>'+esc(b.id)+'</b> <span class="muted">'+esc(r.name)+'</span> <span class="hold">held</span><pre>'+esc(b.hold)+'</pre></div>');}
          });});
          return items.length?'<h2>Needs you</h2><div class="grid">'+items.join('')+'</div>':'';
        }
        function repo(r){
          var head='<h2>'+esc(r.name)+' <span class="muted">'+r.beads.length+' open, '+r.closed+' closed</span></h2>';
          if(!r.beads.length)return head;
          return head+'<div class="wrap"><table><tr><th>bead</th><th>place</th><th>failures / rounds</th><th>PR, hold</th></tr>'+r.beads.map(function(b){
            return '<tr class="bead" data-bead="'+esc(b.id)+'" data-state="'+esc(r.state)+'"><td>'+esc(b.id)+'</td><td class="place '+esc(b.place)+'">'+esc(b.place.split('_').join(' '))+'</td><td>'+b.failures+' / '+b.rounds+'</td><td>'+link(b.pr)+(b.hold?'<div class="hold">held: '+esc(b.hold)+'</div>':'')+'</td></tr>';
          }).join('')+'</table></div>';
        }
        async function load(){
          var s=await (await fetch('/api/status')).json();LAST=s;
          var l=document.getElementById('loop');l.textContent='loop '+s.loop.active;l.className='pill '+s.loop.active;
          document.getElementById('since').textContent=s.loop.since?'since '+s.loop.since:'';
          document.getElementById('when').textContent='as of '+new Date().toLocaleTimeString();
          document.getElementById('flow').innerHTML=flow(s);
      var d=s.scores[0]||{landed:0};document.getElementById('landed').textContent='landed in the last 24h: '+d.landed+(d.landed?' ('+d.first_try+' first try, '+d.without_claude+' without Claude)':'');
      document.getElementById('lanes').innerHTML=s.lanes.map(lane).join('');
          document.getElementById('needs').innerHTML=needs(s.repos);
          document.getElementById('scores').innerHTML=scores(s.scores);
          document.getElementById('repos').innerHTML=s.repos.map(repo).join('');
          document.getElementById('journal').textContent=s.loop.journal.join(NL);
        }
        async function open_bead(state,id){
          var d=await (await post('/api/bead',{state:state,id:id})).json();var now=LAST?LAST.now:0;
          var h='<button data-close="1">Close</button><h2>'+esc(d.id)+'</h2>';
          if(d.park)h+='<h3>The question</h3><pre>'+esc(d.park)+'</pre>';
          if(d.brief)h+='<details><summary>The research brief</summary><pre>'+esc(d.brief)+'</pre></details>';
          if(d.report)h+='<details><summary>The last report</summary><pre>'+esc(d.report)+'</pre></details>';
          h+='<h3>History</h3>'+d.events.slice().reverse().map(function(e){return '<div class="ev"><b>'+esc(e.kind.split('_').join(' '))+'</b> <span class="muted" title="'+esc(clock(e.at))+'">'+esc(ago(e.at,now))+'</span>'+(e.text?'<pre>'+esc(e.text)+'</pre>':'')+'</div>';}).join('');
          if(d.logs.length)h+='<h3>Round logs</h3>'+d.logs.map(function(f){return '<div><a href="#" data-log="'+esc(f)+'" data-state="'+esc(state)+'">'+esc(f)+'</a></div>';}).join('')+'<pre id="roundlog" class="mono"></pre>';
          var p=document.getElementById('panel');p.innerHTML=h;p.className='open';
        }
        async function open_log(state,file){var lines=await (await post('/api/log',{state:state,file:file})).json();document.getElementById('roundlog').textContent=lines.join(NL)||'(empty)';}
        document.addEventListener('click',async function(e){
          var t=e.target,d=t.dataset||{};
          if(d.tell){tell(d.state,d.id,d.tell);return;}
          if(d.loop){if(confirm(d.loop+' the loop?')){var r=await post('/api/loop',{what:d.loop});alert(await r.text());load();}return;}
          if(d.abort){if(confirm('Abort '+d.abort+'? The loop starts it again, no failure charged.')){var r2=await post('/api/abort',{state:d.state,id:d.abort});alert(await r2.text());load();}return;}
          if(d.close){document.getElementById('panel').className='';return;}
          if(d.log){e.preventDefault();open_log(d.state,d.log);return;}
          var row=t.closest&&t.closest('[data-bead]');if(row){open_bead(row.dataset.state,row.dataset.bead);}
        });
        document.addEventListener('keydown',function(e){if(e.key==='Escape')document.getElementById('panel').className='';});
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
    let path = root.tools.scratch("page-script.js");
    baml.fs.write(path, script);
    let out = baml.sys.run("node", args = ["--check", path], capture_output = true);
    assert.equal(out.stderr.to_string(), "");
    assert.equal(out.exit_code, 0)
}

test "the page's other requests are POSTs for the states it shows" {
    assert.equal(act("GET", "/", "", ["/s"]) == null, true);
    assert.equal(act("GET", "/api/bead", "", ["/s"])?.status, 405);
    assert.equal(act("POST", "/api/bead", "{\"state\":\"/etc\",\"id\":\"x\"}", ["/s"])?.status, 403);
    assert.equal(
        act("POST", "/api/abort", "{\"state\":\"/etc\",\"id\":\"x\"}", ["/s"])?.status,
        403,
    );
    assert.equal(act("POST", "/api/loop", "{\"what\":\"rm\"}", ["/s"])?.status, 400);
    assert.equal(
        act("POST", "/api/bead", "{\"state\":\"/s\",\"id\":\"t-1\"}", ["/s"])?.content_type,
        "application/json",
    )
}

test "a bead's stage is the one its failures put it on" {
    let p = root.supervisor.policy();
    assert.equal(stage_name(p, 0), "local");
    assert.equal(stage_name(p, 2), "frontier");
    assert.equal(stage_name(p, 3), "")
}
