# Issue tracker: beads

Issues and specs for this repo are beads in `.beads/`, worked with the `bd` CLI. The
`bead-loop:beads` skill has the exact syntax for this bd version; `bead-loop:breakdown`
and `bead-loop:delegate` cover cutting work into beads the loop can land.

## Conventions

- **Create**: `bd create "<title>" -t task|bug|feature|epic -d "..." --acceptance "..."`; multi-line bodies via `--body-file -` with a heredoc.
- **Read**: `bd show <id>` (or `--json`).
- **List**: `bd list --status open`, `bd ready -l <label>` for unblocked work, `bd search "text"`.
- **Child of a parent**: `bd create ... --parent <parent-id>` (ids become `<parent>.<n>`).
- **Comment**: `bd comment <id> "..."`; progress or BLOCKED notes: `bd update <id> --append-notes "<who> <date>: ..."`.
- **Labels**: `bd label add <id> <label>` / `bd label remove <id> <label>`.
- **Close**: `bd close <id> --reason "..."`, never `--status closed`.

`.beads/issues.jsonl` is tracked and the owner commits it; leave `.beads/` out of task commits.

## Handing a bead to the loop

`ready-for-agent` means a bead is fully specified. It does not put the bead on the loop's
queue. That's the `delegate:local` label (`label` in `.bead-loop.toml`); apply it per the
`bead-loop:delegate` skill.

## When a skill says "publish to the issue tracker"

Create a bead.

## When a skill says "fetch the relevant ticket"

`bd show <id>`.

## Wayfinding operations

Used by `/wayfinder`. The **map** is an epic with **child** beads as tickets.

- **Map**: an epic labelled `wayfinder:map` (`bd create -t epic -l wayfinder:map`), holding the Notes / Decisions-so-far / Fog body.
- **Child ticket**: `bd create --parent <map-id> -l wayfinder:<type>` (`research`/`prototype`/`grilling`/`task`).
- **Blocking**: `bd dep <blocker> --blocks <blocked>`. A ticket is unblocked when every blocker is closed.
- **Frontier query**: `bd ready`, scoped to the map's children; first in map order wins.
- **Claim**: `bd update <id> --claim`, the session's first write.
- **Resolve**: `bd close <id> --reason "<answer>"`, then append a gist and the id to the map's notes (`bd update <map-id> --append-notes "..."`).
