# Modularity / De-Monolithization (specs)

Plan of record for splitting the four over-threshold `ogent` source files behind
filename-preserving façades (strictly isomorphic), plus the safe execution runbook.

- `decomposition-plan.md`: per-file winner designs, file tables, migration order, rubric scores,
  runners-up, and the elisp isomorphism gate. **Authoritative spec for the beads.**
- `runbook.md`: the safe per-move procedure + gate commands + cycle/load-order rules.

Tracked work: beads epic **`ogent-xlo`** (`br show ogent-xlo`). Status update 2026-07-13: the
kernel-extraction option (bead `ogent-xlo.7`) was **executed** — `ogent-armory-store.el` now carries
the C1+C2+C3 kernel (413 LOC, moved verbatim) behind the `ogent-armory.el` façade; the remaining
façade stays un-split (rationale in the plan §5).

Full analysis (census, per-file seam findings, Phase-3 reader surfaces, baselines, fresh-eyes audit)
lives in the sibling workspace `../../ogent__demonolith_workspace/` (committed git repo). Plan/runbook
here are the post-audit (SHIP) versions.
