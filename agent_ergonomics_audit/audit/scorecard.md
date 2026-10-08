# Agent Ergonomics Scorecard

Generated: 2026-10-08T19:16:29Z
Source: `agent_ergonomics_audit/audit/agent_surfaces.jsonl` (pass 2)


## Per-surface scores

| surface_id | weighted | intu | ergo | ease | parse | error | intent | safe | det | self | comp | regr |
|------------|----------|------|------|------|-------|-------|--------|------|-----|------|------|------|
| sdk_method__doctor__batch | 861 | 825 | 875 | 800 | 850 | 800 | 1000 | 1000 | 800 | 825 | 850 | 850 |
| sdk_method__doctor__run | 827 | 825 | 850 | 675 | 850 | 725 | 1000 | 1000 | 775 | 750 | 850 | 800 |
| sdk_method__execution__wrapper | 650 | 775 | 825 | 700 | 300 | 775 | 0 | 700 | 725 | 750 | 775 | 825 |
| sdk_method__registry__available-tools | 815 | 800 | 825 | 700 | 800 | 850 | 775 | 1000 | 800 | 775 | 850 | 800 |
| sdk_method__registry__tool-get | 704 | 775 | 800 | 650 | 775 | 125 | 500 | 1000 | 750 | 750 | 850 | 775 |
| sdk_method__registry__tool-spec-get | 720 | 800 | 800 | 675 | 825 | 125 | 500 | 1000 | 800 | 775 | 850 | 775 |
| sdk_method__tools__bash-async | 720 | 800 | 825 | 725 | 775 | 725 | 1000 | 0 | 700 | 750 | 825 | 800 |
| sdk_method__tools__bash | 672 | 800 | 800 | 675 | 325 | 725 | 1000 | 0 | 800 | 725 | 750 | 800 |
| sdk_method__tools__edit-file | 572 | 750 | 800 | 700 | 250 | 850 | 0 | 0 | 650 | 750 | 750 | 800 |
| sdk_method__tools__glob | 677 | 800 | 800 | 700 | 275 | 750 | 0 | 1000 | 800 | 750 | 800 | 775 |
| sdk_method__tools__grep-async | 715 | 800 | 800 | 700 | 725 | 800 | 0 | 1000 | 700 | 750 | 825 | 775 |
| sdk_method__tools__grep | 688 | 800 | 800 | 700 | 325 | 800 | 0 | 1000 | 800 | 750 | 800 | 800 |
| sdk_method__tools__read-file | 704 | 825 | 875 | 725 | 325 | 825 | 0 | 1000 | 800 | 775 | 825 | 775 |
| sdk_method__tools__write-file | 586 | 775 | 825 | 650 | 250 | 800 | 0 | 125 | 775 | 725 | 750 | 775 |
| verb__make__clean | 604 | 750 | 750 | 650 | 250 | 250 | 0 | 1000 | 800 | 650 | 800 | 750 |
| verb__make__compile | 522 | 700 | 700 | 650 | 250 | 250 | 0 | 1000 | 650 | 650 | 250 | 650 |
| verb__make__help | 631 | 925 | 675 | 750 | 0 | 325 | 125 | 1000 | 800 | 775 | 825 | 750 |
| verb__make__offline-test | 654 | 800 | 750 | 750 | 350 | 800 | 0 | 1000 | 500 | 700 | 750 | 800 |
| verb__make__recompile | 540 | 750 | 750 | 650 | 250 | 250 | 0 | 1000 | 650 | 650 | 250 | 750 |

## Distribution histogram

### Weighted score distribution (per surface)

```
   0- 99 │  (0)
 100-199 │  (0)
 200-299 │  (0)
 300-399 │  (0)
 400-499 │  (0)
 500-599 │ ████ (4)
 600-699 │ ███████ (7)
 700-799 │ █████ (5)
 800-899 │ ███ (3)
 900-999 │  (0)
1000     │  (0)
```

## Below-Polish-Bar surfaces (weighted < 750)

- sdk_method__execution__wrapper (weighted: 650)
- sdk_method__registry__tool-get (weighted: 704)
- sdk_method__registry__tool-spec-get (weighted: 720)
- sdk_method__tools__bash-async (weighted: 720)
- sdk_method__tools__bash (weighted: 672)
- sdk_method__tools__edit-file (weighted: 572)
- sdk_method__tools__glob (weighted: 677)
- sdk_method__tools__grep-async (weighted: 715)
- sdk_method__tools__grep (weighted: 688)
- sdk_method__tools__read-file (weighted: 704)
- sdk_method__tools__write-file (weighted: 586)
- verb__make__clean (weighted: 604)
- verb__make__compile (weighted: 522)
- verb__make__help (weighted: 631)
- verb__make__offline-test (weighted: 654)
- verb__make__recompile (weighted: 540)
