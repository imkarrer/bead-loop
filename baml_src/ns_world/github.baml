// Reading a PR. Pure, so it is tested on literal gh output.

class RollupItem {
    conclusion: string?,
    state: string?,
    status: string?,
    name: string?,
    context: string?,
    description: string?,
}

class PrView {
    url: string,
    state: string,
    mergeable: string?,
    mergeStateStatus: string?,
    headRefOid: string?,
    statusCheckRollup: RollupItem[]?,
}

const RED_STATES: string[] = ["FAILURE", "ERROR", "CANCELLED", "TIMED_OUT", "ACTION_REQUIRED", "STARTUP_FAILURE"];
const GREEN_STATES: string[] = ["SUCCESS", "NEUTRAL", "SKIPPED"];

function check_state(c: RollupItem) -> string throws never {
    c.conclusion ?? c.state ?? c.status ?? ""
}

function pr_events(view: PrView) -> root.machine.Event[] throws never {
    if (view.state == "MERGED") {
        return [root.machine.PrMerged { kind: "pr_merged", url: view.url }];
    }
    if (view.state == "CLOSED") {
        return [root.machine.PrClosed { kind: "pr_closed", url: view.url }];
    }
    if (view.mergeable == "CONFLICTING") {
        return [root.machine.Conflicting { kind: "conflicting" }];
    }
    let checks = view.statusCheckRollup ?? [];
    let red = checks.filter((c) -> {
        RED_STATES.includes(check_state(c))
    });
    if (red.length() > 0) {
        let names = red
            .map((c) -> {
                c.name ?? c.context ?? "a check"
            })
            .join(", ");
        return [root.machine.ChecksRed { kind: "checks_red", checks: names, head: view.headRefOid ?? "" }];
    }
    if (
        checks.length() == 0
            || !checks.every((c) -> {
                GREEN_STATES.includes(check_state(c))
            })
    ) {
        return [];
    }
    if (view.mergeStateStatus == "BEHIND") {
        [root.machine.Behind { kind: "behind" }]
    } else {
        [root.machine.ChecksGreen { kind: "checks_green" }]
    }
}

function view_of(text: string) -> PrView {
    baml.json.decode<PrView>(text)
}

/// How long the watcher has already seen this PR in each situation, in seconds.
/// The caller keeps the stamps; this function only classifies.
class PrClock {
    /// auto, pipeline, manual, or external.
    merge: string,
    green_for: int,
    quiet_for: int,
    red_for: int,
    /// Failing checks the base requires. Empty and `required_known` means none are.
    required_failing: string[],
    required_known: bool,
    /// The head a killed run was already re-run on.
    rerun_head: string,
}

const PIPELINE_TIMEOUT: int = 1800;
const CI_TIMEOUT: int = 7200;
const NOCHECK_GRACE: int = 300;

class CheckRow {
    name: string?,
    state: string?,
    description: string?,
    bucket: string?,
}

class Required {
    known: bool,
    failing: string[],
    killed: bool,
}

function is_skipped_build(c: RollupItem) -> bool throws never {
    let text = `${c.name ?? ""} ${c.context ?? ""} ${c.description ?? ""}`;
    text.includes(" skipped") || text.ends_with("skipped")
}

/// A skipped build is not a result. If every check is one, the PR is still pending.
function without_skipped(view: PrView) -> PrView throws never {
    let all = view.statusCheckRollup ?? [];
    let kept = all.filter((c) -> {
        !is_skipped_build(c)
    });
    let rollup = if (all.length() > 0 && kept.length() == 0) {
        [
            RollupItem {
                conclusion: null,
                state: null,
                status: "IN_PROGRESS",
                name: null,
                context: null,
                description: null,
            },
        ]
    } else {
        kept
    };
    PrView {
        url: view.url,
        state: view.state,
        mergeable: view.mergeable,
        mergeStateStatus: view.mergeStateStatus,
        headRefOid: view.headRefOid,
        statusCheckRollup: rollup,
    }
}

function is_failing_check(c: CheckRow) -> bool throws never {
    let s = c.state ?? "";
    RED_STATES.includes(s) || s == "fail" || s == "failure" || (c.bucket ?? "") == "fail"
}

