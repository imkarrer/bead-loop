# The stamp is its own record, hashed by content

Every model session gets a stamp in a new per-bead file, `beads/ID/stamps.jsonl`, one line
each, carrying its round, kind and log stem, rather than fields on `rounds.jsonl` (send-backs
only, and read into the worker's prompt, so it cannot hold the round that lands without
growing the prompt) or a sidecar beside the log (which `logs_of` would sweep into the
brief). The stamp records `loop_sha` and a dirty flag, and also hashes the agent file
and the skills tree by content, because `install.sh` links `agents/` and `skills/` into
the checkout's working tree: the prompts a round sees can differ from the commit the
binary was built from, so the sha alone would mislabel them.
