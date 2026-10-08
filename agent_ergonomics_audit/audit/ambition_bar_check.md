# Ambition bar check

The required self-prompt was applied verbatim before closure:

```
That's it?? I was hoping you would get a lot more practical value out of this skill.
Where are the dramatic improvements? Re-read the playbook, look at the surfaces still
scoring below 500 on output_parseability / error_pedagogy / intent_inference /
self_documentation, and ship a substantially larger batch of high-leverage changes.
You're allowed to be ambitious. Default to acting, not deliberating.
```

The initial eleven recommendations were implemented in separate commits. The
follow-up application batch added R012's actionable offline prerequisite checks
and repaired reviewed preview/accept failure reporting, MCP false/null/omission
handling, approval aliases, exact declared argument names, exact-case edits and
glob patterns, stable reviewed targets, and copyable doctor examples. Those are
actual tested changes, beyond the initial scorecard.

The audit maps twelve applied recommendations to their primary implementation
commits and regression wrappers. Some recommendations share surfaces; their
paired uplift is not an estimate of each commit's independent causal effect.
Review repairs and documentation corrections are not inflated into nineteen
independent 100-point improvements. Final per-surface and per-dimension changes
are in uplift_diff.md; count/median summaries are in manifest.json.

All five missing workflow types now exist: JSON capabilities, an embedded agent
guide, JSON doctor reports, local triage composition, and corrective errors/name
aliases. Changes cover validation, failure teaching, discovery, determinism and
regression coverage rather than one dimension. Each recommendation has genuine
baseline-fail/post-pass proof.

The remaining low dimensions received another explicit review. Text read/search/
shell results have consumers that expect their current strings; introducing a
new structured result contract across sync/async callers needs a separate versioned
API and migration plan. The existing makem logger still emits ANSI/timestamps and
compiler prose, and task/argument typo recovery does not cover every Make target.
These are documented follow-up scope, not hidden successful scores. Raw trusted
SDK mutators remain outside the registered approval boundary, so their safety
scores stay low; the new guide documents the correct gated entry point.

This pass therefore stops after the expanded application and two final clean
review rounds, with a bounded 19-surface audit. It does not certify all Armory UI
flows, arbitrary provider behavior, or production security.

Final bar: 12 primary recommendation commits; 11 dimensions with positive mean change;
median surface uplift 143; all 19 surfaces gain 100 in at least one dimension.
Deferred scope is tracked as ogent-v2fp and ogent-lkvs. The user-facing handoff
is: applied 12 fixes, added agent discovery/JSON health and safer tool contracts,
verified Emacs 29/30 and real-dependency offline workflows, then pushed master
and checked its exact CI run.

Remote CI follow-up: the doctor correction now avoids locale-dependent curly
quotes and is pinned under every Emacs quote style. It is a repair to R008,
not an additional inflated primary recommendation count.