/// `gh pr checks --required --json`. Text that does not parse means gh refused,
/// which includes a base with no required checks: the caller must not treat that
/// as "nothing required is failing".
function required_of(text: string) -> Required throws never {
    let rows = baml.json.decode<CheckRow[]>(text) catch_all (e) {
        _ => {
            return Required { known: false, failing: [], killed: false };
        },
    };
    let failing = rows.filter((c) -> {
        is_failing_check(c)
    });
    let lines = failing.map((c) -> {
        let name = c.name ?? "a check";
        let why = c.description ?? "";
        if (why.length() == 0) {
            name
        } else {
            `${name}: ${why}`
        }
    });
    let killed = failing.length() > 0
        && failing.every((c) -> {
            (c.description ?? "").includes("(exit status -1)")
        });
    Required { known: true, failing: lines, killed: killed }
}

function waited(why: string) -> root.machine.Event throws never {
    root.machine.WaitedTooLong { kind: "waited_too_long", why: why }
}

/// The merge watcher. `pr_events` is the snapshot; the clock says how long it has
/// looked like that, which is what turns a green pipeline PR into a hold.
function watch_pr(view: PrView, clock: PrClock) -> root.machine.Event[] throws never {
    let seen = without_skipped(view);
    let base = pr_events(seen);
    let first = base.at(0);
    if (
        first is root.machine.PrMerged
            || first is root.machine.PrClosed
            || first is root.machine.Conflicting
    ) {
        return base;
    }
    if (first is root.machine.ChecksGreen) {
        if (clock.merge == "pipeline" && clock.green_for >= PIPELINE_TIMEOUT) {
            return [
                waited(
                    `${seen.url} has been green for ${clock.green_for / 60} min and the pipeline has not merged it`,
                ),
            ];
        }
        return base;
    }
    if (first is root.machine.Behind) {
        return base;
    }
    if (first is root.machine.ChecksRed) {
        if (clock.required_known && clock.required_failing.length() == 0) {
            let quiet: root.machine.Event[] = [root.machine.RedNotRequired { kind: "red_not_required" }];
            if (clock.merge != "external" && clock.red_for >= CI_TIMEOUT) {
                quiet.push(
                    waited(
                        `${seen.url} has been red for ${clock.red_for / 3600} h only in checks the base does not require`,
                    ),
                );
            }
            return quiet;
        }
        let head = seen.headRefOid ?? "";
        if (
            clock.merge == "pipeline"
                && clock.required_known
                && required_killed(clock)
                && head.length() > 0
                && head != clock.rerun_head
        ) {
            let names = clock.required_failing.join(", ");
            return [root.machine.RedKilled { kind: "red_killed", checks: names, head: head }];
        }
        return base;
    }
    let checks = seen.statusCheckRollup ?? [];
    if (checks.length() == 0 && clock.quiet_for >= NOCHECK_GRACE) {
        return [waited(`${seen.url} has had no checks for ${clock.quiet_for / 60} min`)];
    }
    if (checks.length() > 0 && clock.quiet_for >= CI_TIMEOUT) {
        return [waited(`${seen.url} has been pending for ${clock.quiet_for / 3600} h`)];
    }
    []
}

function required_killed(clock: PrClock) -> bool throws never {
    clock.required_failing.length() > 0
        && clock.required_failing.every((line) -> {
            line.includes("(exit status -1)")
        })
}

test "a merged PR" {
    assert.is_type<root.machine.PrMerged>(pr_events(view_of(`{"url":"u","state":"MERGED"}`)).at(0));
}

test "a closed PR" {
    assert.is_type<root.machine.PrClosed>(pr_events(view_of(`{"url":"u","state":"CLOSED"}`)).at(0));
}

test "a conflict comes before the checks" {
    let v = view_of(
        `{"url":"u","state":"OPEN","mergeable":"CONFLICTING","statusCheckRollup":[{"conclusion":"FAILURE"}]}`,
    );
    assert.is_type<root.machine.Conflicting>(pr_events(v).at(0));
}

test "one red check is red, and names itself" {
    let v = view_of(
        `{"url":"u","state":"OPEN","headRefOid":"h","statusCheckRollup":[{"conclusion":"SUCCESS"},{"name":"gate","conclusion":"FAILURE"}]}`,
    );
    let e = pr_events(v).at(0);
    if let r: root.machine.ChecksRed = e {
        assert.equal(r.checks, "gate");
        assert.equal(r.head, "h");
    } else {
        assert.is_true(false);
    }
}

test "a commit status counts by its state" {
    let v = view_of(`{"url":"u","state":"OPEN","statusCheckRollup":[{"context":"ci","state":"ERROR"}]}`);
    assert.is_type<root.machine.ChecksRed>(pr_events(v).at(0));
}

