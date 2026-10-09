"""Independent anchors chosen before reading other scorers or raw history."""
import datetime
import json
import sys
from pathlib import Path

OUT = Path(__file__).resolve().parent
DIMENSIONS = ['agent_intuitiveness', 'agent_ergonomics', 'agent_ease_of_use',
              'output_parseability', 'error_pedagogy', 'intent_inference',
              'safety_with_recovery', 'determinism_and_reproducibility',
              'self_documentation', 'composability', 'regression_resistance']
RUBRIC = 'sha256:44e7c00b3dee6be38118f1f40719d814278cb129f9aad34572e0936104b135a4'
SNAPSHOTS = {'baseline': 'b3caf9300c7336ef812ed061158f851c5a47ccf7',
             'current': 'a2fa8ce0533b4a508fb641f343fa55b15fd6fc60'}
BASE = {
 'sdk_method__tools__write-file': [750,850,350,100,750,0,0,750,350,800,600],
 'sdk_method__tools__edit-file': [750,850,400,100,850,0,0,750,400,800,650],
 'sdk_method__registry__tool-get': [750,900,450,850,250,250,1000,750,450,850,600],
 'sdk_method__execution__wrapper': [750,750,500,100,650,0,500,750,500,400,650],
 'verb__make__recompile': [750,800,650,100,350,0,250,600,600,250,400],
 'verb__make__clean': [750,650,650,100,250,0,250,750,600,800,500],
 'sdk_method__tools__read-file': [750,850,650,100,800,0,1000,750,650,800,650],
 'sdk_method__tools__glob': [750,850,550,100,750,0,1000,750,650,750,650],
 'sdk_method__tools__grep': [750,800,650,100,750,0,1000,700,650,650,650],
}
CURRENT = {
 'sdk_method__tools__write-file': BASE['sdk_method__tools__write-file'],
 'sdk_method__tools__edit-file': BASE['sdk_method__tools__edit-file'],
 'sdk_method__registry__tool-get': [750,900,450,850,250,500,1000,750,450,850,700],
 'sdk_method__execution__wrapper': [750,750,600,850,850,0,600,800,650,450,750],
 'verb__make__recompile': [800,800,800,800,800,250,250,650,800,850,800],
 'verb__make__clean': BASE['verb__make__clean'],
 'sdk_method__tools__read-file': [750,850,700,800,800,0,1000,850,750,850,700],
 'sdk_method__tools__glob': [750,850,700,800,750,0,1000,800,750,850,700],
 'sdk_method__tools__grep': [750,800,700,800,750,0,1000,800,750,800,700],
}
PROBES = {
 'sdk_method__tools__write-file': ['raw-write-first-and-repeat', 'raw-write-invalid-content',
                                  'raw-write-overwrites-without-approval', 'raw-helper-method-aliases'],
 'sdk_method__tools__edit-file': ['raw-edit-first', 'raw-edit-not-found', 'raw-edit-ambiguous',
                                 'raw-edit-repeat-identical-initial-content', 'raw-helper-method-aliases'],
 'sdk_method__registry__tool-get': ['registry-first-symbol-string-underscore-alias-typo'],
 'sdk_method__execution__wrapper': ['wrapper-first-and-repeat', 'wrapper-wrong-order',
                                   'wrapper-no-method-alias', 'wrapper-actual-policy-denial',
                                   'wrapper-edit-review-keeps-file'],
 'sdk_method__tools__read-file': ['raw-read-first-repeat-and-pagination', 'raw-read-invalid-offset',
                                 'raw-read-method-aliases', 'raw-read-json-repeat'],
 'sdk_method__tools__glob': ['raw-glob-first-and-repeat', 'raw-glob-invalid-path', 'raw-glob-json-repeat'],
 'sdk_method__tools__grep': ['raw-grep-first-and-repeat', 'raw-grep-invalid-regex', 'raw-grep-json-repeat'],
}
NOTES = {
 'sdk_method__tools__write-file': 'Scope is direct ogent-tool--write-file, not registered write dispatch. One-line callable API; prose return and actionable user-error validation. It overwrites even under a deny rule: no approval/dry-run/rollback gate. No primitive method aliases. Source-defined method and its targeted tests are unchanged; all paired scores remain flat.',
 'sdk_method__tools__edit-file': 'Scope is direct ogent-tool--edit-file. Unique-context and boolean validation protect against ambiguous edits but do not add approval or rollback to a successful destructive mutation. No primitive method aliases. Repeat comparison restores identical initial content; this does not claim repeat-on-already-edited-content idempotency. Unchanged function, scope and criteria yield flat paired scores.',
 'sdk_method__registry__tool-get': 'Scope is ogent-tool-get itself, returning an actual gptel-tool struct or documented nil. Symbol/string and underscore canonicalization work in both snapshots; common read/cat tool-name aliases work only in current. Typos and unknown names still return nil here: corrective ogent-tool-ensure errors belong to another API. safety_with_recovery n/a: lookup/registration cache changes cause no irreversible user-data operation.',
 'sdk_method__execution__wrapper': 'Scope is a spec-bound positional gptel closure, not ogent-agent-call named dispatch. intent_inference applies under the SDK rubric and scores zero: the method supplies no common alternative method aliases and does not reorder positional arguments. Corrective type/arity validation belongs to error_pedagogy. Current optional JSON adds versioned typed results, recovery messages and tests. Both snapshots own approval/edit review; leases/rollback are absent. Both can use the interactive approval owner, so the separate nonprompting public SDK does not confer composability credit here.',
 'verb__make__recompile': 'Scope is the actual Make recompile target and actual makem subprocess. Macro clean+compile, exit propagation and compiler invocation verified in a tracked provider-free fixture. intent_inference applies: mutable verbs are not n/a. Neither snapshot supports a recompile alias; current typo recompiel routes to generic make help, earning only partial discovery-level recovery. Current JSON preserves helper-specific failure code separately from GNU Make exit 2. PID and temporary argv paths vary; no byte-identical report claim.',
 'verb__make__clean': 'Scope is the generated lisp/test .elc cleanup target. It is mutating, so safety and intent apply. Standard GNU Make -n offers a preview; no confirmation gate or advertised rollback. The bound is generated bytecode, with compile available for recreation. No clean-specific aliases or typo correction. Existing clean/help cleanup test covers real find deletion. format=json still supplies no clean result schema; documented exclusion is honored. Canonical cleanup, bounded mutation and targeted tests are unchanged; paired scores remain flat.',
 'sdk_method__tools__read-file': 'Scope is the raw read primitive. Under SDK composability, standard returned Lisp strings and catchable conditions compose without prompts/ANSI in baseline; absence of JSON is output_parseability, not a CLI pipeline failure. Current explicit plist/json adds structured positions, snapshot and continuation data. No raw primitive method aliases; registered read/cat aliases are a separate named surface. safety_with_recovery n/a: read-only file operation.',
 'sdk_method__tools__glob': 'Scope is the raw glob primitive. Baseline returned standard strings compose in Lisp, with no prompts/ANSI; newline-separated filenames still limit parseability. Current explicit plist/json adds path objects and complete bounded pages. Snapshot identifies file metadata rather than content. No raw primitive method aliases. safety_with_recovery n/a: read-only discovery.',
 'sdk_method__tools__grep': 'Scope is the raw grep primitive. Baseline returns standard strings and signals catchable user-errors; optional streaming callbacks and progress messages require management, limiting SDK composability. Current explicit plist/json returns vectors of match objects with positions and snapshots using the actual GNU grep engine in these transcripts. No direct search alias at the primitive API. safety_with_recovery n/a: read-only search. No inference/provider/auth requests.',
}

