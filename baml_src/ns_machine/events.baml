// What can happen to a bead. The event log is these, one per line, and a bead's state is
// a fold over them.

// What a model did. The only events that can charge a failure: `charge` takes this union,
// so an infrastructure event passed to it does not compile.
class WorkerBlocked {
    kind: "worker_blocked",
    line: string,
}

class NoCommit {
    kind: "no_commit",
}

class RoundTimedOut {
    kind: "round_timed_out",
}

class WorkerCrashed {
    kind: "worker_crashed",
    words: string,
}

class GateFailedTwice {
    kind: "gate_failed_twice",
    errors: string,
}

class DiffProblems {
    kind: "diff_problems",
    problems: string,
}

class PrecheckSentBack {
    kind: "precheck_sent_back",
    block: string,
}

class Rejected {
    kind: "rejected",
    line: string,
    text: string,
}

class ReviewerCrashed {
    kind: "reviewer_crashed",
    words: string,
}

class ChecksRed {
    kind: "checks_red",
    checks: string,
    head: string,
}

type ModelOutcome = WorkerBlocked
    | NoCommit
    | RoundTimedOut
    | WorkerCrashed
    | GateFailedTwice
    | DiffProblems
    | PrecheckSentBack
    | Rejected
    | ReviewerCrashed
    | ChecksRed;

// What the world did. Never a failure: the round did not happen.
enum Trouble {
    Setup,
    Git,
    Harness,
    Push,
    Gh,
    Bd,
    SignedOut,
    NoSuchTarget,
    MergeRefused,
}

class Infra {
    kind: "infra",
    what: Trouble,
    words: string,
}

// Research.
class ResearchPicked {
    kind: "research_picked",
}

class BriefWritten {
    kind: "brief_written",
    overruled: bool,
}

class ResearchBlocked {
    kind: "research_blocked",
    line: string,
    second_opinion: bool,
}

// The dev lane.
class Picked {
    kind: "picked",
}

class Committed {
    kind: "committed",
    sha: string,
}

class GatePassed {
    kind: "gate_passed",
}

// The review lane.
class ReviewPicked {
    kind: "review_picked",
}

class Approved {
    kind: "approved",
}

class PrOpened {
    kind: "pr_opened",
    url: string,
    head: string,
}

class BranchPushed {
    kind: "branch_pushed",
    compare_url: string,
}

// The merge queue, as observed.
class PrMerged {
    kind: "pr_merged",
    url: string,
}

class PrClosed {
    kind: "pr_closed",
    url: string,
}

class Conflicting {
    kind: "conflicting",
}

class RedKilled {
    kind: "red_killed",
    checks: string,
    head: string,
}

class RedNotRequired {
    kind: "red_not_required",
}

class ChecksGreen {
    kind: "checks_green",
}

class Behind {
    kind: "behind",
}

class WaitedTooLong {
    kind: "waited_too_long",
    why: string,
}

class PrAdopted {
    kind: "pr_adopted",
    url: string,
}

class MergedOutside {
    kind: "merged_outside",
    url: string,
}

// You.
class Answered {
    kind: "answered",
    text: string,
}

class Reopened {
    kind: "reopened",
}

class Escalated {
    kind: "escalated",
}

// The loop.
class RoundLost {
    kind: "round_lost",
}

class HoldCleared {
    kind: "hold_cleared",
}

type Event = ModelOutcome
    | Infra
    | ResearchPicked
    | BriefWritten
    | ResearchBlocked
    | Picked
    | Committed
    | GatePassed
    | ReviewPicked
    | Approved
    | PrOpened
    | BranchPushed
    | PrMerged
    | PrClosed
    | Conflicting
    | RedKilled
    | RedNotRequired
    | ChecksGreen
    | Behind
    | WaitedTooLong
    | PrAdopted
    | MergedOutside
    | Answered
    | Reopened
    | Escalated
    | RoundLost
    | HoldCleared;

// What the shell must do after a step. Each is safe to repeat: a crash can land between
// doing one and recording that it was done.
class Note {
    text: string,
}

class PrepareWorktree {
    resume: bool,
}

class RemoveBranch {
}

class DeleteRemoteBranch {
}

class SecondOpinion {
    first_reply: string,
}

class WriteParkBrief {
    because: string,
}

class PushAndOpenPr {
}

class MergePr {
}

class UpdateBranch {
}

class Relabel {
}

class CloseBead {
    url: string?,
}

class Refuse {
    why: string,
}

type Effect = Note
    | PrepareWorktree
    | RemoveBranch
    | DeleteRemoteBranch
    | SecondOpinion
    | WriteParkBrief
    | PushAndOpenPr
    | MergePr
    | UpdateBranch
    | Relabel
    | CloseBead
    | Refuse;

class Step {
    bead: Bead,
    effects: Effect[],
}