test "pending is nothing yet" {
    let v = view_of(
        `{"url":"u","state":"OPEN","statusCheckRollup":[{"conclusion":"SUCCESS"},{"status":"IN_PROGRESS"}]}`,
    );
    assert.equal(pr_events(v).length(), 0)
}

test "no checks is nothing yet" {
    assert.equal(pr_events(view_of(`{"url":"u","state":"OPEN"}`)).length(), 0)
}

test "all green" {
    let v = view_of(
        `{"url":"u","state":"OPEN","mergeStateStatus":"CLEAN","statusCheckRollup":[{"conclusion":"SUCCESS"},{"conclusion":"SKIPPED"}]}`,
    );
    assert.is_type<root.machine.ChecksGreen>(pr_events(v).at(0));
}

test "green but behind" {
    let v = view_of(
        `{"url":"u","state":"OPEN","mergeStateStatus":"BEHIND","statusCheckRollup":[{"conclusion":"SUCCESS"}]}`,
    );
    assert.is_type<root.machine.Behind>(pr_events(v).at(0));
}

function clock_of(merge: string) -> PrClock throws never {
    PrClock {
        merge: merge,
        green_for: 0,
        quiet_for: 0,
        red_for: 0,
        required_failing: [],
        required_known: false,
        rerun_head: "",
    }
}

test "a green pipeline PR is held once it has waited half an hour" {
    let v = view_of(
        `{"url":"u","state":"OPEN","mergeStateStatus":"CLEAN","statusCheckRollup":[{"conclusion":"SUCCESS"}]}`,
    );
    let young = clock_of("pipeline");
    assert.is_type<root.machine.ChecksGreen>(watch_pr(v, young).at(0));
    let old = clock_of("pipeline");
    old.green_for = 1800;
    assert.is_type<root.machine.WaitedTooLong>(watch_pr(v, old).at(0));
}

test "no checks for five minutes is a hold, and sooner is pending" {
    let v = view_of(`{"url":"u","state":"OPEN"}`);
    let soon = clock_of("pipeline");
    soon.quiet_for = 60;
    assert.equal(watch_pr(v, soon).length(), 0);
    let late = clock_of("pipeline");
    late.quiet_for = 300;
    assert.is_type<root.machine.WaitedTooLong>(watch_pr(v, late).at(0));
}

test "red only in checks the base does not require is not charged" {
    let v = view_of(
        `{"url":"u","state":"OPEN","headRefOid":"h","statusCheckRollup":[{"name":"lint","conclusion":"FAILURE"}]}`,
    );
    let c = clock_of("pipeline");
    c.required_known = true;
    assert.is_type<root.machine.RedNotRequired>(watch_pr(v, c).at(0));
}

test "a killed required check is re-run once" {
    let v = view_of(
        `{"url":"u","state":"OPEN","headRefOid":"h","statusCheckRollup":[{"name":"gate","conclusion":"FAILURE"}]}`,
    );
    let c = clock_of("pipeline");
    c.required_known = true;
    c.required_failing = ["gate: timed out (exit status -1)"];
    assert.is_type<root.machine.RedKilled>(watch_pr(v, c).at(0));
    c.rerun_head = "h";
    assert.is_type<root.machine.ChecksRed>(watch_pr(v, c).at(0));
}

test "a skipped build is not a red result" {
    let v = view_of(
        `{"url":"u","state":"OPEN","statusCheckRollup":[{"context":"ci","state":"ERROR","description":"Build #9 skipped"}]}`,
    );
    assert.equal(watch_pr(v, clock_of("pipeline")).length(), 0)
}

test "required checks that do not parse are unknown" {
    let r = required_of("not json");
    assert.is_true(!r.known);
    let ok = required_of(`[{"name":"gate","state":"FAILURE","description":"boom (exit status -1)"}]`);
    assert.is_true(ok.known);
    assert.is_true(ok.killed);
    assert.equal(ok.failing.length(), 1)
}

test "gh's extra fields are ignored" {
    let v = view_of(
        `{"url":"u","state":"OPEN","mergedAt":null,"statusCheckRollup":[{"__typename":"CheckRun","conclusion":"SUCCESS","detailsUrl":"x"}]}`,
    );
    assert.is_type<root.machine.ChecksGreen>(pr_events(v).at(0));
}
