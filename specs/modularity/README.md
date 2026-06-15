# Modularity / De-Monolithization (specs)

Plan of record for splitting the four over-threshold `ogent` source files behind
filename-preserving façades (strictly isomorphic), plus the safe execution runbook.

- `decomposition-plan.md` — per-file winner designs, file tables, migration order, rubric scores,
  runners-up, and the elisp isomorphism gate. **Authoritative spec for the beads.**
- `runbook.md` — the safe per-move procedure + gate commands + cycle/load-order rules.

Tracked work: beads epic **`ogent-xlo`** (`br show ogent-xlo`). `ogent-armory.el` is a B11 justified
monolith — left alone (rationale in the plan §5; deferred kernel-extraction option = bead `ogent-xlo.7`).

Full analysis (census, per-file seam findings, Phase-3 reader surfaces, baselines, fresh-eyes audit)
lives in the sibling workspace `../../ogent__demonolith_workspace/` (committed git repo). Plan/runbook
here are the post-audit (SHIP) versions.
