"""Validate scorer B's independent files; never opens other scorers' data."""
import hashlib
import json
from pathlib import Path
import subprocess

repo = Path('/workspace/ogent')
audit = repo / 'agent_ergonomics_audit'
own = audit / 'audit/evidence/pass_3/scorerB'
current_sha = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=repo, text=True).strip()
baseline_sha = (own / 'baseline-source/TARGET_SHA').read_text().strip()
dimensions = {'agent_intuitiveness', 'agent_ergonomics', 'agent_ease_of_use',
              'output_parseability', 'error_pedagogy', 'intent_inference',
              'safety_with_recovery', 'determinism_and_reproducibility',
              'self_documentation', 'composability', 'regression_resistance'}
expected_fields = {'surface_id', 'scorer_id', 'rubric_version', 'target_sha',
                   'scores', 'evidence', 'notes'}
rubric = json.loads((audit / 'audit/manifest.json').read_text())['rubric_version']

def rows(path):
    return [json.loads(line) for line in path.read_text().splitlines()]

original_ids = {r['surface_id'] for r in rows(audit / 'audit/surface_inventory.jsonl')}
new_ids = {'sdk_method__agent__' + name for name in
           ['call', 'next', 'batch', 'call-async', 'describe', 'schema']}
cited_files = set()

def check_citation(citation):
    assert citation['file'] and isinstance(citation['line'], int)
    source = (audit / citation['file']).resolve()
    assert source.exists(), source
    assert 1 <= citation['line'] <= len(source.read_text().splitlines()), citation
    cited_files.add(source)
    if 'additional_evidence' in citation:
        check_citation(citation['additional_evidence'])

score_summary = []
for path, expected, sha in [
        (audit / 'audit/partial/scores_pass4_current_scorerB.jsonl', original_ids, current_sha),
        (own / 'new_api_scores.jsonl', new_ids, current_sha),
        (own / 'baseline_paired_scores.jsonl', original_ids, baseline_sha)]:
    records = rows(path)
    assert len(records) == len(expected)
    assert {r['surface_id'] for r in records} == expected
    for record in records:
        assert set(record) == expected_fields
        assert record['scorer_id'] == 'scorerB' and record['target_sha'] == sha
        assert record['rubric_version'] == rubric
        assert set(record['scores']) == dimensions
        for dimension, value in record['scores'].items():
            assert type(value) is int and 0 <= value <= 1000 and value % 50 == 0
            if value > 700:
                check_citation(record['evidence'][dimension])
    score_summary.append({'file': str(path.relative_to(audit)), 'rows': len(records),
                          'target_sha': sha, 'high_score_evidence_valid': True})

