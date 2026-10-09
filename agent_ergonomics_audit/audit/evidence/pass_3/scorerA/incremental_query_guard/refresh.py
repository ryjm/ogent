"""Refresh retained independent judgments after bounded shared validation.

Does not perform fresh independent scoring, aggregation, source edits or Git
mutations.  Archive originals, baseline evidence and runtime logs are immutable.
"""
from pathlib import Path
import datetime
import difflib
import hashlib
import json
import subprocess
import sys
import tarfile

ROOT = Path('/workspace/ogent')
AUDIT = ROOT / 'agent_ergonomics_audit/audit'
HERE = Path(__file__).resolve().parent
PREVIOUS = 'a2fa8ce0533b4a508fb641f343fa55b15fd6fc60'
CURRENT = sys.argv[1]
BASELINE = 'b3caf9300c7336ef812ed061158f851c5a47ccf7'
STAMP = datetime.datetime.now(datetime.timezone.utc).isoformat()
ARCHIVE = AUDIT / 'evidence/pass_3/interim_a2fa8ce_scoring.tar.gz'
REL = 'audit/evidence/pass_3/scorerA/incremental_query_guard'
LAST_EXECUTED = 'b7b966c6ac5acc15d15c8ea0c70d81653072cae9'
FF4_SHA = 'ff4e96c21d5fb3ffe79843fbce8392390d1c8bf4'
B7 = HERE.parent / 'incremental_root_guard'
FF4 = HERE.parent / 'incremental_final'


def sha(data):
    return hashlib.sha256(data).hexdigest()


def dump(path, data):
    path.write_text(json.dumps(data, indent=2, ensure_ascii=False) + '\n')


def git_blob(commit, path):
    return subprocess.check_output(['git', 'show', f'{commit}:{path}'], cwd=ROOT)


def archived(path):
    with tarfile.open(ARCHIVE) as archive:
        return archive.extractfile(path).read()


def rows(data):
    return [json.loads(line) for line in data.splitlines()]


def walk(value):
    if isinstance(value, dict):
        yield value
        for child in value.values():
            yield from walk(child)
    elif isinstance(value, list):
        for child in value:
            yield from walk(child)


assert subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip() == CURRENT
assert sha(ARCHIVE.read_bytes()) == '5ead33e2eb0496fcf5ed38869d99ae77c64978f0cb7481c241bfc6a817e5e05b'
changed = subprocess.check_output(['git', 'diff', '--name-only', PREVIOUS, CURRENT,
                                   '--', 'lisp', 'test', 'Makefile', 'makem.sh'], cwd=ROOT, text=True).splitlines()
assert 'lisp/ogent-agent.el' in changed and 'lisp/ogent-tool-results.el' in changed, changed

# Fresh query probes; previous root and broader probes retain actual execution identities.
runs = json.loads((HERE / 'runs.json').read_text())
definition_identities = None
for run in runs:
    assert run['target_sha'] == CURRENT and run['exit_code'] == 0
    output = ROOT / run['stdout']
    records = rows(output.read_bytes())
    assert len(records) == 10 and all(record['passed'] is True for record in records)
    observed = records[1]['value']
    if definition_identities is None:
        definition_identities = observed
    else:
        assert definition_identities == observed
    run.update({'record_count': 10, 'behavior_records': 8, 'identity_guard_records': 2,
                'stdout_sha256': sha(output.read_bytes()),
                'stderr_sha256': sha((ROOT / run['stderr']).read_bytes())})
    assert sha((ROOT / run['probe_source']).read_bytes()) == run['probe_sha256']
    dump(HERE / (run['label'] + '.run.json'), run)
