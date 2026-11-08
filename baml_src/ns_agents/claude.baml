// The Claude Code stage's client, built per round. BAML's ClaudeCodeClient passes
// `--tools` and the permission mode but `--allowedTools` only for MCP servers, and its
// stderr and the CLI's own stream go nowhere. So each round runs the CLI through a
// two-line wrapper it writes beside its log: the wrapper adds what may run without
// asking, and tees the stream into the round's log, where the page reads Claude's tool
// calls and a failed round reads what the CLI said.
//
// pw-xl2, 8 Nov: the client was built with BAML's defaults, `--tools ""`, so Claude had
// no way to read or edit the worktree; it answered "BLOCKED: Placeholder" and the bead
// parked. Before that, fourteen rounds failed on "the Claude Code CLI exited with code 1",
// with the reason in a stream nobody kept.

/// Claude Code's own tools, by role. The worker edits and runs in its worktree. A reviewer
/// only reads: the diff is in its prompt, so it has no shell at all (a "read-only" shell
/// allow-list is not one: `rg --pre` runs commands and `git diff --output` writes files).
function claude_tools(writes: bool) -> string[] throws never {
    if (writes) {
        ["Read", "Edit", "Write", "Glob", "Grep", "Bash"]
    } else {
        ["Read", "Glob", "Grep"]
    }
}

/// What runs without asking; a -p session has no one to ask, so anything else is refused.
/// Reading, editing and writing are allowed under the round's working directory, its
/// worktree, and nowhere else.
function claude_allowed(writes: bool) -> string throws never {
    if (writes) {
        "Read(./**),Edit(./**),Write(./**),Glob,Grep,Bash"
    } else {
        "Read(./**),Glob,Grep"
    }
}

/// The wrapper's text: the CLI with the allow-list, its stream teed into `log`, its stderr
/// beside it, and its own exit status.
function claude_wrapper(log: string, writes: bool) -> string throws never {
    let allowed = claude_allowed(writes);
    [
        "#!/bin/sh",
        "# One Claude Code turn for a bead-loop round (baml_src/ns_agents/claude.baml).",
        `log='${log}'`,
        `{ claude "$@" '--allowedTools=${allowed}' --strict-mcp-config 2>>"$log.err"; echo $? >"$log.rc"; } | tee -a "$log"`,
        `exit "$(cat "$log.rc" 2>/dev/null || echo 1)"`,
        "",
    ]
        .join("\n")
}

/// The client a `claude/MODEL` stage means for one round, working in `dir`. With no log,
/// or when the wrapper cannot be written, the CLI itself, unlogged.
function claude_client(
    model: string,
    dir: string,
    log: string,
    writes: bool,
) -> ai.Client throws never {
    let name = model.split("/").at(1) ?? "sonnet";
    let tools = claude_tools(writes);
    let script = `${log}.sh`;
    let wrote = log.length() > 0
        && (
            baml.fs.write(script, claude_wrapper(log, writes)) catch_all (e) {
                _ => "no",
            }
        )
            != "no";
    let ran = wrote
        && (
            baml.sys.run("chmod", args = ["+x", script]) catch_all (e) {
                _ => null,
            }
        )
            != null;
    let exe = if (ran) {
        script
    } else {
        "claude"
    };
    claude_code.ClaudeCodeClient.new(
        model = name,
        executable = exe,
        cwd = dir,
        timeout_ms = 3600000,
        permission_mode = "default",
        harness_tools = tools,
    )
}

/// What the CLI said, from the round's log: the last result event's text, then its
/// stderr. Empty when it said nothing.
function claude_said(log: string) -> string throws never {
    let text = baml.fs.read(log) catch_all (e) {
        _ => "",
    };
    let said = "";
    for (let line in text.split("\n")) {
        if (line.starts_with("{") && line.includes("\"type\":\"result\"")) {
            let raw = baml.json.parse(line) catch_all (e) {
                _ => null,
            };
            if (raw != null) {
                let r = baml.json.path_or<string>(raw, ".result", "");
                if (r.length() > 0) {
                    said = r;
                }
            }
        }
    }
    let err = (
        baml.fs.read(`${log}.err`) catch_all (e) {
            _ => "",
        }
    )
        .trim();
    if (err.length() == 0) {
        said
    } else if (said.length() == 0) {
        err
    } else {
        `${said}\n${err}`
    }
}

test "the worker may edit and the reviewer only reads, neither outside the worktree" {
    assert.contains(claude_tools(true).join(","), "Edit");
    assert.is_true(!claude_tools(false).join(",").includes("Edit"));
    assert.is_true(!claude_tools(false).join(",").includes("Bash"));
    assert.equal(claude_allowed(false), "Read(./**),Glob,Grep");
    assert.contains(claude_allowed(true), "Edit(./**)")
}

test "the wrapper tees the stream into the log and keeps the CLI's status" {
    let w = claude_wrapper("/s/logs/x.1.Work.jsonl", true);
    assert.contains(w, "log='/s/logs/x.1.Work.jsonl'");
    assert.contains(w, "'--allowedTools=Read(./**),Edit(./**),Write(./**),Glob,Grep,Bash'");
    assert.contains(w, "| tee -a \"$log\"");
    assert.contains(w, "exit \"$(cat \"$log.rc\"")
}

test "a round's Claude client runs the wrapper, which runs" {
    let log = root.tools.scratch("cc.jsonl");
    let _ = claude_client("claude/sonnet", "/tmp", log, false);
    assert.contains(baml.fs.read(`${log}.sh`), "tee -a");
    let out = baml.sys.run("/bin/sh", args = ["-n", `${log}.sh`], capture_output = true);
    assert.equal(out.exit_code, 0);
    let _ = baml.fs.remove(`${log}.sh`);
}

test "what the CLI said is its last result, then its stderr" {
    let log = root.tools.scratch("cc-said.jsonl");
    let _ = baml.fs.write(
        log,
        "{\"type\":\"system\",\"subtype\":\"init\"}\n{\"type\":\"result\",\"is_error\":true,\"result\":\"You've hit your session limit · resets 3pm\"}\n",
    );
    let _ = baml.fs.write(`${log}.err`, "Error: exiting\n");
    let said = claude_said(log);
    assert.contains(said, "hit your session limit");
    assert.contains(said, "Error: exiting");
    assert.equal(claude_said(root.tools.scratch("cc-none.jsonl")), "");
    let _ = baml.fs.remove(log);
    let _ = baml.fs.remove(`${log}.err`);
}
