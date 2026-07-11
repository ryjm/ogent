# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
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
