# Agent Ergonomics Scorecard

Generated: 2026-10-08T23:48:10Z
Source: `/workspace/ogent/agent_ergonomics_audit/audit/agent_surfaces.jsonl` (pass 3)


## Per-surface scores

| surface_id | weighted | intu | ergo | ease | parse | error | intent | safe | det | self | comp | regr |
|------------|----------|------|------|------|-------|-------|--------|------|-----|------|------|------|
| sdk_method__doctor__batch | 729 | 800 | 800 | 700 | 825 | 750 | 0 | 1000 | 775 | 750 | 825 | 800 |
| sdk_method__doctor__run | 693 | 800 | 800 | 550 | 775 | 725 | 0 | 1000 | 775 | 600 | 800 | 800 |
| sdk_method__execution__wrapper | 545 | 750 | 750 | 500 | 250 | 650 | 0 | 500 | 700 | 650 | 500 | 750 |
| sdk_method__registry__available-tools | 761 | 775 | 775 | 575 | 775 | 775 | 800 | 1000 | 750 | 600 | 800 | 750 |
| sdk_method__registry__tool-get | 645 | 750 | 850 | 450 | 750 | 250 | 250 | 1000 | 750 | 500 | 850 | 700 |
| sdk_method__registry__tool-spec-get | 695 | 800 | 800 | 550 | 775 | 250 | 375 | 1000 | 800 | 725 | 825 | 750 |
| sdk_method__tools__bash-async | 529 | 775 | 725 | 625 | 575 | 675 | 0 | 0 | 375 | 550 | 775 | 750 |
| sdk_method__tools__bash | 531 | 775 | 750 | 650 | 250 | 750 | 0 | 0 | 625 | 650 | 625 | 775 |
| sdk_method__tools__edit-file | 531 | 750 | 850 | 400 | 250 | 800 | 0 | 0 | 750 | 500 | 800 | 750 |
| sdk_method__tools__glob | 640 | 750 | 750 | 650 | 250 | 750 | 0 | 1000 | 750 | 650 | 750 | 750 |
| sdk_method__tools__grep-async | 629 | 775 | 725 | 625 | 500 | 650 | 0 | 1000 | 575 | 550 | 800 | 725 |
| sdk_method__tools__grep | 631 | 750 | 750 | 650 | 250 | 750 | 0 | 1000 | 750 | 650 | 650 | 750 |
| sdk_method__tools__read-file | 650 | 750 | 750 | 650 | 250 | 800 | 0 | 1000 | 750 | 650 | 800 | 750 |
| sdk_method__tools__write-file | 513 | 750 | 850 | 350 | 250 | 750 | 0 | 0 | 750 | 500 | 800 | 650 |
| verb__make__clean | 577 | 750 | 650 | 650 | 250 | 250 | 0 | 1000 | 750 | 600 | 800 | 650 |
| verb__make__compile | 484 | 775 | 500 | 575 | 250 | 575 | 0 | 1000 | 250 | 500 | 250 | 650 |
| verb__make__help | 654 | 875 | 725 | 750 | 250 | 425 | 125 | 1000 | 825 | 750 | 825 | 650 |
| verb__make__offline-test | 559 | 750 | 500 | 575 | 250 | 750 | 125 | 1000 | 250 | 550 | 650 | 750 |
| verb__make__recompile | 504 | 750 | 750 | 650 | 250 | 500 | 0 | 1000 | 250 | 500 | 250 | 650 |

## Distribution histogram

### Weighted score distribution (per surface)

```
   0- 99 │  (0)
 100-199 │  (0)
 200-299 │  (0)
 300-399 │  (0)
 400-499 │ █ (1)
 500-599 │ ████████ (8)
 600-699 │ ████████ (8)
 700-799 │ ██ (2)
 800-899 │  (0)
 900-999 │  (0)
1000     │  (0)
```

## Below-Polish-Bar surfaces (weighted < 750)

- sdk_method__doctor__batch (weighted: 729)
- sdk_method__doctor__run (weighted: 693)
- sdk_method__execution__wrapper (weighted: 545)
- sdk_method__registry__tool-get (weighted: 645)
- sdk_method__registry__tool-spec-get (weighted: 695)
- sdk_method__tools__bash-async (weighted: 529)
- sdk_method__tools__bash (weighted: 531)
- sdk_method__tools__edit-file (weighted: 531)
- sdk_method__tools__glob (weighted: 640)
- sdk_method__tools__grep-async (weighted: 629)
- sdk_method__tools__grep (weighted: 631)
- sdk_method__tools__read-file (weighted: 650)
- sdk_method__tools__write-file (weighted: 513)
- verb__make__clean (weighted: 577)
- verb__make__compile (weighted: 484)
- verb__make__help (weighted: 654)
- verb__make__offline-test (weighted: 559)
- verb__make__recompile (weighted: 504)
