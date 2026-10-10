---
name: emacs-ui-build
description: Implement a polished native Emacs UI from audited needs or a selected reference.
---

# Emacs UI implementation

Read the design router, pattern references, repository AGENTS/specs, and existing UI owners. Establish the current visual and behavioral baseline first. Implement the smallest coherent design system that improves the complete primary journey, including empty/attention states, contextual help, navigation, details, and refresh.

Use inherited semantic faces and buffer-local typography. Make full identifiers, provenance, provider/role/stream capabilities, and recorded evidence accessible. Choose readable wrapped rows or adaptive columns for narrow windows; keep an explicit full-detail view when appropriate. Completion must work with built-in completing-read and gain grouping/annotations automatically in Vertico or other compatible stacks.

Keep domain records and approval policy in their existing owners. No presentation helper sends inference, logs into providers, changes global bindings, changes the user’s theme, or stores data in a new format. Preserve origin context and stable selected item. New commands get meaningful interaction tests; do not test decorative pixel constants. Run strict repository lint and required behavior tests, then follow emacs-ui-qa.

For feedback on editable work, anchor comments to exact source text and display full notes in a native reader. Batch related comments through the existing request lifecycle, return bounded diffs, and preserve accepted passages until the user releases them. Treat stale anchors and malformed replacements as recoverable review states. Keep draft feedback usable after restart.

For delegated Org work, attach durable results to the original heading, keep completion from stealing focus, and distinguish run state from actual check state. Review isolated worktree patches with ordinary diff navigation and hunk comments. Preserve the user's checkout and index until explicit application. Verify the complete return-to-heading, comment, revise, and apply journey with owned process and HTTP fixtures; a static screenshot does not prove it.

Readers should expose the next action for the current state, full saved drafts and a direct route to verification output. Label a previous patch while its revision is running. Persist running/cancelled check states at the process lifecycle boundary; do not reuse an old exit code as evidence for new work. Preserve identity plus the relative text offset and window start when metadata changes, rather than retaining an absolute buffer position.
