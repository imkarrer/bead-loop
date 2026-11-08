# Design: BAML and measuring the agents

Status: proposed; researched 2026-11-07. BAML facts were read from its source on `canary`
at about `baml-language` 0.25.2; nothing of BAML's was installed or run, so every BAML
behaviour below is what the source and its docs say, not what was observed. Counts are
from the session logs on this box. Nothing here is built.

The question: how can the loop use BAML, locally, to get the observability it needs to
measure a change? Read [design-measurement.md](design-measurement.md) first.

## The answer

**BAML cannot observe the agents the loop runs today.** It records what runs inside its
own runtime, and the loop's sessions run inside opencode, aider and Claude Code. Its
tracing is good, local, and queryable with SQL, but it would only see a session that BAML
itself drives.

So BAML is not the route to the measurement plan. That plan's gaps are a missing bench
run, too little stamped data, and one logging hole, and none of them is a tracing
problem. BAML does fit one narrow job: **an offline eval of the reviewer**, which is one
model call on frozen inputs and can be repeated cheaply. Try it there, outside the
supervisor, and let the result decide whether it goes further.

**Overtaken 2026-11-07:** the owner chose a complete rebuild on BAML, which is
[design-baml-native.md](design-baml-native.md). "What to do" and "what not to do" answered
the narrower question of adding BAML to the current loop. BAML was run after this was
written: that doc's checks replace anything here they disagree with, such as the
`BAML_TELEMETRY_HTTP_BODIES` setting, which does not exist in 0.25.2.

## What BAML is now

BAML has changed shape, so older write-ups mislead.

- It is now "the programming language for agents" ([README]), not a prompt DSL. There are
  two lines: v0 (`0.226.x`, the `baml-cli serve`, `client<llm>` and `Collector` that
  `docs.boundaryml.com` still describes) and the new language (`baml-language-0.25.x`).
  The old `client<llm>` block is removed in the new line ([SKILL]).
