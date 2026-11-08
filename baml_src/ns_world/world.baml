// Everything outside the loop, behind one interface: bd, git, gh and the rounds. Production,
// the bench and the tests differ only in which World they hold, so what is measured is what
// ships. Every method throws Infra, because the world failing is never a bead's failure.

class Ticket {
    id: string,
    title: string,
    description: string,
    acceptance: string,
}

enum RoundKind {
    Work,
    Review,
    Research,
}

/// A round that has ended, and what it found.
class RoundDone {
    id: string,
    kind: RoundKind,
    events: root.machine.Event[],
}

class RoundRunning {
    id: string,
    kind: RoundKind,
    /// The model the round runs on: its provider is the lane it holds.
    model: string,
}

/// An open `bead/ID` PR, whoever opened it.
class Adoptable {
    id: string,
    url: string,
    /// Opened by the account the loop acts as.
    own: bool,
}

/// Something you told the loop about one bead: an answer, a reopen, an escalation.
class Mail {
    id: string,
    event: root.machine.Event,
}

interface World {
    /// Beads with the loop's label it may work: those with no open blocker, and those it
    /// already carries (bd status in_progress).
    function tickets(self) -> Ticket[] throws root.machine.Infra;
    function prepare_worktree(self, id: string, resume: bool) -> void throws root.machine.Infra;
    function remove_branch(self, id: string) -> void throws root.machine.Infra;
    function start_round(
        self,
        id: string,
        kind: RoundKind,
        model: string,
        note: string,
    ) -> void throws root.machine.Infra;
    /// The rounds running now. They outlive the supervisor, so a restart asks.
    function running(self) -> RoundRunning[] throws root.machine.Infra;
    /// The rounds that ended and have not been taken yet. Each is handed over once.
    function take_finished(self) -> RoundDone[] throws root.machine.Infra;
    /// What changed on a PR, as events.
    function observe_pr(
        self,
        id: string,
        pr: string,
    ) -> root.machine.Event[] throws root.machine.Infra;
    function push_and_open_pr(self, id: string) -> root.machine.PrOpened throws root.machine.Infra;
    /// Push the branch, open no PR, and say where one would be opened.
    function push_branch(self, id: string) -> root.machine.BranchPushed throws root.machine.Infra;
    function merge_pr(self, id: string) -> void throws root.machine.Infra;
    function update_branch(self, id: string) -> void throws root.machine.Infra;
    function relabel(self, id: string) -> void throws root.machine.Infra;
    function delete_remote_branch(self, id: string) -> void throws root.machine.Infra;
    function note(self, id: string, text: string) -> void throws root.machine.Infra;
    /// The bead's status in bd: what the loop is doing with it, kept on the bead itself.
    function set_status(self, id: string, status: string) -> void throws root.machine.Infra;
    function close_bead(self, id: string, url: string?) -> void throws root.machine.Infra;
    function write_park_brief(self, id: string, because: string) -> void throws root.machine.Infra;
    /// Open PRs on `bead/*` branches, which the loop takes into its merge queue.
    function adoptable(self) -> Adoptable[] throws root.machine.Infra;
    /// What you told the loop since the last tick. Each is handed over once.
    function inbox(self) -> Mail[] throws root.machine.Infra;
}
