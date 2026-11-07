// Reading a PR. Pure, so it is tested on literal gh output.

class RollupItem {
    conclusion: string?,
    state: string?,
    status: string?,
    name: string?,
    context: string?,
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

test "gh's extra fields are ignored" {
    let v = view_of(
        `{"url":"u","state":"OPEN","mergedAt":null,"statusCheckRollup":[{"__typename":"CheckRun","conclusion":"SUCCESS","detailsUrl":"x"}]}`,
    );
    assert.is_type<root.machine.ChecksGreen>(pr_events(v).at(0));
}