dump(HERE / 'runs.json', runs)
dump(HERE / 'definition_identities.json', definition_identities)
assert len(definition_identities) == 188
assert [item['method'] for item in definition_identities if not (item['body_equal'] and item['signature_equal'])] == ['ogent-tool-process--search-options']
query_guard = json.loads((HERE / 'query_source_guard.json').read_text())
assert query_guard['previous_source_sha'] == LAST_EXECUTED and query_guard['current_source_sha'] == CURRENT
assert query_guard['only_change_two_additive_unicode_guards'] and query_guard['previous_rest_of_module_byte_identical']
assert query_guard['previous_sha256'] == sha(git_blob(LAST_EXECUTED, 'lisp/ogent-tool-process.el'))
assert query_guard['current_sha256'] == sha(git_blob(CURRENT, 'lisp/ogent-tool-process.el'))
ff4_hashes = json.loads((HERE / 'ff4_evidence_hashes.json').read_text())
assert all(sha((FF4 / name).read_bytes()) == digest for name, digest in ff4_hashes.items())
ff4_runs = json.loads((FF4 / 'runs.json').read_text())
assert sum(run['record_count'] for run in ff4_runs) == 34
assert all(run['target_sha'] == FF4_SHA for run in ff4_runs)
ff4_archive = AUDIT / 'evidence/pass_3/interim_ff4e96c_scoring.tar.gz'
assert sha(ff4_archive.read_bytes()) == '18268a6159dca4b223a18d2ce5692387ecb90886aea0ebb18afcec605fe7413f'
b7_hashes = json.loads((HERE / 'b7_evidence_hashes.json').read_text())
assert all(sha((B7 / name).read_bytes()) == digest for name, digest in b7_hashes.items())
b7_runs = json.loads((B7 / 'runs.json').read_text())
assert sum(run['record_count'] for run in b7_runs) == 18
assert all(run['target_sha'] == LAST_EXECUTED for run in b7_runs)
b7_archive = AUDIT / 'evidence/pass_3/interim_b7b966c_scoring.tar.gz'
assert sha(b7_archive.read_bytes()) == '931c8036c2dca00b133239ecba9b2836ce56a883eae3d853e218c5edf3b04bf3'
transport_methods = ['ogent-tool-results-read', 'ogent-tool-results-format',
                     'ogent-tool-execution-json', 'ogent-tool-execution-wrapper',
                     'ogent-tool-contract--json-text', 'ogent-agent-call',
                     'ogent-agent-call-async', 'ogent-tool-get']
previous_identities = json.loads((B7 / 'definition_identities.json').read_text())
for method in transport_methods:
    for guard in [previous_identities, definition_identities]:
        identity = next(item for item in guard if item['method'] == method)
        assert identity['body_equal'] and identity['signature_equal'], method
reuse = {'executed_source_sha': FF4_SHA, 'new_execution': False,
         'records': 34, 'behavior_records': 28, 'identity_guard_records': 6,
         'runs': ff4_runs, 'evidence_files_byte_identical': len(ff4_hashes),
         'archive': 'audit/evidence/pass_3/interim_ff4e96c_scoring.tar.gz',
         'archive_sha256': sha(ff4_archive.read_bytes()),
         'definition_guards': ['audit/evidence/pass_3/scorerA/incremental_root_guard/definition_identities.json', REL + '/definition_identities.json'],
         'unchanged_transport_methods': transport_methods,
         'basis': 'Transitive actual source-form identity from ff4 to b7 and b7 to current preserves Unicode-result serializers, read, batch, ledger/approval, schema and actual gptel wrapper bodies. Changed structured search query preflight is covered by fresh query controls. Old transcripts are not relabeled.'}
dump(HERE / 'reused_ff4_evidence.json', reuse)
b7_reuse = {'executed_source_sha': LAST_EXECUTED, 'new_execution': False,
            'records': 18, 'behavior_records': 14, 'identity_guard_records': 4,
            'runs': b7_runs, 'evidence_files_byte_identical': len(b7_hashes),
            'archive': 'audit/evidence/pass_3/interim_b7b966c_scoring.tar.gz',
            'archive_sha256': sha(b7_archive.read_bytes()),
            'definition_guard': REL + '/definition_identities.json',
            'search_options_additive_guard': REL + '/query_source_guard.json',
            'basis': 'Structured glob, result serializers and SDK bodies are identical. Search-options differs only by the new string Unicode guards; existing root validation and target classification forms are preserved, and prior ASCII query root checks pass through the additive guards. Original b7 transcripts remain b7 executions.'}
dump(HERE / 'reused_b7_evidence.json', b7_reuse)

paths = set(['Makefile', 'makem.sh', 'test/ogent-test-helper.el',
             'lisp/ogent-agent.el', 'lisp/ogent-tool-results.el',
             'lisp/ogent-tool-contract.el',
             'lisp/ogent-tool-execution.el', 'lisp/ogent-tool-process.el',
             'lisp/ogent-tools.el', 'lisp/ogent-models.el', 'lisp/ogent-doctor.el',
             'lisp/ogent-ledger.el', 'lisp/ui/ogent-ui-toolcalls.el'])
