# Agent Ergonomics Scorecard

Generated: 2026-10-08T23:48:10Z
Source: `/workspace/ogent/agent_ergonomics_audit/audit/agent_surfaces.jsonl` (pass 4)


## Per-surface scores

| surface_id | weighted | intu | ergo | ease | parse | error | intent | safe | det | self | comp | regr |
|------------|----------|------|------|------|-------|-------|--------|------|-----|------|------|------|
| sdk_method__doctor__batch | 729 | 800 | 800 | 700 | 825 | 750 | 0 | 1000 | 775 | 750 | 825 | 800 |
| sdk_method__doctor__run | 693 | 800 | 800 | 550 | 775 | 725 | 0 | 1000 | 775 | 600 | 800 | 800 |
| sdk_method__execution__wrapper | 645 | 750 | 750 | 600 | 850 | 800 | 0 | 650 | 800 | 650 | 500 | 750 |
| sdk_method__registry__available-tools | 761 | 775 | 775 | 575 | 775 | 775 | 800 | 1000 | 750 | 600 | 800 | 750 |
| sdk_method__registry__tool-get | 668 | 750 | 850 | 450 | 750 | 250 | 500 | 1000 | 750 | 500 | 850 | 700 |
| sdk_method__registry__tool-spec-get | 706 | 800 | 800 | 550 | 775 | 250 | 500 | 1000 | 800 | 725 | 825 | 750 |
| sdk_method__tools__bash-async | 529 | 775 | 725 | 625 | 575 | 675 | 0 | 0 | 375 | 550 | 775 | 750 |
| sdk_method__tools__bash | 602 | 775 | 800 | 650 | 775 | 750 | 0 | 0 | 625 | 650 | 800 | 800 |
| sdk_method__tools__edit-file | 531 | 750 | 850 | 400 | 250 | 800 | 0 | 0 | 750 | 500 | 800 | 750 |
| sdk_method__tools__glob | 718 | 750 | 850 | 650 | 800 | 750 | 0 | 1000 | 800 | 700 | 850 | 750 |
| sdk_method__tools__grep-async | 629 | 775 | 725 | 625 | 500 | 650 | 0 | 1000 | 575 | 550 | 800 | 725 |
| sdk_method__tools__grep | 709 | 750 | 800 | 650 | 800 | 750 | 0 | 1000 | 800 | 700 | 800 | 750 |
| sdk_method__tools__read-file | 727 | 750 | 850 | 650 | 800 | 800 | 0 | 1000 | 850 | 700 | 850 | 750 |
| sdk_method__tools__write-file | 513 | 750 | 850 | 350 | 250 | 750 | 0 | 0 | 750 | 500 | 800 | 650 |
| verb__make__clean | 577 | 750 | 650 | 650 | 250 | 250 | 0 | 1000 | 750 | 600 | 800 | 650 |
| verb__make__compile | 759 | 800 | 800 | 800 | 800 | 800 | 575 | 1000 | 375 | 775 | 825 | 800 |
| verb__make__help | 668 | 875 | 725 | 825 | 250 | 425 | 125 | 1000 | 825 | 825 | 825 | 650 |
| verb__make__offline-test | 559 | 750 | 500 | 575 | 250 | 750 | 125 | 1000 | 250 | 550 | 650 | 750 |
| verb__make__recompile | 745 | 800 | 800 | 800 | 800 | 800 | 250 | 1000 | 500 | 800 | 850 | 800 |

## Distribution histogram

### Weighted score distribution (per surface)

```
   0- 99 │  (0)
 100-199 │  (0)
 200-299 │  (0)
 300-399 │  (0)
 400-499 │  (0)
 500-599 │ █████ (5)
 600-699 │ ██████ (6)
 700-799 │ ████████ (8)
 800-899 │  (0)
 900-999 │  (0)
1000     │  (0)
```

## Below-Polish-Bar surfaces (weighted < 750)

- sdk_method__doctor__batch (weighted: 729)
- sdk_method__doctor__run (weighted: 693)
- sdk_method__execution__wrapper (weighted: 645)
- sdk_method__registry__tool-get (weighted: 668)
- sdk_method__registry__tool-spec-get (weighted: 706)
- sdk_method__tools__bash-async (weighted: 529)
- sdk_method__tools__bash (weighted: 602)
- sdk_method__tools__edit-file (weighted: 531)
- sdk_method__tools__glob (weighted: 718)
- sdk_method__tools__grep-async (weighted: 629)
- sdk_method__tools__grep (weighted: 709)
- sdk_method__tools__read-file (weighted: 727)
- sdk_method__tools__write-file (weighted: 513)
- verb__make__clean (weighted: 577)
- verb__make__help (weighted: 668)
- verb__make__offline-test (weighted: 559)
- verb__make__recompile (weighted: 745)
