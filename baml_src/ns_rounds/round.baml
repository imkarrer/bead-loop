// One round, in its own process. It reads a spec, works in the bead's worktree, and leaves
// a result file; the supervisor reads that on a later tick. The round may outlive the
// supervisor that started it.

class RoundSpec {
    id: string,
    kind: root.world.RoundKind,
    model: string,
    /// The model server, from `[providers.NAME]`; empty takes the environment.
    base_url: string,
    /// The pre-check model and its server; empty is no pre-check.
    precheck: string,
    precheck_url: string,
    dir: string,
    base: string,
    bead: string,
    gate: string,
    /// What the last round was sent back with.
    note: string,
    /// The worker's last report, for the reviewer.
    report: string,
    /// Where the worker writes that report, and the reviewer reads it.
    report_file: string,
    /// The researcher's brief, for the worker.
    brief: string,
    /// Where the researcher writes that brief, and the worker reads it.
    brief_file: string,
    log_file: string,
    result_file: string,
}

const MAX_STEPS: int = 80;
/// The diff is in the prompt. A 40-step budget was enough for the 30B to search 38 times
/// and never return a verdict (t-1 e2e, 7 Nov).
const REVIEW_STEPS: int = 12;

function infra_harness(words: string) -> root.machine.Event throws never {
    root.machine.Infra { kind: "infra", what: root.machine.Trouble.Harness, words: words }
}

function git_head(dir: string) -> string throws never {
    let out = baml.sys.run("git", args = ["rev-parse", "HEAD"], cwd = dir, capture_output = true) catch_all (e) {
        _ => {
            return "";
        },
    };
    out.stdout.to_string().trim()
}

class GateRun {
    ok: bool,
    output: string,
}

/// The gate decides, whatever the model reported.
function run_gate(dir: string, gate: string) -> GateRun throws never {
    if (gate.length() == 0) {
        return GateRun { ok: true, output: "" };
    }
    let out = baml.sys.shell(
        gate,
        cwd = dir,
        capture_output = true,
        timeout = baml.time.Duration.from_seconds(3600),
    ) catch_all (e) {
        _ => {
            return GateRun { ok: false, output: `the gate did not finish: ${e}` };
        },
    };
    GateRun {
        ok: out.exit_code == 0,
        output: root.tools.tail(out.stdout.to_string() + out.stderr.to_string()),
    }
}

/// What a worker's report and the commits it left add up to. Pure, so it is tested alone.
function work_outcome(
    report: root.agents.Report,
    before: string,
    after: string,
) -> root.machine.Event? throws never {
    if (report.outcome == "blocked") {
        return root.machine.WorkerBlocked { kind: "worker_blocked", line: `BLOCKED: ${report.summary}` };
    }
    if (before == after) {
        return root.machine.NoCommit { kind: "no_commit" };
    }
    null
}

/// The worker's report as the reviewer sees it.
function report_text(report: root.agents.Report) -> string throws never {
    `${report.outcome}: ${report.summary}`
}

function save_report(path: string, report: root.agents.Report) -> void throws never {
    if (path.length() == 0) {
        return;
    }
    let _ = baml.fs.write(path, report_text(report)) catch_all (e) {
        _ => null,
    };
}

function load_report(path: string) -> string throws never {
    baml.fs.read(path) catch_all (e) {
        _ => "",
    }
}

function event_log(path: string) -> (ai.events.Event) -> void throws never {
    let out = baml.fs.open(path, "a") catch_all (e) {
        _ => {
            return (x) -> {};
        },
    };
    (x) -> {
        let line = baml.json.stringify(x) catch_all (e) {
            _ => "{}",
        };
        let _ = out.write(line + "\n") catch_all (e) {
            _ => 0,
        };
    }
}

