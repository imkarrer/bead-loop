// What a bead is, as the loop knows it. A bead has exactly one Place, so "one place"
// (docs/state-machine.md) needs no filter: it cannot be in two queues.
//
// Every persisted variant carries a literal `kind`. JSON drops the class name, and with
// `kind` a baml.json.decode<T> gets the right variant back.

class Ready {
    kind: "ready",
}

class Researching {
    kind: "researching",
}

class Working {
    kind: "working",
    committed: bool,
}

class InReview {
    kind: "in_review",
}

class Reviewing {
    kind: "reviewing",
}

class Publishable {
    kind: "publishable",
    compare_url: string,
}

class Merging {
    kind: "merging",
    pr: string,
    adopted: bool,
}

class Parked {
    kind: "parked",
    question: string,
}

class Closed {
    kind: "closed",
    url: string?,
}

type Place = Ready
    | Researching
    | Working
    | InReview
    | Reviewing
    | Publishable
    | Merging
    | Parked
    | Closed;

/// Something outside the loop must change. Orthogonal to Place: a held bead stays in its
/// queue and nothing is charged.
class Hold {
    what: string,
    words: string,
}

/// What the next worker round is told to do with the branch.
enum Order {
    Fresh,
    FixInPlace,
    Rebase,
    /// Act on the review comments on the open PR.
    Feedback,
}

class Bead {
    id: string,
    place: Place,
    failures: int,
    rounds: int,
    hold: Hold?,
    /// A branch survives from an earlier round; the next one resumes it.
    kept: bool,
    order: Order,
    /// An open PR the next push updates: sent back from the merge queue.
    pr: string?,
    /// The first REJECT line of the last rejection, to catch the same one twice.
    last_reject: string?,
    /// The head CI was last charged for, and the head already re-run once.
    charged_head: string?,
    rerun_head: string?,
    /// What the last send-back said, for the next round to act on.
    last_note: string?,
    /// The researcher's brief; absent means research has not run yet.
    brief: string?,
    /// The researcher's BLOCKED, while a second opinion on it waits its turn in the research
    /// queue. It goes through the queue like any research round: started from a step's
    /// effect, mid-tick, it was found "lost" a second later (web-2ad.3, 8 Nov).
    first_block: string?,
    /// Harness holds in a row with nothing else between: a broken harness is retried, not
    /// forever (pw-xl2, 8 Nov: the same CLI error, picked again every three minutes all night).
    harness_streak: int,

    function new(id: string) -> Bead throws never {
        Bead {
            id: id,
            place: Ready { kind: "ready" },
            failures: 0,
            rounds: 0,
            hold: null,
            kept: false,
            order: Order.Fresh,
            pr: null,
            last_reject: null,
            charged_head: null,
            rerun_head: null,
            last_note: null,
            brief: null,
            first_block: null,
            harness_streak: 0,
        }
    }

    function copy(self) -> Bead throws never {
        Bead {
            id: self.id,
            place: self.place,
            failures: self.failures,
            rounds: self.rounds,
            hold: self.hold,
            kept: self.kept,
            order: self.order,
            pr: self.pr,
            last_reject: self.last_reject,
            charged_head: self.charged_head,
            rerun_head: self.rerun_head,
            last_note: self.last_note,
            brief: self.brief,
            first_block: self.first_block,
            harness_streak: self.harness_streak,
        }
    }

    function at(self, place: Place) -> Bead throws never {
        let n = self.copy();
        n.place = place;
        n
    }
}
