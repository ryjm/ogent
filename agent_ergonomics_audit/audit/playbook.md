# Applied ergonomics playbook

Scope: 19 primary Emacs SDK/build surfaces; no standalone CLI or provider inference.

- **R-001 — Report grep failures instead of successful no-match text:** Separate diagnostic output; reject exit codes outside 0/1 with corrective regex/path guidance. Proof: `audit/regression_tests/R-001__grep-errors.test.sh`; implementation `8579c3d`.
- **R-002 — Quote grep filters and support leading-dash patterns:** Quote each shell argument and insert end-of-options before the pattern. Proof: `audit/regression_tests/R-002__grep-arguments.test.sh`; implementation `d5b1733`.
- **R-003 — Honor recursive glob patterns with stable ordering:** Implement ** semantics including zero directory levels; reject invalid roots; sort tied mtimes by path. Proof: `audit/regression_tests/R-003__glob-recursive.test.sh`; implementation `9cef9fd`.
- **R-004 — Make file reading paginated and reject invalid bounds:** Validate path/offset/limit; make truncation and next offset discoverable. Proof: `audit/regression_tests/R-004__read-pagination.test.sh`; implementation `87f8231`.
- **R-005 — Enforce nonempty unique edit matches before mutation:** Reject empty/ambiguous old strings and normalize explicit false in review and direct paths. Proof: `audit/regression_tests/R-005__edit-contract.test.sh`; implementation `13523fa`.
- **R-006 — Validate tool arguments before approval or mutation:** Share presence/type/enum/arity validation across gptel and UI; direct writes validate content before filesystem changes. Proof: `audit/regression_tests/R-006__argument-contract.test.sh`; implementation `1114b4e`.
- **R-007 — Normalize tool names and suggest corrections safely:** Accept wire snake_case and strings for exact lookup; reject unknown configured tools with precise suggestions instead of silently removing them. Proof: `audit/regression_tests/R-007__tool-names.test.sh`; implementation `81b2e90`.
- **R-008 — Offer compatible JSON doctor reports:** Add an optional JSON format retaining the existing Org output and 0/1/2 severity contract. Proof: `audit/regression_tests/R-008__doctor-json.test.sh`; implementation `ac5940a`.
- **R-009 — Expose deterministic capabilities and an agent guide:** Export tool argument/effect/approval metadata and a safe local triage composition; document SDK entry points without provider access. Proof: `audit/regression_tests/R-009__capabilities.test.sh`; implementation `ceb7438`.
- **R-010 — Preserve shell result contracts under limits:** Validate shell arguments, bound output without losing final exit status, and preserve available async prefixes at output limits. Proof: `audit/regression_tests/R-010__bash-contract.test.sh`; implementation `28f31ec`.
- **R-011 — Make development commands report failures honestly:** Remove forced compile success, clean source and test bytecode, and document automation entry points. Proof: `audit/regression_tests/R-011__make-contract.test.sh`; implementation `fe75a37`.
- **R-012 — Explain offline prerequisites before fixture startup:** Keep missing-prerequisite failures on stderr, with exact OGENT_ELPA_DIR setup and retry. Proof: `audit/regression_tests/R-012__offline-contract.test.sh`; implementation `303fa14`.

The review extended R-003/R-005 with exact-case matching, R-005 with honest preview/acceptance state and stable reviewed paths, R-006 with native/MCP boolean representation and exact declared-key precedence, R-007 with approval alias consistency, and R-008 with a valid correction example. These are compatibility and correctness fixes, with dedicated native regressions.

Scores remain below a universal readiness threshold on text results, raw mutation APIs, async ordering, and build diagnostic streams. See HANDOFF.md for practical limits.