function run_worker(spec: RoundSpec, task: string) -> root.agents.Report {
    if (root.agents.uses_claude(spec.model)) {
        return root.agents.WorkOnClaude(task);
    }
    root.runner.run_compacted(
        root.agents.client_for(spec.model, spec.base_url),
        root.agents.Work@spec(task),
        MAX_STEPS,
        event_log(spec.log_file),
    )
}

function failed_session(e: unknown) -> root.machine.Event throws never {
    match (e) {
        let x: ai.errors.StepBudgetExceeded => {
            root.machine.RoundTimedOut { kind: "round_timed_out" }
        },
        let x: ai.errors.ParseFailed => {
            root.machine.WorkerCrashed { kind: "worker_crashed", words: "its report did not parse" }
        },
        let x: ai.errors.FinishReasonError => {
            root.machine.WorkerCrashed { kind: "worker_crashed", words: "its reply was cut off" }
        },
        let x: ai.errors.ToolFailedError => {
            root.machine.WorkerCrashed { kind: "worker_crashed", words: x.message }
        },
        _ => infra_harness(`${e}`),
    }
}

function worker_task(spec: RoundSpec) -> string throws never {
    let body = spec.bead;
    if (spec.brief.length() > 0) {
        body = `${body}\n\n<research>\n${spec.brief}\n</research>`;
    }
    if (spec.note.length() > 0) {
        body = `${body}\n\nThe last round was sent back:\n${spec.note}`;
    }
    body
}

/// The gate passed: the pre-check, when there is one, may still send it back.
function passed(spec: RoundSpec, done: root.machine.Event) -> root.machine.Event[] throws never {
    let sent = precheck(spec);
    if let e: root.machine.Event = sent {
        [done, e]
    } else {
        [done, root.machine.GatePassed { kind: "gate_passed" }]
    }
}

/// SEND BACK is the only verdict that counts: a model that fails to answer is not the
/// worker's fault, so the round goes on to review.
function precheck(spec: RoundSpec) -> root.machine.Event? throws never {
    if (spec.precheck.length() == 0) {
        return null;
    }
    let diff = baml.sys.run(
        "git",
        args = ["diff", `${spec.base}...HEAD`],
        cwd = spec.dir,
        capture_output = true,
    ) catch_all (e) {
        _ => {
            return null;
        },
    };
    let agent = ai.Agent.new(
        client = root.agents.client_for(spec.precheck, spec.precheck_url),
        max_steps = 2,
        on_event = event_log(spec.log_file),
    ) catch_all (e) {
        _ => {
            return null;
        },
    };
    let v = agent.run(
        root.agents.Precheck@spec(spec.bead, load_report(spec.report_file), diff.stdout.to_string()),
    ) catch_all (e) {
        _ => {
            return null;
        },
    };
    precheck_outcome(v.value)
}

function precheck_outcome(v: root.agents.PrecheckVerdict) -> root.machine.Event? throws never {
    if (v.send_back) {
        root.machine.PrecheckSentBack { kind: "precheck_sent_back", block: v.block }
    } else {
        null
    }
}

function work_round(spec: RoundSpec) -> root.machine.Event[] throws never {
    let before = git_head(spec.dir);
    let task = worker_task(spec);
    let failed: root.machine.Event? = null;
    let report = run_worker(spec, task) catch_all (e) {
        _ => {
            let out: root.machine.Event[] = [failed_session(e)];
            return out;
        },
    };
    save_report(spec.report_file, report);
    let after = git_head(spec.dir);
    let stop = work_outcome(report, before, after);
    if let event: root.machine.Event = stop {
        return [event];
    }
    let done: root.machine.Event = root.machine.Committed { kind: "committed", sha: after };
    let first = run_gate(spec.dir, spec.gate);
    if (first.ok) {
        return passed(spec, done);
    }
    //# One fix round, with the gate's output
    let fix = `${spec.bead}\n\nYour commit is on this branch, but the gate failed. Fix it and commit:\n${first.output}`;
    let fixed = run_worker(spec, fix) catch_all (e) {
        _ => {
            let out: root.machine.Event[] = [done, failed_session(e)];
            return out;
        },
    };
    save_report(spec.report_file, fixed);
    let second = run_gate(spec.dir, spec.gate);
    if (second.ok) {
        passed(spec, done)
    } else {
        [done, root.machine.GateFailedTwice { kind: "gate_failed_twice", errors: second.output }]
    }
}

