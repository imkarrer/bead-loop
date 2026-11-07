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

/// Read lines of a file. A file longer than the limit comes in parts: pass `offset`, the
/// 1-based line to start from, for the next one.
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
    let parts = text.split(old_text);
    let found = parts.length() - 1;
    if (found == 0) {
        return not_found(path, text, old_text);
    }
    if (found > 1) {
        return `old_text appears ${found} times in ${path}: include more of the lines around it`;
    }
    let n = baml.fs.write(path, parts.join(new_text)) catch_all (e) {
        _ => {
            return `cannot write ${path}: ${e}`;
        },
    };
    `edited ${path}`
}

/// Says where the match broke, because a near miss is the common case for a small model.
function not_found(path: string, text: string, old_text: string) -> string throws never {
    let wanted = old_text.split("\n");
    let lines = text.split("\n");
    let first = (wanted.at(0) ?? "").trim();
    let i = 0;
    while (i < lines.length()) {
        if ((lines.at(i) ?? "").trim() == first && first.length() > 0) {
            let n = i + 1;
            return `old_text not found in ${path}. Its first line matches line ${n} once spaces are ignored, so the indentation or a later line differs. Read from line ${n} and copy the text exactly.`;
        }
        i = i + 1;
    }
    `old_text not found in ${path}, and its first line is nowhere in the file. Read the file again and copy the text exactly.`
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
