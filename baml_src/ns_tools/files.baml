// The tools a round's model can call. A tool returns text the model can act on, including
// when it fails: a failure is something to read, not an exception.
// A session runs with its worktree as the current directory, and bwrap keeps it there.

// A file is read whole where it can be. Handed part of one, the 30B re-reads the same
// lines from the top, and telling it the next offset does not help (bl-gld, 7 Nov).
const READ_LIMIT: int = 2000;
const OUTPUT_LIMIT: int = 6000;

/// Keeps the end of long output, where a compiler or test run says what happened.
function tail(text: string) -> string throws never {
    let n = text.length();
    if (n <= OUTPUT_LIMIT) {
        return text;
    }
    `[first ${n - OUTPUT_LIMIT} characters cut]\n${text.slice(n - OUTPUT_LIMIT, n)}`
}

function seen_path() -> string throws never {
    `/tmp/bead-loop-seen-${baml.sys.pid()}`
}

function already_read(path: string, offset: int) -> bool throws never {
    let text = baml.fs.read(seen_path()) catch_all (e) {
        _ => "",
    };
    text.split("\n").includes(`${path}\t${offset}`)
}

/// Drop the session's read memory. Compaction has removed those tool results from
/// the prompt, so a later read must return the file again.
function forget_reads() -> void throws never {
    let _ = baml.fs.write(seen_path(), "") catch_all (e) {
        _ => 0,
    };
}

function mark_read(path: string, offset: int) -> void throws never {
    let out = baml.fs.open(seen_path(), "a") catch_all (e) {
        _ => {
            return;
        },
    };
    let _ = out.write(`${path}\t${offset}\n`) catch_all (e) {
        _ => 0,
    };
    let _ = out.close() catch_all (e) {
        _ => null,
    };
}

/// Read lines of a file. A file longer than the limit comes in parts: pass `offset`, the
/// 1-based line to start from, for the next one. A second read of the same lines in this
/// process returns a stub, so whole-file reads do not pile up (bl-b1a.1, 7 Nov).
function read_file(path: string, offset: int = 1) -> string throws never {
    let text = baml.fs.read(path) catch_all (e) {
        _ => {
            return `cannot read ${path}: no such file, or it is not text`;
        },
    };
    let lines = text.split("\n");
    let total = lines.length();
    let start = if (offset < 1) {
        0
    } else {
        offset - 1
    };
    if (start >= total) {
        return `${path} has only ${total} lines`;
    }
    let end = if (start + READ_LIMIT < total) {
        start + READ_LIMIT
    } else {
        total
    };
    if (already_read(path, offset)) {
        return `${path} already read this session (lines ${start + 1}-${end} of ${total}). Use that text; do not read it again.`;
    }
    mark_read(path, offset);
    let body = lines.slice(start, end).join("\n");
    `[${path}: lines ${start + 1}-${end} of ${total}]\n${body}`
}

/// Create a file, or replace all of one.
function write_file(path: string, content: string) -> string throws never {
    let n = baml.fs.write(path, content) catch_all (e) {
        _ => {
            return `cannot write ${path}: ${e}`;
        },
    };
    `wrote ${n} bytes to ${path}`
}

/// Replace `old_text` with `new_text` in a file. `old_text` must match exactly, whitespace
/// included, and appear exactly once.
function edit_file(path: string, old_text: string, new_text: string) -> string throws never {
    let text = baml.fs.read(path) catch_all (e) {
        _ => {
            return `cannot read ${path}: no such file, or it is not text`;
        },
    };
    if (old_text.length() == 0) {
        return "old_text is empty: use write_file to create a file";
    }
    let found = count(text, old_text);
    // A local model often escapes quotes and newlines that are not escaped in the file
    // (bl-b1a.1, 7 Nov: \"id\" for "id"). Undone on both sides, when that makes it match.
    if (found == 0 && unescaped(old_text) != old_text && count(text, unescaped(old_text)) == 1) {
        return replace_once(path, text, unescaped(old_text), unescaped(new_text), " (after undoing escaped quotes)");
    }
    if (found == 0) {
        return not_found(path, text, old_text);
    }
    if (found > 1) {
        return `old_text appears ${found} times in ${path}: include more of the lines around it`;
    }
    replace_once(path, text, old_text, new_text, "")
}

function count(text: string, part: string) -> int throws never {
    text.split(part).length() - 1
}

function unescaped(s: string) -> string throws never {
    s.split("\\\"").join("\"").split("\\n").join("\n")
}

function replace_once(
    path: string,
    text: string,
    old_text: string,
    new_text: string,
    how: string,
) -> string throws never {
    let n = baml.fs.write(path, text.split(old_text).join(new_text)) catch_all (e) {
        _ => {
            return `cannot write ${path}: ${e}`;
        },
    };
    `edited ${path}${how}`
}