def transcript_evidence(phase, surface):
    name = f'{phase}-sdk-ogent-fixes.stdout.log'
    text = (OUT / name).read_text()
    lines = text.splitlines()
    markers = PROBES[surface]
    excerpts = []
    for marker in markers:
        found = next(((n + 1, line) for n, line in enumerate(lines)
                      if f':probe "{marker}"' in line), None)
        if found:
            excerpts.append({'probe': marker, 'line': found[0], 'stdout_excerpt': found[1]})
    return {'file': 'agent_ergonomics_audit/audit/evidence/pass_3/tiebreaker/' + name,
            'invocation': json.loads((OUT / f'{phase}-sdk-ogent-fixes.json').read_text())['argv'],
            'probes': excerpts,
            'second_runtime': f'audit/evidence/pass_3/tiebreaker/{phase}-sdk-ogent-fixes-29.stdout.log',
            'source_identity': 'audit/evidence/pass_3/tiebreaker/source-identities.json'}

def make_evidence(phase, surface):
    stem = 'make-clean' if surface.endswith('clean') else 'make-recompile'
    files = [f'{phase}-{stem}-first.stdout.log', f'{phase}-{stem}-first.stderr.log']
    if stem == 'make-clean':
        files += [f'{phase}-{stem}-repeat.stdout.log', f'{phase}-{stem}-dry-run.stdout.log']
    else:
        files += [f'{phase}-{stem}-typo.stdout.log', f'{phase}-{stem}-typo.stderr.log',
                  f'{phase}-{stem}-compiler-failure.stdout.log', f'{phase}-{stem}-compiler-failure.stderr.log']
        if phase == 'current':
            files += [f'{phase}-{stem}-json-first.stdout.log', f'{phase}-{stem}-json-repeat.stdout.log',
                      f'{phase}-{stem}-eof-failure.stdout.log',
                      'current-make-capabilities.stdout.log']
    line = (100 if phase == 'current' else 88) if surface.endswith('clean') else (105 if phase == 'current' else 93)
    return {'file': 'Makefile', 'line': line,
            'invocation': json.loads((OUT / f'{phase}-{stem}-first.json').read_text())['argv'],
            'transcripts': ['audit/evidence/pass_3/tiebreaker/' + f for f in files],
            'help': f'audit/evidence/pass_3/tiebreaker/{phase}-make-help.stdout.log',
            'identity': f'audit/evidence/pass_3/tiebreaker/{phase}-make-source-identities.json'}

