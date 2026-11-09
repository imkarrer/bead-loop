# Parity with the Rust suite

The cutover ([#225](https://github.com/imkarrer/bead-loop/pull/225)) deleted `test/run.sh`:
148 cases that ran the Rust binary against stub bd, gh and models. Each case was a
lesson from production. This file lists every one of them and where the BAML loop stands
on it, so a lesson gets ported on purpose instead of being rediscovered by a bead.

When you port a case, change its row to `e2e` and name the new case. When you drop one,
change it to `dropped` and say where the drop is written down. `test/e2e/parity.sh`
checks that every row is here and that each `e2e` or `changed` row names a case
`test/e2e/cases` defines. The Rust cases are in git: `git show 8907dfa:test/run.sh`.

The rows were read from the code on 9 Nov 2026, after the bl-lkb ports (#251 to #271,
#274, #275). Line numbers drift.

## Where it stands

| status | rows | meaning |
| --- | --- | --- |
| `e2e` | 69 | a case in `test/e2e/cases` proves it against real git, bd and a gate |
| `changed` | 2 | a case keeps the Rust name but asserts what the BAML loop does instead |
| `core` | 13 | the loop does it, but only a FakeWorld test proves it; 9 of these cross the world, which FakeWorld cannot see |
| `untested` | 10 | the code is there, and no test covers it |
| `missing` | 17 | the loop does not do it |
| `dropped` | 27 | removed on purpose: opencode, aider, stamps, stats, bench, `[[lanes]]`, seats ([config.md](../../docs/config.md#not-read)) |
| `moot` | 10 | the design makes the failure impossible |

That leaves 42 rows to prove, build or decide: 3 are P1, 22 P2 and 17 P3. `port` is P1
when the live config uses the behaviour and getting it wrong wastes rounds, loses work,
or merges the wrong thing. P2 means it is used but cheap to notice. P3 is an edge case,
or unused. `seam` is yes when the behaviour crosses git, bd, gh, Claude, a model server,
the gate, a process or a restart.

## Port first

These differ from the Rust loop today, and each one was checked in the code.

1. **A red PR under `merge = "pipeline"` can rebuild forever** (row 32). When CI is red
   on a head that has already been charged, `red()` relabels (`step.baml:480`) with no
   count. After a fix round that commits nothing, every red re-run starts another build
   and is never charged. Rust charged the re-run's red. The port,
   `case_ci_red_unchanged_head_reruns`, checks the relabel and leaves that assertion out.
   bead-loop and inquire-platform merge by pipeline.
2. **A `.bead-loop.toml` that does not parse reads as empty** (row 50).
   `config_from_toml` turns the parse error into an empty table (`config.baml:201`), so
   the repo runs with `merge = "auto"` and no gate or setup. In preservation-workbench,
   which merges `manual` and `external`, one typo would turn on auto-merge. Rust stopped.
3. **Two cases now assert the new hold behaviour under the Rust names** (rows 112, 113,
   and 94). A held bead is retried every 5 ticks and noted each time, and five holds in
   a row park it (`step.baml:7`, `:75`). So a model server, or a signed-out Claude, that
   is down for five retries parks every bead that tries it. Rust doubled the backoff,
   noted once, and parked after a day. bl-lkb.15 asked the worker to report blocked
   rather than port a case the loop fails; it rewrote the assertions instead, so the
   gate now defends the change. Decide whether it is wanted: if it is, rename the cases
   and say so in [state-machine.md](../../docs/state-machine.md); if not, it is a bug.
4. **A merged bead keeps its worktree** (rows 2, 65). `closed()` deletes only the remote
   branch (`step.baml:213`), so `wt/ID` and the local `bead/ID` stay. On 9 Nov,
   bead-loop's state held 27 worktrees and 220 MB, including bl-dze.1's a day after it
   merged.
5. **A waiting PR's note repeats** (rows 35, 116). The waiting holds put the elapsed
   minutes in their words (`github.baml:190`, `:226`), and `hold_for` writes a note
   whenever the words change, so the bead gets a bd note on every look. Rust noted once.
6. **A PR closed during a rebase or feedback round goes unseen** (row 98). Only a Merging
   bead's PR is watched (`supervisor.baml:349`), and the rebase round starts without
   reading the PR, so once the round is approved the loop opens a new PR for the work you
   closed.
7. **A labelled bead someone else set in_progress is picked.** `tickets()` adds every
   labelled `in_progress` bead (`live.baml:234`), and one the loop has never seen starts
   Ready (`supervisor.baml:389`). [state-machine.md](../../docs/state-machine.md) says
   only the loop's own are picked.

Two bugs found while porting are fixed: a bead ready to publish counts toward
`max_inflight` (row 107, bl-lkb.8), and a stage with no reviewer goes straight to the PR
(row 26, bl-lkb.11).

These smaller differences came up while classifying the rows. The e2e file headers
confirm the slug, the blind second opinion and the fixed park brief; the rest were not
each re-checked:
- A usage limit holds Claude only in the repo that met it (`supervisor.baml:551`), so
  each repo and target meets it once.
- The research second opinion sees only the bead, not the first answer's BLOCK
  (`round.baml:456`).
- A `bead/ID-slug` PR is adopted with the slug inside the id (`live.baml:1208`).
- A stage with no worker runs on the Devbox default client (`clients.baml:36`).
- An unknown `work:NAME` is skipped without a word, and a bead with two `work:` labels is
  taken by both targets.
- A publishable bead does not count toward `max_inflight`.
- Park briefs are fixed text, because `ParkBriefAgent` is never called, and the
  post-mortem is gone. The README still describes both.
- An answer becomes the next round's note without the question it answers.
- Repos tick in config order, so the first one listed takes a free slot first.

## The cases

| # | Rust case | what it checked | status | seam | port | where it stands |
| --- | --- | --- | --- | --- | --- | --- |
| 1 | `case_dry_run` | `--dry-run` prints the prompt, leaves the bead alone, calls no model | missing | yes | P3 | main.baml has run/tell/lint/round only; a prompt is seen only in a round's log |
| 2 | `case_done_to_pr` | worker→reviewer→push→PR to base, in_progress, URL noted, assignee=label, worktree removed | e2e | yes | - | case_lands (+case_bd_follows_the_round); missing: no assignee set; worktree never removed, even after merge |
| 3 | `case_plain_pr` | pr_style plain: bead title, no id prefix, verify section, bead marker | untested | yes | P2 | live.baml:495-505; body is the description alone: no "How to verify", no `<!-- bead: -->` |
| 4 | `case_actor_from_env` | BEADS_ACTOR beats the label as the bd assignee | missing | yes | P3 | mark_args (live.baml:1507) writes only status and labels; no assignee is ever set |
| 5 | `case_blocked` | BLOCKED at last stage parks, line noted, model brief in worktree, nothing pushed | core | yes | P2 | step_test.baml:227, :882; brief is static text (live.baml:642); ParkBriefAgent never called |
| 6 | `case_no_commit` | no commit is noted, nothing pushed | e2e | yes | - | case_no_commit (sendbacks.sh) |
| 7 | `case_postmortem` | after a failed round the precheck model writes a post-mortem into the note | missing | yes | P2 | no post-mortem call in baml_src; note is note_of alone ("worker made no commit"); README:52 still describes it |
| 8 | `case_postmortem_unavailable` | post-mortem error: note is the tail alone, one failure, no hold | moot | yes | - | no post-mortem call exists to fail; charge as in step_test.baml:239 |
| 9 | `case_precheck_pass` | precheck PASS sits between worker and reviewer, in the worktree, logged | e2e | yes | - | case_precheck_pass (precheck.sh) |
| 10 | `case_precheck_sendback` | SEND BACK charges one failure, work order noted, reviewer skipped | e2e | yes | - | case_precheck_sendback (precheck.sh) |
| 11 | `case_precheck_unavailable` | precheck server error or crash falls through to review, uncharged | e2e | yes | - | case_precheck_unavailable (precheck.sh); one path now: the pre-check is a call inside the round |
| 12 | `case_diff_checks` | diff_checks catches placeholder tests before review | dropped | yes | - | config.md Not read; nothing raises DiffProblems (precheck.sh header) |
| 13 | `case_uncommitted_is_settled` | loop commits a done worker's leftovers, then pushes | e2e | yes | - | case_uncommitted_is_settled (sendbacks.sh); the subject is `ID: summary`, not `ID: title` |
| 14 | `case_gate_fails_twice` | gate red, one fix round fed its output, then charged, nothing pushed | e2e | yes | - | case_gate_fails_twice (sendbacks.sh), and case_red_gate_parks |
| 15 | `case_gate_fixed_on_revision` | gate red then fixed by the revision round: reviewed, pushed, two commits | e2e | yes | - | case_gate_fixed_on_revision (sendbacks.sh) |
| 16 | `case_reject_then_approve` | REJECT work order fed to next round on the kept branch; lands | e2e | yes | - | case_reject_then_approve; missing: 2nd review never sees prior work order; not told branch holds commit |
| 17 | `case_stamps_every_session` | one stamps.jsonl line per session | dropped | yes | - | #225: stamps not carried over; telemetry is the BAML trace store |
| 18 | `case_reject_until_parked` | rejects use up the stages → parked, history, model brief from logs | e2e | yes | - | case_reject_until_parked (escalation.sh); the park brief is fixed text, not built from the round logs |
| 19 | `case_claim_line` | one claim stamp, at the first claim | dropped | yes | - | #225: stamps not carried over |
| 20 | `case_lint` | lint flags missing paths and prose acceptance, notes the verdict | core | yes | P2 | lint.baml:267, :272; on_base git check and bd note untested; `linted` claim field dropped with stamps |
| 21 | `case_lint_run` | --run: setup in a throwaway worktree, green-on-base acceptance flagged | untested | yes | P2 | lint.baml:119-186 run_problems; no test |
| 22 | `case_stats_rows` | stats --rows prints JSONL, one row per bead | dropped | yes | - | #225: stats --rows and the scoreboard not carried over |
| 23 | `case_bench_freeze` | bench freeze writes case.json from the merge commit | dropped | yes | - | #225: bench freeze not carried over (offline.baml runs cases, no freeze) |
| 24 | `case_bench_freeze_hidden` | bench freeze cuts hidden tests by name | dropped | yes | - | #225: bench freeze not carried over |
| 25 | `case_rows_reverted` | stats rows flag landings reverted after 14 days | dropped | yes | - | #225: stats --rows not carried over |
| 26 | `case_no_reviewer` | a stage with no reviewer goes straight to PR | e2e | no | - | case_no_reviewer (last-stage.sh); bl-lkb.11 made a stage with no reviewer go straight to the PR (step.baml) |
| 27 | `case_two_seats_both_approve` | every seat reviews; all approve → push; PR body lists both | dropped | yes | - | config.md Not read: seat lists (`approvals`) |
| 28 | `case_two_seats_first_reject_sends_back` | "all" rule: the first seat's reject decides | dropped | no | - | config.md Not read: seat lists |
| 29 | `case_seats_any_rule` | "any" rule: one approve is enough | dropped | yes | - | config.md Not read: `approvals` |
| 30 | `case_ci_pending_then_green` | pending holds the merge; green squash-merges, deletes branch, closes bead | e2e | yes | - | case_ci_pending_then_green (merge.sh); the close reason is the URL, not the checks |
| 31 | `case_ci_red` | CI red → dev queue, +1, not re-adopted, fix pushes to the same PR | e2e | yes | - | case_ci_red (merge.sh); the note names the checks, without description or link |
| 32 | `case_ci_red_unchanged_head_reruns` | pipeline no-commit fix: relabel, old red not recharged, re-run's red charged | missing | yes | P1 | case_ci_red_unchanged_head_reruns (merge.sh) ports the relabel, not "the re-run's own red is charged": step.baml:480 relabels every red at that head, so it rebuilds forever |
| 33 | `case_ci_killed_job_reruns_once` | killed required job re-run once by relabel, then charged | e2e | yes | - | case_ci_killed_job_reruns_once (merge.sh) |
| 34 | `case_ci_red_unrequired_waits` | red only in unrequired checks waits; held after the CI timeout | e2e | yes | - | case_ci_red_unrequired_waits (merge.sh); the hold after the CI timeout is not asserted |
| 35 | `case_ci_red_unchanged_head_holds` | auto: the same red is not charged twice, held saying why | e2e | yes | - | case_ci_red_unchanged_head_holds (merge.sh); the hold is noted again every 5 ticks |
| 36 | `case_ci_red_park_briefs_in_its_own_checkout` | a CI-red park's brief runs in a checkout of the bead branch | moot | yes | - | park brief is static text from the reason (live.baml:642); no model reads any checkout |
| 37 | `case_external_green` | external: green is never merged or held; status shows awaiting | e2e | yes | - | case_external_green (adopt.sh) |
| 38 | `case_external_nocheck` | external: a PR with no checks is not merged, held or noted | e2e | yes | - | case_external_nocheck (adopt.sh); "no note either" is not asserted |
| 39 | `case_external_merged` | external: a MERGED PR closes the bead and leaves the merge queue | e2e | yes | - | case_external_merged (adopt.sh) |
| 40 | `case_external_red` | external: CI red sends the bead back, +1, failing check named | e2e | yes | - | case_external_red (adopt.sh) |
| 41 | `case_merge_pipeline` | pipeline: label on open, loop never merges on green, MERGED closes | e2e | yes | - | case_merge_pipeline (merge.sh) |
| 42 | `case_ci_skipped_build_is_not_red` | a skipped Buildkite build is not charged red; a later real red is | e2e | yes | - | case_ci_skipped_build_is_not_red (merge.sh) |
| 43 | `case_merge_pipeline_label_and_adoption` | an adopted PR gets the configured merge_label and is never merged by the loop | e2e | yes | - | case_merge_pipeline_label_and_adoption (adopt.sh) |
| 44 | `case_merge_pipeline_label_missing` | label refused: noted, still tracked, nobody merges on green | untested | yes | P2 | not ported: the gh stub cannot refuse a label (merge.sh header); supervisor.baml:104 holds on a failed relabel |
| 45 | `case_behind_then_closed_unmerged` | behind: update-branch, no merge; closed unmerged: parked, noted, untracked | e2e | yes | - | case_behind_then_closed_unmerged (merge.sh) |
| 46 | `case_inflight_limits_tick` | max_inflight = 1: no new bead picked while a PR is open | e2e | no | - | case_inflight_limits_tick (lanes.sh) |
| 47 | `case_inflight_limits_per_target` | max_inflight counts per target: a full target queue spares the default | e2e | no | - | case_inflight_limits_per_target (targets-lanes.sh); targets no longer inherit the repo's max_inflight (config.baml:495) |
| 48 | `case_nothing_ready` | a bead without the queue label is never picked | e2e | yes | - | case_nothing_ready (queue.sh) |
| 49 | `case_lock_skips` | a held state lock makes a tick a clean no-op | missing | yes | P3 | not ported: no lock file by design (resident.sh header); a second `run` on one state dir starts every round twice |
| 50 | `case_config_layers` | global stages serve repos, repo stages win, ~ in repos, bad TOML dies | core | no | P1 | config.baml:331, :343; repo-wins untested; unparseable TOML is read as empty, not a stop (config.baml:201) |
| 51 | `case_a_stage_with_no_worker_stops` | a stage with no worker, or no stages, stops the run loudly | missing | no | P2 | not ported: the stages are never checked (last-stage.sh header); a stage with no worker runs on the default client (clients.baml:36) |
| 52 | `case_escalation_stages` | failures walk fast×2 then slow×1, then park; parked bead not retried | e2e | no | - | case_escalation_stages (escalation.sh); the notes leave out the round, the model and the park count |
| 53 | `case_same_reject_twice_escalates` | the same REJECT twice jumps to the next stage's worker, noted | e2e | no | - | case_same_reject_twice_escalates (escalation.sh) |
| 54 | `case_different_rejects_do_not_escalate` | two different REJECTs stay on the current stage | e2e | no | - | case_different_rejects_do_not_escalate (escalation.sh) |
| 55 | `case_repeat_cycles` | on_exhaust = repeat cycles the stages; bead stays queued | core | no | P3 | step_test:617; not ported: no e2e case sets on_exhaust = "repeat" (escalation.sh header) |
| 56 | `case_blocked_at_last_stage_parks` | BLOCKED goes on at the first stage, parks at the last, even under repeat | e2e | no | - | case_blocked_at_last_stage_parks (last-stage.sh), under on_exhaust = "repeat" |
| 57 | `case_claude_stage_after_local_ones` | a failed local round escalates to Claude, whose prompt carries the note | e2e | yes | - | case_claude_stage_after_local_ones (last-stage.sh); only the last note reaches Claude |
| 58 | `case_aider_stage` | aider harness: provider from opencode.json, gate as lint, edit committed | dropped | yes | - | aider is gone (#225 Not ported); config.md Not read: `harness` |
| 59 | `case_command_harness` | a harness = "command" provider runs sh -c with BEAD_* env | dropped | yes | - | config.md Not read: provider keys `harness`, `command` |
| 60 | `case_harness_label` | a harness:* label overrides the stage's harness | dropped | no | - | config.md Not read: "The label `harness:*` is ignored too" |
| 61 | `case_adopts_foreign_bead_prs` | a green bead/ID-slug PR from elsewhere is merged, its bead closed; others ignored | e2e | yes | - | case_adopts_foreign_bead_prs (adopt.sh); a bead/ID-slug branch keeps the slug in the id (adopt.sh header) |
| 62 | `case_adopted_prs_do_not_block_new_work` | an adopted PR pending CI is tracked but not counted toward max_inflight | e2e | no | - | case_adopted_prs_do_not_block_new_work (adopt.sh) |
| 63 | `case_adopt_off` | adopt = false leaves other people's bead PRs alone | e2e | no | - | case_adopt_off (adopt.sh) |
| 64 | `case_closes_bead_merged_outside_the_loop` | a ready bead whose PR merged outside the loop is closed with the url | missing | yes | P2 | not ported: only a parked bead's merged PR closes it (adopt.sh header, supervisor.baml:326); the bead is worked again |
| 65 | `case_parked_bead_whose_pr_merged` | a parked bead's open PR is not adopted; once merged, bead closed, branches gone | e2e | yes | - | case_parked_bead_whose_pr_merged (adopt.sh); the worktree and local branch are kept (step.baml:213) |
| 66 | `case_status_lists_worktree_sessions` | status lists opencode sessions per worktree; ORPHAN with abort hint | dropped | yes | - | config.md Not read: `attach`; the opencode server is gone (#225) |
| 67 | `case_rejoined_session_is_not_an_orphan` | a session marked for rejoin shows REJOIN, not ORPHAN | dropped | yes | - | config.md Not read: `attach`; design-baml-native.md: the rejoin protocol is gone |
| 68 | `case_timeout_aborts_server_session` | a timed-out worker is charged and its server session aborted | dropped | yes | - | config.md Not read: `attach`, a stage's `timeout`; the timeout charge itself is live.baml:1472 |
| 69 | `case_stalled_session_is_aborted_well_under_worker_timeout` | stall_compactions/stall_steps end a stalled worker early, noted | dropped | yes | - | config.md Not read: stall_compactions, stall_steps; closest now is the probe limit (files.baml:482) |
| 70 | `case_sigterm_aborts_server_session` | SIGTERM exits 143 and aborts the running server session | moot | yes | - | rounds are detached and outlive a stop (KillMode=process), so no session is orphaned; a stop no longer frees the GPU |
| 71 | `case_stop_charges_no_failure` | a stop cuts the round short with no charge; recover reopens it | moot | yes | - | a round is its own detached process; a stop races nothing (holds-world.sh header); a lost round is case_recover_reopens_an_interrupted_round |
| 72 | `case_restart_rejoins_the_worker_session` | a restart mid-work-round costs no round; one worker call reaches the PR | e2e | yes | - | case_lands: every tick is a new process and takes the detached round's result; a plain stop no longer aborts |
| 73 | `case_restart_rejoins_no_older_rounds_session` | recover never rejoins an older round's or a Claude round's session | dropped | yes | - | design-baml-native.md §2: rounds outlive a restart, so the rejoin protocol is gone; one result file per round |
| 74 | `case_restart_rejoins_the_reviewer_session` | a restart mid-review costs no round; its APPROVE is taken | e2e | yes | - | case_lands: one tick process starts the review round, a later one takes its result |
| 75 | `case_restart_rejoins_a_seat_session` | After a restart mid seat 2's review, rejoins only that seat's opencode session | dropped | - | - | seat lists (`approvals`) and `attach` are in docs/config.md "Not read" |
| 76 | `case_recover_rejoins_a_session_that_finished_in_the_gap` | A round that finished while the loop was down is taken, not reopened | e2e | yes | - | case_lands: each tick is its own process (run.sh), so every result is taken after a restart |
| 77 | `case_recover_reopens_a_round_the_server_died_under` | A round that ended with no result is reopened, with no failure charged | core | yes | P2 | supervisor_test.baml:268, :547 (lost, uncharged, started again); step_test.baml:654 |
| 78 | `case_new_attempt_aborts_leftover_session` | A leftover session in the old worktree is aborted before the worktree is recreated | moot | - | - | no session on a server: the agent is the round process, and a live process keeps its bead Working (supervisor.baml:250) |
| 79 | `case_server_not_asked_before_its_worktree_exists` | opencode is never asked about a worktree that is not yet on disk | dropped | - | - | opencode removed (#225); the research pick prepares the worktree first (step_test.baml:834) |
| 80 | `case_status_json_and_ui` | Status JSON from bd and the server; page renders queues, flow, levers, logs, scoreboard | core | yes | P2 | supervisor_test.baml:638; page.baml:441/451/490; flow.baml:516. Scoreboard dropped (#225); decisions always [] (flow.baml:225) |
| 81 | `case_tick_goes_round_while_there_is_work` | Lanes drain both queues in one tick; max_inflight pauses the dev lane | core | no | P2 | supervisor_test.baml:201 (fewest failures first), :353 (max_inflight), :365 (max_open_prs); resident 30 s ticks replace the draining |
| 82 | `case_lanes_run_side_by_side` | Dev and review lanes run at once; both beads go through both | e2e | yes | - | case_lanes_run_side_by_side (lanes.sh) |
| 83 | `case_pause_one_lane` | `pause review` starts nothing on that lane; `resume` picks it up | missing | no | P2 | no per-lane pause: the only levers are systemd stop/timer (page.baml:177), which stop every lane |
| 84 | `case_pause_mid_round` | Pause mid-round: the round finishes, the lane starts nothing more, says so once | missing | yes | P3 | same gap: stopping the unit leaves rounds running (KillMode=process) but stops all lanes |
| 85 | `case_stale_assignee_does_not_block` | An open bead with someone else as assignee is still picked | e2e | - | - | case_stale_assignee_does_not_block (queue.sh) |
| 86 | `case_review_that_explains_itself_first_approves` | A reply that reasons first and ends APPROVE counts as an approval | moot | - | - | the verdict is a typed Decision that BAML parses (review_prompt.baml:19); no line is read from text |
| 87 | `case_long_review_replies_keep_their_verdict` | Verdict and whole work order survive replies longer than twenty lines | moot | - | - | typed Verdict and WorkOrder (review_prompt.baml:19); the work order reaching the next worker: case_reject_then_approve |
| 88 | `case_long_done_report_reaches_the_reviewer` | The worker's long DONE report reaches the review prompt whole | core | yes | P3 | round.baml:604 (typed summary saved and loaded whole) |
| 89 | `case_review_lane_waits_for_dev_to_claim` | Review lane does not leave before dev claims; the tick goes round again | moot | - | - | one sequential tick, no lane threads or locks; what dev queues is reviewed on the next tick |
| 90 | `case_slow_pickers_leave_the_tick` | Slow-picking lanes do not hold each other inside a tick | moot | - | - | same: no lane waits on another; a tick reads, starts rounds and returns (supervisor.baml:233) |
| 91 | `case_escalate_to_the_last_stage` | Escalate sets the last stage's count, reopens a parked bead, next round on Claude | e2e | no | - | case_escalate_to_the_last_stage, case_escalate_reopens_a_parked_bead (research-answers.sh); an unparked bead is refused |
| 92 | `case_human_queue_answer_and_open` | An answer reopens a parked bead and the next round reads it; `open` starts Claude | e2e | no | - | case_human_queue_answer_and_open (research-answers.sh), the answer half; `open` is gone |
| 93 | `case_brief_falls_back_to_the_loops_question` | With no brief from a model, the park question is the loop's own | core | no | P3 | park.baml:49; not ported: a park brief is always the loop's own text, ParkBriefAgent is never called (research-answers.sh header) |
| 94 | `case_claude_signed_out_beads_wait` | Claude signed out: its beads wait uncharged, others run, escalate is refused | missing | yes | P2 | not ported: no sign-in check (limits.sh header); each round is held, and five holds park the bead (step.baml:75) |
| 95 | `case_provider_probe_down_beads_wait` | A failing probe: rounds wait, with no round, no failure and no hold | dropped | - | - | state-machine.md Not built; not ported (limits.sh header): a down server is found one round at a time |
| 96 | `case_conflicting_pr_rebased_by_the_last_stage` | A CONFLICTING PR gets an uncharged rebase round (last stage or conflict_worker); same PR updated | e2e | yes | - | case_conflicting_pr_rebased_by_the_last_stage (merge.sh); conflict_worker is not asserted |
| 97 | `case_feedback_review_sends_back_to_same_pr` | A CHANGES_REQUESTED review sends the bead back on the same PR, once | e2e | yes | - | case_feedback_review_sends_back_to_same_pr (levers.sh) |
| 98 | `case_conflict_pr_closed_parks` | A conflict round whose PR closed, with the branch matching main, parks once | missing | yes | P1 | not ported: the rebase round starts without reading the PR (merge.sh header); a PR closed meanwhile gets a new one |
| 99 | `case_mergeable_unknown_is_pending_not_nocheck` | Mergeable UNKNOWN with an empty rollup is pending, not the no-checks hold | missing | yes | P3 | not ported: UNKNOWN falls through to the no-checks path (merge.sh header) |
| 100 | `case_target` | A work:NAME bead is worked in the target checkout, pushed to the fork, PR on pr_repo, closed | e2e | yes | - | case_target (targets-merge.sh) |
| 101 | `case_target_skills` | The repo's .agents skills are linked into the target worktree and excluded once | missing | yes | P3 | not ported: nothing links skills into a worktree (targets-lanes.sh header) |
| 102 | `case_target_external_merge_mode` | The target's external merge mode beats the repo's auto; the PR is not merged | e2e | no | - | case_target_external_merge_mode (targets-merge.sh) |
| 103 | `case_target_unknown` | An unknown work:NAME is held with the reason, no failure, no worktree | missing | no | P2 | not ported: an unknown work:NAME is dropped silently by takes() (targets-merge.sh header); never held |
| 104 | `case_target_review_lane` | The reviewer's diff is taken against base_remote/base (upstream/main) | e2e | yes | - | case_target_review_lane (targets-lanes.sh) |
| 105 | `case_ask_holds_the_pr` | open_pr = ask pushes the branch, opens no PR, waits for publish | e2e | yes | - | case_ask_holds_the_pr (levers.sh) |
| 106 | `case_publish` | Publish opens the proposed PR with a title override; the merge closes the bead | e2e | yes | - | case_publish (levers.sh); the body is the bead's description (#234) |
| 107 | `case_ask_counts_inflight` | A proposed (ask) bead takes one max_inflight slot | e2e | no | - | case_ask_counts_inflight (levers.sh); bl-lkb.8 made a bead ready to publish count (supervisor.baml's inflight) |
| 108 | `case_recover_leaves_a_proposed_bead` | A restart leaves a proposed bead waiting, not reopened | e2e | yes | - | case_recover_leaves_a_proposed_bead (levers.sh) |
| 109 | `case_git_refusing_the_worktree_holds` | git refusing the worktree holds the bead uncharged; it is worked once the obstacle goes | e2e | yes | - | case_git_refusing_the_worktree_holds (holds-world.sh) |
| 110 | `case_setup_failure_is_held` | A failing setup holds the bead uncharged; it is skipped while the hold is young, then retried | e2e | yes | - | case_setup_failure_is_held (holds-world.sh) |
| 111 | `case_harness_down_is_held` | A down harness holds worker or reviewer uncharged; a timeout is still a failure | e2e | yes | - | case_harness_down_is_held (holds-harness.sh); the timeout charge is not asserted |
| 112 | `case_repeated_hold_restarts_backoff` | a re-hold for the same reason restarts the backoff clock, with no second note | changed | no | P2 | case_repeated_hold_restarts_backoff (holds-harness.sh) asserts a fixed 5-tick retry and a note on every hold; Rust restarted a backoff and noted once |
| 113 | `case_hold_backs_off_exponentially_then_parks` | backoff doubles per hold; a bead held a day parks with its reason | changed | no | P2 | case_hold_backs_off_exponentially_then_parks (holds-harness.sh) asserts five holds then park (step.baml:7); Rust doubled the backoff and parked after a day |
| 114 | `case_harness_error_is_held` | server error before the model answers: held, no failure, same stage retries | e2e | yes | - | case_harness_error_is_held (holds-harness.sh); the fix-round variant is not asserted |
| 115 | `case_recover_reopens_an_interrupted_round` | round cut short by a stop: requeued uncharged, branch resumed, parked bead untouched | e2e | yes | - | case_recover_reopens_an_interrupted_round (holds-world.sh); a parked bead staying parked is not asserted |
| 116 | `case_merge_queue_holds` | PR waiting (pipeline unmerged, pending, manual, refused, no checks): held, still polled | core | yes | P2 | github.baml:311,322; step_test:422,428,452,520. "Noted once" fails: a note every minute or every clear |
| 117 | `case_one_place_invariant` | merge-queue bead refuses answer/escalate; a bead reopened by hand in bd is not re-picked | e2e | yes | - | case_one_place_invariant (queue.sh) |
| 118 | `case_priority_repo` | `priority REPO` marker puts that repo first; status shows it | missing | no | P3 | not ported: no priority command (queue.sh header); repos tick in config order (main.baml:180) |
| 119 | `case_run_is_resident` | `run` stays up, wake starts a new bead at once, TERM exits 143 | e2e | yes | - | case_run_is_resident (resident.sh); a 30 s heartbeat replaces the bell |
| 120 | `case_claude_lane_waits_on_no_local_model` | Claude-stage bead runs on its own lane beside the GPU; pause the claude lane | core | yes | P2 | supervisor_test:812,335 (one lane per provider). Lane pause/resume missing |
| 121 | `case_claude_sign_in_expiring_is_held` | Claude auth error: held with Claude's words, no failure, retried later | core | yes | P2 | step_test:280; e2e case_claude_failure_is_kept checks the words but also accepts worker_crashed |
| 122 | `case_usage_limit_holds_the_provider` | a usage limit holds this bead and every other Claude bead until reset | e2e | yes | - | case_usage_limit_holds_the_provider (limits.sh), one repo: the hold is per supervisor (supervisor.baml:551) |
| 123 | `case_usage_limit_mid_session` | a limit hit after tokens were spent is still held, uncharged | e2e | yes | - | case_usage_limit_mid_session (limits.sh) |
| 124 | `case_lanes_from_toml` | `[[lanes]]` tables define lanes that carry their models' rounds; pause one | dropped | no | - | docs/config.md "Not read": `[[lanes]]` (a lane is a provider) |
| 125 | `case_lane_with_two_slots` | parallel=2: two beads at once, each its own slot and worktree; pause | e2e | yes | - | case_lane_with_two_slots (lanes.sh); lane pause is gone |
| 126 | `case_lanes_derive_from_providers` | no `[[lanes]]`: one lane per provider runs both worker and reviewer | e2e | yes | - | case_lanes_derive_from_providers (lanes.sh) |
| 127 | `case_research_round_before_the_worker` | brief written before round 1, carried in the worker prompt, no failure | e2e | yes | - | case_research_round_before_the_worker (research-first.sh) |
| 128 | `case_researched_bead_runs_under_aider` | a brief naming existing files moves the worker to aider | dropped | yes | - | config.md "Not read": research_aider; aider gone |
| 129 | `case_harness_opencode_keeps_a_researched_bead_in_opencode` | harness:opencode label keeps the worker in opencode | dropped | yes | - | config.md "Not read": the harness:* label; opencode gone |
| 130 | `case_research_blocked_parks` | a BLOCKED the second opinion upholds parks the bead before any edit, uncharged | e2e | yes | - | case_research_blocked_parks (research-first.sh); the second opinion is not handed the first reply (round.baml:456) |
| 131 | `case_research_second_opinion_overrules_a_block` | second opinion's brief overrules the BLOCKED; worker goes on, nothing parked | e2e | yes | - | case_research_second_opinion_overrules_a_block (research-first.sh); the same gap |
| 132 | `case_research_every_refreshes` | research="every" refreshes the brief after a send-back | dropped | yes | - | state-machine.md Not built; config.md Not read; research-answers.sh header |
| 133 | `case_research_worker_does_not_wait` | worker with a free slot takes a bead that has no brief | e2e | yes | - | case_research_worker_does_not_wait (research-first.sh) |
| 134 | `case_restart_rejoins_a_research_session_as_research` | restart mid-research rejoins it as research, not as the worker | moot | yes | - | each round is its own process returning a typed RoundDone (round.baml:542); the place is folded from the log; no session to rejoin |
| 135 | `case_rejoin_refuses_a_session_of_another_round` | worker aborts a session the server titles as research | dropped | yes | - | config.md "Not read": attach; opencode sessions gone |
| 136 | `case_research_skips_an_aider_bead` | harness:aider bead skips research, empty brief | dropped | yes | - | config.md "Not read": the harness:* label; aider gone |
| 137 | `case_research_lane_feeds_the_worker_lane` | research briefs both beads, then the worker works each with its brief | core | yes | P2 | supervisor_test:233,335. By design a busy researcher leaves the second bead unbriefed |
| 138 | `case_stage_label_starts_there` | stage:NAME raises the failure count to that stage's start, noted | e2e | yes | - | case_stage_label_starts_there |
| 139 | `case_stage_label_goes_to_its_lane` | a bead labelled for the Claude stage never runs a local round | e2e | yes | - | case_stage_label_starts_there (no local-model request); supervisor_test:812 |
| 140 | `case_install_on_macos` | install.sh on Darwin writes launchd agents; a re-run leaves them alone | untested | yes | P3 | install.sh:95 launchd_agents; CI runs only bash -n and shellcheck. Still links agents into opencode |
| 141 | `case_install_from_the_package` | packaged install links through the flox env; plists run the env's binary | untested | yes | P3 | install.sh:17-27; test/package.sh only checks the files exist |
| 142 | `case_deploy_heals_empty_binary` | empty installed binary with deployed at head redeploys the same release | untested | yes | P2 | scripts/deploy.sh:57-64; no test |
| 143 | `case_deploy_syncs_before_recording` | sync runs before `deployed` is written | untested | yes | P3 | scripts/deploy.sh:133; no test |
| 144 | `case_deploy_empty_download_fails` | a 0-byte release download fails before install | untested | yes | P2 | scripts/deploy.sh:89-92; no test |
| 145 | `case_ui_on_macos` | page under launchd: log from file, launchctl Stop/Off, no timer | missing | yes | P3 | page reads journalctl/systemctl only (flow.baml:458, page.baml:177); BEAD_LOOP_LOG ignored |
| 146 | `case_setup_adds_a_repo` | add_repo puts a repo in the one-line repos list, once | untested | no | P3 | scripts/setup-macos.sh:30; no test |
| 147 | `case_configure_models` | checks llm-box serves the models, writes providers and stages, backs up old files | untested | yes | P3 | scripts/configure-models.sh:38-44; no test |
| 148 | `case_doctor` | doctor probes each dependency red/green, `--json`, page banner | missing | yes | P3 | no doctor subcommand; the page's doctor list is always empty (flow.baml:505) |
