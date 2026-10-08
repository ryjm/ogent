# Fresh-agent comparison

Both fresh-context agents received the same seven canonical goals and could
inspect runtime documentation and metadata. The baseline completed 7/7 goals
with 4 first-strategy successes; the post simulation completed 7/7 with 5.
Baseline median product round trips were 3; post median was 2. Both had no
unresolved stuck goals. The post log records 13 product round trips plus one
shared capabilities/guide query, compared with 19 baseline recorded invocations.
Collection/batching differs, so those totals are descriptive rather than an
experimentally controlled efficiency estimate. No sampled inference-token
counts were available; literal discovery tokens are preserved instead.

Post recursion, paging, leading-dash search, ambiguous edits and JSON health
completed on the first strategy. The baseline used Bash for deeper globbing, a
regex workaround for a dash, and manual JSON serialization for health. Post
tool-only apropos still needed a registry query before discovering the new
agent-prefixed API, so runtime discoverability remains imperfect.

The post build task initially copied only the Makefile and hit a missing makem
fixture prerequisite. A fixture-only passthrough then proved selected-Emacs
forwarding and status propagation; it did not validate actual makem integration.
Independent scorer/root native evidence covers actual makem separately. The
baseline compilation goal used compile, so it did not expose recompile's known
false-success defect. Direct fixture SDK calls did not exercise approval gates;
regression tests and reviewer probes cover the registered boundary.

The post agent received candidate 303fa14 and ran during later review fixes,
without reading source/README/AGENTS/prior scores or independently inspecting
the final hash. It is not an exact-final-SHA simulation. Final native regression,
Emacs 29/30, and review checks target 2401f03, and the later fixes preserve the
canonical demonstrated behaviors. Health reports honestly returned local
deficiencies with code 2 under test doubles; valid JSON was not a provider
readiness certificate. Neither simulation logged into or called a provider.

Primary artifacts: agent_simulations/pre_pass_1/canonical/summary.json and each
task transcript; agent_simulations/post_pass_1/canonical/metrics.json and
transcript.jsonl. Async=false metadata describes the primary registered
synchronous call shape; separately available streaming functions are not
represented as a second capabilities call shape in this version.
