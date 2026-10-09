---
name: emacs-ui-build
description: Implement a polished native Emacs UI from audited needs or a selected reference.
---

# Emacs UI implementation

Read the design router, pattern references, repository AGENTS/specs, and existing UI owners. Establish the current visual and behavioral baseline first. Implement the smallest coherent design system that improves the complete primary journey, including empty/attention states, contextual help, navigation, details, and refresh.

Use inherited semantic faces and buffer-local typography. Make full identifiers, provenance, provider/role/stream capabilities, and recorded evidence accessible. Choose readable wrapped rows or adaptive columns for narrow windows; keep an explicit full-detail view when appropriate. Completion must work with built-in completing-read and gain grouping/annotations automatically in Vertico or other compatible stacks.

Keep domain records and approval policy in their existing owners. No presentation helper sends inference, logs into providers, changes global bindings, changes the user’s theme, or stores data in a new format. Preserve origin context and stable selected item. New commands get meaningful interaction tests; do not test decorative pixel constants. Run strict repository lint and required behavior tests, then follow emacs-ui-qa.