sets = []
for scorer, dest in [('scorerA', AUDIT / 'partial/scores_pass4_current_scorerA.jsonl'),
                     ('scorerB', AUDIT / 'partial/scores_pass4_current_scorerB.jsonl'),
                     ('scorerT', AUDIT / 'evidence/pass_3/tiebreaker/current_scores.jsonl')]:
    origin = f'evidence/pass_3/triangulation/current/{scorer}.jsonl'
    sets.append((scorer, dest, origin, rows(archived(origin))))
for scorer in ['scorerA', 'scorerB']:
    origin = f'evidence/pass_3/{scorer}/new_api_scores.jsonl'
    sets.append((scorer + '_new_api', AUDIT / origin, origin, rows(archived(origin))))


def resolve_evidence(file):
    if file.startswith('../'):
        return AUDIT.parent / file, file[3:]
    if file.startswith('audit/'):
        return AUDIT.parent / file, None
    if file.startswith('agent_ergonomics_audit/'):
        return ROOT / file, None
    return ROOT / file, file


for _, _, _, records in sets:
    for record in records:
        for item in walk(record['evidence']):
            if 'file' in item:
                _, source = resolve_evidence(item['file'])
                if source:
                    paths.add(source)

identities = {}
for path in sorted(paths):
    prior = git_blob(PREVIOUS, path)
    current = git_blob(CURRENT, path)
    assert (ROOT / path).read_bytes() == current, f'Dirty cited source: {path}'
    identities[path] = {'previous_source_sha': PREVIOUS, 'current_source_sha': CURRENT,
                        'previous_git_blob': subprocess.check_output(['git', 'rev-parse', f'{PREVIOUS}:{path}'], cwd=ROOT, text=True).strip(),
                        'current_git_blob': subprocess.check_output(['git', 'rev-parse', f'{CURRENT}:{path}'], cwd=ROOT, text=True).strip(),
                        'previous_sha256': sha(prior), 'sha256': sha(current),
                        'whole_blob_identical': prior == current, 'working_bytes_equal_git_show': True}
    last = git_blob(LAST_EXECUTED, path)
    identities[path]['previous_execution_source_sha'] = LAST_EXECUTED
    identities[path]['previous_execution_sha256'] = sha(last)
    identities[path]['whole_blob_identical_to_previous_execution'] = last == current
    ff4 = git_blob(FF4_SHA, path)
    identities[path]['ff4_execution_source_sha'] = FF4_SHA
    identities[path]['ff4_execution_sha256'] = sha(ff4)
    identities[path]['whole_blob_identical_to_ff4_execution'] = ff4 == current
dump(HERE / 'source_identities.json', {'previous_sha': PREVIOUS, 'current_sha': CURRENT,
                                     'changed_files': changed, 'files': identities})

