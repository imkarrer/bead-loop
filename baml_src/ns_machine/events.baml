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
    postmortem: string?,
}

class RoundTimedOut {
    kind: "round_timed_out",
}

class WorkerCrashed {
    kind: "worker_crashed",
    words: string,
    postmortem: string?,
}

class GateFailedTwice {
    kind: "gate_failed_twice",
    errors: string,
    postmortem: string?,
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
    text: string,
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
    /// Opened by the loop's own account, by this loop before a restart or by the Rust
    /// loop before the cutover: then it is the loop's own, counted and sent back like one.
    own: bool?,
}

/// Review comments on the loop's own PR from someone else, newer than the last acted on.
class Feedback {
    kind: "feedback",
    text: string,
    /// The newest comment's time, so the same comments are acted on once.
    at: string,
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

/// The bead carries a `stage:NAME` label: it starts on that stage, as the Rust loop's did.
class StageLabelled {
    kind: "stage_labelled",
    stage: string,
}

class Escalated {
    kind: "escalated",
}

/// You: the work is done; push the branch and stop at a PR for you to open. A parked bead
/// whose branch holds work (pw-xl2, 8 Nov: committed and gated, then a false BLOCKED).
class Published {
    kind: "published",
}

/// You: open the PR for a pushed branch, with this title and body (the page's Open PR).
class PrRequested {
    kind: "pr_requested",
    title: string,
    body: string,
}

/// The worker found nothing to change: the branch's commit already does what the bead asks,
/// the rejection was wrong, and the gate still passes. Its report is the rebuttal. Back to
/// review, uncharged, with the last stage's reviewer as the tiebreak (web-2ad.3, 8 Nov:
/// Claude reverted a regression the false REJECT had caused, found its work already
/// committed, and was charged "no commit").
class Rebutted {
    kind: "rebutted",
    text: string,
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
    | Feedback
    | Answered
    | Reopened
    | Escalated
    | StageLabelled
    | Published
    | Rebutted
    | PrRequested
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

class WriteParkBrief {
    because: string,
}

/// Push and open the PR; with a title, the one you gave, else the bead's. `was` is the
/// PR the bead had, if any: checked just before the push, so a round that closes while
/// it ran does not get a second one.
class PushAndOpenPr {
    title: string?,
    body: string?,
    was: string?,
}

/// open_pr = "ask": push the branch and stop short of a PR, for you to open.
class PushBranch {
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
    | WriteParkBrief
    | PushAndOpenPr
    | PushBranch
    | MergePr
    | UpdateBranch
    | Relabel
    | CloseBead
    | Refuse;

class Step {
    bead: Bead,
    effects: Effect[],
}
