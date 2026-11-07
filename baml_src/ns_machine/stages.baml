// Which model works a bead at a given failure count.

class Stage {
    name: string,
    worker: string,
    reviewer: string,
    attempts: int,
}

enum OnExhaust {
    Park,
    Repeat,
}

enum MergeMode {
    Auto,
    Pipeline,
    Manual,
    External,
}

class Policy {
    stages: Stage[],
    on_exhaust: OnExhaust,
    merge: MergeMode,
    /// A second model looks at a researcher's BLOCKED before the bead parks.
    second_opinion: bool,
    /// Push and stop short of a PR, for you to publish.
    ask_before_pr: bool,
    /// The researcher model; empty means the worker round runs without a brief.
    research: string,
}

function total_attempts(stages: Stage[]) -> int throws never {
    stages.reduce(
        (sum, s) -> {
            sum + s.attempts
        },
        0,
    )
}

/// The stage at `failures`, or null when they are used up and the policy parks.
function stage_for(policy: Policy, failures: int) -> Stage? throws never {
    let total = total_attempts(policy.stages);
    if (total == 0) {
        return null;
    }
    let n = failures;
    if (n >= total) {
        if (policy.on_exhaust == OnExhaust.Park) {
            return null;
        }
        n = n % total;
    }
    let count = 0;
    for (let s in policy.stages) {
        count = count + s.attempts;
        if (n < count) {
            return s;
        }
    }
    null
}

/// The lowest failure count that lands on the last stage.
function last_stage_start(policy: Policy) -> int throws never {
    let last = policy.stages.at(policy.stages.length() - 1);
    if let s: Stage = last {
        total_attempts(policy.stages) - s.attempts
    } else {
        0
    }
}

function on_last_stage(policy: Policy, failures: int) -> bool throws never {
    failures >= last_stage_start(policy)
}

/// The next failure count whose stage has a different worker, or null if none does.
function next_worker_at(policy: Policy, failures: int) -> int? throws never {
    let current = stage_for(policy, failures)?.worker;
    let n = failures + 1;
    let total = total_attempts(policy.stages);
    while (n < total) {
        let s = stage_for(policy, n);
        if (s?.worker != current) {
            return n;
        }
        n = n + 1;
    }
    null
}
