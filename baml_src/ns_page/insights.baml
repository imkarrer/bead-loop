// Insights: what the loop's own record says to change. Each is a small table with a
// level and one line saying what to do. Two sources: the BAML traces under each
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

/// A table cell as a number; 0 when it is null or not a number.
function number_cell(v: json) -> float throws never {
    baml.json.to<float>(v) catch_all (e) {
        _ => 0.0,
    }
}

/// "POST http://192.168.1.51:8100/v1/chat/completions" -> "192.168.1.51:8100".
function server_of(call: string) -> string throws never {
    let after_scheme = call.split("://").at(1) ?? call;
    after_scheme.split("/").at(0) ?? after_scheme
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
    let rows: string[][] = [];
    let level = "ok";
    let hint = "";
    for (let t in tables) {
        for (let r in t.rows) {
            let call = cell(r.at(0) ?? null);
            let kind = cell(r.at(1) ?? null);
            let calls = cell(r.at(2) ?? null);
            let failed = cell(r.at(3) ?? null);
            let avg_s = cell(r.at(4) ?? null);
            let max_s = cell(r.at(5) ?? null);
            let n = number_cell(r.at(2) ?? null);
            let n_failed = number_cell(r.at(3) ?? null);
            let n_max = number_cell(r.at(5) ?? null);
            let server = server_of(call);
            rows.push([server, kind, calls, failed, avg_s, max_s]);
            if (n_failed > 0.1 * n) {
                if (level != "bad") {
                    level = "bad";
                    hint
                        = `${server} failed ${failed} of ${calls} ${kind} calls: read that server's log`;
                }
            } else if (n_max > 600.0) {
                if (level == "ok") {
                    level = "warn";
                    hint
                        = `${server} ${kind} calls took up to ${max_s}s: rounds queue for its one slot; raise [providers.NAME] parallel or move a stage off it`;
                }
            }
        }
    }
    Insight {
        key: "model_calls",
        title: "Model calls",
        about: "every call a round made to a model server, by server and round kind",
        columns: ["server", "kind", "calls", "failed", "avg s", "max s"],
        rows: rows,
        level: level,
        hint: hint,
    }
}

/// 2. What rounds came to, by kind and model.
function round_outcomes(tallies: root.supervisor.FTally[]) -> Insight throws never {
    let round_logs: root.supervisor.FRoundRec[] = [];
    for (let tally in tallies) {
        for (let log in tally.round_log) {
            round_logs.push(log);
        }
    }

    let grouped: map<string, root.supervisor.FRoundRec[]> = {};
    for (let log in round_logs) {
        let key = `${log.kind}|${log.model}`;
        let logs = grouped.get(key) ?? [];
        logs.push(log);
        grouped.set(key, logs);
    }

    let rows: string[][] = [];
    let level = "ok";
    let hint = "";
    for (let key in grouped.keys()) {
        let logs = grouped.get(key) ?? [];
        let kind = key.split("|").at(0) ?? "";
        let model = key.split("|").at(1) ?? "";
        let rounds = logs.length();
        let good = 0;
        let sent_back = 0;
        let held = 0;
        let reasons: map<string, int> = {};
        for (let log in logs) {
            let is_good = (kind == "work" && (log.outcome == "gate_passed" || log.outcome == "rebutted"))
                || (kind == "review" && log.outcome == "approved")
                || (kind == "research" && log.outcome == "brief_written");
            let is_held = log.outcome == "infra" || log.outcome == "round_lost";
            if (is_good) {
                good = good + 1;
            } else if (is_held) {
                held = held + 1;
            } else {
                sent_back = sent_back + 1;
                let c = reasons.get(log.outcome) ?? 0;
                reasons.set(log.outcome, c + 1);
            }
        }
        let top_reason = "";
        let top_count = 0;
        for (let reason in reasons.keys()) {
            let c = reasons.get(reason) ?? 0;
            if (c > top_count) {
                top_count = c;
                top_reason = reason;
            }
        }
        rows.push([kind, model, `${rounds}`, `${good}`, `${sent_back}`, `${held}`, top_reason]);
        if (level != "warn" && rounds >= 4 && good * 2 < rounds) {
            level = "warn";
            hint
                = `${model}'s ${kind} rounds came good ${good} of ${rounds}; most went back as ${top_reason}`;
        }
    }

    let sort_key = (row: string[]) -> int {
        let n = baml.json.decode<int>(row[2] ?? "0") catch_all (e) {
            _ => 0
        };
        -n
    };
    rows.sort_by_key(sort_key);

    Insight {
        key: "round_outcomes",
        title: "Round outcomes",
        about: "what each kind of round came to, by model",
        columns: ["kind", "model", "rounds", "good", "sent back", "held", "top reason"],
        rows: rows,
        level: level,
        hint: hint,
    }
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
    // Collect all round logs from tallies
    let round_logs: root.supervisor.FRoundRec[] = [];
    for (let tally in tallies) {
        for (let log in tally.round_log) {
            round_logs.push(log);
        }
    }

    // Group round logs by provider
    let grouped: map<string, root.supervisor.FRoundRec[]> = {};
    for (let log in round_logs) {
        let provider = root.supervisor.provider_of(log.model);
        let logs = grouped.get(provider) ?? [];
        logs.push(log);
        grouped.set(provider, logs);
    }

    // Calculate stats for each provider
    let rows: string[][] = [];
    let level = "ok";
    for (let provider in grouped.keys()) {
        let logs = grouped.get(provider) ?? [];
        let rounds = logs.length();
        let waits: int[] = [];
        for (let log in logs) {
            waits.push(log.waited_s);
        }
        waits.sort();
        let median_wait = if (waits.length() == 0) {
            0
        } else if (waits.length() % 2 == 1) {
            waits[waits.length() / 2]
        } else {
            let left = waits[waits.length() / 2 - 1];
            let right = waits[waits.length() / 2];
            (left + right) / 2
        };
        let longest_wait = if (waits.length() == 0) {
            0
        } else {
            waits[waits.length() - 1]
        };

        // Format wait times
        let median_str = format_wait(median_wait);
        let longest_str = format_wait(longest_wait);

        rows.push([provider, `${rounds}`, median_str, longest_str]);

        // Check if median wait is over 600 seconds
        if (median_wait > 600) {
            level = "warn";
        }
    }

    // Sort by median wait, longest first
    let sort_key = (row: string[]) -> int {
        let wait_str = row[2];
        let wait_seconds = parse_wait(wait_str);
        -wait_seconds
    };
    rows.sort_by_key(sort_key);

    // Build hint if there's a warning
    let hint = if (level == "warn") {
        let warn_row = rows[0] ?? [];
        let median = warn_row[2] ?? "0s";
        let server = warn_row[0] ?? "unknown";
        `beads wait a median ${median} for ${server}: raise its [providers.${server}] parallel or move a stage off it`
    } else {
        ""
    };

    Insight {
        key: "lane_wait",
        title: "Waiting for a lane",
        about: "from a bead being ready to its round starting, by model server",
        columns: ["server", "rounds", "median wait", "longest wait"],
        rows: rows,
        level: level,
        hint: hint,
    }
}