- It is Apache-2.0 ([repo]) and moving fast: 15 `baml-language` releases since August,
  three of them on 6 November. Breaking changes land in point releases: `trace.rich()`
  was removed on 7 October ([#5184]).
- Rust is an **alpha** SDK, beside Go, Java, Swift and C++; only Python and TypeScript are
  beta ([SDKs]). It ships as the `baml_bridge` crate, which embeds the engine.
- It has no `serve` command any more ([commands.rs]), and no OpenAI-compatible proxy that
  I could find. The CLI has `run`, `test`, `query` and `pack`, among others.

## What it records

Anything run by the BAML engine is recorded to a local store, `.baml/btel/recordings`
([local_files.rs]), with no account: without cloud credentials a host falls back to local
recording ([btel_bcs README], [runtime_telemetry.rs]). `baml query` then runs SQL over it
through a SQLite index ([query_command.rs]), with `--format jsonl` for a script.

| what | where |
| --- | --- |
| each call: inputs, output, error, duration, parent span, usage per model | `spans` ([catalog.rs]) |
| each HTTP request: method, URL, status, bodies up to 8 MiB; secrets hashed | `network_span` rows ([#5068], [#5069]) |
| our own join keys, set by `--context` or `BAML_CONTEXT` | `context_metadata` ([run_command.rs]) |
| a run as typed events: tool calls, each `ModelCall` with usage, time to first token, raw request and response | `ai.Journal`, `on_event` ([events.baml], [SKILL]) |

Two things stand out. `BAML_CONTEXT` could carry a bead id and log stem, so a span joins
to a stamp. And a recorded reply can become an offline test: `F@parse` replays it with no
model call ([SKILL]).

## Where it stops

| the session | what BAML sees |
| --- | --- |
| opencode | nothing: its own process and its own HTTP |
| aider | nothing, same reason |
| Claude Code, launched by the loop | nothing |
| Claude Code, launched by BAML's `ClaudeCodeClient` | one turn. There is no HTTP to record, `capture_wire` is inert, and it runs with `--no-session-persistence` ([cc_cli.baml]) |
| a BAML `ai.Agent` against the local server | everything: `GenericClient` takes a `base_url` for llama.cpp ([generic.baml]) |

OpenTelemetry does not close this. The only mention found is website copy about sending
traces *to Boundary's cloud* ([adopt.tsx]); nothing ingests them into the local store.
Boundary Studio is hosted, and I found no self-hosted option.

## What the loop has today

The logs already hold most of what BAML would record, for opencode at least: every step's
tokens and cost, and every tool call with its input and output. The gaps are elsewhere.

**Almost no stamped data.** 91 stamp lines across 24 beads, in all repos. The stamp only
pays off once a slice has rows in it.

**No data at all since 30 October.** A hard stop left `~/.local/bin/bead-supervisor` as a
0-byte file, which exits 0, so the service looks healthy while the loop is dead. Deploys
fail too, on empty git objects in the deploy clone.

**The bench cannot run.** `bench freeze` exists; the `bench` run does not (`src/main.rs`).
This is the controlled comparison the whole plan rests on, and
[design-bench.md](design-bench.md)'s "nothing here is built" is now slightly stale.

**Metered sessions are the darkest.** All 585 Claude Code sessions, about $473 of the
recorded cost, leave one summary line: `harness.rs:237` asks for `--output-format json`,
and `--no-session-persistence` (`:239`) means no transcript survives. For the sessions
that cost money, there is no record of what the model did.

**Format is not the problem.** The obvious pitch for BAML is typed output replacing the
`APPROVE:` / `REJECT:` string match. The logs do not support it:

| 487 non-empty reviews | count |
| --- | --- |
| a verdict line, as asked | 429 |
| no text in the log, no error | 42 |
| no text, a harness error | 8 |
| text, but no verdict word | 6 |
| Claude Code `is_error` | 2 |
| a verdict in the wrong shape | **0** |

Typed output could reach 6 of 487. The 42 overstate real losses, because the harness
recovers a lost reply from the server after the log is written (`harness.rs:310`). These
are transport failures, and a schema does not fix a reply that never arrived.

## What to do, in order

1. **Bring the loop back.** Every other step needs rows.
2. **Make Claude Code sessions visible.** No BAML. Switch to `stream-json`, read the
   `result` line for the reply, and keep `stats.rs` `round_cost` reading it line by line.
   `harness.rs:247` parses the whole file as one JSON value today, and the `api_error`
   path depends on that parse. Small, and it covers the most expensive sessions.
3. **Build the bench run.** This is what the plan is waiting on.
4. **Try BAML on one thing: a reviewer eval, offline.** A separate `evals/reviewer/`
   project, with no change to the supervisor:
   - Input: a frozen bead and diff. Truth: the hidden check, or a landed bead reverted
     within 14 days.
   - Arms: two `GenericClient`s or two prompts over the same cases, repeated with
     `testing.Quorum(n, m)` and `PassRate` ([runners.baml]).
   - Results: `baml query --format jsonl`. `TestReport` holds only outcome, duration and
     message ([types.baml]), and I found no JUnit or JSON flag on `baml test`, so spans
     are the data.

   Why here: a review is one call, so N repeats on frozen inputs take minutes, where a
   bench run needs a worktree and a gate each time. It also measures something nothing
   measures now, how often the reviewer is right. Its limit: 102 of 285 opencode reviews
   used no tools, so a no-tool eval fairly represents only those; the rest need `ai.Agent`
   with file tools.

   As a hypothesis: *a reviewer prompt or model chosen by this eval moves bench
   hidden-check catch rate on the same cases.* If the eval's ranking does not agree with
   the bench's, drop it.
5. **Only if 4 pays off: a live seat.** `harness = "command"` already runs any command with
   the prompt on stdin (`harness.rs:267`), so `baml run` or a `baml pack` binary can be a
   seat with no Rust binding. It needs one addition: pass the log stem in the environment,
   so `BAML_CONTEXT` can carry it.
6. **Maybe, much later: a BAML worker as a bench arm.** It is the only way BAML sees a
   worker, and it fits the "harness per model family" row of the hypothesis table. It
   means writing the edit and shell tools, and `ai.Agent` defaults to 12 steps where local
   workers average about 38. A bench arm first, never production.

If raw requests from local models are ever needed across every harness, a logging proxy in
front of port 8100 sees them all. Decision 12 applies: not until a hypothesis asks.

## What not to do

- **Do not embed `baml_bridge` in the supervisor.** Alpha, and a fast-moving dependency in
  the one binary that must not break.
- **Do not port the workers to BAML to get traces.** That swaps a harness to gain
  observability, and it changes the thing being measured.
- **Do not use Boundary Studio.** Prompts carry repo code, and it is not local.

## If it is tried: the settings

```bash
export BOUNDARY_API_KEY=local      # select local recording, even with a saved login
export DO_NOT_TRACK=1              # CLI usage analytics off
export BAML_HOME="$STATE_DIR/baml" # recordings beside the loop's state
```

- **Pin the version.** `BAML_TOOLCHAIN` defaults to `canary` ([ENV_VARS.md]).
- **Check the wrapper.** Release builds of the `baml` wrapper record to Boundary through an
  embedded credential, which only `BAML_TELEMETRY=off` stops, and that also stops the
  recording we want ([TELEMETRY.md]). Calling `baml-cli` directly with
  `BAML_CLI_ALLOW_DIRECT=1` should avoid it. Confirm with no egress before trusting it.
- **Expect the store to move.** [#5539] (open) changes the path under `BAML_HOME`, and
  [#5536] (open) fixes `BAML_TELEMETRY=off` being ignored by generated SDKs. The index
  itself is disposable, rebuilt on a schema change ([schema.rs]); keep the recordings.
- **Treat recordings as sensitive.** Bodies hold prompts and code, and they can include
  the process's command line ([#5485]).

## Not verified

- That any of this runs: the first step of 4 is a smoke test with no egress.
- `GenericClient` against the box's llama.cpp server; the source says it should work.
- Schema-aligned parsing on the local models. The `bex_sap` crate has no README, and I
  took no benchmark from it, since format is not the problem here.
- A search result says v1's bridges no longer export `Collector`, in favour of
  `ai.Journal`. The 0.20.1 release body did not show that, so treat it as unconfirmed; the
  `Journal` itself was read in source.
- That the `stream-json` switch needs `--verbose` under `-p`; check when building it.
- The 1,246 empty worker logs, 1,206 of them in `inquire-platform` and `library-ai-lab`.
  One known source is `harness.rs` blanking the log on a Claude API error; the rest is
  unexplained, and worth a look before any landing rate is trusted for those repos.
- opencode's own OpenTelemetry: its status is unclear from issue threads. Its logs already
  carry the events, so this plan does not need it.

## Sources

BAML source is on `canary`, read 2026-11-07.

[README]: https://github.com/BoundaryML/baml/blob/canary/README.md
[repo]: https://github.com/BoundaryML/baml
[SKILL]: https://github.com/BoundaryML/baml/blob/canary/skills/baml-core/SKILL.md
[SDKs]: https://github.com/BoundaryML/baml/blob/canary/baml_language/sdks/README.md
[commands.rs]: https://github.com/BoundaryML/baml/blob/canary/baml_language/crates/baml_cli/src/commands.rs
[local_files.rs]: https://github.com/BoundaryML/baml/blob/canary/baml_language/crates/btel_settings/src/local_files.rs
[btel_bcs README]: https://github.com/BoundaryML/baml/blob/canary/baml_language/crates/btel_bcs/README.md
[runtime_telemetry.rs]: https://github.com/BoundaryML/baml/blob/canary/baml_language/crates/baml_cli/src/runtime_telemetry.rs
[query_command.rs]: https://github.com/BoundaryML/baml/blob/canary/baml_language/crates/baml_cli/src/query_command.rs
[catalog.rs]: https://github.com/BoundaryML/baml/blob/canary/baml_language/crates/baml_query_btel/src/catalog.rs
[schema.rs]: https://github.com/BoundaryML/baml/blob/canary/baml_language/crates/baml_query_btel/src/schema.rs
[run_command.rs]: https://github.com/BoundaryML/baml/blob/canary/baml_language/crates/baml_cli/src/run_command.rs
[events.baml]: https://github.com/BoundaryML/baml/blob/canary/baml_language/crates/baml_builtins2/baml_std/ai/ns_events/events.baml
[cc_cli.baml]: https://github.com/BoundaryML/baml/blob/canary/baml_language/crates/baml_builtins2/baml_std/claude_code/cli.baml
[generic.baml]: https://github.com/BoundaryML/baml/blob/canary/baml_language/crates/baml_builtins2/baml_std/openai/generic.baml
[runners.baml]: https://github.com/BoundaryML/baml/blob/canary/baml_language/crates/baml_builtins2/baml_std/testing/runners.baml
[types.baml]: https://github.com/BoundaryML/baml/blob/canary/baml_language/crates/baml_builtins2/baml_std/testing/types.baml
[adopt.tsx]: https://github.com/BoundaryML/baml/blob/canary/typescript2/app-website/components/home/adopt.tsx
[ENV_VARS.md]: https://github.com/BoundaryML/baml/blob/canary/baml_language/ENV_VARS.md
[TELEMETRY.md]: https://github.com/BoundaryML/baml/blob/canary/TELEMETRY.md
[#5068]: https://github.com/BoundaryML/baml/pull/5068
[#5069]: https://github.com/BoundaryML/baml/pull/5069
[#5184]: https://github.com/BoundaryML/baml/pull/5184
[#5485]: https://github.com/BoundaryML/baml/pull/5485
[#5536]: https://github.com/BoundaryML/baml/pull/5536
[#5539]: https://github.com/BoundaryML/baml/pull/5539
