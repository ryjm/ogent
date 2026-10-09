# Pass 3 → Pass 4 Uplift Diff

Generated: 2026-10-08T23:48:11Z

## Per-surface uplift

| surface_id | prior weighted | new weighted | Δ | improved dims | regressed dims |
|------------|----------------|--------------|---|---------------|-----------------|
| sdk_method__doctor__batch | 729 | 729 | +0 | (none) | (none) |
| sdk_method__doctor__run | 693 | 693 | +0 | (none) | (none) |
| sdk_method__execution__wrapper | 545 | 645 | +100 | agent_ease_of_use (+100); output_parseability (+600); error_pedagogy (+150); safety_with_recovery (+150); determinism_and_reproducibility (+100) | (none) |
| sdk_method__registry__available-tools | 761 | 761 | +0 | (none) | (none) |
| sdk_method__registry__tool-get | 645 | 668 | +23 | intent_inference (+250) | (none) |
| sdk_method__registry__tool-spec-get | 695 | 706 | +11 | intent_inference (+125) | (none) |
| sdk_method__tools__bash | 531 | 602 | +71 | agent_ergonomics (+50); output_parseability (+525); composability (+175) | (none) |
| sdk_method__tools__bash-async | 529 | 529 | +0 | (none) | (none) |
| sdk_method__tools__edit-file | 531 | 531 | +0 | (none) | (none) |
| sdk_method__tools__glob | 640 | 718 | +78 | agent_ergonomics (+100); output_parseability (+550); determinism_and_reproducibility (+50); self_documentation (+50); composability (+100) | (none) |
| sdk_method__tools__grep | 631 | 709 | +78 | agent_ergonomics (+50); output_parseability (+550); determinism_and_reproducibility (+50); self_documentation (+50); composability (+150) | (none) |
| sdk_method__tools__grep-async | 629 | 629 | +0 | (none) | (none) |
| sdk_method__tools__read-file | 650 | 727 | +77 | agent_ergonomics (+100); output_parseability (+550); determinism_and_reproducibility (+100); self_documentation (+50); composability (+50) | (none) |
| sdk_method__tools__write-file | 513 | 513 | +0 | (none) | (none) |
| verb__make__clean | 577 | 577 | +0 | (none) | (none) |
| verb__make__compile | 484 | 759 | +275 | agent_ergonomics (+300); agent_ease_of_use (+225); output_parseability (+550); error_pedagogy (+225); intent_inference (+575); determinism_and_reproducibility (+125); self_documentation (+275); composability (+575); regression_resistance (+150) | (none) |
| verb__make__help | 654 | 668 | +14 | agent_ease_of_use (+75); self_documentation (+75) | (none) |
| verb__make__offline-test | 559 | 559 | +0 | (none) | (none) |
| verb__make__recompile | 504 | 745 | +241 | agent_intuitiveness (+50); agent_ergonomics (+50); agent_ease_of_use (+150); output_parseability (+550); error_pedagogy (+300); intent_inference (+250); determinism_and_reproducibility (+250); self_documentation (+300); composability (+600); regression_resistance (+150) | (none) |

**Median uplift across 19 scored surfaces:** 11 pts
**Mean uplift across 19 scored surfaces:** 50 pts
