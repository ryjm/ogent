# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- One-key response rating (`C-c . *`, `ogent-analytics-rate-response`):
  rate the response at point 1-5 via `read-char-choice` (two keystrokes
  total).  The engine stamps each completion's analytics row id into the
  request block drawer (`OGENT_COMPLETION_ID`) at record time -- fan-out
  members onto their own Response headlines -- so any response stays
  rateable after newer requests land; re-rating updates the same row and
  sets its outcome to `rated`.
- Per-model pricing and completion cost tracking:
  `ogent-analytics-model-pricing` maps model-id prefixes (longest prefix
  wins, covering dated variants) to USD per-mtok rates, with a starter
  table for the shipped registry.  Costs are computed at record time
  into the new `completions.cost_usd` column; unpriced models store
  NULL, never 0.  The analytics schema now migrates via an idempotent
  `user_version`-pragma pattern (`ogent-analytics--migrate-schema`),
  which also adds `completions.fanout_group`: the recorder accepts a
  trailing `:fanout-group` keyword, so every fan-out member's row
  carries its shared group id while plain requests record NULL.
- Structured issue editor (`ogent-issues-edit`, bound to `e` in the issue
  list, detail view, and `?` dispatch): a form-style buffer with read-only
  chrome, freely editable title/assignee/labels/description/design/
  acceptance-criteria/notes fields, and cycling pill controls for
  priority (P0-P4), type, and status (RET/SPC/mouse to cycle, digits for
  direct selection, `=` for completion).  The header line tracks unsaved
  fields live; `C-c C-c` submits only the changed fields through a single
  `br update`, `C-c C-r` reverts the field at point, and every teardown
  path (`C-c C-k`, `C-x k`) confirms before discarding unsaved work.  On
  update failure the buffer stays intact and editable.
  `ogent-issues-bd-update` now supports title, type, assignee, design,
  acceptance criteria, notes, and label add/remove flags.
- GPT-5.6 model family (`gpt-5.6-sol`, `gpt-5.6-terra`, `gpt-5.6-luna`) and
  Claude Sonnet 5 in the model registry; `gpt-5.6-sol` is the new default.
- `ogent-model-picker` (`C-c . @`): an oh-my-pi style model cockpit for
  switching the session/buffer model, setting the default, assigning
  per-task model roles, pinning models onto Org subtrees, and browsing the
  registry as an Org table (`ogent-models-browse`).
- Model roles (`ogent-model-roles`): map tasks (`edit`, `codemap`, `fast`,
  `deep`) to models or alias roles, with per-project overrides via
  `ogent-project-model-roles` in `.ogent.el`.
- Layered model resolution (`ogent-models-effective`): inherited
  `OGENT_MODEL` Org property > task role > gptel session model > project
  model > default.  Org Babel blocks accept `@role` designators in `:model`
  and honor the inherited property.
- Official model aliases resolve everywhere via `:aliases` registry
  metadata and `ogent-models-canonical-id`: `gpt-5.6` canonicalizes to
  `gpt-5.6-sol` and `claude-haiku-4-5` to its dated id, across explicit
  requests, roles, session state, project settings, and Babel.
- Claude Fable 5 (`claude-fable-5`) is now fully supported: shipped
  Anthropic registry entries declare `media`/`tool-use`/`cache`
  capabilities so tool calling, image input, and prompt caching work
  even on gptel releases that predate the model (older gptel would
  otherwise silently drop tools from requests).
- Armory display buffers now share Magit-style section chrome through
  `ogent-ui-section`: one header-line contract, section navigation,
  point-preserving refresh, shared jump prefix, and `C-u g` force refresh
  semantics across Home, status, agents, jobs, tasks, conversations,
  search, apps, org chart, and the Zen review dashboard.
- Added a stamp-based `ogent-armory-cache` for Armory data fetches, keyed
  by root and data kind and invalidated by durable Org/app file mtimes.
- Zen transcripts now expose a `?` dispatch menu, direct run navigation,
  review target selection, result-density cycling, and a sectioned review
  dashboard using the shared ogent section UI.

### Changed
- Onboarding model catalogs now resolve from `ogent-model-registry` (single
  source of truth) instead of duplicating ids and descriptions.
- Bumped minimum transient to 0.13.5 and Org to 9.8.7.

### Fixed
- `ogent-model-unpin` is scope-aware: it deletes a direct heading pin
  silently, asks before removing an inherited ancestor pin or the
  file-wide keyword at its source, and works under subtree narrowing.
- The model registry browser remembers the buffer it was opened from,
  so refreshing or switching from inside it keeps reporting that
  buffer's effective model (including `OGENT_MODEL` pins).
- The picker's roles header wraps at token boundaries using the live
  transient window width instead of hard-wrapping mid-model-id.
- An explicit `@role` typo in a Babel `:model` header signals a user
  error instead of silently running the default model; an invalid
  `OGENT_MODEL` property binds nothing, so resolution falls through to
  the next layer and the picker reports the true source.
- Anthropic OAuth (Claude Pro/Max) requests now work with current gptel releases: the request and curl-args advice tolerate gptel's widened function arities, and the backend emits Bearer OAuth headers instead of leaking the default `x-api-key` header.
- Magit-Section 4.5.0+ compatibility: collapsible-section visibility indicators use the new `magit-section-visibility-indicators` variable when present, falling back to the deprecated singular variable on older Magit.
- Armory transient dispatch menus no longer rely on `transient-define-group`
  or named group references, so CI works with older Transient packages while
  keeping the shared jump menu generated from one project macro; shared
  section macros also avoid sandbox-only byte-compile warnings when Magit is
  absent.
- `make lint` is green again: removed an invalid `declare-function` for
  the `magit-insert-section` macro, kept EIEIO's compile-time slot
  validation out of the runtime-only edit-diff section classes, and
  repointed org-roam/flycheck/evil forward declarations at their real
  defining files (struct accessors and macro-generated commands are
  declared file-only).
- Theme visual feedback no longer uses `cl-return-from` in plain `defun`
  bodies when animations are disabled, and every `ogent-theme-*` face now
  carries a terminal fallback `:inherit` clause.
- Zen review badges and request labels use semantic `ogent-theme-*` faces,
  and active-run animation ticks now stay scoped to visible Zen buffers
  that still contain active request headings.

## [0.1.0] - 2026-06-17

### Added
- Org-first AI prompting with `@handle` context references, pinned context, and codemap-backed project slices.
- gptel-backed model and preset selection, including provider onboarding for OAuth and API-key flows.
- Companion buffers and structured response blocks for working on prompts outside Org source trees.
- Inline edit review flows with diff rendering and accept/reject mechanics for generated code changes.
- Codemap generation and project exploration helpers for navigating larger codebases from inside Emacs.
- Armory views for agents, conversations, jobs, and related operational state.
- A modularized codebase split into focused façade-backed modules instead of a single monolithic entry file.

[Unreleased]: https://github.com/ryjm/ogent/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/ryjm/ogent/releases/tag/v0.1.0
