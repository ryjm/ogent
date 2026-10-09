# Round 6 evidence

Target: `9ac13b23032f40eccb9a627a824be45656292056`.
Baseline: `b3caf9300c7336ef812ed061158f851c5a47ccf7`.
Result: one P2 search scope finding; see `../../../phase7_pass_3_review_round6.md`.

`record.py` runs real argv without shell interpolation and writes complete
stdout/stderr plus command, cwd, exit code, and elapsed time in JSON.

| Evidence | Result |
|---|---|
| `focused-ert-29-source`, `focused-ert-30-source` | 188 expected, zero unexpected/skips, exit 0 each |
| `boundary-final-29`, `boundary-final-30` | 4 expected, zero unexpected, exit 0 each; printed symlink discrepancy |
| `focused-ert-29`, `focused-ert-30` | Initial launch failed 127: PATH omitted installed Emacs |
| `boundary-29`, `boundary-30` | Initial fixture failed one assertion: symbol allow rule instead of string |
| `boundary-probe.el` | Final independent probe and symlink comparison |
| `probe-sha256.txt` | Final fixture and recorder identities |
| `runtime-identities` | Actual Emacs 30.2, ripgrep 15.2.0, grep 3.11, xargs 4.10.0 versions |
| `start-sha.txt`, `end-sha.txt` | Same exact target SHA |
| `start-production-status.txt`, `end-production-status.txt` | Empty production status |
| `start-production.diff`, `end-production.diff` | Empty production diff |

Containers: `ogent-fixes` (Emacs 30.2) and `ogent-fixes-29` (Emacs 29.1),
repository mounted at `/work`. Source-forced helper loaded first.
Ripgrep: real `/tmp/ogent-test-rg` version 15.2.0. GNU grep/xargs are actual
container executables; only `executable-find` chooses the engine. No full
repository native suite, lint, compile, provider request, or login ran here.

Minimal finding: `source.txt` contains `needle\n`; `link.txt` is a symbolic
link to it. Ripgrep directory filter `link.txt` returns no match, while
`l?nk.txt` and `l[ia]nk.txt` return `link.txt`; GNU returns `link.txt` for
all three. The final stdout records show this on both runtimes.
