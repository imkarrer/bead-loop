# Design: targets — the beads in one repo, the work and the PR in another

Status: built — PRs #63, #80, #91, #92, #95, #98, #101, #103, #104 and the pr_style PR; the house-rules bead bl-3x2 last. Written 2026-09-21 from `src/` as it is.

## What is wrong now

The loop takes one path per repo and asks it to be four things at once: where `bd`
reads and writes (`.beads/`), where `.bead-loop.toml` lives, the git checkout the
worktrees hang off and the PR is opened against, and the name of the state directory.
`Repo` in `src/config.rs` is that conflation as a struct: `repo.repo` is `bd`'s cwd
(`shell::bd`), `git -C`'s dir (28 call sites), and `gh`'s cwd, which is how `gh` decides
which GitHub repo a PR belongs to.

The first case that breaks it is already here. `~/src/preservation-workbench`
(`imkarrer/preservation-workbench`, prefix `pw`) holds the backlog for the Euclid
collaboration; the code the beads change lives in three sibling checkouts that are
**not ours and do not use beads**:

| checkout | origin | upstream | who merges |
| --- | --- | --- | --- |
| `~/src/euclid` | `imkarrer/euclid` (fork) | `brownnrl/euclid` | Nelson |
| `~/src/euclids-elements-lektor` | `brownnrl/euclids-elements-lektor` (no fork yet) | — | Nelson |
| `~/src/euclids-elements.org` | `brownnrl/euclids-elements.org` | — | Nelson |

The `pw` beads already say which: every one carries a `work:euclid`-style label. What
the loop lacks is a way to read that label and act on it — a worktree in `~/src/euclid`
off `upstream/main`, a push to `origin` (the fork), a PR on `brownnrl/euclid` with head
`imkarrer:bead/pw-…`, and then *not* merging it, because merging is Nelson's.

Three things follow from "not ours" that the loop has never had to think about:

1. **Nothing of ours may land in their tree.** No `.bead-loop.toml`, no `.beads/`, no
   skills directory committed by accident. The target's configuration lives in the beads
   repo.
2. **A PR to a collaborator is a message to a person.** The loop opens PRs on its own
   repos by the dozen; on someone else's, one at a time, in their house style, and — by
   default — only after the operator has looked at the branch. The relationship is worth
   more than the throughput.
3. **The merge is not ours to make or to time.** `merge = "manual"` holds the bead for
   *you* once green; here green means nothing until the maintainer acts, which may be a
   week. That is a wait, not a hold.

## The proposal

### Vocabulary

- **beads repo** — an entry in `repos`: has `.beads/` and `.bead-loop.toml`. `bd` runs
  here; the state dir is named after it. Unchanged.
- **target** — a git checkout the round works in and the GitHub repo its PR goes to.
  Every beads repo has a *default target*: itself, exactly today's behaviour. More come
  from `[targets.NAME]` tables in the beads repo's `.bead-loop.toml`.
- A bead **picks its target by label**: `work:NAME` (the prefix is `target_label`,
  default `"work"`, because that is what the `pw` beads already use). No such label: the
  default target. A label naming no configured target, or two `work:` labels: the bead
  is **held** with the reason, no failure — a config mistake is the world's, not the
  bead's.

### Config

```toml
# ~/src/preservation-workbench/.bead-loop.toml
label = "delegate:local"
target_label = "work"                 # the label prefix that names a target (default)

[targets.euclid]
path = "~/src/euclid"                 # the checkout; required
base = "main"                         # default: base_remote's HEAD
base_remote = "upstream"              # default: upstream when that remote exists, else origin
push_remote = "origin"                # default: origin — where bead/* branches go
pr_repo = "brownnrl/euclid"           # default: base_remote's GitHub repo
setup = "npm ci"
gate = "npm test"
merge = "external"                    # the maintainer merges; the loop watches
open_pr = "ask"                       # default when pr_repo's owner is not `gh api user`
pr_style = "plain"                    # default when open_pr defaults to ask
max_inflight = 1                      # one thing at a time, on someone else's repo

[targets.lektor]
path = "~/src/euclids-elements-lektor"
pr_repo = "brownnrl/euclids-elements-lektor"
```