/// Format wait time as "45s", "12m" or "2h05"
function format_wait(seconds: int) -> string throws never {
    if (seconds < 90) {
        `${seconds}s`
    } else if (seconds < 90 * 60) {
        let minutes = (seconds + 30) / 60; // Round to nearest minute
        `${minutes}m`
    } else {
        let hours = seconds / 3600;
        let mins = (seconds % 3600 + 30) / 60; // Round to nearest minute
        `${hours}h${mins}`
    }
}

/// Parse formatted wait time back to seconds
function parse_wait(formatted: string) -> int throws never {
    if (formatted.ends_with("s")) {
        baml.json.decode<int>(formatted.slice(0, formatted.length() - 1)) catch_all (e) {
            _ => 0
        }
    } else if (formatted.ends_with("m")) {
        let mins = baml.json.decode<int>(formatted.slice(0, formatted.length() - 1)) catch_all (e) {
            _ => 0
        };
        mins * 60
    } else {
        // Format is "hmm" or "hhmm"
        let parts = formatted.split("h");
        if (parts.length() == 2) {
            let hours = baml.json.decode<int>(parts[0] ?? "") catch_all (e) {
                _ => 0
            };
            let mins = baml.json.decode<int>(parts[1] ?? "") catch_all (e) {
                _ => 0
            };
            hours * 3600 + mins * 60
        } else {
            // Try to parse as "hhmm"
            let num = baml.json.decode<int>(formatted) catch_all (e) {
                _ => 0
            };
            let hours = num / 100;
            let mins = num % 100;
            hours * 3600 + mins * 60
        }
    }
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

test "model calls name the server and flag slow ones" {
    let table = TraceTable {
        columns: [],
        rows: [["POST http://192.168.1.51:8100/v1/chat/completions", "review", 6, 0, 202.2, 895.2]],
    };
    let i = model_calls([table]);
    let row = i.rows.at(0) ?? [];
    assert.equal(row.at(0) ?? "", "192.168.1.51:8100");
    assert.equal(row.at(1) ?? "", "review");
    assert.equal(row.at(2) ?? "", "6");
    assert.equal(i.level, "warn");
    assert.is_true(i.hint.includes("895.2"))
}

test "lane wait is the median by server" {
    let i = lane_wait(
        [
            root.supervisor.tally_of(
                "t-1",
                [
                    root.supervisor.round_rec("review", "acbox/reviewer", "approved", waited_s = 60),
                    root.supervisor.round_rec(
                        "review",
                        "acbox/reviewer",
                        "approved",
                        waited_s = 900,
                    ),
                    root.supervisor.round_rec(
                        "review",
                        "acbox/reviewer",
                        "approved",
                        waited_s = 1200,
                    ),
                    root.supervisor.round_rec("work", "devbox/coder", "gate_passed", waited_s = 30),
                ],
            ),
        ],
    );
    assert.equal(i.rows.length(), 2);
    assert.equal(i.rows[0][0], "acbox");
    assert.equal(i.rows[0][1], "3");
    assert.equal(i.rows[0][2], "15m");
    assert.equal(i.rows[0][3], "20m");
    assert.equal(i.rows[1][0], "devbox");
    assert.equal(i.rows[1][1], "1");
    assert.equal(i.rows[1][2], "30s");
    assert.equal(i.rows[1][3], "30s");
    assert.equal(i.level, "warn");
}

test "round outcomes count good, sent back and held by model" {
    let i = round_outcomes(
        [
            root.supervisor.tally_of(
                "t-1",
                [
                    root.supervisor.round_rec("work", "devbox/coder", "gate_passed"),
                    root.supervisor.round_rec("work", "devbox/coder", "no_commit"),
                    root.supervisor.round_rec("work", "devbox/coder", "no_commit"),
                    root.supervisor.round_rec("work", "devbox/coder", "infra"),
                ],
            ),
        ],
    );
    assert.equal(i.rows.length(), 1);
    assert.equal(i.rows[0], ["work", "devbox/coder", "4", "1", "2", "1", "no_commit"]);
    assert.equal(i.level, "warn");
}
