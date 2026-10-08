import json
import pathlib
import re

repo = pathlib.Path('/workspace/ogent')
audit = repo / 'agent_ergonomics_audit'
partial = audit / 'audit/partial'
inventory = [json.loads(line) for line in (audit / 'audit/surface_inventory.jsonl').read_text().splitlines()]
runtime = {row['probe']: row for line in (partial / 'scorerA_post_runtime.jsonl').read_text().splitlines() if (row := json.loads(line))}
make_runtime = {row['probe']: row for line in (partial / 'scorerA_post_make_runtime.jsonl').read_text().splitlines() if (row := json.loads(line))}
dimensions = ['agent_intuitiveness', 'agent_ergonomics', 'agent_ease_of_use',
              'output_parseability', 'error_pedagogy', 'intent_inference',
              'safety_with_recovery', 'determinism_and_reproducibility',
              'self_documentation', 'composability', 'regression_resistance']

definitions = {
 'sdk_method__tools__read-file': ([850,900,700,300,800,0,1000,800,750,800,750], 'read-valid-1','read-valid-2','read-negative-offset',81,
   'Positive bounds are validated with offset=1/limit=200 corrective guidance. Pagination names exact next call and long-line truncation is explicit. Repeated pages identical. Results remain numbered text rather than structured lines; the additive handbook/capabilities document this existing surface without changing its result format.'),
 'sdk_method__tools__glob': ([800,850,700,250,750,0,1000,800,750,800,750], 'glob-valid-1','glob-valid-2','glob-missing-root',61,
   'Recursive ** now includes root, shallow and deeply nested files; equal-mtime paths receive lexical tie-break. Missing root is an actionable error. Paths remain newline text, with a fixed 100-result cap lacking explicit truncation metadata. The paired existing method is assessed, not the new discovery endpoint.'),
 'sdk_method__tools__grep': ([800,850,700,300,800,0,1000,800,750,750,800], 'grep-valid-1','grep-valid-2','grep-invalid-regex',24,
   'Invalid regex now signals exit2 with valid-pattern retry advice; no match is success. Pattern option terminator and independently quoted arguments prevent the demonstrated filter injection and leading-hyphen misinterpretation. No wall-clock footer. Text locations/result-line count remain informal schema; context separators and lines are accurately called result lines.'),
 'sdk_method__tools__grep-async': ([800,850,700,700,800,0,1000,650,750,800,750], 'grep-async-valid-1','grep-async-valid-2','grep-async-invalid-regex',24,
   'Structured native callback events distinguish match/done/error; invalid regex gives teaching terminal error. Shared quoting fixes prevent injected execution, so safety is now n/a for read-only search. Stream chunk/order and context-line semantics prevent a maximum determinism/parseability score.'),
 'sdk_method__tools__bash': ([800,850,650,350,800,1000,0,800,700,650,800], 'bash-valid-1','bash-valid-2','bash-invalid-timeout',296,
   'Command/directory/positive timeout validated before spawn; shell failure status survives truncated output, stderr lifecycle sentinel removed, elapsed prose removed. Result is still mixed human stdout/stderr/exit text. Direct private shell function executes immediately; handbook explicitly requires registered policy wrapper for approval, so raw SDK safety remains zero. Intent n/a: no SDK name decoder; shell-language typos outside scope.'),
 'sdk_method__tools__bash-async': ([800,850,700,700,800,1000,0,650,700,800,800], 'bash-async-valid-1','bash-async-valid-2','post-shell-async-truncation',307,
   'Explicit output-cap notice retains chunk prefix and done7; exact-limit/oversized ERT cases finish once. Native stdout/stderr/done events compose, but observed relative stdout/stderr event order differs between repeats. Raw function still bypasses approval boundary; safety remains zero. Intent n/a for private positional shell method; parameter validation belongs error pedagogy.'),
 'sdk_method__tools__write-file': ([750,850,600,250,800,0,0,800,700,750,750], 'write-valid','write-repeat','write-invalid-content',128,
   'Invalid integer content now rejects before mutation and existing one text remains intact. Successful low-level call still directly overwrites a file, has no dry-run or undo contract, and returns human prose; safety stays zero under the original SDK criterion. Registered execution provides review, but its safety is scored separately.'),
 'sdk_method__tools__edit-file': ([800,850,650,250,850,0,0,500,700,700,800], 'edit-ambiguous',None,'edit-missing-old',100,
   'Ambiguous old text now rejects with count2, unique-context/replace_all guidance and unchanged same same bytes. Empty strings and wrong booleans rejected; default preview uses identical preflight and stable absolute reviewed target. Successful direct API still overwrites immediately; no approval/undo gate at this raw surface, so safety remains zero. Repeating a replacement is not idempotent.'),
 'sdk_method__registry__tool-get': ([750,850,650,800,0,500,1000,700,750,850,750], 'tool-get-valid',None,'tool-get-typo',182,
   'String and symbol names plus registered underscore aliases resolve to native gptel objects. Deliberate missing-entry nil remains compatible: original tool-get does not itself teach typo recovery; strict ensure does, and is not conflated with this paired surface. Shared handbook and capabilities improve discovery.'),
 'sdk_method__registry__tool-spec-get': ([800,850,700,850,0,500,1000,800,800,850,750], 'tool-spec-valid','post-tool-spec-repeat','tool-spec-string',182,
   'Canonical string/symbol and underscore alias return native argument/effect/description plists with stable repeat bytes. Missing spec still deliberately nil; strict correction endpoint is separate. Additive versioned discovery describes registry metadata but does not turn this native plist API into JSON.'),
 'sdk_method__registry__available-tools': ([800,850,700,800,850,800,1000,800,750,850,800], 'available-tools-1','available-tools-2','available-tools-unknown-filter',194,
   'Enabled list stays native gptel objects and stable order. Misspelled filter now rejects with did-you-mean read-file, sorted valid names and capability guidance instead of silent empty list. Aliases are canonicalized consistently with approval rules; disabled nil remains meaningful.'),
 'sdk_method__execution__wrapper': ([750,850,650,300,750,0,700,700,750,750,800], 'wrapper-stale',None,'wrapper-arity-invalid',139,
   'Excess positional values now produce Tool error before policy/execution instead of being discarded; declared types, booleans, unknown and duplicate named args are checked. Shared preview checks uniqueness before showing review and fixes absolute target. Async ownership remains exactly-once. Failure result remains text, and safe concurrency/reversal contract is incomplete; safety700 rather than maximal.'),
 'sdk_method__doctor__run': ([850,850,650,850,650,1000,1000,800,750,850,800], 'doctor-run-1','doctor-run-2','doctor-crash-contained',204,
   'Existing core native plist schema remains intact and contains per-check crashes. JSON serialization is an explicit separate operation; run itself is not credited as JSON endpoint. Shared versioned health/guide improve introspection. Intent n/a for canonical zero-argument SDK invocation; malformed check outcomes belong error pedagogy. Fixed fixture repetition stable; live environment may change.'),
 'sdk_method__doctor__batch': ([850,850,800,850,750,1000,1000,800,800,850,850], 'post-doctor-json-1','post-doctor-json-2','doctor-crash-contained',204,
   'Optional JSON emits only versioned data, explicit status/exit-code and ordered checks; own two fixture invocations byte-identical. Human Org default and returned 0/1/2 preserved. Invalid format fails before probes with exact retry. Intent n/a for canonical native invocation. Environment/probe volatility and absence of schema-version bump enforcement prevent maximum scores.'),
 'verb__make__help': ([850,650,750,0,250,0,1000,800,750,800,750], 'help-1','help-2',None,355,
   'Help now lists clean/recompile, consistent EMACS override, provider-free SDK discovery, JSON doctor and severity dictionary. Identical repeats and no diagnostics. Human text only: no Make target JSON schema or typo recovery. SDK discovery is named as a follow-up and is not treated as the help target output.'),
 'verb__make__compile': ([700,650,650,100,250,0,1000,700,650,250,650], 'compile-dry',None,None,344,
   'Make now forwards selected EMACS to makem consistently. Recompile calls this same dependency-aware target. Failure recipe is observable nonzero, but actual makem text still repeats compiler diagnostics on stdout and stderr, with ANSI/timestamps in stderr. No machine-readable compilation result. Safety n/a: regenerable bytecode only.'),
 'verb__make__recompile': ([750,750,650,100,250,0,1000,700,650,250,750], 'recompile-failing-emacs',None,None,344,
   'Own isolated fixture using actual makem and selected fake Emacs returns nonzero with compiler diagnostic, preserving failure rather than declaring success. Clean targets lisp/test bytecode and no production files were touched by probe. makem logs remain ANSI/timestamp prose and stdout diagnostics, so parseability/composability remain low. Safety n/a: regenerable bytecode only.'),
 'verb__make__clean': ([800,850,650,0,250,0,1000,800,650,800,750], 'clean-1','clean-2',None,355,
   'Clean now removes generated test bytecode as well as lisp bytecode and is explicitly documented with compile/recompile recovery. Own fixture repeated output identical. Human success prose remains unstructured, with no custom error teaching or aliases. Safety n/a: only regenerable bytecode changes.'),
 'verb__make__offline-test': ([800,750,700,500,800,0,750,500,700,750,850], 'offline-missing-deps',None,'offline-missing-deps',453,
   'Missing OGENT_ELPA_DIR now fails before fixtures, with empty stdout and exact export/retry on stderr, confirmed by own invocation. Optional source and required binaries also preflight. Local fixtures have bounded execution/cleanup and four required CI dependency combinations. Successful ERT output remains human logs, so preflight purity does not make the entire target a JSON result. Provider login/inference excluded.'),
}

