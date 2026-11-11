// The log on disk: one append-only file per bead. A line that does not parse is skipped and
// said, because a crash can leave a half-written last line.

class FileLog {
    state: string,

    function path(self, id: string) -> string throws never {
        `${self.state}/beads/${id}/events.jsonl`
    }

    implements Log {
        function append(self, id: string, event: root.machine.Event) -> void throws never {
            let dir = `${self.state}/beads/${id}`;
            let _ = baml.sys.run("mkdir", args = ["-p", dir]) catch_all (e) {
                _ => null,
            };
            let json = baml.json.stringify(event) catch_all (e) {
                _ => {
                    self.say("error", `cannot encode an event for ${id}: ${e}`);
                    return;
                },
            };
            let line = stamped(json, root.supervisor.unix_seconds());
            let wrote = write_line(self.path(id), line) catch_all (e) {
                _ => {
                    self.say("error", `cannot append to ${id}'s log: ${e}`);
                },
            };
        }

        function ids(self) -> string[] throws never {
            let out = baml.sys.run("ls", args = [`${self.state}/beads`], capture_output = true) catch_all (e) {
                _ => {
                    let none: string[] = [];
                    return none;
                },
            };
            // Only a directory with a log is a bead of this loop's.
            out.stdout.to_string().split("\n").filter((f) -> {
                f.length() > 0
                    && (
                        baml.fs.exists(self.path(f)) catch_all (e) {
                            _ => false,
                        }
                    )
            })
        }

        function load(self, id: string) -> root.machine.Event[] throws never {
            let events: root.machine.Event[] = [];
            let text = baml.fs.read(self.path(id)) catch_all (e) {
                _ => {
                    return events;
                },
            };
            for (let line in text.split("\n")) {
                if (line.length() > 0) {
                    let parsed = decode_line(line) catch_all (e) {
                        _ => {
                            self.say("warn", `skipping a bad line in ${id}'s log: ${line}`);
                            null
                        },
                    };
                    if let event: root.machine.Event = parsed {
                        events.push(event);
                    }
                }
            }
            events
        }

        function timed(self, id: string) -> TimedEvent[] throws never {
            timed_events(self.state, id)
        }

        function side(self, id: string, name: string) -> string throws never {
            if (name.includes("/") || id.includes("/")) {
                return "";
            }
            baml.fs.read(`${self.state}/beads/${id}/${name}`) catch_all (e) {
                _ => "",
            }
        }

        function round_logs(self, id: string) -> string[] throws never {
            let out = baml.sys.run("ls", args = ["-1t", `${self.state}/logs`], capture_output = true) catch_all (e) {
                _ => {
                    let none: string[] = [];
                    return none;
                },
            };
            out.stdout.to_string().split("\n").filter((f) -> {
                f.starts_with(`${id}.`) && f.ends_with(".jsonl")
            })
        }

        function put_view(self, text: string) -> void throws never {
            // Written whole, then moved: the page never reads half a view.
            let tmp = `${self.state}/view.json.tmp`;
            let _ = baml.fs.write(tmp, text) catch_all (e) {
                _ => {
                    return;
                },
            };
            let _ = baml.sys.run("mv", args = ["-f", tmp, `${self.state}/view.json`]) catch_all (e) {
                _ => null,
            };
        }

        function say(self, level: string, text: string) -> void throws never {
            let line = loop_line(root.supervisor.unix_seconds(), level, text);
            let path = `${self.state}/loop.log`;
            let wrote = write_line(path, line) catch_all (e) {
                _ => {
                    // A state dir not made yet (a repo whose config failed): make it, once.
                    let _ = baml.sys.run("mkdir", args = ["-p", self.state]) catch_all (e2) {
                        _ => null,
                    };
                    let again = write_line(path, line) catch_all (e2) {
                        _ => null,
                    };
                },
            };
        }
    }
}

/// One line of STATE/loop.log: the second, the level, and the text on one line.
function loop_line(at: int, level: string, text: string) -> string throws never {
    `${at} ${level} ${text.split("\n").join(" | ")}`
}