# Re-map all current source citations through the actual line diff.  Runtime
# citations retain their original byte offsets and explicit old execution scope.
line_changes = []
runtime_citations = 0
source_citations = 0
outputs = []
for scorer, destination, origin, records in sets:
    original_vectors = {record['surface_id']: record['scores'] for record in records}
    records = json.loads(json.dumps(records))
    for record in records:
        record['target_sha'] = CURRENT
        if 'source_sha' in record:
            record['source_sha'] = CURRENT
        record['judgment_source_sha'] = PREVIOUS
        record['revalidated_at'] = STAMP
        record['incremental_revalidation'] = {
            'method': 'retained original independent judgment; fresh bounded query validation plus explicit ff4 and b7 execution reuse',
            'new_independent_blind_full_reading': False,
            'original_raw_archive': 'audit/evidence/pass_3/interim_a2fa8ce_scoring.tar.gz',
            'original_raw_member': origin,
            'source_identity_guard': REL + '/source_identities.json',
            'new_runtime_evidence': [REL + '/emacs29.stdout.jsonl', REL + '/emacs30.stdout.jsonl'],
            'reused_runtime_evidence': [REL + '/reused_ff4_evidence.json', REL + '/reused_b7_evidence.json'],
            'numeric_vector_sha256': sha(json.dumps(record['scores'], sort_keys=True).encode()),
            'basis': 'Fresh query checks cover raw field refusal, native/JSON consistency, callback delivery and valid Unicode pagination. The b7/current source-form guards preserve all bodies except additive search preflight validation; prior root and gptel evidence retain their original execution targets.',
        }
        for dim, score in record['scores'].items():
            assert isinstance(score, int) and score % 50 == 0 and 0 <= score <= 1000
            if score > 700:
                assert record['evidence'].get(dim), (scorer, record['surface_id'], dim)
        for item in walk(record['evidence']):
            if 'file' not in item:
                continue
            filename, source = resolve_evidence(item['file'])
            assert filename.is_file(), filename
            if source:
                source_citations += 1
                item['source_sha'] = CURRENT
                item['source_sha256'] = identities[source]['sha256']
                if source in changed and isinstance(item.get('line'), int):
                    oldlines = git_blob(PREVIOUS, source).decode().splitlines()
                    newlines = git_blob(CURRENT, source).decode().splitlines()
                    oldline = item['line'] - 1
                    found = False
                    for tag, i1, i2, j1, j2 in difflib.SequenceMatcher(None, oldlines, newlines, autojunk=False).get_opcodes():
                        if i1 <= oldline < i2:
                            new = j1 + oldline - i1 if tag == 'equal' else j1
                            item['line'] = new + 1
                            if item['line'] != oldline + 1:
                                line_changes.append({'set': scorer, 'surface_id': record['surface_id'], 'file': source,
                                                     'previous_line': oldline + 1, 'line': item['line']})
                            found = True
                            break
                    assert found
            else:
                runtime_citations += 1
                item['artifact_sha256'] = sha(filename.read_bytes())
                item['execution_scope'] = 'retained cited artifact from the original judgment; not newly executed at the final source snapshot'
                item['incremental_source_guard'] = REL + '/source_identities.json'
            if isinstance(item.get('line'), int):
                assert 1 <= item['line'] <= len(filename.read_bytes().splitlines()), (filename, item['line'])
        assert record['scores'] == original_vectors[record['surface_id']]
    destination.parent.mkdir(exist_ok=True)
    destination.write_text(''.join(json.dumps(record, ensure_ascii=False, sort_keys=True) + '\n' for record in records))
    outputs.append({'set': scorer, 'file': str(destination.relative_to(AUDIT.parent)), 'rows': len(records),
                    'target_sha': CURRENT, 'judgment_source_sha': PREVIOUS,
                    'numeric_vectors_unchanged': True, 'sha256': sha(destination.read_bytes())})

# Reparse actual old build outputs without running builds.  Both actual build
# owners match the new snapshot byte-for-byte; the raw reports still say a2fa.
build_reports = []
for family, file in [('scorerA', 'make_runtime.jsonl'), ('scorerB', 'build-runtime.jsonl')]:
    path = AUDIT / 'evidence/pass_3' / family / file
    records = rows(path.read_bytes())
    parsed = []
    for record in records:
        assert record['target_sha'] == PREVIOUS
        try:
            data = json.loads(record['stdout'])
        except json.JSONDecodeError:
            continue
        assert data['contract_version'] == '1'
        assert data['status'] in ('success', 'error')
        assert (record['exit_code'] == 0) == (data['status'] == 'success')
        parsed.append({'probe': record['probe'], 'actual_prior_exit_code': record['exit_code'],
                       'status': data['status']})
    build_reports.append({'file': str(path.relative_to(AUDIT.parent)), 'sha256': sha(path.read_bytes()),
                          'executed_source_sha': PREVIOUS, 'new_build_execution': False,
                          'prior_commands': len(records), 'json_reports_reparsed': len(parsed), 'reports': parsed})
for meta in sorted((AUDIT / 'evidence/pass_3/tiebreaker').glob('current-make-*.json')):
    data = json.loads(meta.read_text())
    if 'stdout' not in data:
        continue
    output, _ = resolve_evidence(data['stdout'])
    try:
        report = json.loads(output.read_text())
    except json.JSONDecodeError:
        continue
    assert report['contract_version'] == '1'
    assert (data['exit_code'] == 0) == (report['status'] == 'success')
    build_reports.append({'file': str(output.relative_to(AUDIT.parent)), 'sha256': sha(output.read_bytes()),
                          'executed_source_sha': PREVIOUS, 'new_build_execution': False,
                          'json_reports_reparsed': 1, 'status': report['status']})
dump(HERE / 'reused_build_reports.json', {'reuse_basis': {p: identities[p] for p in ['Makefile', 'makem.sh']},
                                        'reports': build_reports})

