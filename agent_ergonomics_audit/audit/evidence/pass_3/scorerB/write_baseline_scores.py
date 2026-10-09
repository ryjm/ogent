"""Paired baseline judgment with the same criteria as scorer B's current rows."""
import json
from pathlib import Path

repo=Path('/workspace/ogent')
audit=repo/'agent_ergonomics_audit'
own=audit/'audit/evidence/pass_3/scorerB'
baseline=own/'baseline-source'
sha=(baseline/'TARGET_SHA').read_text().strip()
current=[json.loads(line) for line in (audit/'audit/partial/scores_pass4_current_scorerB.jsonl').read_text().splitlines()]
dimensions=list(current[0]['scores'])
probe_rows=[json.loads(line) for line in (own/'baseline-probe.stdout.jsonl').read_text().splitlines()]
probe_index={r['probe']:(i,r) for i,r in enumerate(probe_rows,1)}
build_rows=[json.loads(line) for line in (own/'baseline-build-runtime.jsonl').read_text().splitlines()]
build_index={r['probe']:(i,r) for i,r in enumerate(build_rows,1)}

def rt(name,note):
    line,row=probe_index[name]
    return {'file':'audit/evidence/pass_3/scorerB/baseline-probe.stdout.jsonl','line':line,
            'invocation':row['invocation'],'note':note}

def build(name,note):
    line,row=build_index[name]
    return {'file':'audit/evidence/pass_3/scorerB/baseline-build-runtime.jsonl','line':line,
            'invocation':' '.join(row['argv']),'note':note}

def src(path,anchor,note):
    line=next(i for i,text in enumerate((baseline/path).read_text().splitlines(),1) if anchor in text)
    return {'file':'audit/evidence/pass_3/scorerB/baseline-source/'+path,'line':line,'note':note}

def stable(name,second,note):
    assert probe_index[name][1]['result']['value']==probe_index[second][1]['result']['value']
    return rt(name,note+' Identical repeated returned value at '+second+', line '+str(probe_index[second][0])+'.')

def safety(path,anchor,note):
    ev=src(path,anchor,'n/a: '+note);ev['n/a']=True;return ev