function review_text(v: root.agents.Verdict) -> string throws never {
    if let w: root.agents.WorkOrder = v.work_order {
        `REJECT: ${v.reason}\n\nFor the worker:\n- What is wrong: ${w.what_is_wrong}\n- Why it fails the bead: ${w.why_it_fails}\n- What to do: ${w.what_to_do}\n- How to check: ${w.how_to_check}\n- Leave alone: ${w.leave_alone}`
    } else {
        `REJECT: ${v.reason}`
    }
}

/// A verdict as an event. Pure, so it is tested alone.
function review_outcome(v: root.agents.Verdict) -> root.machine.Event throws never {
    if (v.decision == root.agents.Decision.Approve) {
        root.machine.Approved { kind: "approved" }
    } else {
        root.machine.Rejected {
            kind: "rejected",
            line: `REJECT: ${v.reason}`,
            text: review_text(v),
        }
    }
}

function run_reviewer(spec: RoundSpec, diff: string) -> root.agents.Verdict {
    if (root.agents.uses_claude(spec.model)) {
        return root.agents.ReviewOnClaude(spec.bead, spec.report, diff);
    }
    let agent = ai.Agent.new(
        client = root.agents.client_for(spec.model, spec.base_url),
        max_steps = REVIEW_STEPS,
        on_event = event_log(spec.log_file),
    );
    agent.run(root.agents.Review@spec(spec.bead, spec.report, diff)).value
}

/// No verdict is "nothing from the model": held, not charged. state-machine.md, and the
/// t-1 e2e that charged a worker because the reviewer ran out of steps.
function review_failed_session(e: unknown) -> root.machine.Event throws never {
    match (e) {
        let x: ai.errors.StepBudgetExceeded => {
            infra_harness("the reviewer returned no verdict: out of steps")
        },
        let x: ai.errors.ParseFailed => {
            infra_harness("the reviewer returned no verdict: it did not parse")
        },
        _ => infra_harness(`${e}`),
    }
}

function review_round(spec: RoundSpec) -> root.machine.Event[] throws never {
    let diff = baml.sys.run(
        "git",
        args = ["diff", `${spec.base}...HEAD`],
        cwd = spec.dir,
        capture_output = true,
    ) catch_all (e) {
        _ => {
            let out: root.machine.Event[] = [infra_harness(`git diff failed: ${e}`)];
            return out;
        },
    };
    let verdict = run_reviewer(spec, diff.stdout.to_string()) catch_all (e) {
        _ => {
            let out: root.machine.Event[] = [review_failed_session(e)];
            return out;
        },
    };
    [review_outcome(verdict)]
}

function run_researcher(spec: RoundSpec) -> root.agents.ResearchResult {
    let agent = ai.Agent.new(
        client = root.agents.client_for(spec.model, spec.base_url),
        max_steps = 40,
        on_event = event_log(spec.log_file),
    );
    agent.run(root.agents.Research@spec(spec.bead)).value
}

function research_round(spec: RoundSpec) -> root.machine.Event[] throws never {
    let result = run_researcher(spec) catch_all (e) {
        _ => {
            let out: root.machine.Event[] = [infra_harness(`${e}`)];
            return out;
        },
    };
    if (result.outcome == "brief" && spec.brief_file.length() > 0) {
        let _ = baml.fs.write(spec.brief_file, root.agents.brief_text(result)) catch_all (e) {
            _ => null,
        };
    }
    let second = spec.note.starts_with("BLOCKED:");
    [root.agents.research_outcome(result, second)]
}

