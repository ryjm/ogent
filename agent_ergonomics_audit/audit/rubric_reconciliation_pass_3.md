# Paired calibration for the second implementation pass

Production baseline is `b3caf9300c7336ef812ed061158f851c5a47ccf7`;
measured source is `5d07d807bc85a093725db24e33996b4af690ec0f`.
The original nineteen-surface inventory is unchanged. Two independent peer
readings established the paired judgments on the archived baseline and an
earlier implementation freeze. Nine surfaces also received independent third
readings because a dimension spread exceeded 300 in either snapshot. Later
repairs received shared incremental verification: source citations and hashes
were refreshed, changed boundaries were probed on both Emacs versions, and
unchanged executable bodies support explicitly identified evidence reuse.
All 59 original numeric vectors were retained. These are not two new blind
readings of the final source. The latest query checks contribute 20 fresh
passing records; 18 b7 root records and 34 ff4 transport records remain labeled
with their original execution revisions.
The six new named SDK APIs are measured separately without fictional zero
baselines and are excluded from the paired means.

The historical pass 1/2 numbers are preserved. Initially carrying pass 2 into
pass 3 made attribution misleading: new scorers applied different judgments
about primitive method aliases, trusted raw mutations and volatile external
output. The initial carry is retained in
`evidence/pass_3/historical_carried_baseline.jsonl`. Pass 3 now contains a
genuine paired reassessment of the archived baseline under the same criteria
as pass 4, rather than treating calibration changes as implementation gains.

## Large-disagreement decisions

The wrapper intent spread is 600. The independent third reading establishes
that the inventoried positional wrapper has no method aliases; named dispatch
is a different API. Its intent score is zero in both snapshots. Parameter
validation remains useful error pedagogy. Make recompile's intent spread is
500: final generic `make help` recovery earns partial credit (250), while
compile-specific spellings do not confer aliases on recompile. Both decisions
use paired third evidence rather than averaging incompatible applicability.

Make clean safety has an applicability disagreement. Two readings assign
1000 as inapplicable to bounded regenerable bytecode; the third assigns 250
for mutation without confirmation. The aggregate follows the required median
(1000 in both snapshots). The coordinator accepts the majority's narrow scope:
the actual recipe removes generated `.elc` within the two specified trees,
GNU Make offers a preview, and compilation recreates it. This is not a safety
certificate for arbitrary file deletion. The dissent is retained unchanged.
It contributes no uplift. Raw write/edit remain applicable with low safety
scores because approval belongs to registered execution, not raw primitives.

All other third scores contribute their dimension medians without overwriting
the original scorer judgments. Third evidence and anchor interpretations are
in [criteria](evidence/pass_3/tiebreaker/criteria.md). Raw paired A/B/T rows,
hashes and arithmetic are in
[aggregation](evidence/pass_3/triangulation/aggregation.json).

## Results and limits

The equal-weight mean changes **605.3 → 656.2**. Median uplift over all nineteen
is **11**; over the ten changed original surfaces it is **77.5**. Nine original
surfaces gain at least 100 on a dimension. No aggregate surface regresses by
more than 50. Eleven independently tested behavior upgrades were shipped;
that is not eleven separately attributable numerical gains. Related changes
share surfaces, and new APIs lack paired historical scores. The mandatory
ambition prompt and further implementation round are recorded separately.

Per-dimension medians and equal-weight means are floored to integers using the
installed skill aggregator. These are qualitative same-model peer judgments,
not empirical agent success rates. Source/dependency bootstrap failures are
retained but excluded from successful runtime conclusions. Actual baseline
source is loaded after helpers that prepend current source. Both Emacs versions
and actual Makefile/makem fixtures are identified in the scorer provenance.

Ignored live source/fixture copies are archived losslessly in tar.gz files;
[archive manifest](evidence/pass_3/source_fixture_archives.json) supplies hashes,
member hashes and extraction instructions. Keeping live copies out of Git
prevents makem from discovering duplicate old features and tests. Historical
artifacts and invalidated intermediate freezes remain available.
