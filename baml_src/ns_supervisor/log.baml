// The event log: each bead's history, and the only state the loop keeps of its own.

interface Log {
    function append(self, id: string, event: root.machine.Event) -> void throws never;
    function ids(self) -> string[] throws never;
    function load(self, id: string) -> root.machine.Event[] throws never;
    /// The bead's log with the second each event was written (0 when not known).
    function timed(self, id: string) -> TimedEvent[] throws never;
    /// A file the rounds leave beside the log: `report`, `brief`, `park.md`; "" if none.
    function side(self, id: string, name: string) -> string throws never;
    /// The bead's round logs, newest first.
    function round_logs(self, id: string) -> string[] throws never;
    /// What the page shows: STATE/view.json.
    function put_view(self, text: string) -> void throws never;
}

class Entry {
    id: string,
    event: root.machine.Event,
}

class MemoryLog {
    entries: Entry[],
    view: string,

    function new() -> MemoryLog throws never {
        MemoryLog { entries: [], view: "" }
    }

    implements Log {
        function append(self, id: string, event: root.machine.Event) -> void throws never {
            self.entries.push(Entry { id: id, event: event });
        }
        function ids(self) -> string[] throws never {
            let out: string[] = [];
            for (let e in self.entries) {
                if (!out.includes(e.id)) {
                    out.push(e.id);
                }
            }
            out
        }
        function load(self, id: string) -> root.machine.Event[] throws never {
            self.entries
                .filter((e) -> {
                    e.id == id
                })
                .map((e) -> {
                    e.event
                })
        }
        function timed(self, id: string) -> TimedEvent[] throws never {
            self.load(id).map((e) -> {
                TimedEvent { at: 0, event: e }
            })
        }
        function side(self, id: string, name: string) -> string throws never {
            ""
        }
        function round_logs(self, id: string) -> string[] throws never {
            let none: string[] = [];
            none
        }
        function put_view(self, text: string) -> void throws never {
            self.view = text;
        }
    }
}
