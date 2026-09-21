# Design: providers — any models, any number of lanes, more than one reviewer

Status: proposal, nothing built. Written 2026-09-21 from `src/` as it is, after
[design-lanes-per-server.md](design-lanes-per-server.md) (built, PR #35) and beside
[design-targets.md](design-targets.md) (orthogonal: targets say where the code lives,
providers say how the models run).

## The goal

Someone who is not the author reads the README, has a laptop with Ollama and an API
key, or a team box with three GPUs and two subscriptions, and configures the loop for
it without reading `src/`. That means three things the loop does not do today:

1. **Any model, local or paid, is a first-class stage member.** Nothing in the code
   knows a vendor. A paid model gets a lane of its own without being spelled `claude/`.
2. **As many lanes as the operator likes, each as wide as its provider allows.** A
   remote API is not one slot.
3. **More than one reviewer on a stage**, from different families or different
   harnesses, with a rule for how their verdicts combine.

And one thing it must keep: the state machine in
[state-machine.md](state-machine.md) is the product. Every state, exit and invariant
there is unchanged by this note.

## What is wrong now

The model name does three jobs. `devbox/coder` says which server (the lanes match on
the `devbox/` prefix), which harness (no prefix: opencode) and which model. `claude/sonnet`
says Claude Code by its prefix, and that prefix is read in ten places — the harness, the
probe, the default lanes, the status JSON, the scoreboard's "local" tile, the page's
Claude column and Sign in, the page server's auth check, the escalate command's wording.
`aider:devbox/coder` is a third syntax for the same idea. A model reached through a paid
API in opencode — `anthropic/claude-sonnet-4-5`, `openai/gpt-5` — runs, but it lands in
the `dev` and `review` lanes behind the GPU, one round at a time, and counts as "local"
on the scoreboard.

A lane runs one round. A stage has one worker and one reviewer, and the reviewer round
hard-codes the agent's name. The seeded config, the agent files' `model:` lines and the
README's diagram name this box's servers.

## Vocabulary

Six words, used the same way in the config, the docs, the page and the code:

| word | is | named where |
| --- | --- | --- |
| **provider** | a model endpoint: how it is reached, how many sessions it runs at once, what it costs | `[providers.NAME]`; a model is `NAME/model` |
| **harness** | the program that runs one session: `opencode`, `claude-code`, `aider`, or `command` | `harness` on the provider |
| **lane** | one consumer of the queues: the models it takes, its roles, how many rounds at once | `[[lanes]]`, or derived from the providers |
| **stage** | a worker and its reviewers, for the next `failures` send-backs | `[[stages]]`, unchanged |
| **seat** | one reviewer on a stage: a model, and optionally its own agent | the `reviewer` list |
| **role** | what a session is for: `worker`, `reviewer`, `conflict`, `brief`, `precheck`, `postmortem` | fixed; the agent files |

Two words that are on purpose not here: *server* (a provider is a server, or a slice of
one; the word adds nothing) and *vendor* (the code never learns one).

The bead labels the loop reads, the common set:

| label | means |
| --- | --- |
| `delegate:local` (the `label` key) | the loop may work this bead; unchanged |
| `harness:aider` · `harness:opencode` | this bead's worker runs under that harness, whatever the stage says; unchanged |
| `stage:NAME` | this bead starts on the named stage, not the first — the planner's escalate |

## The proposal

### Providers

```toml
[providers.devbox]                      # llama-server on this box, through opencode
probe = "http://127.0.0.1:8080/health"  # GET answers 2xx, else the lane holds with the reason
                                        # harness = "opencode", parallel = 1, cost = "local" are the defaults

[providers.anthropic]                   # a paid API, through opencode's anthropic provider
parallel = 4
cost = "metered"

[providers.claude]                      # the Claude Code subscription; probe built in (claude auth status)
harness = "claude-code"
parallel = 2
cost = "metered"

[providers.aider-devbox]                # aider, talking to devbox's server
harness = "aider"
via = "devbox"                          # the opencode provider whose baseURL and key aider uses

[providers.codex]                       # anything else: a command with the contract below
harness = "command"
command = "codex exec --full-auto -"
cost = "metered"
```

| key | default | what |
| --- | --- | --- |
| `harness` | `opencode` | `opencode` · `claude-code` · `aider` · `command` |
| `parallel` | `1` | sessions this provider runs at once — the width of its lane, and a semaphore every inline call (pre-check, post-mortem, brief) takes too |
| `cost` | `local` | `local` or `metered`; the scoreboard's "landed without metered models" reads this, nothing else does |
| `probe` | none (`claude-code`: `claude auth status`) | a URL the loop GETs before a round; a failure holds the *lane* with the reason, not the bead (this is bl-ycs) |
| `via` | required by `aider` | the opencode provider whose `baseURL` and `apiKey` the harness speaks to |
| `attach` | none | the opencode server rounds run on, for the live view and for rejoin after a restart (today a repo key; it belongs to the provider, and the repo key stays as an alias for opencode providers) |
| `command` | required by `command` | the harness command |
| `model_flag` | none | for `command`: how the model name is passed, e.g. `"--model {model}"` |

**The `command` contract**, so that any CLI is a harness without a line of Rust: the
command runs in the worktree with the prompt on stdin; `BEAD_ROLE`, `BEAD_MODEL`,
`BEAD_AGENT_PROMPT` (the agent file's body) and `BEAD_TIMEOUT` in its environment; it
writes the model's words to stdout and exits 0. The loop reads the last lines for
`DONE:` / `BLOCKED:` / `APPROVE:` / `REJECT:` exactly as it does for Claude Code. A
non-zero exit is the harness failing (the bead is held), a zero exit with no output is
"never answered" (held), and a read-only role is the command's own promise — the loop
cannot take tools away from a program it does not know, so the docs say so.

**Backward compatibility, by implicit providers.** A model naming no `[providers.X]`
gets one: `claude/*` is `harness = "claude-code", cost = "metered"`; `aider:P/M` is
aider via `P`; anything else is opencode, one slot, local. Every config that runs today
runs unchanged, and the `aider:` spelling stays as sugar.

### Lanes

**Derived by default.** Without `[[lanes]]`, the loop runs one lane per provider that
any stage, seat, `conflict_worker` or `brief_model` names, across the repos: `models =
["NAME/*"]`, both roles, `parallel` from the provider, in the order the providers first
appear. So a config whose stages say `ollama/qwen3` and `anthropic/sonnet` gets an
`ollama` lane and an `anthropic` lane and never sees the word. The `dev` + `review` pair
by role goes: it was the shape before lanes per server, and a lane per provider is what
that note wanted. (`dev` and `review` remain as names the page uses for the *queues*.)

**Explicit when the operator wants grouping.** `[[lanes]]` still replaces the defaults
— this box keeps `gpu`, `cpu`, `claude` — and gains `parallel`, default the smallest
`parallel` of the providers it matches, so a lane over `acbox/*` is as wide as ac-box.

```toml
[[lanes]]
name = "paid"
models = ["anthropic/*", "openai/*"]
parallel = 4
```

**Width.** A lane with `parallel = N` is N threads named `NAME`, `NAME.2` … `NAME.N`.
Each holds its own lock and marker (`lane.NAME.K`, one bead each); `pause NAME` pauses
all of them; the page shows one panel per lane with a row per slot. The per-provider
semaphore in `run_agent` is what keeps two lanes over one provider honest, and what
keeps a burst of pre-checks from four paid worker rounds from stacking on the one-slot
utility model: one rule for lane rounds and inline calls alike.

The two quirks of lane order stay as they are — the first lane parks exhausted beads,
the first reviewing lane takes rounds with no reviewer — and the derived order makes
them predictable: the first stage's worker's provider.

### Seats: more than one reviewer

```toml
[[stages]]
name = "local"
worker = "devbox/coder"
reviewer = ["acbox/reviewer", "anthropic/sonnet"]     # a string still means one seat
approvals = "all"                                     # all (default) · any · a number
failures = 3

[[stages]]
name = "frontier"
worker = "claude/sonnet"
reviewer = [{ model = "claude/opus" }, { model = "openai/gpt-5", agent = "bead-security-reviewer" }]
approvals = 1
failures = 1
```

- **Every seat is its own round**, taken by the lane that owns its model, so seats on
  different providers run side by side. The prompt is the same for every seat — the
  bead, the worker's report, the diff — and a seat never sees another's verdict. A blind
  vote is what a second family is for.
- **A seat may name its agent**; the default is `bead-reviewer` on every seat. That is
  the same pairing the pre-check uses (an agent file plus a model key), built once.
- **The rule.** `all`: the first `REJECT` sends the bead back; the PR opens when every
  seat has approved. `any`: the first `APPROVE` opens the PR; the bead goes back only
  when every seat has rejected. A number N: the PR at N approvals; back when N is no
  longer reachable. Whichever lane's verdict decides does the push and the PR, exactly
  the tail of today's reviewer round.
- **One work order.** The deciding `REJECT`'s block is the note the worker acts on; the
  other seats' verdicts so far are appended under it, named by model, for the record
  and the briefer. The reviewer agent's contract — a REJECT is a work order, not a grade
  — is unchanged.
- **On disk.** `review/ID` keeps the worker's last line as now; `review/ID.seats/K`
  holds seat K's verdict once it has one, and `review/ID.seats/K.running` while a lane
  is on it. A seat round is: a bead in the review queue with a seat whose file is
  missing and not running, whose model this lane takes. A seat that finishes after the
  bead has left the queue (sent back by another seat) logs its verdict and drops it.
  `rejoin/ID` becomes `rejoin/ID.K` so a restart rejoins each seat's session.
- **The PR body** gets one `Reviewer (model): APPROVE …` line per seat.

### Roles

The list is closed: `worker`, `reviewer`, `conflict`, `brief`, `precheck`, `postmortem`.
User-defined roles would dissolve the state machine; what people actually want — a
second opinion, a cheaper first look, a different prompt — is seats, the pre-check, and
a seat's `agent`. Each role has a default agent file and the keys that name its model
(`worker`/`reviewer` on the stage, `conflict_worker`, `brief_model`, `precheck_model`),
all provider/model references, all subject to the same lanes and semaphores.

### The bead's say: `stage:NAME`

Stages gain an optional `name` (default: their 1-based index as a string). A bead
labelled `stage:frontier` starts there: its failure count is floored to that stage's
first count when it is first claimed, noted on the bead. It is `escalate` at filing
time, for the planner who knows a bead is beyond the first stage — and it is how a
paid-only user with one stage and a local-only user with three read the same docs.

### What the page and the scoreboard say

- The lane panels are the lanes, one row per slot. A lane whose provider's probe fails
  says so in its panel with the reason — "signed out" for Claude Code, the HTTP error
  for a URL — and its beads wait in their queues. The Sign in flow stays as the one
  built-in fix, shown only for a `claude-code` provider.
- The Claude column becomes the **metered** column: every bead whose current stage
  names a metered provider, and where it sits. Same view, generic name.
- The scoreboard's "local" tile reads "without metered models", from `cost`.
- The GPU game/work toggle is already discovered, not configured (`gpu-mode` on PATH);
  it stays, documented as an operator hook this box happens to have.

### Defaults and docs

- `install.sh` seeds a config that names no server: a commented catalogue of provider
  shapes (llama-server through opencode, Ollama, a paid API through opencode, Claude
  Code, aider, a command) and one stage to fill in. A stage with an empty worker is a
  config error at load, said by name.
- The agent files drop their `model:` lines: the loop always passes the model.
- The README leads with the loop — queues, roles, lanes, stages, seats — with generic
  provider names in the diagram. This box becomes [examples/homelab.md](examples/homelab.md)
  (the two servers, the 4B utility model, the subscription as the last stage), beside
  three more: a laptop with Ollama and a paid reviewer; API-only, no local model, one
  wide lane; a review quorum of three families. Each is a complete pair of config files.
- [config.md](config.md) gets the providers table and the seat keys;
  [design.md](design.md#harnesses) gets the `command` contract.

## What does not change

- The state machine: every state, every exit, the invariants, the send-back counter,
  the stage table by failures, `on_exhaust`, holds and parks, the merge modes, the
  watcher, adoption, targets.
- `dev_one` and `review_one` as rounds. `review_one` runs one seat instead of one
  reviewer; the decision moves out of it into a small `quorum` function with unit tests.
- Today's config files. Every key reads as before; `claude/*` and `aider:` keep working
  through implicit providers; a single-string `reviewer` is one seat under `all`.
- The pre-check and post-mortem (epic bl-6fx): inline calls, as designed. They gain the
  provider semaphore and lose nothing.

## What it costs

- Lane width is the one real change in the loop: slot markers, locks, the status JSON's
  `lanes` value (a map of name to bead today; a map of name to a list of slots), the
  page's lane panels, recover's sweep of markers. `tick`'s idle logic counts slots.
- The review queue gains a directory per bead in review. `status`, `watch`, recover and
  the page read it.
- Two harness cases become a lookup on the provider; the ten `starts_with("claude/")`
  sites become one `provider.harness` or `provider.cost` read each.
- `test/run.sh` gains cases for a wide lane, a quorum (all / first reject / any), a
  probe holding a lane, and a `command` harness stub. The stubs in `test/bin` already
  stand in for opencode, claude and aider.

## Order of work

0. Land bl-6fx.1–.3 as filed. They touch the round at the lines they cite and nothing
   below changes them.
1. **Providers.** `[providers.*]` parsed; implicit providers for the three spellings;
   `run_agent` picks the harness from the provider; `probe` generalised and holding the
   lane (bl-ycs); `attach` on the provider; the `command` harness and its contract. A
   pure refactor: the integration suite passes unchanged. One PR.
2. **Lanes.** Derived lanes; `parallel` on lanes and providers; the semaphore; slot
   markers and locks; status JSON and the page's panels. One PR.
3. **Seats.** The reviewer list, `approvals`, `quorum`, the seats directory, per-seat
   rejoin, the PR body. One PR, with the three quorum cases.
4. **Vocabulary on the page and the board.** `cost` in stats; the metered column; probe
   failures in the lane panel; `stage:NAME` and stage names. One PR.
5. **Docs.** The README rewrite, the examples, config.md, the seeded catalogue, the
   agent files. bl-6fx.5 folds in here rather than into today's README.

## The questions to grill

- **`all` as the default rule.** It is the strict one and the slow one: a quorum of
  three waits for the slowest seat before the PR. `any` is the fast one and the weak
  one. The default should be the one a reader expects "two reviewers" to mean, and I
  think that is `all`.
- **Blind seats, always.** A sequential mode — seat two reads seat one — is a different
  instrument (a debate), cheap to add later on the same files, and not built first.
- **`command` and read-only roles.** A reviewer under an unknown CLI can edit; the loop
  reviews the diff it made, not the worktree after, so an edit by a reviewer changes
  nothing that ships — but it should be said. The alternative, refusing `command` for
  read-only roles, closes the door the harness exists to open.
- **Derived lanes across repos.** Two repos with different stages derive the union of
  providers; a provider named by one repo idles when that repo is quiet. That is a
  thread on the bell, and the cost of not making lanes per repo.
