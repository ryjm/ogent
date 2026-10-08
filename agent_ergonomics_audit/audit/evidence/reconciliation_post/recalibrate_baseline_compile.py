"""Explicit one-dimension baseline calibration; preserve historical bytes first."""
import hashlib
import json
from pathlib import Path

out = Path(__file__).parent
audit = out.parents[1]
sid = 'verb__make__compile'
name = 'scores_pass1_' + sid + '_scorertiebreaker.jsonl'
partial = audit / 'partial' / name
archive_dir = audit / 'triangulation/baseline_pre_paired_calibration'
archive_dir.mkdir(parents=True, exist_ok=True)
archive = archive_dir / name
if not archive.exists():
    archive.write_bytes(partial.read_bytes())
original = json.loads(archive.read_text())
assert original['scores']['composability'] == 500
row = json.loads(archive.read_text())
row['scores']['composability'] = 250
row['weighted_score'] = sum(row['scores'].values()) / 11
row['target_sha'] = '72016bb66928a20a49238266645abde583fa595d'
proof = json.loads((out / 'make_runtime.jsonl').read_text().splitlines()[3])
assert proof['stage'] == 'baseline' and proof['probe'] == 'compile-actual-makem-failure'
assert proof['exit_code'] == 2 and proof['stdout'] == 'fixture compiler failed\n'
assert '\x1b[' in proof['stderr']
row['evidence']['composability'] = dict(
    file='audit/evidence/reconciliation_post/make_runtime.jsonl', line=4,
    invocation=proof['invocation'], exit_code=proof['exit_code'],
    stdout_excerpt=proof['stdout'], stderr_excerpt=proof['stderr'],
    target_sha=row['target_sha'],
    reason='Fresh actual-baseline-makem probe under non-TTY NO_COLOR=1 CI=true TERM=dumb copies compiler diagnostics onto stdout and emits ANSI/timestamp logs on stderr. Nonzero failure status makes scripting possible but the rubric500 NO_COLOR/stream criteria are unmet. Same observed contract and composability250 anchor as post row13. A replaced makem stub demonstrates forwarding only.')
row['notes'] += (
    ' Explicit paired-calibration amendment: only composability500→250 is changed, '
    'using fresh actual baseline makem runtime at audit/evidence/reconciliation_post/make_runtime.jsonl:4; '
    'the other ten original historical dimension assessments remain intact. '
    'This is correction of an overcredited baseline anchor, not a functional implementation regression. '
    'Original complete byte-for-byte partial archived under audit/triangulation/baseline_pre_paired_calibration/'
    + name + '; exact changes/hash recorded in recalibration_manifest.json. '
    'See audit/rubric_reconciliation_post.md appendix.')
partial.write_text(json.dumps(row, sort_keys=True) + '\n')
manifest = dict(
    surface_id=sid, scorer_id='tiebreaker', pass_number=1,
    historical_archive=str(archive.relative_to(audit.parent)),
    historical_sha256=hashlib.sha256(archive.read_bytes()).hexdigest(),
    active_partial=str(partial.relative_to(audit.parent)),
    active_sha256=hashlib.sha256(partial.read_bytes()).hexdigest(),
    rubric_version=row['rubric_version'], baseline_sha=row['target_sha'],
    changes={'scores.composability': {'before':500,'after':250},
             'weighted_score': {'before':original['weighted_score'],'after':row['weighted_score']},
             'evidence.composability': 'actual delegated makem runtime replaces source-only/stub inference',
             'notes': 'explicit history and paired-calibration explanation',
             'target_sha': 'explicit baseline SHA added'},
    unchanged_score_dimensions=[k for k in row['scores'] if k != 'composability'])
(archive_dir / 'recalibration_manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
assert all(row['scores'][k] == original['scores'][k]
           for k in original['scores'] if k != 'composability')
print(json.dumps(manifest, indent=2))
