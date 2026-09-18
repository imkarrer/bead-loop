| PR opened | in_progress, comment with the url | pushed; nothing merges until a later tick sees every check green |
# bead-loop

Work [beads](https://github.com/steveyegge/beads) with local models in any repo: a
supervisor script picks a labelled bead, an implementor model works it in a fresh
worktree, a gate proves it, a reviewer model judges the diff, a PR goes up, CI runs,
green merges, the bead closes. No model runs the loop; models do the two jobs that
need judgement.

```mermaid
flowchart TD
  T([systemd user timer<br/>every 10 min, one tick]) --> R

  subgraph tick [bead-supervisor tick — bash, deterministic, one bead per repo]
    direction TB
    R[reconcile: read every open bead PR] --> P{bd ready -l LABEL}
    P -- nothing --> Z([done])
    P -- top bead --> C[bd claim<br/>git worktree add bead/ID off origin/BASE]
    C --> U[SETUP<br/>npm ci]
    U --> W[implementor session<br/>bead-worker agent]
    W -- DONE + commit --> G[GATE<br/>typecheck · lint]
    W -- BLOCKED --> F
    G -- fail, first time --> W
    G -- fail, second time --> F
    G -- pass --> V[review session<br/>bead-reviewer agent, read-only]
    V -- REJECT, first time --> W
    V -- REJECT, second time --> F[attempt failed: note on the bead<br/>worktree removed]
    F -- next stage, or repeat --> Q[back in the queue<br/>fewest attempts first]
    F -- exhausted, or BLOCKED at the last stage --> H[parked in_progress<br/>for you]
    V -- APPROVE --> PR[git push · gh pr create<br/>inflight/ID = PR url]
  end

  W -.- GPU[(devbox/coder<br/>Qwen3-Coder-30B-A3B<br/>RTX 4080, this box)]
  V -.- CPU[(acbox/coder<br/>Qwen3-Coder-Next 80B Q8<br/>hp 840z, 256 GB RAM, CPU)]

  PR --> CI[Buildkite, queue self on ac-box]
  CI -- all checks green<br/>on a later tick --> M[squash-merge · delete branch<br/>bd close ID]
  CI -- red --> N[note on bead<br/>PR stays open for you]
  CI -- no checks --> N

  classDef model fill:#f3f0ff,stroke:#7c5cff,color:#222
  classDef stop fill:#fff3f0,stroke:#e0503c,color:#222
  class GPU,CPU model
  class H,N stop
```

| Role | What | Where it runs here |
| --- | --- | --- |
| Supervisor | `bin/bead-supervisor`, bash, deterministic | systemd user timer on this box |
| Implementor | opencode agent `bead-worker` | `devbox/coder` — Qwen3-Coder-30B on the RTX 4080; `claude/opus` as the last stage |
| Reviewer | opencode agent `bead-reviewer`, read-only | `acbox/coder` — Qwen3-Coder-Next 80B Q8 on ac-box's CPU |

Both models are opencode providers in `~/.config/opencode/opencode.json`; any
`provider/model` works in their place. The fast model implements; the slow, stronger
model gets one call per PR, where it pays.

## Layout

```
skills/beads/             bd syntax                        -> ~/.config/opencode/skills/beads
skills/bead-workflow/     one bead, start to finish        -> ~/.config/opencode/skills/bead-workflow
agents/bead-worker.md     implementor agent                -> ~/.config/opencode/agents/
agents/bead-reviewer.md   reviewer agent                   -> ~/.config/opencode/agents/
bin/bead-supervisor       the loop                         -> ~/.local/bin/
systemd/                  supervisor oneshot + 10 min timer, opencode-web service
bead-loop.example         per-repo config                  -> <repo>/.bead-loop
docs/loop.mmd             the diagram above
```

`./install.sh` makes the links (re-runnable). Repo-specific skills (how to verify,
house style, vocabulary) stay in each repo under `.agents/skills/` or
`.opencode/skills/`; the workflow skill tells the worker to look for them.

## Per repo

1. Label the beads the model may work: `bd label add <id> delegate:local`.
   A bead needs a DESCRIPTION naming the files and an ACCEPTANCE CRITERIA the
   worker can run; the workflow skill turns anything vaguer into a `BLOCKED:` note.
2. Copy `bead-loop.example` to `<repo>/.bead-loop`: the label, base branch, `SETUP`
   (what a fresh worktree needs, e.g. `npm ci`), `GATE` (fast local proof),
   `REVIEW_MODEL`, `MERGE`.
3. Add the repo to `REPOS` in `~/.config/bead-loop/config`.
4. On GitHub: CI that reports a status on PRs. `gh` must be logged in. The supervisor
   never asks GitHub to auto-merge (on a branch with no required checks that merges
   immediately); a later tick merges once every reported check is green, and refuses
   while none is reported. Branch protection, where the plan allows it, is a second lock.

## Watching it

Interactive: `opencode-web.service` serves opencode's web UI at
<http://127.0.0.1:4096>. With `ATTACH=http://127.0.0.1:4096` in the global config
every worker and reviewer session runs inside that server, so it streams there live,
titled by bead, with the diff. No terminal needed. The UI starts empty per browser: **Add
project** → select the repo (e.g. `~/src/inquire-platform`); its bead sessions, run in
worktrees, file under it. Once per browser per repo.

From a terminal:

```bash
journalctl --user -u bead-supervisor.service -f -o cat    # stage transitions, one line each
bead-supervisor status                                    # ready beads, PRs in flight, CI red
bead-supervisor log ~/src/repo [bead-id]                  # the newest session, one line per tool call
```

State lives in `~/.local/state/bead-loop/<repo>/`: `inflight/<id>` (the PR url),
`logs/<id>.<stamp>.*` (setup, worker, gate, reviewer output per attempt), `wt/<id>`
(the worktree while a bead is in progress).

## Run

```bash
bead-supervisor --dry-run work ~/src/repo               # the bead and prompt it would use
bead-supervisor --local work ~/src/repo inq-abc.1       # implement, gate, review; no push
bead-supervisor work ~/src/repo                         # one bead through to a PR
bead-supervisor tick                                    # what the timer does
systemctl --user enable --now opencode-web.service bead-supervisor.timer
sudo loginctl enable-linger $USER                       # timers survive logout
```

## Lifecycle of one bead

An **attempt** is worker → gate (one fix round on failure) → reviewer (one fix round on
REJECT). It ends in a PR, or in a note on the bead saying exactly where it stopped.

What happens after a failed attempt is the **escalation path**, `STAGES` in `.bead-loop`:

```
STAGES=devbox/coder:acbox/coder:3 acbox/coder:acbox/instruct:2:14400
ON_EXHAUST=repeat
```

Read: three attempts with the fast GPU worker reviewed by the 80B; then two with the 80B
implementing and the *other* 80B reviewing (four-hour timeout); then, with `repeat`,
around again until it lands. A stage may name `claude/<alias>` (`claude/opus`,
`claude/sonnet`): that attempt runs in Claude Code (`claude -p`) instead of opencode, the
agent file's body as its system prompt, tools by role — the frontier model gets only
what the local ones could not land. It needs `claude` on PATH and logged in once
(`claude`, then `/login`); the skills are linked into `~/.claude/skills` by `install.sh`. A failed attempt puts the bead back in the queue with its
note; the next attempt reads the notes of the earlier ones. Among ready beads the one
with the fewest attempts goes first, so a stubborn bead never starves the rest.

Two things park a bead (`in_progress`, no more attempts) for a human: the stages are
exhausted with `ON_EXHAUST=park`, or the *last* stage says `BLOCKED:` — a claim in the
bead is false, and no model fixes that.

## PRs from anyone

`reconcile` also **adopts** any open PR on a `bead/<id>…` branch it did not open — another
session's, or yours by hand. It merges on green like its own and closes the bead the
branch names. Adopted PRs cost CI, not the model, so they do not count toward
`MAX_INFLIGHT`. `ADOPT=0` in `.bead-loop` turns it off.

## What each outcome does to the bead

| Outcome | Bead | Branch / PR |
| --- | --- | --- |
| Worker `BLOCKED:` | note with the worker's line; back in the queue for the next stage, parked if this was the last | removed |
| Setup fails, or no commit | note with the tail of the log; next attempt | removed |
| Gate fails twice (one revision round with its output) | note with the errors; next attempt | removed |
| Reviewer `REJECT:` twice | note with the last rejection; next attempt | removed |
| Attempts exhausted (`ON_EXHAUST=park`) | in_progress, for you | — |
| PR opened | in_progress, comment with the url | pushed |
| CI green | closed with the PR url | squash-merged, branch deleted |
| CI red | in_progress, one note | PR left open for you |
| PR closed unmerged | in_progress, note | gone |

`in_progress` is the parking state: `bd ready` never hands it out again, and `bd show`
says why. Reopen with `bd update <id> --status open` once the bead or the code is fixed.

The worker never runs `bd`; the bead's text is in its prompt and the supervisor
records every state change in the operator's checkout. `.beads/issues.jsonl` changes
there, uncommitted, for you to commit with your own work.

## Checks

`test/run.sh` drives the supervisor through every row of the outcome table above with
stub `bd`, `opencode` and `gh` (`test/bin/`) and a real git origin: no model, no network,
a few seconds. `test/lint-skills.sh` checks the frontmatter opencode needs. Both run with
shellcheck in `.github/workflows/ci.yml` on every push and PR, and `main` requires that
check green.

## Why this shape

- One model server per box, so one bead in flight per box: `MAX_INFLIGHT` defaults to 1
  and the timer serialises ticks with a lock.
- The 80B at ~3 tok/s is too slow to sit in an agentic edit loop and too good to leave
  out; one review call per PR is where it pays. First live result: it rejected a diff
  the 30B had declared done, for duplicating entries that already existed.
- Every claim is checked by something that is not the model that made it: the gate,
  the reviewer, CI, and the merge check are independent refusals.
- `run_agent` in `bin/bead-supervisor` is the one seam to the harness: opencode for local
  models, Claude Code for `claude/*`; adding aider would be one more case there.
