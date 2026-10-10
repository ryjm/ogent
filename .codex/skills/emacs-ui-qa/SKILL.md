---
name: emacs-ui-qa
description: Verify native Emacs appearance and interaction across themes, window sizes, terminal, and optional integrations.
---

# Emacs UI verification

Read the design router and audit findings. Capture the exact implemented source in real Emacs; inspect final saved screenshots rather than relying on old captures or code. Verify light/dark at 60/80/112 columns, a split window, ASCII/no icon fonts, and actual terminal Emacs. Report any untested combination honestly. Check primary identifiers/actions fit; long prose wraps; details remain accessible; status is understandable without color.

Exercise keys through the actual keymap: navigate, select, open details, filter, clear filter, refresh, fold/unfold when Magit exists, and q back. Check selection, scroll, origin pin, draft, and focus survive refresh/resize. Verify plain Emacs and available Doom/Evil hooks without taking global keys. Confirm optional packages are optional and provider requests remain zero in local fixtures.

Verify newly added bindings in a fresh Emacs process. Reloading a defvar keymap keeps its old bindings and can invalidate an interactive fixture. Exercise proposal-to-diff and check-output-to-patch return paths; mutate the reader preamble and retain the selected hunk or feedback text. Navigate actual hunks from the reader's summary, not only after manually placing point inside a diff. Capture real running, failed and cancelled checks with owned processes, and confirm that unavailable actions disappear after apply/reject/cancel.

Run meaningful behavior regression tests and strict lint on the final source. Save commands, exit codes, versions, screenshot provenance, and observed limitations. Refresh evidence after any source fix. Honor the user’s publishing instructions: for this repository push directly to master and confirm CI for that exact SHA; do not open PRs.
