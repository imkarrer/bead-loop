// The event log: each bead's history, and the only state the loop keeps of its own.

interface Log {
    function append(self, id: string, event: root.machine.Event) -> void throws never;
    function ids(self) -> string[] throws never;
    function load(self, id: string) -> root.machine.Event[] throws never;
}

class Entry {
    id: string,
    event: root.machine.Event,
}

class MemoryLog {
    entries: Entry[],

    function new() -> MemoryLog throws never {
        MemoryLog { entries: [] }
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
            self.entries.filter((e) -> { e.id == id }).map((e) -> { e.event })
        }
    }
}
