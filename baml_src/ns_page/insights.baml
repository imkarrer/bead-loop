// Insights: what the loop's own record says to change. Each is a small table with a
// level and one line saying what to do about it. Two sources: the BAML traces under each
// repo's .baml/btel, read with `baml-cli query --format json`, and the tallies each
// supervisor writes into STATE/view.json (each bead's rounds, from its event log).
// The page asks /api/insights, which this builds at most once every five minutes.

/// One insight as the page draws it: a table, a level and what to do.
class Insight {
    key: string,
    title: string,
    /// What the table counts, in one line.
    about: string,
    columns: string[],
    rows: string[][],
    /// ok, warn or bad: how the page colours it.
    level: string,
    /// What to do about it, in one line; empty when there is nothing to do.
    hint: string,
}

class Insights {
    at: int,
    insights: Insight[],
}

/// A query's answer as `baml-cli query --format json` gives it.
class TraceColumn {
    name: string,
}

class TraceTable {
    columns: TraceColumn[],
    rows: json[][],
}

/// Model calls by server and round kind: how many, how many failed, how long. The span's
/// `duration` is NULL for many calls, so the time comes from its start and end.
const MODEL_CALLS_SQL: string = "SELECT span_name AS call, json_extract(context_metadata,'$.kind') AS kind, count(*) AS n, sum(status <> 'return') AS failed, round(avg((julianday(end_time)-julianday(start_time))*86400),1) AS avg_s, round(max((julianday(end_time)-julianday(start_time))*86400),1) AS max_s FROM spans WHERE span_type='network_span' GROUP BY 1,2 ORDER BY n DESC";

/// The newest baml-cli scripts/ensure-baml.sh has fetched; "" when there is none.
function baml_cli() -> string throws never {
    shell_out("ls -d \"$HOME\"/.cache/bead-loop/baml-*/bin/baml-cli 2>/dev/null | sort -V | tail -1")
        .trim()
}

/// One read-only query over a repo's traces; an empty table when the repo has none, or
/// the CLI is missing or fails.
function trace_rows(repo: string, sql: string) -> TraceTable throws never {
    let none = TraceTable { columns: [], rows: [] };
    let cli = baml_cli();
    let there = baml.fs.exists(`${repo}/.baml/btel`) catch_all (e) {
        _ => false,
    };
    if (cli.length() == 0 || !there) {
        return none;
    }
    let out = baml.sys.run(
        "env",
        args = [
            `BAML_HOME=${repo}/.baml`,
            "DO_NOT_TRACK=1",
            "BAML_CLI_ALLOW_DIRECT=1",
            cli,
            "--agent-skill-check",
            "off",
            "query",
            "--local",
            "--format",
            "json",
            "--max-wall",
            "60s",
            sql,
        ],
        cwd = repo,
        capture_output = true,
    ) catch_all (e) {
        _ => {
            return none;
        },
    };
    if (out.exit_code != 0) {
        return none;
    }
    baml.json.decode<TraceTable>(out.stdout.to_string()) catch_all (e) {
        _ => none,
    }
}

/// A table cell as text: a string as it is, a number or null as JSON writes it.
function cell(v: json) -> string throws never {
    if let s: string = v {
        return s;
    }
    baml.json.stringify(v) catch_all (e) {
        _ => "",
    }
}

function empty_insight(
    key: string,
    title: string,
    about: string,
    columns: string[],
) -> Insight throws never {
    Insight {
        key: key,
        title: title,
        about: about,
        columns: columns,
        rows: [],
        level: "ok",
        hint: "",
    }
}

// ---- the five insights: each is built by its own bead ---------------------------------

/// 1. Model calls, from the traces of every repo.
function model_calls(tables: TraceTable[]) -> Insight throws never {
    empty_insight(
        "model_calls",
        "Model calls",
        "every call a round made to a model server, by server and round kind",
        ["server", "kind", "calls", "failed", "avg s", "max s"],
    )
}

/// 2. What rounds came to, by kind and model.
function round_outcomes(tallies: root.supervisor.FTally[]) -> Insight throws never {
    empty_insight(
        "round_outcomes",
        "Round outcomes",
        "what each kind of round came to, by model",
        ["kind", "model", "rounds", "good", "sent back", "held", "top reason"],
    )
}

/// 3. Rejections a worker rebutted, and what the second review said.
function overturned(tallies: root.supervisor.FTally[]) -> Insight throws never {
    empty_insight(
        "overturned",
        "Rejections disputed",
        "a REJECT the worker rebutted, and whether the tiebreak review upheld it",
        ["bead", "rejected by", "the REJECT", "tiebreak"],
    )
}

/// 4. Holds by their cause.
function holds_by_cause(tallies: root.supervisor.FTally[]) -> Insight throws never {
    empty_insight(
        "holds",
        "Holds by cause",
        "rounds held without a charge: the harness, a server, git, gh or bd",
        ["cause", "holds", "beads", "last words"],
    )
}

/// 5. How long a bead waits for a free lane.
function lane_wait(tallies: root.supervisor.FTally[]) -> Insight throws never {
    empty_insight(
        "lane_wait",
        "Waiting for a lane",
        "from a bead being ready to its round starting, by model server",
        ["server", "rounds", "median wait", "longest wait"],
    )
}

/// Every insight, from the configs' views and their repos' traces.
function insights_of(configs: root.supervisor.LoopConfig[]) -> Insights throws never {
    let tallies: root.supervisor.FTally[] = [];
    let tables: TraceTable[] = [];
    let repos: string[] = [];
    for (let c in configs) {
        for (let t in view_at(c.state).tallies) {
            tallies.push(t);
        }
        if (!repos.includes(c.repo)) {
            repos.push(c.repo);
            tables.push(trace_rows(c.repo, MODEL_CALLS_SQL));
        }
    }
    Insights {
        at: root.supervisor.unix_seconds(),
        insights: [
            model_calls(tables),
            round_outcomes(tallies),
            overturned(tallies),
            holds_by_cause(tallies),
            lane_wait(tallies),
        ],
    }
}

test "every insight is there, each a titled table" {
    let none: root.supervisor.LoopConfig[] = [];
    let i = insights_of(none);
    assert.equal(
        i.insights
            .map((x) -> {
                x.key
            })
            .join(","),
        "model_calls,round_outcomes,overturned,holds,lane_wait",
    );
    for (let x in i.insights) {
        assert.is_true(x.title.length() > 0);
        assert.is_true(x.columns.length() > 0);
    }
}

test "a repo with no traces is an empty table, not an error" {
    let t = trace_rows(root.tools.scratch("no-traces"), MODEL_CALLS_SQL);
    assert.equal(t.rows.length(), 0)
}

test "a cell is its text" {
    assert.equal(cell("acbox"), "acbox");
    assert.equal(cell(3), "3");
    assert.equal(cell(null), "null")
}
