# The frontier-only control is a bench arm, not a production share

The baseline for "should this bead be delegated at all" is a bench arm whose config has
only the last (metered) stage, run on the same cases as the arm under test. We rejected
sending ~5% of production beads straight to the last stage: it spends money on live
beads, takes them from the local models, and is still uncontrolled. Until the bench
exists, the last stage's record on escalated beads stands in, read as biased toward the
hard beads.
