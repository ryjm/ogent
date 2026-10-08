# Pass 1 → Pass 2 Uplift Diff

Generated: 2026-10-08T19:16:29Z

## Per-surface uplift

| surface_id | prior weighted | new weighted | Δ | improved dims | regressed dims |
|------------|----------------|--------------|---|---------------|-----------------|
| sdk_method__doctor__batch | 745 | 861 | +116 | agent_intuitiveness (+75); agent_ergonomics (+75); agent_ease_of_use (+150); output_parseability (+500); error_pedagogy (+50); determinism_and_reproducibility (+50); self_documentation (+175); composability (+100); regression_resistance (+100) | (none) |
| sdk_method__doctor__run | 795 | 827 | +32 | agent_ease_of_use (+175); self_documentation (+150); regression_resistance (+50) | (none) |
| sdk_method__execution__wrapper | 518 | 650 | +132 | agent_intuitiveness (+50); agent_ergonomics (+100); agent_ease_of_use (+175); error_pedagogy (+500); safety_with_recovery (+75); self_documentation (+200); composability (+100); regression_resistance (+200) | (none) |
| sdk_method__registry__available-tools | 602 | 815 | +213 | agent_intuitiveness (+50); agent_ease_of_use (+175); error_pedagogy (+750); intent_inference (+775); self_documentation (+225); regression_resistance (+275) | (none) |
| sdk_method__registry__tool-get | 563 | 704 | +141 | agent_intuitiveness (+150); agent_ease_of_use (+225); intent_inference (+500); self_documentation (+325); regression_resistance (+275) | (none) |
| sdk_method__registry__tool-spec-get | 602 | 720 | +118 | agent_intuitiveness (+50); agent_ease_of_use (+225); intent_inference (+500); determinism_and_reproducibility (+50); self_documentation (+200); regression_resistance (+250) | (none) |
| sdk_method__tools__bash | 481 | 672 | +191 | agent_intuitiveness (+50); agent_ease_of_use (+175); output_parseability (+125); error_pedagogy (+575); determinism_and_reproducibility (+550); self_documentation (+325); composability (+200); regression_resistance (+150) | agent_ergonomics (-50) |
| sdk_method__tools__bash-async | 622 | 720 | +98 | agent_intuitiveness (+50); agent_ease_of_use (+75); error_pedagogy (+475); determinism_and_reproducibility (+100); self_documentation (+100); composability (+75); regression_resistance (+200) | (none) |
| sdk_method__tools__edit-file | 334 | 572 | +238 | agent_intuitiveness (+375); agent_ergonomics (+125); agent_ease_of_use (+275); error_pedagogy (+600); determinism_and_reproducibility (+125); self_documentation (+325); composability (+375); regression_resistance (+400) | (none) |
| sdk_method__tools__glob | 481 | 677 | +196 | agent_intuitiveness (+425); agent_ergonomics (+150); agent_ease_of_use (+250); error_pedagogy (+500); determinism_and_reproducibility (+75); self_documentation (+350); composability (+75); regression_resistance (+300) | (none) |
| sdk_method__tools__grep | 322 | 688 | +366 | agent_intuitiveness (+125); agent_ergonomics (+100); agent_ease_of_use (+200); output_parseability (+225); error_pedagogy (+750); safety_with_recovery (+1000); determinism_and_reproducibility (+550); self_documentation (+250); composability (+500); regression_resistance (+325) | (none) |
| sdk_method__tools__grep-async | 531 | 715 | +184 | agent_intuitiveness (+50); agent_ease_of_use (+100); error_pedagogy (+425); safety_with_recovery (+1000); self_documentation (+150); composability (+75); regression_resistance (+175) | (none) |
| sdk_method__tools__read-file | 561 | 704 | +143 | agent_intuitiveness (+75); agent_ergonomics (+75); agent_ease_of_use (+200); error_pedagogy (+550); self_documentation (+300); composability (+75); regression_resistance (+250) | (none) |
| sdk_method__tools__write-file | 406 | 586 | +180 | agent_ease_of_use (+300); output_parseability (+50); error_pedagogy (+750); determinism_and_reproducibility (+50); self_documentation (+375); composability (+100); regression_resistance (+300) | (none) |
| verb__make__clean | 454 | 604 | +150 | agent_ease_of_use (+400); determinism_and_reproducibility (+50); self_documentation (+400); composability (+50); regression_resistance (+750) | (none) |
| verb__make__compile | 422 | 522 | +100 | agent_ergonomics (+50); agent_ease_of_use (+200); self_documentation (+250); regression_resistance (+650) | agent_intuitiveness (-50) |
| verb__make__help | 493 | 631 | +138 | agent_intuitiveness (+50); agent_ergonomics (+50); agent_ease_of_use (+250); error_pedagogy (+75); self_documentation (+275); composability (+50); regression_resistance (+750) | (none) |
| verb__make__offline-test | 550 | 654 | +104 | agent_intuitiveness (+50); agent_ease_of_use (+250); output_parseability (+250); error_pedagogy (+300); self_documentation (+200); composability (+50); regression_resistance (+50) | (none) |
| verb__make__recompile | 277 | 540 | +263 | agent_intuitiveness (+500); agent_ergonomics (+150); agent_ease_of_use (+400); output_parseability (+250); error_pedagogy (+250); self_documentation (+400); composability (+250); regression_resistance (+750) | determinism_and_reproducibility (-50) |

**Median uplift across 19 scored surfaces:** 143 pts
**Mean uplift across 19 scored surfaces:** 163 pts

## Regressions (per-dim drop > 25 pts)

| surface_id | dim | prior | new | Δ |
|------------|-----|-------|-----|---|
| sdk_method__tools__bash | agent_ergonomics | 850 | 800 | -50 |
| verb__make__compile | agent_intuitiveness | 750 | 700 | -50 |
| verb__make__recompile | determinism_and_reproducibility | 700 | 650 | -50 |