readonly = {s['surface_id'] for s in inventory if not s['mutates']}
readonly |= {'verb__make__compile','verb__make__recompile','verb__make__clean'}
intent_na = {'sdk_method__tools__bash','sdk_method__tools__bash-async','sdk_method__doctor__run','sdk_method__doctor__batch'}
all_records=[]
for surface in inventory:
    sid=surface['surface_id']
    nums,probe,repeat,error_probe,testline,notes=definitions[sid]
    observed=runtime if surface['is_sdk_surface'] else make_runtime
    file=surface['source']['file']
    source=(repo/file).read_text().splitlines()
    if surface['is_sdk_surface']:
        line=next(i+1 for i,t in enumerate(source) if t.startswith('(defun '+surface['name']+' '))
    else:
        line=next(i+1 for i,t in enumerate(source) if t.startswith(surface['name']+':'))
    invocation=('docker exec ogent-fixes timeout 35 emacs -Q --batch -L /work/lisp -L /work/lisp/ui -l /work/agent_ergonomics_audit/audit/partial/scorerA_post_probe.el; probe='+probe) if surface['is_sdk_surface'] else ' '.join(observed[probe]['invocation'])
    row=observed[probe]
    ev={'file':file,'line':line,'invocation':invocation,
        'stdout_excerpt':row.get('result',row.get('stdout',row.get('error','')))[:1400],
        'transcript':'audit/partial/scorerA_post_runtime.jsonl' if surface['is_sdk_surface'] else 'audit/partial/scorerA_post_make_runtime.jsonl'}
    if not surface['is_sdk_surface']:
        ev.update(exit_code=row['exit_code'],stderr_excerpt=row['stderr'][:1400])
    evidence={d:dict(ev) for d in dimensions}
    if error_probe:
        error=observed[error_probe]
        evidence['error_pedagogy'].update(probe=error_probe,stdout_excerpt=str(error)[:1400])
        if nums[5]>0 and sid not in intent_na:
            evidence['intent_inference']=dict(evidence['error_pedagogy'])
    if repeat:
        evidence['determinism_and_reproducibility'].update(repeat_probe=repeat,
          repeat_stdout_excerpt=observed[repeat].get('result',observed[repeat].get('stdout',''))[:1400])
    if surface['is_sdk_surface'] and nums[8]>700:
        evidence['self_documentation']={'file':'lisp/ogent-agent.el','line':96,
          'invocation':'(ogent-agent-guide); (ogent-agent-capabilities \'json)',
          'stdout_excerpt':runtime['post-guide']['result'][:1400],
          'reason':'Shared existing-tool handbook/live metadata; original return format scored independently.'}
    evidence['regression_resistance']={'file':'test/ogent-agent-ergonomics-tests.el','line':testline,
      'invocation':'docker exec ogent-fixes env TMPDIR=/work/agent_ergonomics_audit/audit/partial timeout 35 bash /work/agent_ergonomics_audit/tools/run-ert.sh ^ogent-agent-ergonomics',
      'transcript':'audit/partial/scorerA_post_regression.stderr',
      'reason':'Independent current replay succeeded; behavioral regression assertion at cited test line. Schema version change enforcement is incomplete.'}
    if sid in readonly:
        reason='n/a — read-only surface; no irreversible operation. Optional provider/network probes excluded.'
        if sid.startswith('verb__make__') and sid!='verb__make__help':
            reason='n/a — only regenerable bytecode artifacts change; false-success/log issues remain parseability, error-pedagogy and determinism concerns.'
        evidence['safety_with_recovery']={'reason':reason}
        notes += ' safety_with_recovery is n/a for this read-only or regenerable-bytecode surface.'
    if sid in intent_na:
        evidence['intent_inference']={'reason':'n/a — same reconciled SDK applicability as baseline: canonical zero-argument doctor or private positional shell method has no alternative-name decoder; malformed parameters belong error pedagogy and shell-language typo recovery is outside scope.'}
        notes += ' intent_inference is n/a under the reconciled SDK applicability.'
    record={'surface_id':sid,'scorer_id':'A','rubric_version':'sha256:44e7c00b3dee6be38118f1f40719d814278cb129f9aad34572e0936104b135a4',
      'scores':dict(zip(dimensions,nums)),'weighted_score':sum(nums)/11,
      'evidence':evidence,'notes':notes+' SDK adaptation and reconciled baseline applicability retained. Frozen source 2ee1692212afcc0e0a7a245bdf023dfa2d750172; same-model independent scorer A, no scorer B output read.'}
    path=partial/f'scores_pass2_{sid}_scorerA.jsonl'
    path.write_text(json.dumps(record,ensure_ascii=False,sort_keys=True)+'\n')
    all_records.append(record)
    print('scored',sid,'as A: weighted='+str(round(record['weighted_score'],1)),'wrote',path)

assert len(all_records)==19
for r in all_records:
    assert len(r['scores'])==11
    assert all(0<=v<=1000 and v%50==0 for v in r['scores'].values())
    assert abs(r['weighted_score']-sum(r['scores'].values())/11)<1e-9
    assert all(r['evidence'].get(k) for k,v in r['scores'].items() if v>700)
baseline=[json.loads((partial/f'scores_pass1_{s["surface_id"]}_scorerA.jsonl').read_text()) for s in inventory]
summary={'scorer_id':'A','target_sha':'2ee1692212afcc0e0a7a245bdf023dfa2d750172','surfaces':19,
         'baseline_mean':sum(r['weighted_score'] for r in baseline)/19,
         'post_mean':sum(r['weighted_score'] for r in all_records)/19}
summary['delta']=summary['post_mean']-summary['baseline_mean']
(partial/'scorerA_post_summary.json').write_text(json.dumps(summary,indent=2)+'\n')
print(json.dumps(summary))