for phase, scores_by_surface in [('baseline', BASE), ('current', CURRENT)]:
    if len(sys.argv) > 1 and phase != sys.argv[1]:
        continue
    rows = []
    for surface, values in scores_by_surface.items():
        scores = dict(zip(DIMENSIONS, values))
        evidence = {}
        common = (make_evidence(phase, surface) if surface.startswith('verb__')
                  else transcript_evidence(phase, surface))
        for dimension, score in scores.items():
            evidence[dimension] = dict(common)
            evidence[dimension]['criterion'] = NOTES[surface]
        if surface in ('sdk_method__registry__tool-get', 'sdk_method__tools__read-file',
                       'sdk_method__tools__glob', 'sdk_method__tools__grep'):
            evidence['safety_with_recovery'] = {'reason': 'n/a — read-only lookup/read/discovery/search; no irreversible user-data operation',
                                                'source_identity': 'audit/evidence/pass_3/tiebreaker/source-identities.json'}
        if phase == 'current' and surface in ('sdk_method__tools__read-file', 'sdk_method__tools__glob', 'sdk_method__tools__grep'):
            evidence['self_documentation']['additional_file'] = 'lisp/ogent-agent.el'
            evidence['self_documentation']['additional_line'] = 278
            evidence['output_parseability']['additional_file'] = ('lisp/ogent-tool-results.el' if not surface.endswith('grep') else 'lisp/ogent-tool-process.el')
        if phase == 'current' and surface == 'sdk_method__execution__wrapper':
            evidence['output_parseability']['additional_file'] = 'lisp/ogent-tool-execution.el'
            evidence['output_parseability']['additional_line'] = 53
            evidence['regression_resistance'] = {'file': 'test/ogent-agent-execution-tests.el', 'line': 927,
                'assertion': 'The wrapper JSON callback contract asserts (= calls 1) and exact data.value; stale metadata after approval asserts no replacement execution. Real ledger completion I/O recovery retains stdout/stderr and exactly one callback at line 246. Context tests at lines 444 and 523 assert paired ledger events at the original destination without changing callback ambient settings.',
                'terminal_transcripts': ['audit/evidence/pass_3/tiebreaker/current-ledger-terminal-ogent-fixes.stderr.log', 'audit/evidence/pass_3/tiebreaker/current-ledger-terminal-ogent-fixes-29.stderr.log'],
                'source_sha': SNAPSHOTS[phase]}
        if phase == 'current' and surface == 'verb__make__recompile':
            evidence['regression_resistance'] = {'file': 'test/makem-report-tests.sh', 'line': 145,
                'assertion': 'Real Make recompile report parsed with json.load; requested_tasks == [compile] and commands is nonempty. Real compiler error assertions at lines 184-188.',
                'ci_file': '.github/workflows/ci.yml', 'ci_line': 108,
                'source_sha': SNAPSHOTS[phase]}
        rows.append({'surface_id': surface, 'scorer_id': 'tiebreaker', 'pass': 3,
                     'target_sha': SNAPSHOTS[phase], 'source_sha': SNAPSHOTS[phase],
                     'rubric_version': RUBRIC, 'scores': scores,
                     'weighted_score': round(sum(values) / len(DIMENSIONS), 3),
                     'evidence': evidence, 'notes': NOTES[surface],
                     'scored_at': datetime.datetime.now(datetime.timezone.utc).isoformat()})
    destination = OUT / ('baseline_paired_scores.jsonl' if phase == 'baseline' else 'current_scores.jsonl')
    destination.write_text(''.join(json.dumps(row, sort_keys=True) + '\n' for row in rows))
    print(f'{phase}: {len(rows)} independent all-11-dimension rows written to {destination.name}')
