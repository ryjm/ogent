# Agent Ergonomics Scorecard

Generated: 2026-10-08T23:48:12Z
Source: `/workspace/ogent/agent_ergonomics_audit/audit/new_api_surfaces_pass_4.jsonl` (pass 4)


## Per-surface scores

| surface_id | weighted | intu | ergo | ease | parse | error | intent | safe | det | self | comp | regr |
|------------|----------|------|------|------|-------|-------|--------|------|-----|------|------|------|
| sdk_method__agent__call | 813 | 825 | 850 | 825 | 875 | 825 | 800 | 650 | 775 | 850 | 875 | 800 |
| sdk_method__agent__next | 740 | 825 | 850 | 800 | 875 | 775 | 0 | 650 | 875 | 825 | 875 | 800 |
| sdk_method__agent__batch | 847 | 825 | 900 | 800 | 875 | 775 | 800 | 1000 | 850 | 825 | 875 | 800 |
| sdk_method__agent__call-async | 790 | 800 | 825 | 800 | 875 | 800 | 800 | 650 | 650 | 825 | 875 | 800 |
| sdk_method__agent__describe | 856 | 850 | 825 | 825 | 875 | 825 | 800 | 1000 | 875 | 900 | 875 | 775 |
| sdk_method__agent__schema | 752 | 825 | 800 | 750 | 875 | 750 | 0 | 1000 | 875 | 825 | 875 | 700 |

## Distribution histogram

### Weighted score distribution (per surface)

```
   0- 99 │  (0)
 100-199 │  (0)
 200-299 │  (0)
 300-399 │  (0)
 400-499 │  (0)
 500-599 │  (0)
 600-699 │  (0)
 700-799 │ ███ (3)
 800-899 │ ███ (3)
 900-999 │  (0)
1000     │  (0)
```

## Below-Polish-Bar surfaces (weighted < 750)

- sdk_method__agent__next (weighted: 740)
