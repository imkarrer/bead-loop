# Why this shape

- Two model servers on two boxes, so a lane each: the GPU implements the next bead while
  the CPU reviews the last, and each lane has one bead at a time. No cap on PRs in flight
  by default: bd's dependencies say what must land before what, and the queues absorb
  the rest — a green PR waiting on CI must never idle the GPU.
- A resident process, not a timer. The old oneshot-and-timer left the GPU idle for up to
  fourteen minutes at a time — a merge seen only at a tick's edges, a rejected bead
  waiting for the next tick, three minutes of timer after every pass. Now every producer
  rings the bell and every consumer is on it. The one clock left is GitHub's, and it runs
  only while a PR is open. ([design-resident-loop.md](design-resident-loop.md) is the
  note it was built from.)
- The 80B on the CPU box generates at 10–12 tok/s and prefills at ~140 tok/s (gpt-oss-120b
  there is the same class, ~14 tok/s): a fresh 20k-token diff is minutes before the first
  token, and every agentic turn would pay that again. Too slow to sit in an edit loop,
  too good to leave out; one review call per round is where it pays. Per bead, review is
  three times faster than dev (median 3.5 vs 11 minutes over a week), so the review queue
  rarely holds more than one.
- The reviewer is a different model family from the workers: what the Qwen models share
  — a habit, a blind spot — one of them cannot catch in the other.
- A lane per model server, not per role, because the scarce thing is the server: a round
  on the CPU box must never hold the GPU's queue, and a bead escalated to Claude must
  start now, on Anthropic, behind nobody.
  ([design-lanes-per-server.md](design-lanes-per-server.md).)
- A send-back is a failure, wherever it comes from — the gate, the reviewer, CI — and the
  failure count alone picks the stage. One counter, one table, no special cases. And the
  world's failures — a server down, setup broken, CI silent — are never the bead's: held,
  with the reason, until the world changes.
- Every claim is checked by something that is not the model that made it: the gate, the
  reviewer, CI, and the merge check are independent refusals.
- Rust, one binary, because two of the last bugs were bash bugs (a `${x:+…}` word that
  emptied every worker prompt; an exit code misread), because a lane must not die on a
  stray non-zero exit, and because the resident loop wants threads, a signal handler and
  a lock without a `set -e` under them. `run_agent` in `src/harness.rs` is the one seam
  to the harness: opencode for local models, Claude Code for `claude/*`, aider for
  `aider:*`; each is one case there.

## Harnesses

The worker's model name picks its harness. `provider/model` is an opencode agent: the
model reads the repo with tools, finds the files to touch, runs commands, commits, and
ends with `DONE:` or `BLOCKED:`. `claude/<alias>` (`claude/sonnet`, `claude/opus`) is
the same round in Claude Code (`claude -p`), the agent file's body as its system prompt,
tools by role; it needs `claude` on PATH and logged in once (`claude`, then `/login`),
and `install.sh` links the skills into `~/.claude/skills`. `aider:provider/model` runs
aider (`aider --yes-always --no-auto-commits --message ...`) on the same provider's
server — its `baseURL` in `~/.config/opencode/opencode.json`, spoken as `openai/model` —
handing it the files the bead's DESCRIPTION names (every token with a slash or a dot that
exists in the worktree) and the `gate` as its `--lint-cmd`. Aider explores nothing and
commits nothing: the loop commits what it edited, a zero exit with a diff is done, a
non-zero exit is a failure, and there is no `DONE:` line.

A provider with `harness = "command"` and `command = "..."` (and optional `model_flag`,
`{model}` replaced) runs the command with the prompt on stdin and `BEAD_ROLE`,
`BEAD_MODEL`, `BEAD_AGENT_PROMPT`, `BEAD_TIMEOUT` in the environment. Its stdout is the
model's words: a non-zero exit is the harness failing, an empty stdout is a round the
model never answered (held, no failure). A read-only role (reviewer, researcher) is the
command's own promise.

Aider is the better choice for a small model on a file-scoped bead with a runnable gate:
the edit format is stricter than tool calls, the files are given, and the gate runs after
each edit inside aider's own loop. Opencode is the better choice when the bead needs the
model to find its files, run the tests it names, or stop with `BLOCKED:` and a reason.
The reviewer is never aider: a review reads, it does not edit.

A bead can pick its worker's harness over the stage's, by label: `harness:aider` puts the
stage's opencode model under aider (`devbox/coder` runs as `aider:devbox/coder`),
`harness:opencode` takes an `aider:` model out of it. A `claude/*` stage is not touched by
either. The dev lane logs the harness it chose and the label that chose it, once per
round; the stage's reviewer and failure count are the same either way.
