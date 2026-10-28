# The headline metric puts no price on human time

The headline is metered USD per landed bead, always read beside landing rate and human
touches per landed bead; the guardrail is defects after merge (a revert, or a later bead
linked to it by a `caused-by` dependency, within 14 days). We rejected the proposed `USD + minutes × owner rate`: no
minutes are measured, and a made-up rate would let a config buy fewer dollars with more
of the owner's time without that showing. The definitions are fixed before any tuning,
so changing them later breaks every comparison made under them.
