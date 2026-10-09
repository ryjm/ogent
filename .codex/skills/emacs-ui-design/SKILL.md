---
name: emacs-ui-design
description: Design and improve native Emacs UI with theme-aware hierarchy, discoverable keyboard actions, and verified layouts.
---

# Emacs UI design system

Use these original native adapters for ogent UI work. They adapt the installed Product Design workflows to actual Emacs buffers; browser screenshots, CSS, Sites deployment, and image-generated mockups are replaced by real Emacs rendering and interactions. The user’s repository and instructions take precedence.

Read `references/emacs-patterns.md` before proposing a visual change. Route a critique to `emacs-ui-audit`, reference research to `emacs-ui-research`, alternative layouts to `emacs-ui-ideate`, implementation to `emacs-ui-build`, and final verification to `emacs-ui-qa`. Continue from evidence through implementation when the user asks for changes; do not introduce a design-approval pause unless a choice blocks the task.

Use `emacs-performance` for measured latency and lifecycle costs, `emacs-accessibility` for complete keyboard and readable-state checks, and `emacs-packaging` for real dependency floors, autoloads and optional integrations. These are original repository skills, not claims that an external skill was installed.

## Native contract

- Honor the user’s theme, font, completion stack, window configuration, and keybindings. Scope presentation to owned buffers. Use semantic face inheritance, never impose a global theme or fonts.
- Text remains searchable and copyable. Durable ogent records remain Org. Display properties may enrich presentation but must not hide policy, erase provenance, or change stored content.
- Put project identity, attention, and the next useful action in the first viewport. Use a small set of roles: strong structure, salient actions, faded context, subtle grouping, and critical exceptions.
- Support 60, 80, and 112 character windows, light/dark themes, Unicode and ASCII, vanilla Emacs and Doom/Evil. Responsive means usable without horizontal scrolling for the primary workflow, not silently truncating identifiers needed for a decision.
- Reuse sections, Org folding, tabulated-list-mode, completing-read metadata, transients, and standard buffer history. Optional packages improve the experience but must not become requirements.
- Preserve selected item, scroll position, fold state, draft, and originating context across refresh and navigation. Never steal focus during streaming.
- Status includes words, not color alone. Approval/effects, disabled actions, errors, and missing evidence stay explicit. Browsing must not authenticate or call providers.

## Source workflow adaptations

| Installed skill | Native adaptation |
| --- | --- |
| product-design:index | This router; existing Emacs code supplies the implementation target. |
| product-design:audit | Capture actual Emacs windows first; separate screenshot findings from keyboard/behavior evidence. |
| product-design:ideate | Compare actual renderable native layouts under the same content, theme, and width. |
| product-design:image-to-code | Translate a selected native visual reference into faces, sections, properties, windows, and keymaps. |
| product-design:url-to-code | Study a live package’s interactions and sources; clone only when explicitly requested, otherwise attribute and adapt principles. |

The five available Product Design skills were read on 2026-10-09. Their internal cloud reference files were not exposed by the skill reader; these adapters do not claim to reproduce them. Installed JSM reality-check and agent-readiness skills address project/CLI behavior, not visual design. Sites and analytical dashboards are adjacent web/data workflows, not an Emacs runtime. No cloud skill is overwritten or copied verbatim.