# All original paired baseline bytes, A's 196 manifest entries, and every
# archived historical member stay immutable.
old_hashes = json.loads((HERE / 'pre_refresh_artifact_hashes.json').read_text())
baseline_manifest = json.loads((AUDIT / 'evidence/pass_3/scorerA/preservation_a2f.json').read_text())['baseline_before']
assert len(baseline_manifest) == 196
for name, expected in baseline_manifest.items():
    assert sha((AUDIT / 'evidence/pass_3/scorerA' / name).read_bytes()) == expected, name
baseline_files = {}
for path, expected in old_hashes.items():
    name = Path(path).name
    if 'baseline' in path or 'interim' in name:
        assert sha((AUDIT / path).read_bytes()) == expected, path
        baseline_files[path] = expected
dump(HERE / 'preservation.json', {'baseline_A_manifest_entries': 196, 'all_A_196_byte_identical': True,
                                  'baseline_and_historical_files': baseline_files,
                                  'baseline_and_historical_files_unchanged': len(baseline_files),
                                  'immutable_original_scoring_archive_sha256': sha(ARCHIVE.read_bytes())})

# Current source hashes; original baseline hash rows remain exactly as written.
b_hashfile = AUDIT / 'evidence/pass_3/scorerB/source_hashes.json'
b_hashes = json.loads(b_hashfile.read_text())
for record in b_hashes:
    if record['file'].startswith('../'):
        path = record['file'][3:]
        content = git_blob(CURRENT, path)
        assert (ROOT / path).read_bytes() == content
        record['source_sha'] = CURRENT
        record['sha256'] = sha(content)
dump(b_hashfile, b_hashes)
t_hashfile = AUDIT / 'evidence/pass_3/tiebreaker/source-identities.json'
t_hashes = json.loads(t_hashfile.read_text())
t_hashes['current_sha'] = CURRENT
for record in t_hashes['rows']:
    if record['phase'] == 'current':
        content = git_blob(CURRENT, record['path'])
        assert (ROOT / record['path']).read_bytes() == content
        record['source_sha'] = CURRENT
        record['actual_path'] = str(ROOT / record['path'])
        record['sha256'] = sha(content)
        record['equal_git_show'] = True
t_hashes['incremental_validation'] = REL + '/validation.json'
dump(t_hashfile, t_hashes)

summary = {'target_sha': CURRENT, 'judgment_source_sha': PREVIOUS, 'baseline_sha': BASELINE,
           'method': 'fresh shared query validation and explicit ff4/b7 execution reuse of retained independent A/B/T judgments; not new blind full readings',
           'source_changed_files': changed, 'source_files_verified': len(identities),
           'whole_blob_identical_files': sum(x['whole_blob_identical'] for x in identities.values()),
           'successful_probe_processes': 2, 'successful_records': 20,
           'behavior_records': 16, 'identity_guard_records': 4,
           'reused_ff4_execution_records': 34, 'reused_ff4_evidence': REL + '/reused_ff4_evidence.json',
           'reused_b7_execution_records': 18, 'reused_b7_evidence': REL + '/reused_b7_evidence.json',
           'new_independent_full_readings': 0, 'new_build_commands': 0,
           'runs': runs, 'outputs': outputs, 'source_citations_verified': source_citations,
           'retained_runtime_citations_verified': runtime_citations, 'source_line_changes': line_changes,
           'all_numeric_vectors_unchanged': True, 'baseline_A196_bytes_unchanged': True,
           'baseline_B19_and_T9_bytes_unchanged': True,
           'old_raw_transcripts_and_target_markers_preserved': True,
           'source_definition_guard': REL + '/definition_identities.json',
           'definition_identity_previous_source_sha': LAST_EXECUTED,
           'unchanged_executable_definitions': sum(x['body_equal'] and x['signature_equal'] for x in definition_identities),
           'changed_executable_definitions': [x for x in definition_identities if not (x['body_equal'] and x['signature_equal'])],
           'interim_021_invalidated_evidence': 'audit/evidence/pass_3/scorerA/incremental_021cca4/validation_021_pre_repair.json',
           'interim_ff4_archive': 'audit/evidence/pass_3/interim_ff4e96c_archive.json',
           'interim_b7_archive': 'audit/evidence/pass_3/interim_b7b966c_archive.json',
           'initial_probe_fixture_error': json.loads((HERE / 'initial_fixture_error.json').read_text()),
           'source_files_matching_previous_b7_execution': sum(x['whole_blob_identical_to_previous_execution'] for x in identities.values()),
           'reused_ff4_and_b7_records_are_not_fresh_executions': True,
           'numeric_basis': 'Early query guards restore unsupported_output uniformly before search or continuation construction, while valid Unicode query pagination remains functional. Existing aliases, schemas, approval/ledger behavior and JSON transport retain their selected bands; no changed anchor is justified.',
           'scoped_native_validation': 'Owned by coordinator; no broad native suite or build battery rerun here',
           'providers_called': False, 'inference_called': False}