primary = rows(own / 'probe.stdout.jsonl')
assert len(primary) == 70 and len({r['probe'] for r in primary}) == 70
assert (own / 'probe.target_sha').read_text().strip() == current_sha
assert (own / 'registry.target_sha').read_text().strip() == current_sha
assert len(rows(own / 'registry.stdout.jsonl')) == 4
assert (own / 'object.target_sha').read_text().strip() == current_sha
objects = rows(own / 'object.stdout.jsonl')
assert len(objects) == 3 and all(r['result']['status'] == 'returned' for r in objects)
assert objects[0]['result']['value']['data']['value'] == 'original label'
cache_result = objects[1]['result']['value']
assert cache_result['same_before_change'] and cache_result['fresh_after_change']
assert json.loads(cache_result['old_wrapper_result'])['error']['code'] == 'unavailable'
assert json.loads(objects[2]['result']['value'])['error']['code'] == 'unavailable'
assert (own / 'search.target_sha').read_text().strip() == current_sha
searches = rows(own / 'search.stdout.jsonl')
assert len(searches) == 5 and all(r['result']['status'] == 'returned' for r in searches)
search = {r['probe']: r['result']['value'] for r in searches}
assert [Path(m['path']).name for m in search['late-nul-and-bom-skipped']['data']['matches']] == ['normal.el']
assert [Path(m['path']).name for m in search['ordinary-symlink-file-selected']['data']['matches']] == ['link.el']
assert [Path(m['path']).name for m in search['directory-symlink-not-traversed']['data']['matches']] == ['link.el', 'normal.el']
assert [Path(m['path']).name for m in search['excluded-invalid-utf8-name-unread']['data']['matches']] == ['link.el']
assert json.loads(search['selected-invalid-utf8-name-refused'])['error']['code'] == 'unsupported_output'
assert (own / 'ledger.target_sha').read_text().strip() == current_sha
ledgers = rows(own / 'ledger.stdout.jsonl')
assert len(ledgers) == 4 and all(r['result']['status'] == 'returned' for r in ledgers)
ledger = {r['probe']: r['result']['value'] for r in ledgers}
sync = ledger['sync-completion-io-failure-retains-mutation']
assert sync['calls'] == 1 and sync['bytes'] == 'completed bytes'
assert sync['result']['data']['value'] == 'completed mutation'
assert sync['result']['error']['code'] == 'ledger_write_failed'
assert 'Do not rerun' in sync['result']['error']['recovery']
immediate = ledger['immediate-async-io-failure-delivers-once-and-returns-nil']
assert immediate['calls'] == 1 and immediate['callbacks'] == 1 and immediate['returned_nil']
assert immediate['terminal']['data']['value'] == 'retained async bytes'
assert immediate['terminal']['error']['code'] == 'ledger_write_failed'
assert immediate['terminal']['error']['tool_error']['code'] == 'execution_failed'
ui = ledger['legacy-ui-completion-retains-data-and-visible-warning']
assert ui['calls'] == 1 and ui['bytes'] == 'UI completed bytes'
assert 'UI completed mutation' in ui['reply'] and 'Ledger warning:' in ui['reply']
start = ledger['start-io-failure-prevents-execution']
assert start['calls'] == 0 and start['callbacks'] == 1 and start['returned_nil']
assert start['terminal']['status'] == 'error'
assert (own / 'context.target_sha').read_text().strip() == current_sha
contexts = rows(own / 'context.stdout.jsonl')
assert len(contexts) == 3 and all(r['result']['status'] == 'returned' for r in contexts)
context = {r['probe']: r['result']['value'] for r in contexts}
for value in context.values():
    assert value['first_types'] == ['tool-start', 'tool-finish']
    assert value['wrong_project_types'] == [] and value['caller_enabled_nil']
sdk_context = context['sdk-project-switch-and-future-settings']
assert sdk_context['calls'] == 3 and sdk_context['caller_project_is_b']
assert not sdk_context['disabled_future_file_exists']
assert sdk_context['future_types'] == ['tool-start', 'tool-finish']
assert sdk_context['caller_file'] == 'future-sdk.org'
json_context = context['json-wrapper-relative-destination-survives-project-switch']
assert json.loads(json_context['reply'])['status'] == 'ok'
assert json_context['future_types'] == [] and json_context['caller_file'] == 'future-json.org'
legacy_context = context['legacy-async-relative-destination-survives-project-switch']
assert legacy_context['callbacks'] == 1 and legacy_context['terminal'] == 'legacy switched'
assert legacy_context['future_types'] == [] and legacy_context['caller_file'] == 'future-legacy.org'
assert (own / 'encoding.target_sha').read_text().strip() == current_sha
encoding_metadata = rows(own / 'encoding.metadata.jsonl')[0]
assert encoding_metadata['native_text_first_codepoints'][:2] == [65533, 65533]
encoding_json = json.loads((own / 'encoding.actual-tool.stdout.json').read_bytes())
assert encoding_json['data']['encoding_loss']
assert encoding_json['data']['matches'][0]['text'].startswith('\ufffd\ufffd')
baseline_hashes = json.loads((own / 'baseline_refresh_identity.json').read_text())
assert all(hashlib.sha256((own / name).read_bytes()).hexdigest() == digest
           for name, digest in baseline_hashes.items())
probe = {r['probe']: r['result']['value'] for r in primary if r['result']['status'] == 'returned'}
assert probe['copy-before-policy']['data']['content'] == 'first one'
frozen = probe['batch-frozen-later-call']['data']['results'][1]
assert frozen['tool'] == 'read-file' and frozen['data']['content'] == 'first one'
assert probe['default-read-configured-cap']['data']['limit'] == 1
assert [Path(m['path']).name for m in probe['gnu-component-filter']['data']['matches']] == ['direct.el']
assert probe['gnu-explicit-file-filter']['data']['matches'] == []
assert json.loads(probe['unsupported-raw-name-json'])['error']['code'] == 'unsupported_output'
for record in primary:
    value = record['result'].get('value')
    if isinstance(value, str) and value.lstrip().startswith('{'):
        json.loads(value)

