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
frontier models (`gpt-5.5`, `claude-fable-5`, `claude-opus-4-8`, ...), so
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
(setq gptel-model "gpt-5.5")
```

`M-x ogent-onboard` is the recommended path. It will create backends and
update the model registry for you.

## Model selection

- **Default model**: set `ogent-default-model` to the model ID you want to use
  when no explicit selection is made.
- **Single model**: the prompt dispatcher (key `m`) sets
  `gptel-backend`/`gptel-model` for the current request.
- **Multiple models**: the prompt dispatcher (key `M`) selects model IDs
  from `ogent-model-registry` and streams responses side-by-side.

You can also call `ogent-request` with a list of model IDs:

```elisp
(ogent-request "Compare answers" '("gpt-5.5" "claude-fable-5"))
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

```elisp
;; OpenAI: raise reasoning effort for one model
(:id "gpt-5.5-pro" :backend gptel-openai :stream? nil
 :request-params (:reasoning_effort "high"))

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
  ((ogent-default-model . "gpt-5.5")
   (ogent-model-registry .
    ((:id "gpt-5.5" :backend gptel-openai :stream? t :preset ogent-explain)
     (:id "claude-fable-5" :backend gptel-anthropic :stream? t)))
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
