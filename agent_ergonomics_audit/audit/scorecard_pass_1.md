# Agent Ergonomics Scorecard

Generated: 2026-10-08T19:16:29Z
Source: `agent_ergonomics_audit/audit/agent_surfaces.jsonl` (pass 1)


## Per-surface scores

| surface_id | weighted | intu | ergo | ease | parse | error | intent | safe | det | self | comp | regr |
|------------|----------|------|------|------|-------|-------|--------|------|-----|------|------|------|
| sdk_method__doctor__batch | 745 | 750 | 800 | 650 | 350 | 750 | 1000 | 1000 | 750 | 650 | 750 | 750 |
| sdk_method__doctor__run | 795 | 850 | 850 | 500 | 850 | 750 | 1000 | 1000 | 750 | 600 | 850 | 750 |
| sdk_method__execution__wrapper | 518 | 725 | 725 | 525 | 275 | 275 | 0 | 625 | 700 | 550 | 675 | 625 |
| sdk_method__registry__available-tools | 602 | 750 | 800 | 525 | 775 | 100 | 0 | 1000 | 775 | 550 | 825 | 525 |
| sdk_method__registry__tool-get | 563 | 625 | 800 | 425 | 750 | 125 | 0 | 1000 | 725 | 425 | 825 | 500 |
| sdk_method__registry__tool-spec-get | 602 | 750 | 800 | 450 | 825 | 125 | 0 | 1000 | 750 | 575 | 825 | 525 |
| sdk_method__tools__bash-async | 622 | 750 | 850 | 650 | 750 | 250 | 1000 | 0 | 600 | 650 | 750 | 600 |
| sdk_method__tools__bash | 481 | 750 | 850 | 500 | 200 | 150 | 1000 | 0 | 250 | 400 | 550 | 650 |
| sdk_method__tools__edit-file | 334 | 375 | 675 | 425 | 225 | 250 | 0 | 0 | 525 | 425 | 375 | 400 |
| sdk_method__tools__glob | 481 | 375 | 650 | 450 | 250 | 250 | 0 | 1000 | 725 | 400 | 725 | 475 |
| sdk_method__tools__grep-async | 531 | 750 | 800 | 600 | 700 | 375 | 0 | 0 | 675 | 600 | 750 | 600 |
| sdk_method__tools__grep | 322 | 675 | 700 | 500 | 100 | 50 | 0 | 0 | 250 | 500 | 300 | 475 |
| sdk_method__tools__read-file | 561 | 750 | 800 | 525 | 300 | 275 | 0 | 1000 | 775 | 475 | 750 | 525 |
| sdk_method__tools__write-file | 406 | 750 | 800 | 350 | 200 | 50 | 0 | 125 | 725 | 350 | 650 | 475 |
| verb__make__clean | 454 | 750 | 750 | 250 | 250 | 250 | 0 | 1000 | 750 | 250 | 750 | 0 |
| verb__make__compile | 422 | 750 | 650 | 450 | 250 | 250 | 0 | 1000 | 650 | 400 | 250 | 0 |
| verb__make__help | 493 | 875 | 625 | 500 | 0 | 250 | 125 | 1000 | 775 | 500 | 775 | 0 |
| verb__make__offline-test | 550 | 750 | 750 | 500 | 100 | 500 | 0 | 1000 | 500 | 500 | 700 | 750 |
| verb__make__recompile | 277 | 250 | 600 | 250 | 0 | 0 | 0 | 1000 | 700 | 250 | 0 | 0 |

## Distribution histogram

### Weighted score distribution (per surface)

```
   0- 99 │  (0)
 100-199 │  (0)
 200-299 │ █ (1)
 300-399 │ ██ (2)
 400-499 │ ██████ (6)
 500-599 │ █████ (5)
 600-699 │ ███ (3)
 700-799 │ ██ (2)
 800-899 │  (0)
 900-999 │  (0)
1000     │  (0)
```

## Below-Polish-Bar surfaces (weighted < 750)

- sdk_method__doctor__batch (weighted: 745)
- sdk_method__execution__wrapper (weighted: 518)
- sdk_method__registry__available-tools (weighted: 602)
- sdk_method__registry__tool-get (weighted: 563)
- sdk_method__registry__tool-spec-get (weighted: 602)
- sdk_method__tools__bash-async (weighted: 622)
- sdk_method__tools__bash (weighted: 481)
- sdk_method__tools__edit-file (weighted: 334)
- sdk_method__tools__glob (weighted: 481)
- sdk_method__tools__grep-async (weighted: 531)
- sdk_method__tools__grep (weighted: 322)
- sdk_method__tools__read-file (weighted: 561)
- sdk_method__tools__write-file (weighted: 406)
- verb__make__clean (weighted: 454)
- verb__make__compile (weighted: 422)
- verb__make__help (weighted: 493)
- verb__make__offline-test (weighted: 550)
- verb__make__recompile (weighted: 277)
