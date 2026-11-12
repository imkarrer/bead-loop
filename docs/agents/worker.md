# Worker primer: BAML

This repo's logic lives in `baml_src/*.baml`, compiled by `baml-cli`. It is not Python,
TypeScript or Rust: check syntax here before guessing.

## Run one test by name

```
export PATH="$(scripts/ensure-baml.sh):$PATH"
baml-cli --agent-skill-check off test -i "root.rounds::the exact test name"
```

A test's id is `root`, a dot, then its folder's name with the `ns_` prefix dropped
(`ns_rounds` becomes `rounds`), then `::`, then the test's quoted name. `baml-cli
--agent-skill-check off test --list` prints every id.

## Format before every commit

```
baml-cli --agent-skill-check off fmt
```

A file this refuses to format is a syntax error in the file, not the formatter.

## A value that may be null

It has no members until narrowed. Two forms, both real:

```
let words = b.hold?.words ?? "";
```
```
if let h: root.machine.Hold = b.hold {
```

The first reads through `?.` and falls back with `??`. The second binds the narrowed
value to a new name for the rest of the block.

## A call that can fail

Wrap it in `catch_all`, matching every case with `_`:

```
baml.fs.read(path) catch_all (e) {
    _ => "",
}
```

## Building a class literal for a test

A class literal must give every field; don't hand-write one if the file already has a
helper for it. In `step_test.baml`, `policy()` returns a full `Policy` and `bead(place)`
a full `Bead`. In `round.baml`, `spec_of(brief, note)` returns a full `RoundSpec`. Call
the helper and vary its arguments; don't restate every field by hand.

## Before using a name

Search for it first, e.g. `grep -rn <name> baml_src/`. A name from another namespace
that was never imported, or was renamed or removed, will fail to compile, and the error
will not always point at the real cause.

## Never run the whole gate

`.bead-loop.toml`'s `gate` is the full proof, including the packed binary and the
end-to-end cases; it is slow and runs after you anyway. Run `fmt` and `test` yourself
and stop there; leave the gate to the loop.