dump(HERE / 'validation.json', summary)

# A current provenance: prior actual runs remain disclosed as old executions.
a_file = AUDIT / 'evidence/pass_3/scorerA/current_runtime_provenance.json'
a = json.loads(a_file.read_text())
a['reused_b7_runtime_provenance'] = {'target_sha': a['target_sha'], 'runs': a['runs'],
                                          'actual_probe_counts': a['actual_probe_counts'],
                                          'original_archive_member': 'evidence/pass_3/scorerA/current_runtime_provenance.json', 'archive': 'audit/evidence/pass_3/interim_b7b966c_scoring.tar.gz'}
a.update({'target_sha': CURRENT, 'judgment_source_sha': PREVIOUS, 'utc_revalidated': STAMP,
          'runs': runs, 'actual_probe_counts': {'processes': 2, 'records': 20, 'behavior_records': 16, 'identity_guards': 4, 'reused_ff4_records': 34, 'reused_b7_records': 18, 'new_build_commands': 0},
          'source_sha256': {path: item['sha256'] for path, item in identities.items()},
          'method': summary['method'], 'baseline_preserved': {'artifacts': 196, 'all_byte_identical': True, 'verification': REL + '/preservation.json'},
          'incremental_validation': REL + '/validation.json',
          'numeric_judgment': summary['numeric_basis']})
a['unchanged_source_identity'] = {path: item for path, item in identities.items() if item['whole_blob_identical']}
a['changed_source_identity'] = {path: item for path, item in identities.items() if not item['whole_blob_identical']}
dump(a_file, a)
dump(AUDIT / 'evidence/pass_3/scorerA/score_validation.json', summary)

# B current provenance distinguishes old counts/argv from newly executed runs.
for basename in ['provenance.json', 'validation.json']:
    file = AUDIT / 'evidence/pass_3/scorerB' / basename
    b = json.loads(file.read_text())
    b['reused_b7_incremental_runtime_metadata'] = {
        'executed_source_sha': LAST_EXECUTED, 'new_probe_processes': b['new_probe_processes'],
        'new_shared_records': b['new_shared_records'], 'new_behavior_records': b['new_behavior_records'],
        'new_identity_guard_records': b['new_identity_guard_records'],
        'incremental_runs': b['incremental_runs'], 'reuse_guard': REL + '/reused_b7_evidence.json'}
    b.update({'current_sha': CURRENT, 'judgment_source_sha': PREVIOUS, 'incremental_validation': REL + '/validation.json',
              'new_probe_processes': 2, 'new_shared_records': 20, 'new_behavior_records': 16,
              'new_identity_guard_records': 4, 'reused_ff4_records': 34, 'reused_b7_records': 18, 'new_build_commands': 0, 'new_independent_full_readings': 0,
              'all_numeric_vectors_unchanged': True, 'incremental_runs': runs,
              'source_hashes_validated': len(b_hashes), 'current_original19_sha256': outputs[1]['sha256']})
    for score_file in b.get('score_files', []):
        if score_file['target_sha'] == LAST_EXECUTED:
            score_file['target_sha'] = CURRENT
            score_file['judgment_source_sha'] = PREVIOUS
    if 'artifacts_sha256' in b:
        for name in b['artifacts_sha256']:
            b['artifacts_sha256'][name] = sha((file.parent / name).read_bytes())
    dump(file, b)
dump(AUDIT / f'evidence/pass_3/tiebreaker/refresh-{CURRENT[:7]}.json', summary)

print(json.dumps({key: summary[key] for key in ['target_sha', 'successful_probe_processes', 'successful_records',
                                              'behavior_records', 'identity_guard_records', 'source_files_verified',
                                              'whole_blob_identical_files', 'source_citations_verified',
                                              'retained_runtime_citations_verified', 'all_numeric_vectors_unchanged']}, indent=2))