/// The process entry: `bead-agent round --spec_file PATH`, started in the worktree, since
/// the tools take paths relative to it.
function round(spec_file: string) -> string {
    let spec = baml.json.decode<RoundSpec>(baml.fs.read(spec_file));
    let events = if (spec.kind == root.world.RoundKind.Work) {
        work_round(spec)
    } else {
        if (spec.kind == root.world.RoundKind.Review) {
            review_round(spec)
        } else {
            research_round(spec)
        }
    };
    let done = root.world.RoundDone { id: spec.id, kind: spec.kind, events: events };
    let _ = baml.fs.write(spec.result_file, baml.json.stringify(done));
    spec.result_file
}

function report_of(outcome: "done" | "blocked") -> root.agents.Report throws never {
    root.agents.Report { outcome: outcome, summary: "s" }
}

test "a blocked report is the worker's line" {
    let e = work_outcome(report_of("blocked"), "a", "b");
    assert.is_type<root.machine.WorkerBlocked>(e);
}

test "done with no new commit is no commit, whatever it claims" {
    assert.is_type<root.machine.NoCommit>(work_outcome(report_of("done"), "a", "a"));
}

test "done with a commit goes on to the gate" {
    assert.equal(work_outcome(report_of("done"), "a", "b"), null)
}

test "the gate decides, not the report" {
    assert.is_true(!run_gate("/tmp", "exit 3").ok);
    assert.is_true(run_gate("/tmp", "exit 0").ok);
    assert.contains(run_gate("/tmp", "echo broke; exit 1").output, "broke")
}

test "an approval" {
    let v = root.agents.Verdict { decision: root.agents.Decision.Approve, reason: "r", work_order: null };
    assert.is_type<root.machine.Approved>(review_outcome(v));
}

function spec_of(brief: string, note: string) -> RoundSpec throws never {
    RoundSpec {
        id: "t-1",
        kind: root.world.RoundKind.Work,
        model: "m",
        base_url: "",
        precheck: "",
        precheck_url: "",
        dir: ".",
        base: "main",
        bead: "BEAD",
        gate: "",
        note: note,
        report: "",
        report_file: "",
        brief: brief,
        brief_file: "",
        log_file: "",
        result_file: "",
    }
}

test "the worker prompt carries the brief and the send-back" {
    assert.contains(worker_task(spec_of("the brief", "")), "<research>");
    assert.contains(worker_task(spec_of("the brief", "")), "the brief");
    assert.contains(worker_task(spec_of("", "REJECT: x")), "sent back")
}

test "the worker's report is what the reviewer reads" {
    assert.equal(report_text(report_of("done")), "done: s");
    let p = "/tmp/bead-loop-report.txt";
    save_report(p, report_of("done"));
    assert.equal(load_report(p), "done: s");
    assert.equal(load_report("/tmp/bead-loop-report-missing.txt"), "");
    let _ = baml.fs.remove(p);
}

test "a rejection carries the whole work order" {
    let w = root.agents.WorkOrder {
        what_is_wrong: "w",
        why_it_fails: "y",
        what_to_do: "d",
        how_to_check: "c",
        leave_alone: "l",
    };
    let v = root.agents.Verdict { decision: root.agents.Decision.Reject, reason: "r", work_order: w };
    let e = review_outcome(v);
    if let x: root.machine.Rejected = e {
        assert.equal(x.line, "REJECT: r");
        assert.contains(x.text, "- What to do: d");
    } else {
        assert.is_true(false);
    }
}

test "only a SEND BACK from the pre-check counts" {
    let sent = precheck_outcome(root.agents.PrecheckVerdict { send_back: true, block: "SEND BACK: 2" });
    assert.is_type<root.machine.PrecheckSentBack>(sent);
    assert.equal(
        precheck_outcome(root.agents.PrecheckVerdict { send_back: false, block: "PASS" }) == null,
        true,
    )
}

test "no pre-check model is no pre-check" {
    assert.equal(precheck(spec_of("", "")) == null, true)
}
