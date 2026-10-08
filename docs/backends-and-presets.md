# Backends, Models, and Presets

This document explains how ogent selects LLM backends, how model switching
works, and how presets are configured and applied.

## Overview

ogent layers on top of gptel:

- **Backends** (gptel) are transport objects that know how to talk to a
  provider (OpenAI, Anthropic, etc.).
- **Models** (ogent) are entries in `ogent-model-registry` that reference a
  backend plus optional metadata like streaming and presets.
- **Presets** (ogent + gptel) are reusable prompt configurations, usually a
  system message and parameters, registered with gptel.

## Backend switching

### Two ways to select a backend

1. **Direct gptel selection** (single model):
   - ogent uses `gptel-backend` and `gptel-model` when you send a single
     request.
   - The prompt dispatcher (`C-c . p`) exposes this as the **Model** infix
     (key `m`), which lets you pick a provider/model from gptel's known
     backends.

2. **Model registry selection** (multi-model fan-out):
   - When you choose multiple models (prompt dispatcher key `M`), ogent uses
     `ogent-model-registry` entries and resolves each entry's backend.
   - Each model entry can specify `:backend`, `:stream?`, and `:preset`.

### How backend resolution works

`ogent-ui--resolve-backend` accepts several backend forms in the model
registry:

- **Symbol** (e.g., `gptel-openai`): uses the value of the symbol if it is
  bound; otherwise ogent tries `(require 'gptel-openai)` and re-reads it.
- **String** (e.g., "openai"): ogent looks for a symbol named
  `gptel-openai` and uses it if bound; otherwise it tries to `require` it.
- **Function**: the function is called and must return a backend object.

Example registry entry. The shipped registry already includes the current
frontier models (`gpt-6-astra`, `gpt-6.1-sol`, `claude-fable-5-1`, ...), so
add your own entries with `add-to-list` instead of replacing it wholesale:

```elisp
(add-to-list 'ogent-model-registry
             '(:id "my-local-llama" :backend "openai" :stream? t
               :description "Local Llama via an OpenAI-compatible server"))
```

### Creating backends

Backends are created with gptel (or via `ogent-onboard`):

```elisp
;; Example: OpenAI backend
(setq gptel-backend
      (gptel-make-openai "OpenAI" :key "sk-..." :stream t))
(setq gptel-model "gpt-6.1-sol")
```

`M-x ogent-onboard` is the recommended path. It will create backends and
update the model registry for you.

## Current catalog