test "a loop log line is the second, the level and the text, on one line" {
    assert.equal(loop_line(5, "warn", "a\nb"), "5 warn a | b");
}

test "the file log keeps what the loop says in STATE/loop.log" {
    let dir = root.tools.scratch("loop-log-test");
    let _ = baml.sys.run("rm", args = ["-rf", dir]);
    let log_file = FileLog { state: dir };
    log_file.say("error", "first");
    log_file.say("info", "second");
    let text = baml.fs.read(`${dir}/loop.log`);
    assert.is_true(text.includes(" error first\n"));
    assert.is_true(text.includes(" info second\n"));
}

function write_line(path: string, line: string) -> void {
    let out = baml.fs.open(path, "a");
    let _ = out.write(line + "\n");
    out.close();
}

function decode_line(line: string) -> root.machine.Event {
    baml.json.decode<root.machine.Event>(line)
}

test "the log survives a restart and a half-written line" {
    let dir = root.tools.scratch("log-test");
    let _ = baml.sys.run("rm", args = ["-rf", dir]);
    let log_file = FileLog { state: dir };
    log_file.append("t-1", root.machine.Picked { kind: "picked" });
    log_file.append("t-1", root.machine.Rejected { kind: "rejected", line: "l", text: "t" });
    let _ = write_line(log_file.path("t-1"), `{"kind":"comm`);
    let again = FileLog { state: dir };
    assert.equal(again.ids(), ["t-1"]);
    assert.equal(again.load("t-1").length(), 2);
    let _ = baml.sys.run("rm", args = ["-rf", dir]);
}

/// The event with the second it was written, as one more field: `{"at":N,"kind":...}`.
/// An event decodes with the field there or not, so old lines and new read alike.
function stamped(json: string, at: int) -> string throws never {
    if (json.starts_with("{") && at > 0) {
        `{"at":${at},${json.slice(1, json.length())}`
    } else {
        json
    }
}

class Stamp {
    at: int?,
}

/// One line of a bead's log, with its time when it has one (0 for a line written
/// before the stamp).
class TimedEvent {
    at: int,
    event: root.machine.Event,
}

/// A bead's log with times, for the page. Lines that do not parse are skipped.
function timed_events(state: string, id: string) -> TimedEvent[] throws never {
    let out: TimedEvent[] = [];
    let text = baml.fs.read(`${state}/beads/${id}/events.jsonl`) catch_all (e) {
        _ => {
            return out;
        },
    };
    for (let line in text.split("\n")) {
        if (line.length() > 0) {
            let event = decode_line(line) catch_all (e) {
                _ => null,
            };
            if let ev: root.machine.Event = event {
                let s = baml.json.decode<Stamp>(line) catch_all (e) {
                    _ => Stamp { at: null },
                };
                out.push(TimedEvent { at: s.at ?? 0, event: ev });
            }
        }
    }
    out
}

test "a stamped line decodes as its event, and an old one still does" {
    let line = stamped(`{"kind":"picked"}`, 1700000000);
    assert.equal(line, `{"at":1700000000,"kind":"picked"}`);
    assert.is_type<root.machine.Picked>(decode_line(line));
    assert.is_type<root.machine.Picked>(decode_line(`{"kind":"picked"}`));
    let dir = root.tools.scratch("timed-log");
    let _ = baml.sys.run("rm", args = ["-rf", dir]);
    let _ = baml.sys.run("mkdir", args = ["-p", `${dir}/beads/t-1`]);
    let _ = write_line(`${dir}/beads/t-1/events.jsonl`, `{"kind":"picked"}`);
    let log_file = FileLog { state: dir };
    log_file.append("t-1", root.machine.Committed { kind: "committed", sha: "s" });
    let t = timed_events(dir, "t-1");
    assert.equal(t.length(), 2);
    assert.equal(t.at(0)?.at, 0);
    assert.equal((t.at(1)?.at ?? 0) > 1700000000, true);
    assert.equal(log_file.load("t-1").length(), 2)
}
