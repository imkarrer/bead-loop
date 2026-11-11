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
    /// When the round was launched, in unix seconds; 0 when not known.
    started: int?,
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
    let quoted = gate.split("'").join("'\\''");
    let out = baml.sys.shell(
        root.tools.unconfined(`sh -c '${quoted}'`),
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
/// What the reviewer reads of the gate: its command, whether it passed, and the end of its
/// output. web-2ad.3's reviewer rejected a sort as "causing the template to error" while
/// the gate had just built the site; it never saw that.
function gate_text(gate: string, run: GateRun) -> string throws never {
    if (gate.length() == 0) {
        return "no gate is configured for this repo: CI is the gate";
    }
    let verdict = if (run.ok) {
        "passed"
    } else {
        "failed"
    };
    let out = if (run.output.length() > 0) {
        run.output
    } else {
        "(no output)"
    };
    `$ ${gate}\n${verdict}\n${root.tools.tail(out)}`
}

function gate_file(spec: RoundSpec) -> string throws never {
    `${spec.report_file}.gate`
}

function save_gate(spec: RoundSpec, run: GateRun) -> void throws never {
    if (spec.report_file.length() == 0) {
        return;
    }
    let _ = baml.fs.write(gate_file(spec), gate_text(spec.gate, run)) catch_all (e) {
        _ => null,
    };
}

function gate_of(spec: RoundSpec) -> string throws never {
    let text = baml.fs.read(gate_file(spec)) catch_all (e) {
        _ => "",
    };
    if (text.length() > 0) {
        text
    } else if (spec.gate.length() == 0) {
        "no gate is configured for this repo: CI is the gate"
    } else {
        "the gate passed (its output was not kept)"
    }
}

/// Whether the branch has commits the base does not.
function ahead_of_base(dir: string, base: string) -> bool throws never {
    let out = baml.sys.run(
        "git",
        args = ["rev-list", "--count", `${base}..HEAD`],
        cwd = dir,
        capture_output = true,
    ) catch_all (e) {
        _ => {
            return false;
        },
    };
    out.exit_code == 0
        && out.stdout.to_string().trim() != "0"
        && out.stdout.to_string().trim().length() > 0
}

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
        let agent = ai.Agent.new(
            client = root.agents.claude_client(spec.model, spec.dir, spec.log_file, true),
            max_steps = 2,
        );
        return agent.run(root.agents.WorkOnClaude@spec(task)).value;
    }
    root.runner.run_compacted(
        root.agents.client_for(spec.model, spec.base_url),
        root.agents.Work@spec(task),
        MAX_STEPS,
        event_log(spec.log_file),
    )
}

/// What a failed session said: the error, and for a Claude round what the CLI itself
/// said, since "exited with code 1" alone names no cause.
function session_said(spec: RoundSpec, e: unknown) -> string throws never {
    let said = if (root.agents.uses_claude(spec.model)) {
        root.agents.claude_said(spec.log_file)
    } else {
        ""
    };
    if (said.length() == 0) {
        `${e}`
    } else {
        `${e}: ${said}`
    }
}

