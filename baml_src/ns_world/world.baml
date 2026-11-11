// Everything outside the loop, behind one interface: bd, git, gh and the rounds. Production,
// the bench and the tests differ only in which World they hold, so what is measured is what
// ships. Every method throws Infra, because the world failing is never a bead's failure.

class Ticket {
    id: string,
    title: string,
    description: string,
    acceptance: string,
    /// The stage a `stage:NAME` label starts it on; null without one.
    stage: string?,
}

/// The stage a bead's labels name with `stage:NAME`, or null.
function stage_label(labels: string[]) -> string? throws never {
    for (let l in labels) {
        if (l.starts_with("stage:")) {
            return l.split("stage:").at(1);
        }
    }
    null
}

test "a stage label names its stage" {
    assert.equal(stage_label(["delegate:local", "stage:frontier"]) ?? "", "frontier");
    assert.equal(stage_label(["delegate:local"]) == null, true)
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
    /// When it started (0: not known), and the file its tool calls go to.
    since: int,
    log: string,
}

/// An open `bead/ID` PR, whoever opened it.
class Adoptable {
    id: string,
    url: string,
    /// Opened by the account the loop acts as.
    own: bool,
    /// Already merged, not open: the bead was landed outside the loop.
    merged: bool?,
}

/// Something you told the loop about one bead: an event for its machine (an answer, a
/// reopen, ready for PR), or an order the supervisor carries out on it (abort its round,
/// note it in bd). The page and `tell` only ever write mail; the supervisor acts.
class Mail {
    id: string,
    event: root.machine.Event?,
    order: Order?,
}

class AbortOrder {
    kind: "abort",
}

class NoteOrder {
    kind: "note",
    text: string,
}

type Order = AbortOrder | NoteOrder;

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
    /// With a title, the PR you asked for; else the bead's, in pr_style. `was`, if set,
    /// is checked before the push: closed or merged while its round ran returns that
    /// instead of opening a second PR.
    function push_and_open_pr(
        self,
        id: string,
        title: string?,
        body: string?,
        was: string?,
    ) -> root.machine.Event throws root.machine.Infra;
    /// Push the branch, open no PR, and say where one would be opened.
    function push_branch(self, id: string) -> root.machine.BranchPushed throws root.machine.Infra;
    function merge_pr(self, id: string) -> void throws root.machine.Infra;
    function update_branch(self, id: string) -> void throws root.machine.Infra;
    function relabel(self, id: string) -> void throws root.machine.Infra;
    function delete_remote_branch(self, id: string) -> void throws root.machine.Infra;
    function note(self, id: string, text: string) -> void throws root.machine.Infra;
    /// Stop the bead's round and everything it started; the loop finds it lost and starts
    /// it again, uncharged.
    function abort(self, id: string) -> void throws never;
    /// The bead as bd has it, for one `bd ready` no longer lists (parked, in the merge
    /// queue); empty fields when bd does not know it.
    function ticket_of(self, id: string) -> Ticket throws never;
    /// The bead in bd says where it is: its status (empty: as it is), and its place as a
    /// `loop:*` label, `drop` taken off and `label` put on (either empty: none).
    function mark(
        self,
        id: string,
        status: string,
        drop: string,
        label: string,
    ) -> void throws root.machine.Infra;
    function close_bead(self, id: string, url: string?) -> void throws root.machine.Infra;
    function write_park_brief(self, id: string, because: string) -> void throws root.machine.Infra;
    /// Open PRs on `bead/*` branches, which the loop takes into its merge queue.
    function adoptable(self) -> Adoptable[] throws root.machine.Infra;
    /// Whether mail is waiting, without taking it: the loop wakes for it.
    function mail_waiting(self) -> bool throws never;
    /// What you told the loop since the last tick. Each is handed over once.
    function inbox(self) -> Mail[] throws root.machine.Infra;
}
