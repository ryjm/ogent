# Emacs patterns researched for ogent

Observed 2026-10-09. Public GitHub metadata, pinned upstream source, and native reference images were inspected. This is a relevance/adoption shortlist, not an objective ranking of beauty or universal user love. Stars are supporting attention evidence only. The JSON records exact metadata and source revisions; no upstream assets/code are copied into the product.

Adoption snapshot: Doom 22,737; Magit 7,241; gptel 3,547; Nano 2,946; Doom themes 2,424; Org Modern 1,955; agent-shell 1,934; Vertico 1,892; which-key 1,796; Consult 1,665; Corfu 1,544; Dashboard 1,532; Marginalia 989; Elpaca 954; Modus 912. The initial Treemacs fork was the wrong comparison: canonical Alexander-Miller/treemacs had 2,367 stars. Framework/theme/tool categories are not a common ranking. Corfu, Marginalia, and which-key were metadata context, not source-reviewed implementations.

| Pinned source | Learning | ogent application and verification |
| --- | --- | --- |
| [magit/magit: lisp/magit-section.el](https://github.com/magit/magit/blob/49504a982b7d8948da297e1ab515bece4008273d/lisp/magit-section.el) | Stable section identities, fold visibility, contextual actions; refresh should keep the selected work in place. | Section refresh and Home navigation; test reorder/remove/fold and viewport behavior. |
| [minad/consult: README.org](https://github.com/minad/consult/blob/a64569f377b8bc0f62e1d2ae0f3ee48ba4a7cc1c/README.org) | Standard completing-read, grouped sources and reversible preview make a fast contextual chooser. | Model completion metadata and find-model action; do not dispatch inference on preview. |
| [minad/vertico: README.org](https://github.com/minad/vertico/blob/a9998a777f1d92348f84d091bb15b87df933a7a2/README.org) | Minimal correct completion with annotations and groups composes with existing Emacs setup. | Preserve builtin completion and enrich it; no mandatory completion package. |
| [protesilaos/modus-themes: modus-themes.el](https://github.com/protesilaos/modus-themes/blob/aedb41742ff326fa4884136300155ca21a0bd628/modus-themes.el) | Semantic palette mappings, high contrast, and color-deficiency variants belong to the chosen theme. | Inherit link/success/warning/error/shadow; status also has explicit words. |
| [rougier/nano-emacs: nano-faces.el](https://github.com/rougier/nano-emacs/blob/12fbfebec39f72a133c8751cadf3d311b93f5e7f/nano-faces.el) | Strong, salient, faded, subtle, critical and popout roles separate structure from attention. Native screenshots show calm spacing and compact header context. | Compact identity, consistent headings and sparse critical color; never import global font/theme setup. |
| [minad/org-modern: README.org](https://github.com/minad/org-modern/blob/d106d02cf045cc968c09989e9c48e0f2b44c574c/README.org) | Text properties enrich Org while content stays editable/searchable; spacing and fixed/variable pitch need compatibility checks. | Native wrapped catalog rows and small local spacing; preserve durable Org. |
| [progfolio/elpaca: doc/manual.org](https://github.com/progfolio/elpaca/blob/dd3b3fd1547382a52ed5ace4a4b090e60502cf60/doc/manual.org) | A contextual table with a visible query and explicit actions keeps the current working set understandable. | Agent filter with visible state, stable row IDs, and full details reachable through profiles. |
| [xenodium/agent-shell: README.org](https://github.com/xenodium/agent-shell/blob/d9493d8921a6ade0c3a4c561db092803f0595e83/README.org) | Header state exposes selections; viewport separates composing and reading; folding gives tool output useful hierarchy. | Keep model source/provider visible; preserve drafts and origin; do not reproduce its large provider banner. |
| [karthink/gptel: README.org](https://github.com/karthink/gptel/blob/406432d83f8a76e7af54d88c97df1863bd9a9119/README.org) | Work in normal editable Emacs buffers, use transients, and let the user choose model/backend without imposing a chat UI. | Keep Org model browser and picker native and provider-free. |
| [doomemacs/themes: README.md](https://github.com/doomemacs/themes/blob/a59202912ad55014e53a685eee6cd94130bdd4fd/README.md) | Themes support many faces/packages; integration should fit the existing environment. | Inherit existing theme semantics and preserve local Doom/Evil maps. |
| [emacs-dashboard/dashboard: README.org](https://github.com/emacs-dashboard/dashboard/blob/a2c49ba27f3a906fd8b059da55104c1ec562b8b6/README.org) | An entry point links to recent work and useful actions; banners are optional styling. | Home should prioritize attention and work; retain crest as opt-in. |

## Visual references actually inspected

- Nano `images/nano-emacs-light.png`: strong title, quieter context, consistent monospace rhythm, generous whitespace. Its very pale metadata should not be copied as a contrast guarantee.
- agent-shell `agent-shell.png`: visible model/mode state and folded tool hierarchy. The huge provider banner is not suitable for ogent’s operational Home.
- ogent baseline `docs/assets/emacs-ui/before-home-light.png`: 26-line crest precedes useful work, attention not visible in the first 42-line viewport.
- ogent baseline `before-models-narrow.png`: description and capabilities clip at 72 columns.
- ogent baseline `before-agents-light.png`: 14 columns hide status/activity even at 112 columns.

## Acceptance gates

1. Home exposes identity, attention and a useful next action in the first viewport; no mandatory decoration.
2. Model choices keep full IDs, provider, source, role/capability context and honest recorded evidence readable at narrow widths. Full table remains available for users who want it.
3. Lists expose a compact primary working set with find/filter and access to complete records; filtering is explicit, reversible, and stable across refresh.
4. No global theme/font/key changes or mandatory icon/completion packages. Theme roles and ASCII fallback must work.
5. Native captures and actual keyboard traces accompany behavior tests. No provider login, inference, or fabricated success evidence.

## Lessons from applying the skills

- Check the actual active keymap. In real Evil normal state, ogent preserves the universal `g` prefix and refresh is `gr`; headers must show that live binding. The model catalog needs the same optional display-mode integration as Armory.
- Resize after rendering, then wait for redisplay before capturing. A successful evaluator return does not prove the new X window has painted. Reflow must redraw in place without calling `pop-to-buffer`.
- Use `font-lock-face` for custom Org presentation; Org fontification can replace ordinary face properties. Keep words searchable and complete.
- Style the composer header outside its editable content. Guidance inserted into a draft becomes provider prompt text; header presentation avoids that contamination.

- Test actual fontification with optional Magit loaded. Manually rendered section faces need protection from font-lock; the fallback special-mode may look correct while the optional mode strips the hierarchy. Set local split-window wrapping explicitly.
- Buffer-local window resize callbacks must use the supplied window's buffer explicitly. Redisplay may run while another buffer is current, including during theme changes or inactive split-window resizing. Verify cached render width against actual body width and exercise callbacks from an unrelated current buffer.