function failed_session(spec: RoundSpec, e: unknown) -> root.machine.Event throws never {
    let said = session_said(spec, e);
    let limit = limit_hit(said);
    if let held: root.machine.Event = limit {
        return held;
    }
    match (e) {
        let x: ai.errors.StepBudgetExceeded => {
            // Said as what it is: web-2ad.3's second round "timed out" in 3.5 minutes.
            root.machine.WorkerCrashed {
                kind: "worker_crashed",
                words: `it ran out of its ${MAX_STEPS} steps`,
            }
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
        _ => infra_harness(said),
    }
}

function worker_task(spec: RoundSpec) -> string throws never {
    let body = `${spec.bead}\n\nThe base branch is ${spec.base}.`;
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
            let out: root.machine.Event[] = [failed_session(spec, e)];
            return out;
        },
    };
    save_report(spec.report_file, report);
    if (report.outcome == "done") {
        commit_left(spec.dir, spec.id, report.summary);
    }
    let after = git_head(spec.dir);
    // Done, and nothing new to commit, on a branch that already holds work: the worker says
    // the work stands. If the gate agrees, that is a rebuttal of the last REJECT, not a
    // missing commit.
    if (report.outcome == "done" && before == after && ahead_of_base(spec.dir, spec.base)) {
        let check = run_gate(spec.dir, spec.gate);
        save_gate(spec, check);
        if (check.ok) {
            return [root.machine.Rebutted { kind: "rebutted", text: report.summary }];
        }
    }
    let stop = work_outcome(report, before, after);
    if let event: root.machine.Event = stop {
        return [event];
    }
    let done: root.machine.Event = root.machine.Committed { kind: "committed", sha: after };
    let first = run_gate(spec.dir, spec.gate);
    save_gate(spec, first);
    if (first.ok) {
        return passed(spec, done);
    }
    //# One fix round, with the gate's output
    let fix = `${spec.bead}\n\nYour commit is on this branch, but the gate failed. Fix it and commit:\n${first.output}`;
    let fixed = run_worker(spec, fix) catch_all (e) {
        _ => {
            let out: root.machine.Event[] = [done, failed_session(spec, e)];
            return out;
        },
    };
    save_report(spec.report_file, fixed);
    if (fixed.outcome == "done") {
        commit_left(spec.dir, spec.id, fixed.summary);
    }
    let second = run_gate(spec.dir, spec.gate);
    save_gate(spec, second);
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
        let agent = ai.Agent.new(
            client = root.agents.claude_client(spec.model, spec.dir, spec.log_file, false),
            max_steps = 2,
        );
        return agent
            .run(root.agents.ReviewOnClaude@spec(spec.bead, spec.report, gate_of(spec), diff))
            .value;
    }
    let agent = ai.Agent.new(
        client = root.agents.client_for(spec.model, spec.base_url),
        max_steps = REVIEW_STEPS,
        on_event = event_log(spec.log_file),
    );
    agent.run(root.agents.Review@spec(spec.bead, spec.report, gate_of(spec), diff)).value
}