/// Says where the match broke and shows the real lines there, so the model can copy them
/// without reading the whole file again.
function not_found(path: string, text: string, old_text: string) -> string throws never {
    let wanted = old_text.split("\n");
    let lines = text.split("\n");
    let first = (wanted.at(0) ?? "").trim();
    let i = 0;
    while (i < lines.length()) {
        if ((lines.at(i) ?? "").trim() == first && first.length() > 0) {
            let n = i + 1;
            let end = if (i + wanted.length() + 2 < lines.length()) {
                i + wanted.length() + 2
            } else {
                lines.length()
            };
            let real = lines.slice(i, end).join("\n");
            return `old_text not found in ${path}. Its first line matches line ${n} once spaces are ignored, but a later line differs. The file has, from line ${n}:\n${real}\nCopy from that exactly.`;
        }
        i = i + 1;
    }
    `old_text not found in ${path}, and its first line is nowhere in the file. Search for a distinctive word from it, then copy the text exactly.`
}

/// Search the repository's tracked files for a regular expression.
function search(pattern: string) -> string throws never {
    let out = baml.sys.run("git", args = ["grep", "-n", "-E", "-e", pattern], capture_output = true) catch_all (e) {
        _ => {
            return `search failed: ${e}`;
        },
    };
    let text = out.stdout.to_string();
    if (text.length() == 0) {
        `no match for ${pattern}`
    } else {
        tail(text)
    }
}

/// List the repository's tracked files whose path contains `part`; an empty `part` lists all.
function list_files(part: string = "") -> string throws never {
    let out = baml.sys.run("git", args = ["ls-files"], capture_output = true) catch_all (e) {
        _ => {
            return `list failed: ${e}`;
        },
    };
    let all = out.stdout.to_string().split("\n");
    tail(
        all
            .filter((p) -> {
                p.includes(part)
            })
            .join("\n"),
    )
}

/// Run a shell command in the worktree and see its exit code and output.
function run(command: string) -> string throws never {
    let out = baml.sys.shell(command, capture_output = true, timeout = baml.time.Duration.from_seconds(900)) catch_all (e) {
        _ => {
            return `the command did not finish: ${e}`;
        },
    };
    `[exit ${out.exit_code}]\n${tail(out.stdout.to_string() + out.stderr.to_string())}`
}

test "edit replaces text that appears once" {
    let p = "/tmp/bead-loop-edit-once.txt";
    let _ = baml.fs.write(p, "alpha\nbeta\n");
    assert.equal(edit_file(p, "beta", "gamma"), `edited ${p}`);
    assert.equal(baml.fs.read(p), "alpha\ngamma\n");
    let _ = baml.fs.remove(p);
}

test "edit refuses text that appears twice" {
    let p = "/tmp/bead-loop-edit-twice.txt";
    let _ = baml.fs.write(p, "x\nx\n");
    assert.contains(edit_file(p, "x", "y"), "appears 2 times");
    let _ = baml.fs.remove(p);
}

test "edit undoes a model's escaped quotes" {
    let p = "/tmp/bead-loop-edit-esc.txt";
    let _ = baml.fs.write(p, "let b = json!({\"id\": id});\n");
    assert.equal(
        edit_file(p, "json!({\\\"id\\\": id})", "json!({\\\"id\\\": x})"),
        `edited ${p} (after undoing escaped quotes)`,
    );
    assert.equal(baml.fs.read(p), "let b = json!({\"id\": x});\n");
    let _ = baml.fs.remove(p);
}

test "a near miss shows the real lines" {
    let p = "/tmp/bead-loop-edit-show.txt";
    let _ = baml.fs.write(p, "fn a() {\n    let x = 1;\n    let y = 2;\n}\n");
    assert.contains(edit_file(p, "fn a() {\n    let x = 9;", "z"), "    let x = 1;");
    let _ = baml.fs.remove(p);
}

test "edit says where a near miss broke" {
    let p = "/tmp/bead-loop-edit-near.txt";
    let _ = baml.fs.write(p, "fn a() {\n    let x = 1;\n}\n");
    assert.contains(edit_file(p, "  let x = 2;", "y"), "not found");
    assert.contains(edit_file(p, "let x = 1;\nmissing", "y"), "matches line 2");
    let _ = baml.fs.remove(p);
}

test "read comes in parts" {
    let p = "/tmp/bead-loop-read.txt";
    let lines: string[] = [];
    let i = 0;
    while (i < 2100) {
        lines.push(`line ${i}`);
        i = i + 1;
    }
    let _ = baml.fs.write(p, lines.join("\n"));
    assert.contains(read_file(p), "lines 1-2000 of 2100");
    assert.contains(read_file(p, offset = 2001), "lines 2001-2100 of 2100");
    let _ = baml.fs.remove(p);
}

test "a second read of the same lines is a stub" {
    let p = "/tmp/bead-loop-read-again.txt";
    let _ = baml.fs.write(p, "alpha\nbeta\n");
    assert.contains(read_file(p), "alpha");
    assert.contains(read_file(p), "already read this session");
    let _ = baml.fs.remove(p);
}