changes={
 'sdk_method__tools__read-file':dict(agent_intuitiveness=800,agent_ergonomics=750,output_parseability=250,
                                  determinism_and_reproducibility=800,self_documentation=650,composability=800,regression_resistance=800),
 'sdk_method__tools__glob':dict(agent_intuitiveness=800,agent_ergonomics=700,output_parseability=250,
                             determinism_and_reproducibility=800,self_documentation=650,composability=800,regression_resistance=800),
 'sdk_method__tools__grep':dict(agent_intuitiveness=800,agent_ergonomics=750,output_parseability=250,
                             determinism_and_reproducibility=750,self_documentation=650,composability=800,regression_resistance=800),
 'sdk_method__tools__bash':dict(agent_ergonomics=750,output_parseability=250,composability=750,regression_resistance=800),
 'sdk_method__registry__tool-get':dict(regression_resistance=750),
 'sdk_method__execution__wrapper':dict(output_parseability=250,error_pedagogy=600,safety_with_recovery=500,
                                     determinism_and_reproducibility=700,regression_resistance=750),
 'verb__make__help':dict(agent_ease_of_use=750,self_documentation=750),
 'verb__make__compile':dict(agent_intuitiveness=800,agent_ergonomics=500,agent_ease_of_use=650,output_parseability=250,
                          error_pedagogy=500,intent_inference=0,determinism_and_reproducibility=250,
                          self_documentation=500,composability=250,regression_resistance=650),
 'verb__make__recompile':dict(agent_intuitiveness=800,agent_ergonomics=750,agent_ease_of_use=650,output_parseability=250,
                            error_pedagogy=500,intent_inference=0,determinism_and_reproducibility=250,
                            self_documentation=500,composability=250,regression_resistance=650),
}
method_info={
 'sdk_method__tools__read-file':('lisp/ogent-tools.el','ogent-tool--read-file','read-text-1','test/ogent-agent-ergonomics-tests.el','ogent-agent-ergonomics-read-pagination-next-offset'),
 'sdk_method__tools__glob':('lisp/ogent-tools.el','ogent-tool--glob','glob-text-1','test/ogent-agent-ergonomics-tests.el','ogent-agent-ergonomics-glob-recursive-and-stable'),
 'sdk_method__tools__grep':('lisp/ogent-tools.el','ogent-tool--grep','grep-text-1','test/ogent-agent-ergonomics-tests.el','ogent-agent-ergonomics-grep-errors-invalid-regex'),
 'sdk_method__tools__grep-async':('lisp/ogent-tools.el','ogent-tool--grep-async','grep-async','test/ogent-tools-tests.el','ogent-tools-grep-async-accepts-file-path'),
 'sdk_method__tools__bash':('lisp/ogent-tools.el','ogent-tool--bash','bash-text-1','test/ogent-agent-ergonomics-tests.el','ogent-agent-ergonomics-bash-contract-exit-survives-truncation'),
 'sdk_method__tools__bash-async':('lisp/ogent-tools.el','ogent-tool--bash-async','bash-async','test/ogent-tools-tests.el','ogent-tools-bash-async-timeout-callback-once'),
 'sdk_method__tools__write-file':('lisp/ogent-tools.el','ogent-tool--write-file','write-raw','test/ogent-tools-tests.el','ogent-tools-write-file-overwrites-existing'),
 'sdk_method__tools__edit-file':('lisp/ogent-tools.el','ogent-tool--edit-file','edit-raw-1','test/ogent-agent-ergonomics-tests.el','ogent-agent-ergonomics-edit-contract-ambiguous-before-write'),
 'sdk_method__registry__tool-get':('lisp/ogent-models.el','ogent-tool-get','actual-constructor','test/ogent-models-tests.el','ogent-register-tools-forwards-confirm-to-gptel'),
 'sdk_method__registry__tool-spec-get':('lisp/ogent-models.el','ogent-tool-spec-get','registry-spec-alias','test/ogent-agent-ergonomics-tests.el','ogent-agent-ergonomics-tool-names-exact-and-wire-alias'),
 'sdk_method__registry__available-tools':('lisp/ogent-models.el','ogent-tools-enabled-list','enabled-tools-1','test/ogent-agent-ergonomics-tests.el','ogent-agent-ergonomics-tool-names-typo-refuses-with-hint'),
 'sdk_method__execution__wrapper':('lisp/ogent-tool-execution.el','ogent-tool-execution-wrapper','actual-constructor','test/ogent-agent-ergonomics-tests.el','ogent-agent-ergonomics-argument-contract-wrapper-arity'),
 'sdk_method__doctor__run':('lisp/ogent-doctor.el','ogent-doctor-run','doctor-run','test/ogent-doctor-tests.el','ogent-doctor-run-checks-contains-crashes'),
 'sdk_method__doctor__batch':('lisp/ogent-doctor.el','ogent-doctor-batch','doctor-batch-1','test/ogent-agent-ergonomics-tests.el','ogent-agent-ergonomics-doctor-json-severity-and-schema'),
}
rows=[]
for row in current:
    sid=row['surface_id'];scores=dict(row['scores']);scores.update(changes.get(sid,{}));high={}
    notes='Paired baseline independently inspected from exact b3caf930 source; same SDK/CLI criterion and applicability as current scorer B. '
    if sid in method_info:
        path,method,canonical,test_path,test_name=method_info[sid]
        for dim,value in scores.items():
            if value<=700: continue
            if dim=='agent_intuitiveness':high[dim]=rt(canonical,'Canonical native invocation succeeds with the expected baseline interface.')
            elif dim=='agent_ergonomics':high[dim]=rt(canonical,'Canonical SDK operation is one call; registry/wrapper orchestration is internal. No post-pass structured pages are credited.')
            elif dim=='agent_ease_of_use':high[dim]=rt('guide','Embedded baseline handbook provides local SDK examples and discovery pointers.')
            elif dim=='output_parseability':
                if sid=='sdk_method__registry__tool-spec-get':high[dim]=src('lisp/ogent-models.el','(defcustom ogent-tool-registry','Native spec is a documented property list with name/function/argument/effect metadata; not a text reply.')
                elif '__registry__' in sid:high[dim]=rt('actual-constructor','Actual gptel-tool objects expose native name/function accessors, rather than a prose result contract.')
                else:high[dim]=rt('doctor-batch-1' if method=='ogent-doctor-batch' else 'doctor-run','Doctor results are native result plists; JSON batch has versioned check array and severity code.')
            elif dim=='error_pedagogy':
                invalid={'ogent-tool--read-file':'read-invalid','ogent-tool--glob':'glob-invalid','ogent-tool--grep':'grep-invalid',
                         'ogent-tool--bash':'bash-invalid','ogent-tool--write-file':'write-invalid','ogent-tool--edit-file':'edit-ambiguous',
                         'ogent-tools-enabled-list':'registry-enabled-invalid','ogent-doctor-batch':'doctor-batch-invalid'}[method]
                high[dim]=rt(invalid,'Baseline typed corrective error gives the exact valid value/name or unique-context/replace_all alternative; independently observed.')
            elif dim=='intent_inference':high[dim]=rt('registry-enabled-invalid','Configured tool typo gets exact read-file correction; underscore lookup aliases work. This is registry name resolution, not raw function-name recovery.')
            elif dim=='safety_with_recovery':high[dim]=safety(path,'(defun '+method,'metadata lookup, local diagnostics or read/search does not perform irreversible user-data mutation.')
            elif dim=='determinism_and_reproducibility':
                repeated={'ogent-tool--read-file':('read-text-1','read-text-2'),'ogent-tool--glob':('glob-text-1','glob-text-2'),
                          'ogent-tool--grep':('grep-text-1','grep-text-2'),'ogent-tool--bash':('bash-text-1','bash-text-2'),
                          'ogent-tool--write-file':('write-repeat-1','write-repeat-2'),'ogent-tool--edit-file':('edit-raw-1','edit-raw-2'),
                          'ogent-tools-enabled-list':('enabled-tools-1','enabled-tools-2'),
                          'ogent-doctor-run':('doctor-batch-1','doctor-batch-2'),'ogent-doctor-batch':('doctor-batch-1','doctor-batch-2')}
                if method in repeated:
                    a,b=repeated[method];high[dim]=stable(a,b,'Same protected environment/initial bytes yields an identical baseline reply; no future snapshot hash is credited.')
                elif method=='ogent-tool-get':high[dim]=rt('actual-constructor','Actual baseline constructor returns a cached identical tool object for read_file and read-file.')
                else:high[dim]=src(path,'(defun '+method,'Unchanged ordered registry and canonical name deterministically return the same native spec reference.')
            elif dim=='self_documentation':high[dim]=rt('guide','Baseline embedded guide names doctor JSON and its full 0/1/2 severity dictionary; live capabilities expose registered schemas.')
            elif dim=='composability':
                high[dim]=rt(canonical,'Baseline protected NO_COLOR/CI/TERM=dumb SDK run returns ordinary native objects, strings, plists or tagged callbacks; no direct raw SDK prompt.')
            elif dim=='regression_resistance':high[dim]=src(test_path,'(ert-deftest '+test_name,'Baseline test pins this native contract, validation, count/bytes, callback terminal or registry/doctor behavior; no post-pass test is credited.')
        if '__tools__' in sid:
            notes+='Raw intent inference is applicable: direct method aliases/typos fail with void-function in both states; dispatcher aliases earn no private-method credit. '
            if method in ['ogent-tool--bash','ogent-tool--bash-async','ogent-tool--write-file','ogent-tool--edit-file']:
                notes+='Raw mutation safety is applicable and scores zero: direct helpers do not consult approval, provide previews or roll back. Denied wrappers and successful raw writes/edits were paired. '
            else:notes+='Read/search safety is n/a-as-perfect. '
            if method in ['ogent-tool--read-file','ogent-tool--glob','ogent-tool--grep','ogent-tool--bash']:
                notes+='Only the legacy text signature exists in this state; no optional structured format, typed data page or content-addressed snapshot. '
            else:notes+='Source-definition identity with the current method was independently checked; any unchanged criterion retains its current qualitative score. '
        elif method=='ogent-tool-execution-wrapper':
            notes+='Legacy wrapper returns text/Tool error strings; policy gates and edit preview exist, but denied text names no safe review alternative. Snapshot is checked before approval, not afterward. No generic rollback/lease/idempotency. '
        elif '__registry__' in sid:notes+='Safety n/a means lookup/construction only. Unknown get/spec-get returns nil without corrective text; enabled-list supplies its own typed name hint. Actual baseline gptel objects were inspected. '
        else:notes+='Read-only local doctor safety n/a. Method definitions and JSON/severity behavior match current. Only same-environment repeated outputs establish reproducibility; protected bootstrap paths differ across processes. '
    else:
        task=sid.split('__')[-1]
        if task=='help':
            high={
                'agent_intuitiveness':build('make-help','Baseline make help exits zero with target/options/examples menu.'),
                'agent_ease_of_use':build('make-help','Menu contains examples, EMACS selection and live SDK capability/guide/triage pointers; no build JSON mode or NO_COLOR docs.'),
                'safety_with_recovery':safety('Makefile','help:','read-only help output.'),
                'determinism_and_reproducibility':src('Makefile','help:','Fixed echo menu has no timestamps or random IDs.'),
                'self_documentation':build('make-help','Live agent capability/handbook pointer and doctor exit dictionary are in the old menu; build capabilities are absent.'),
                'composability':build('make-help','NO_COLOR/CI/TERM=dumb nonterminal help has plain stdout, empty stderr and zero exit.')}
            notes+='Human help has no JSON payload, but its fixed menu is deterministic. Existing help assertions protect discovery pointers, not the entire menu. Safety n/a read-only.'
        elif task in ['compile','recompile']:
            high['agent_intuitiveness']=build('compile-success-1' if task=='compile' else 'recompile-success','Actual unchanged baseline makem and real Emacs compiler run successfully in an independent tracked fixture.')
            if task=='recompile':high['agent_ergonomics']=build('recompile-success','One target cleans generated bytecode and performs standard compile; failure remains nonzero.')
            high['safety_with_recovery']=safety('Makefile',task+':','the target only creates/removes regenerable bytecode in the isolated fixture; no irreversible user-data operation.')
            notes+='Actual old makem, not a substituted runner, produces human compiler diagnostics on stdout and colored timestamped error logs on stderr despite NO_COLOR/CI/TERM=dumb. Basic process status earns parseability250. Repeated empty successful stdout does not establish general output reproducibility: failure diagnostics vary with wall-clock logs and test timings. No structured process IDs, schema or JSON mode. Known task typo returns generic Invalid rule without correction. Generated-bytecode safety n/a. '
        elif task=='clean':
            high={
                'agent_intuitiveness':build('clean-default','Baseline make clean succeeds and removes generated lisp/test bytecode.'),
                'agent_ergonomics':src('Makefile','clean:','One recursive find removes regenerable bytecode in both source/test trees.'),
                'safety_with_recovery':safety('Makefile','clean:','only generated .elc is removed, preserving .el sources.'),
                'determinism_and_reproducibility':build('clean-default','Fixed plain cleanup message and status have no clocks or random data.'),
                'composability':build('clean-default','Nonterminal cleanup emits one plain line and never prompts; no JSON payload is claimed.'),
                'regression_resistance':src('test/ogent-agent-ergonomics-tests.el','(ert-deftest ogent-agent-ergonomics-make-contract-clean-and-help','Baseline assertions already pin lisp/test bytecode cleanup and help pointers.')}
            notes+='Same stable text/basic process-status parseability250 as current. No gate is needed for regenerable bytecode; safety n/a. The current optional JSON mode routes this message to stderr but creates no clean result schema, so no qualitative score change is inferred.'
        else:
            high={
                'agent_intuitiveness':build('offline-prerequisite-1','Baseline already refuses missing ELPA prerequisite with exact assignment and retry command.'),
                'error_pedagogy':build('offline-prerequisite-1','Empty stdout; stderr names OGENT_ELPA_DIR=/path/to/installed/elpa and make offline-test.'),
                'safety_with_recovery':safety('test/offline/run.sh','fixture_root=$(mktemp -d)','temporary fixtures, loopback transport and cleanup/store guards isolate regenerable test state.'),
                'regression_resistance':src('test/ogent-agent-ergonomics-tests.el','(ert-deftest ogent-agent-ergonomics-offline-contract-missing-dependencies','Baseline assertions already pin data-free preflight error/retry guidance; baseline CI has actual-dependency matrix.')}
            notes+='Same existing isolated fixture and preflight criteria as current; no full shared offline suite was run by this scorer. ERT logs remain human, with timings and no JSON schema. Safety n/a applies to fixture isolation. Initial archive execute-mode omission was corrected and is preserved separately as instrumentation evidence.'
    for dim,value in scores.items():
        assert value%50==0 and 0<=value<=1000
        if value>700:assert dim in high and high[dim].get('file') and high[dim].get('line'),(sid,dim)
    rows.append({'surface_id':sid,'scorer_id':'scorerB','target_sha':sha,'rubric_version':row['rubric_version'],
                 'scores':scores,'evidence':high,'notes':notes})
assert len(rows)==19 and {r['surface_id'] for r in rows}=={r['surface_id'] for r in current}
assert all(r['target_sha']==sha for r in build_rows)
(own/'baseline_paired_scores.jsonl').write_text(''.join(json.dumps(r,sort_keys=True)+'\n' for r in rows))
print('Wrote independent paired baseline rows:',len(rows))