build_records = rows(own / 'build-runtime.jsonl')
assert len(build_records) == 18 and all(r['target_sha'] == current_sha for r in build_records)
build = {r['probe']: r for r in build_records}
json_reports = {}
for record in build_records:
    if record['stdout'].lstrip().startswith('{'):
        json_reports[record['probe']] = json.loads(record['stdout'])
        assert '\x1b' not in record['stdout'] and '\x1b' not in record['stderr']
assert len(json_reports) == 13
for name in ['compile-success-1', 'compile-success-2', 'recompile-success', 'test-success',
             'compile-warning-failure', 'recompile-warning-failure']:
    assert build[name]['exit_code'] == 0
    assert json_reports[name]['status'] == 'success'
for name, code in [('task-typo', 2), ('emacs-option-typo', 2),
                   ('lint-compile-warning-failure', 1), ('compile-syntax-failure', 2),
                   ('recompile-syntax-failure', 2), ('ert-real-failure', 1)]:
    assert build[name]['exit_code'] == code
    assert json_reports[name]['status'] == 'error'
assert json_reports['compile-syntax-failure']['exit_code'] == 1
ert = json_reports['ert-real-failure']
assert any(d['file'] == 'test/scorer-fixture-tests.el' and d['line'] == 4
           for d in ert['diagnostics'])
assert json_reports['compile-success-1'] != json_reports['compile-success-2']
assert all(json.loads((own / 'clean-state.json').read_text()).values())
assert len(rows(own / 'baseline-probe.stdout.jsonl')) == 40
assert len(rows(own / 'baseline-build-runtime.jsonl')) == 12
assert all(r['target_sha'] == baseline_sha for r in rows(own / 'baseline-build-runtime.jsonl'))

hashes = []
for path in sorted((own / 'baseline-source').rglob('*')):
    if not path.is_file() or path.name == 'TARGET_SHA':
        continue
    original_path = str(path.relative_to(own / 'baseline-source'))
    git_bytes = subprocess.check_output(['git', 'show', baseline_sha + ':' + original_path], cwd=repo)
    assert path.read_bytes() == git_bytes, original_path
    hashes.append({'file': str(path.relative_to(audit)), 'source_sha': baseline_sha,
                   'sha256': hashlib.sha256(git_bytes).hexdigest()})
for path in sorted(cited_files):
    if path.is_relative_to(own):
        continue
    original_path = str(path.relative_to(repo))
    git_bytes = subprocess.check_output(['git', 'show', current_sha + ':' + original_path], cwd=repo)
    assert path.read_bytes() == git_bytes, original_path
    hashes.append({'file': '../' + original_path, 'source_sha': current_sha,
                   'sha256': hashlib.sha256(git_bytes).hexdigest()})
for path in ['Makefile', 'makem.sh']:
    assert (own / 'build-fixture' / path).read_bytes() == (repo / path).read_bytes()
    assert (own / 'baseline-build-fixture' / path).read_bytes() == (own / 'baseline-source' / path).read_bytes()
identity = (own / 'baseline-current-function-identity.txt').read_text().splitlines()
assert len(identity) == 9 and all(line.endswith(' t') for line in identity)
(own / 'source_hashes.json').write_text(json.dumps(hashes, indent=2) + '\n')
summary = {'current_sha': current_sha, 'baseline_sha': baseline_sha, 'score_files': score_summary,
           'current_primary_runtime_rows': 70, 'current_real_gptel_registry_rows': 4,
           'current_object_input_cache_runtime_rows': 3,
           'current_binary_selection_runtime_rows': 5,
           'current_ledger_recovery_runtime_rows': 4,
           'current_ledger_context_runtime_rows': 3,
           'current_encoding_metadata_records': 1,
           'baseline_paired_artifacts_byte_identical': True,
           'current_real_build_commands': 18, 'current_json_build_reports': len(json_reports),
           'baseline_runtime_rows': 40, 'baseline_real_build_commands': 12,
           'unchanged_source_forms': 9, 'source_hashes_validated': len(hashes),
           'final_edge_assertions': 'all passed', 'numeric_scores_are_qualitative': True}
(own / 'validation.json').write_text(json.dumps(summary, indent=2) + '\n')
print(json.dumps(summary, indent=2))
