---
name: emacs-ui-audit
description: Audit native Emacs screens and workflows from actual screenshots and keyboard evidence.
---

# Emacs UI audit

Read the design router and research references. Before reporting visual defects, capture the current real Emacs interface with owned offline fixtures. Inspect each saved image. Capture representative entry, selection, details, empty, error, and attention states at normal and narrow widths. Record Emacs/package versions, theme, font, columns, fixture, source commit, and exact filenames.

Report a small set of findings with severity, screenshot or interaction reference, observed behavior, user consequence, and concrete repair. Keep screenshot observations distinct from code inspection, automated assertions, and live keyboard traces. Test focus, selection, refresh, abort, folding, mouse/RET parity, and q-return separately; a screenshot cannot prove them. Never claim provider integration from offline fixtures.

Use an inline report by default. Save durable evidence only when useful to the ongoing repository work. If the user requests fixes, carry the audit through implementation and QA rather than ending with recommendations.