/// No verdict is "nothing from the model": held, not charged. state-machine.md, and the
/// t-1 e2e that charged a worker because the reviewer ran out of steps.
function review_failed_session(spec: RoundSpec, e: unknown) -> root.machine.Event throws never {
    let said = session_said(spec, e);
    let limit = limit_hit(said);
    if let held: root.machine.Event = limit {
        return held;
    }
    match (e) {
        let x: ai.errors.StepBudgetExceeded => {
            infra_harness("the reviewer returned no verdict: out of steps")
        },
        let x: ai.errors.ParseFailed => {
            infra_harness("the reviewer returned no verdict: it did not parse")
        },
        _ => infra_harness(said),
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
            let out: root.machine.Event[] = [review_failed_session(spec, e)];
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

/// A researcher that answers nothing usable is no brief: the worker goes without one, as
/// after a timeout. Holding it researched the bead again and again, and each answer was a
/// good brief that only failed to parse (web-2ad.2 and .3, 8 Nov: `line` was required).
/// A usage limit still holds, and anything else is the harness's.
function research_failed(e: unknown) -> root.machine.Event throws never {
    let limit = limit_hit(`${e}`);
    if let held: root.machine.Event = limit {
        return held;
    }
    match (e) {
        let x: ai.errors.ParseFailed => {
            root.machine.BriefWritten { kind: "brief_written", overruled: false, text: "" }
        },
        let x: ai.errors.StepBudgetExceeded => {
            root.machine.BriefWritten { kind: "brief_written", overruled: false, text: "" }
        },
        _ => infra_harness(`${e}`),
    }
}

function research_round(spec: RoundSpec) -> root.machine.Event[] throws never {
    let result = run_researcher(spec) catch_all (e) {
        _ => {
            let out: root.machine.Event[] = [research_failed(e)];
            return out;
        },
    };
    let second = spec.note.starts_with("BLOCKED:");
    let read = root.tools.probes();
    let event = unread_block(root.agents.research_outcome(result, second), read);
    if (result.outcome == "brief" && spec.brief_file.length() > 0 && read > 0) {
        let _ = baml.fs.write(spec.brief_file, root.agents.brief_text(result)) catch_all (e) {
            _ => null,
        };
    }
    [event]
}

/// Any answer from a researcher that read nothing is no brief: the worker goes, and a
/// worker's own BLOCKED needs the file and line, and a brief written on guesswork
/// restates the bead under <research> instead of helping. bl-dze.6's researcher (8 Nov)
/// answered "insights.baml: no `lane_wait` function found" on its first call, with no
/// read, of a file that defines it; its second opinion did the same, and the bead
/// parked. 39 of 45 research rounds on 8-11 Nov made no tool call at all.
/// `read` is the round's reads, searches and listings: a researcher never edits, so the
/// probe count is all of them.
function unread_block(e: root.machine.Event, read: int) -> root.machine.Event throws never {
    if (read == 0) {
        root.machine.BriefWritten { kind: "brief_written", overruled: false, text: "" }
    } else {
        e
    }
}

test "a research BLOCK with nothing read is no brief, and one after reading stands" {
    let blocked = root.machine.ResearchBlocked {
        kind: "research_blocked",
        line: "BLOCKED: no lane_wait",
        second_opinion: false,
    };
    let unread = unread_block(blocked, 0);
    if let b: root.machine.BriefWritten = unread {
        assert.equal(b.text, "");
    } else {
        assert.is_true(false);
    }
    assert.is_type<root.machine.ResearchBlocked>(unread_block(blocked, 3));
    let brief = root.machine.BriefWritten { kind: "brief_written", overruled: false, text: "x" };
    assert.is_type<root.machine.BriefWritten>(unread_block(brief, 0));
}

test "a brief with nothing read is no brief" {
    let brief = root.machine.BriefWritten { kind: "brief_written", overruled: false, text: "x" };
    let unread = unread_block(brief, 0);
    if let b: root.machine.BriefWritten = unread {
        assert.equal(b.text, "");
    } else {
        assert.is_true(false);
    }
    assert.is_type<root.machine.BriefWritten>(unread_block(brief, 3));
    if let kept: root.machine.BriefWritten = unread_block(brief, 3) {
        assert.equal(kept.text, "x");
    } else {
        assert.is_true(false);
    }
}

/// The process entry: `bead-agent round --spec_file PATH`, started in the worktree, since
/// the tools take paths relative to it.
function round(spec_file: string) -> string {
    let spec = baml.json.decode<RoundSpec>(baml.fs.read(spec_file));
    // The probe count is this round's alone: from zero, and gone when it ends.
    root.tools.edited();
    // The read record is this round's alone too: a research or review round reuses a
    // pid, and a worker's revision session reuses this one (bl-gc1.4).
    root.tools.forget_reads();
    let events = if (spec.kind == root.world.RoundKind.Work) {
        work_round(spec)
    } else {
        if (spec.kind == root.world.RoundKind.Review) {
            review_round(spec)
        } else {
            research_round(spec)
        }
    };
    root.tools.forget_probes();
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
        started: null,
    }
}

test "the worker prompt carries the brief and the send-back" {
    assert.contains(worker_task(spec_of("the brief", "")), "<research>");
    assert.contains(worker_task(spec_of("the brief", "")), "the brief");
    assert.contains(worker_task(spec_of("", "REJECT: x")), "sent back")
}

test "the worker's report is what the reviewer reads" {
    assert.equal(report_text(report_of("done")), "done: s");
    let p = root.tools.scratch("report.txt");
    save_report(p, report_of("done"));
    assert.equal(load_report(p), "done: s");
    assert.equal(load_report(root.tools.scratch("report-missing.txt")), "");
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

/// Claude's own "You've hit your session limit · resets 7:40am (UTC)": the provider's
/// limit, not the model's failure, however many turns the session spent first (bl-boc.5).
/// It holds the bead, and the supervisor holds every claude round while it lasts.
function limit_hit(said: string) -> root.machine.Event? throws never {
    if ((said.includes("hit your") && said.includes("limit")) || said.includes("usage limit reached")) {
        root.machine.Infra {
            kind: "infra",
            what: root.machine.Trouble.SignedOut,
            words: `usage limit on claude: ${root.tools.tail(said)}`,
        }
    } else {
        null
    }
}

test "a usage limit is the provider's, not the worker's" {
    let e = limit_hit("claude: You've hit your session limit · resets 7:40am (UTC)");
    assert.is_type<root.machine.Infra>(e);
    assert.is_type<root.machine.Infra>(limit_hit("Claude AI usage limit reached|1794120000"));
    assert.equal(limit_hit("there is a limit on how much I can help") == null, true)
}

/// A worker that reports done with its change still uncommitted has done the work and
/// skipped the last step (the 30B on fp-p1c, 8 Nov: wrote the test, ran it, reported done,
/// never committed). The round commits for it; the gate still decides whether it is good.
/// Nothing is committed for a blocked report, nor when the tree is clean.
function commit_left(dir: string, id: string, summary: string) -> void throws never {
    let status = baml.sys.run("git", args = ["status", "--porcelain"], cwd = dir, capture_output = true) catch_all (e) {
        _ => {
            return;
        },
    };
    if (status.stdout.to_string().trim().length() == 0) {
        return;
    }
    let line = (summary.split("\n").at(0) ?? "").trim();
    let subject = if (line.length() > 72) {
        line.slice(0, 72)
    } else {
        line
    };
    let _ = baml.sys.run("git", args = ["add", "-A"], cwd = dir, capture_output = true) catch_all (e) {
        _ => null,
    };
    let _ = baml.sys.run(
        "git",
        args = ["commit", "-q", "-m", `${id}: ${subject}`],
        cwd = dir,
        capture_output = true,
    ) catch_all (e) {
        _ => null,
    };
}

test "a done report's uncommitted change is committed for it" {
    let dir = root.tools.scratch("commit-left");
    let _ = baml.sys.run("rm", args = ["-rf", dir]);
    let _ = baml.sys.run("mkdir", args = ["-p", dir]);
    let _ = baml.sys.run("git", args = ["init", "-q"], cwd = dir);
    let _ = baml.sys.run(
        "git",
        args = ["-c", "user.email=t@t", "-c", "user.name=t", "commit", "-q", "--allow-empty", "-m", "base"],
        cwd = dir,
    );
    let before = git_head(dir);
    commit_left(dir, "t-1", "nothing to commit");
    assert.equal(git_head(dir), before);
    baml.fs.write(`${dir}/a.txt`, "a");
    let _ = baml.sys.run("git", args = ["config", "user.email", "t@t"], cwd = dir);
    let _ = baml.sys.run("git", args = ["config", "user.name", "t"], cwd = dir);
    commit_left(dir, "t-1", "wrote a.txt\nmore");
    assert.equal(git_head(dir) != before, true);
    let msg = baml.sys.run("git", args = ["log", "-1", "--format=%s"], cwd = dir, capture_output = true);
    assert.equal(msg.stdout.to_string().trim(), "t-1: wrote a.txt")
}

test "a researcher's answer that will not parse is no brief, not a hold" {
    let e = research_failed(ai.errors.ParseFailed { provider: "openai-generic", raw_output: "{" });
    if let b: root.machine.BriefWritten = e {
        assert.equal(b.text, "");
    } else {
        assert.is_true(false);
    }
}

test "the reviewer reads the gate: its command, its verdict and its output" {
    let t = gate_text("scripts/check.sh", GateRun { ok: true, output: "check: PASS" });
    assert.equal(t, "$ scripts/check.sh\npassed\ncheck: PASS");
    assert.contains(gate_text("", GateRun { ok: true, output: "" }), "CI is the gate")
}

test "a branch ahead of its base is told from one at it" {
    let dir = root.tools.scratch("ahead");
    let _ = baml.sys.run("rm", args = ["-rf", dir]);
    let _ = baml.sys.run("mkdir", args = ["-p", dir]);
    let _ = baml.sys.run("git", args = ["init", "-q", "-b", "main"], cwd = dir);
    let _ = baml.sys.run(
        "git",
        args = ["-c", "user.email=t@t", "-c", "user.name=t", "commit", "-q", "--allow-empty", "-m", "base"],
        cwd = dir,
    );
    assert.equal(ahead_of_base(dir, "main"), false);
    let _ = baml.sys.run(
        "git",
        args = ["-c", "user.email=t@t", "-c", "user.name=t", "commit", "-q", "--allow-empty", "-m", "work"],
        cwd = dir,
    );
    assert.equal(ahead_of_base(dir, "main~1"), true);
    let _ = baml.sys.run("rm", args = ["-rf", dir]);
}