Verified against the [OpenAI catalog](https://developers.openai.com/api/docs/models)
and [Claude catalog](https://platform.claude.com/docs/en/models/overview) on
2026-10-08. The picker and registry browser work offline; listing models does
not require provider login or an API key.

| Provider | Model ID | Use | Context tokens |
| --- | --- | --- | --- |
| OpenAI | `gpt-6-astra` | Strongest reasoning and coding | 1,050,000 |
| OpenAI | `gpt-6.1-sol` | Default; intelligence and cost | 1,050,000 |
| OpenAI | `gpt-6-luna` | Fast, high-volume work | 1,050,000 |
| Anthropic | `claude-fable-5-1` | Deep reasoning and long-horizon agents | 1,000,000 |
| Anthropic | `claude-opus-5-5` | Agentic coding and knowledge work | 1,000,000 |
| Anthropic | `claude-sonnet-5-5` | Speed and intelligence | 1,000,000 |
| Anthropic | `claude-haiku-5-5` | Classification, extraction, routing | 1,000,000 |

Older registry entries and aliases retain their original meaning for saved
Org pins, sessions, and project configurations. Onboarding offers the current
lineup as the preferred choices. Explicit user defaults and role assignments remain in effect.

For actual requests, GPT-6.1 Sol function tools require a gptel **Responses API**
backend; Chat Completions supports it without tools. GPT-6 Luna supports
Chat Completions tools with `reasoning_effort: "none"`, which ogent applies only
when tools are enabled on Chat Completions. Validation runs after presets.
Current and minimum supported gptel create a Responses backend for
`api.openai.com`; custom compatible hosts may use Chat Completions.
Responses-only models (`gpt-5.5-pro`, `gpt-5.3-codex`) receive an actionable
error on Chat Completions. Presets cannot silently change a picked or pinned
model; choose that model explicitly. None of these catalog checks logs in.

Prices use uncached Standard text rates. Documented prompt-length tiers,
including Haiku 5.5 above 100K input tokens, apply to the whole request.
Caching, service tiers, residency and session-wide billing adjustments remain
outside the estimate. The per-row official-source fixture is dated 2026-10-08.

### Task roles

Different tasks can run on different models, oh-my-pi style.
`ogent-model-roles` maps roles to model ids or alias roles:

```elisp
(setq ogent-model-roles
      '((fast . "gpt-6-luna")        ; high-volume background work
        (deep . "claude-fable-5-1") ; hardest reasoning
        (edit . "gpt-6.1-sol")       ; inline edit requests
        (codemap . fast)))             ; alias: codemap follows fast
```

Unassigned roles fall back to `ogent-default-model`.  Projects can shadow
entries via `ogent-project-model-roles` in `.ogent.el`.  Org Babel blocks
accept role designators too: `#+begin_src ogent :model @deep`.

### Dispatcher shortcuts

- **Single model**: the prompt dispatcher (key `m`) sets
  `gptel-backend`/`gptel-model` for the current request; key `@` opens the
  full model picker.
- **Multiple models**: the prompt dispatcher (key `M`) selects model IDs
  from `ogent-model-registry` and streams responses side-by-side.

You can also call `ogent-request` with a list of model IDs:

```elisp
(ogent-request "Compare answers" '("gpt-6.1-sol" "claude-fable-5-1"))
```

## Preset configuration

ogent ships with defaults in `ogent-default-presets` (code review, explain,
refactor). You can add or override presets with `ogent-preset-registry`.
Each entry is a plist with `:name` (symbol) and `:spec` (plist passed to
`gptel-make-preset`).

Example:

```elisp
(setq ogent-preset-registry
      '((:name my-summary
         :spec (:description "Team summary"
                :system "Summarize decisions and open questions."))
        (:name ogent-explain
         :spec (:description "Custom explain"
                :system "Explain code with fewer words."))))
```

### Applying presets

Presets can be applied in three ways:

1. **Prompt cookie**: include `@preset-name` in the prompt text.
2. **Prompt dispatcher**: use the **Preset** infix (key `s`).
3. **Model registry**: set `:preset` on a model entry to apply a default
   preset whenever that model is used.

Example model entry with preset:

```elisp
(:id "gpt-5.5" :backend gptel-openai :stream? t :preset ogent-explain)
```

## Per-model request params & caching

Two optional registry keys surface gptel's per-model machinery:

- `:request-params`: a plist of extra parameters merged into the HTTP
  request body whenever that model is used. gptel reads it from the
  interned model symbol; ogent copies it there on each send via
  `ogent-models-apply-gptel-props`.
- `:capabilities`: gptel capability symbols added (unioned, never
  replaced) to the model symbol. The shipped Anthropic entries declare
  `(media tool-use cache)` so tool calling, image input, and prompt
  caching keep working for model IDs newer than gptel's bundled tables
  (an older gptel that predates a model would otherwise silently drop
  tools from the request).
- `:tools-request-params`: a plist merged **over** `:request-params`, but
  only for Chat Completions requests that actually carry function tools. The shipped
  `gpt-5.6` entries use it for `(:reasoning_effort "none")`, because
  OpenAI's `/v1/chat/completions` rejects a gpt-5.6 request carrying
  function tools with `400 Function tools with reasoning_effort are not
  supported` otherwise. Unlike `:request-params`, this override is bound
  per request (`gptel--request-params`) and never written onto the shared
  gptel model symbol, so a plain `gptel-send` outside ogent keeps the
  model's normal reasoning effort.

```elisp
;; OpenAI: raise reasoning effort for one model
(:id "gpt-5.5-pro" :backend gptel-openai :stream? nil
 :endpoints (responses) :request-params (:reasoning (:effort "high")))

;; Anthropic: enable extended thinking with a token budget
(:id "claude-opus-4-8" :backend gptel-anthropic :stream? t
 :capabilities (media tool-use cache)
 :request-params (:thinking (:type "enabled" :budget_tokens 4096)))
```

Prompt caching itself is controlled by `ogent-gptel-cache`, which ogent
binds to `gptel-cache` on every request. The default `t` caches the full
stable prefix (pinned context, system directive, tools); set it to `nil`
to disable, or to a list of `message`/`system`/`tool` symbols for
finer control. Only the Anthropic backend honors client-side cache
control; other backends ignore the setting.

## Example .dir-locals.el

Project-specific configuration is handy for keeping model/preset choices
consistent across a repo:

```elisp
((org-mode .
  ((ogent-default-model . "gpt-6.1-sol")
   (ogent-model-registry .
    ((:id "gpt-6.1-sol" :backend gptel-openai :stream? t :preset ogent-explain)
     (:id "claude-fable-5-1" :backend gptel-anthropic :stream? t)))
   (ogent-preset-registry .
    ((:name my-summary
      :spec (:description "Team summary"
             :system "Summarize key decisions and risks.")))))))
```

## Troubleshooting

- **"Backend ... not loaded"**
  - The backend module is missing or the backend object isn't bound.
  - Run `M-x ogent-onboard` or ensure `(require 'gptel-openai)` /
    `(require 'gptel-anthropic)` succeeds.

- **"No gptel backends configured"**
  - gptel does not know about any backends. Create one with
    `gptel-make-openai` / `gptel-make-anthropic` or use `ogent-onboard`.

- **"Unknown ogent model"**
  - The model ID is missing from `ogent-model-registry`.
  - Add it or update `ogent-default-model` to a valid ID.

- **Preset not applied**
  - Verify the preset appears in `(ogent-presets-available)` and the
    `@preset` token matches exactly.
  - If you use `:preset` in the model registry, ensure the preset name is a
    symbol (e.g., `ogent-explain`), not a string.

Prices are uncached Standard text estimates checked on 2026-10-08 against
[official OpenAI model pages](https://developers.openai.com/api/docs/models)
and [official Claude pricing](https://platform.claude.com/docs/en/about-claude/pricing).
The dated per-row fixture is `test/data/model-pricing.json`. Documented prompt
length tiers apply to the full request. Cache usage, service tiers, residency,
server tool charges and session-wide adjustments are outside the estimate.