Layering gains one layer: **target > beads repo file > global > default**, for every
key that describes a checkout or a PR (`base`, `setup`, `gate`, `merge`, `merge_label`,
`adopt`, `max_inflight`, and the new ones). Keys that describe the loop (`label`,
`[[stages]]`, models, timeouts, `attach`) are not per target: the same models work every
target of a beads repo.

### Where each tool runs

| tool | today | with targets |
| --- | --- | --- |
| `bd` | `cwd = repo.repo` | `cwd = repo.beads` — the one line in `shell::bd` |
| `git worktree add`, `branch`, `fetch` | `git -C repo.repo` | `git -C repo.repo` where `repo.repo` **is the target's path** — the 28 call sites do not change |
| `git push` | `-u origin BRANCH` | `-u PUSH_REMOTE BRANCH` |
| worktree base | `origin/BASE` | `BASE_REMOTE/BASE`, after `fetch BASE_REMOTE BASE`; the rebase order names the same |
| `gh pr create` | cwd decides the repo | `--repo PR_REPO --head OWNER:BRANCH` when the push remote is not `PR_REPO` (`OWNER` parsed from the push remote's url) |
| `gh pr list --head` | `BRANCH` | `--repo PR_REPO --head OWNER:BRANCH` |
| `gh pr view/merge/edit` | by number, cwd | by the URL already in `inflight/ID` — no cwd dependence at all |
| adopt | `gh pr list` in the repo | once per target's `pr_repo`; only branches naming a bead this beads repo has |

`Repo` grows `beads: PathBuf` (bd's cwd, the `.beads/` check moves there), the parsed
`targets`, and `target: String` (the name it is resolved to, `""` for the default).
`Repo::for_bead(labels) -> Result<Repo, String>` returns a clone with `repo` pointed at
the target's path and the target's keys layered on. The dev lane resolves it at claim
and writes the name to **`$RS/target/ID`**; the review lane, the merge watcher, `open`,
`answer`, `escalate` and recover read it back (`Repo::for_id`). No file means the default
target, so beads in flight across the deploy are unaffected. The file goes with
`inflight/ID` at close, and at park.

The state dir stays keyed by the beads repo: bead ids are unique there, and a target
shared by two beads repos (two backlogs, one codebase) just gets worktrees from both
under their own `$RS/wt/`. `GIT_MUTATION` is process-wide already.

### `merge = "external"`: someone else merges

The watcher's verdicts, against today's table:

| GitHub says | `auto` today | `external` |
| --- | --- | --- |
| MERGED | close the bead | close the bead |
| CLOSED unmerged | park, with the brief | park, with the brief — the maintainer said no, or wants it another way |
| CI red | send back, +1 | send back, +1 — the fix pushes to the same PR |
| conflicts with base | rebase round | rebase round |
| green | merge | **nothing**: "awaiting the maintainer, N days" on the page; no hold, no note |
| no checks / pending > 2h | held | **nothing** — their CI is their business |
| review `CHANGES_REQUESTED` | — | later: the review's comments as a send-back note (a follow-up bead, not this one) |

Not a hold: a hold has a backoff and is retried; this is a wait with no timeout of ours,
and the page shows it as such — with the age, so a PR nobody has looked at in a month is
visible without being nagged about.

### `open_pr = "ask"`: the PR is yours to open

After APPROVE the branch is pushed to `push_remote` as today. Under `ask` the loop does
not call `gh pr create`; it writes the proposed title and body to `$RS/proposed/ID` and
the bead enters the human queue as **ready to publish** — `in_progress`, not held (no
backoff), not parked (nothing failed). The page shows the compare link, the title and
body (editable), and **Open PR**; `bead-supervisor publish REPO ID [--title T] [--body-file
F]` is the same from a terminal. Publishing opens the PR and moves the bead to the merge
queue as if the loop had opened it. A bead ready to publish counts toward `max_inflight`,
so `1` means what it says.

Default: `ask` when `pr_repo`'s owner is not `gh api user -q .login`, `auto` otherwise.
On our own repos nothing changes.

### `pr_style = "plain"`: a contribution, not a loop artifact

Today's PR is titled `pw-1lq: …` and its body ends "Opened by bead-loop; the bead closes
when this merges." — right for our repos, wrong for Nelson's. `plain`: the title is the
bead's title; the body is the bead's description, then **How to verify** quoting the
acceptance criteria, then the worker's evidence line; no id in the title, no loop line;
one `<!-- bead: pw-1lq -->` at the end for traceability. The branch stays `bead/ID…`
(adopt keys on it and it is harmless). Default `plain` whenever `open_pr` defaults to
`ask`. `Co-Authored-By` trailers on commits are the worker's business as today; Nelson
uses them himself.

### House rules travel

The workflow skill tells the worker to read the repo's own `AGENTS.md` and
`<repo>-verify` / `-layout` / `-vocabulary` skills. In a foreign worktree those are the
*target's* (euclid has `AGENTS.md` and `CONTRIBUTING.md`; they should win on style), and
the beads repo's skills — Nelson's fidelity rules, how to run the Lektor checks — are
nowhere the model looks. Proposal: before the worker starts, link each
`<beads repo>/.agents/skills/<name>` into `<wt>/.agents/skills/<name>` where the target has
no skill of that name, and put `.agents/` in the target's `.git/info/exclude` (shared by
its worktrees, local only). `git status` in the worktree must stay clean afterwards, and
the prompt says where the house rules came from. Nothing is committed to their tree.

## What does not change

- Beads repos with no `[targets]`: byte-for-byte today's behaviour (`repo.beads ==
  repo.repo`, `base_remote = push_remote = origin`, `open_pr = auto`, `pr_style = loop`).
- The stages, lanes, queues, failure counting, the bell, the brief. A target is a
  property of a round, not of the loop.
- The worker never runs `bd`, and now never sees a `.beads/` at all in a foreign target.

## What it costs

`src/config.rs` (the struct and the resolution, most of the unit tests), one line in
`src/shell.rs`, the remote names and `--repo` in `src/round.rs` and `src/merge.rs`, a
new verdict branch in `src/merge.rs`, a new human-queue state in `src/human.rs`,
`src/status.rs` and `ui/`, and the suite: a second bare origin standing in for the target
and a `gh` stub that understands `--repo` and `OWNER:BRANCH`. The state machine gains
two states (`ready to publish`, `awaiting maintainer`) and `docs/state-machine.md` two
rows.

## Decisions taken here, to override if wrong

- Route by **label**, not a bead field: `bd` has no field for it, the `pw` beads already
  use `work:`, and a label is visible in every `bd list`.
- `ask` and `plain` **by ownership**, not by a flag you must remember: forgetting on a
  collaborator's repo is the expensive mistake; forgetting on your own costs a click.
- `external` **never holds** on green. Nagging about a maintainer's queue is noise; the
  age on the page is the signal.

## Order of work

1. `[targets]` parsed and resolved per bead; `bd` on `repo.beads` — no behaviour change
   (`bl-mnt`).
2. The round on the target: remotes, `--repo`, `target/ID`; the suite's second origin
   (`bl-6hg`). After this, a `pw` bead lands as a PR on the fork's upstream under
   `merge = "manual"`.
3. `merge = "external"` (`bl-d01`) and `open_pr = "ask"` + `publish` (`bl-tka`): the two
   that make it safe on Nelson's repo.
4. `pr_style = "plain"` (`bl-p4c`), house rules (`bl-3x2`), the page and stats (`bl-b1a`),
   README + example (`bl-p5r`).
5. In preservation-workbench: the `.bead-loop.toml` with the two targets, a fork of the
   lektor repo, `setup`/`gate` that pass in a fresh worktree, and the skills under
   `.agents/skills/`.
