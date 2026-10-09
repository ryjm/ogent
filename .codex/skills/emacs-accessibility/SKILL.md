---
name: emacs-accessibility
description: Audit and repair native Emacs keyboard access, text alternatives, contrast, wrapping, motion and recoverable interaction.
---

# Emacs accessibility

Read the native UI design contract. Walk the entire primary journey through actual keymaps in vanilla Emacs and available Evil integration: entry, draft, completion, submission, pending approval, output, cancellation, error and recovery. Use owned offline fixtures. Capture and inspect real windows before making visual claims.

Every important state needs meaningful words and a reachable action; never rely on color, icon, mouse or transient animation alone. Use inherited semantic faces that work with the user's theme. Check light/dark, 60/80/112 columns, split windows, terminal, ASCII and a larger font. Full arguments, identifiers and errors must remain searchable and copyable through a wrapped detail view. Explain approval effects and the scope of persistent choices before the decision.

Keep input editable, help outside provider text, attachments inspectable, and q/C-g behavior predictable. Preserve focus during background output and selection/scroll during refresh. Check TAB/RET parity, minibuffer cancellation, long multiline prompts, read-only boundaries and command discoverability. Respect user themes, fonts, cursor settings, reduced animation preferences and local keymaps; do not impose global bindings or settings.

Verify meaningful behavior with keyboard traces and regression tests, then capture final source again. Text reachability alone is not screen-reader compatibility: test Emacspeak or another reader if available and record its version and observed behavior; otherwise explicitly mark that support untested. Report evidence, practical consequence and repair for each finding, with honest limitations.
