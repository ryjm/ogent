"""Independent paired baseline judgment under exactly the current scoring criteria."""
import hashlib,json,pathlib
repo=pathlib.Path('/workspace/ogent');ws=repo/'agent_ergonomics_audit'
f=ws/'audit/evidence/pass_3/scorerA';base=f/'baseline_sources'
sha='b3caf9300c7336ef812ed061158f851c5a47ccf7'
dims=['agent_intuitiveness','agent_ergonomics','agent_ease_of_use','output_parseability','error_pedagogy','intent_inference','safety_with_recovery','determinism_and_reproducibility','self_documentation','composability','regression_resistance']
rubric='sha256:'+hashlib.sha256(pathlib.Path('/home/agent/.claude/skills/agent-ergonomics-and-intuitiveness-maximization-for-cli-tools/references/rubric/SCORING-RUBRIC.md').read_bytes()).hexdigest()
sdk=[json.loads(x) for x in (f/'baseline_sdk_runtime.jsonl').read_text().splitlines()]
build=[json.loads(x) for x in (f/'baseline_make_runtime.jsonl').read_text().splitlines()]
def src(path,needle,note):
 n=next(n for n,x in enumerate((base/path).read_text().splitlines(),1) if needle in x)
 return {'file':'audit/evidence/pass_3/scorerA/baseline_sources/'+path,'line':n,'note':note}
def rt(kind,probe,note,**kw):
 data,file={'sdk':(sdk,'baseline_sdk_runtime.jsonl'),'make':(build,'baseline_make_runtime.jsonl')}[kind]
 n=next(n for n,r in enumerate(data,1) if r['probe']==probe);r=data[n-1]
 e={'file':'audit/evidence/pass_3/scorerA/'+file,'line':n,'invocation':r.get('invocation',r.get('argv')),'note':note}
 if kind=='sdk': e.update(outcome=r['outcome'],result_excerpt=r.get('result',r.get('message',''))[:1500])
 else:e.update(exit_code=r['exit_code'],stdout_excerpt=r['stdout'][:2000],stderr_excerpt=r['stderr'][:1200])
 e.update(kw);return e
def ro(path,needle,note='n/a: read-only operation; no irreversible user mutation to gate'):
 e=src(path,needle,note);e['n/a']=True;return e
rows=[]
def add(sid,v,path,needle,note,extra):
 e={d:src(path,needle,'Baseline implementation and docstring of this exact surface; SDK/build applicability explained in notes') for d in dims};e.update(extra)
 rows.append({'surface_id':sid,'scorer_id':'scorerA','rubric_version':rubric,'target_sha':sha,'scores':dict(zip(dims,v)),'evidence':e,'notes':'Same-model qualitative judgment, not agent-success measurements. Independently paired against b3caf930; no historical or other-scorer numerics used. '+note})
raw='SDK positional one-call adaptation is identical to current. Direct method-name aliases are absent: intent applies and is 0. Named API/wrapper policy earns no raw helper credit. '
for name,success,err,regtest in [('read-file','read-text-0','read-invalid','(ert-deftest ogent-agent-ergonomics-read-pagination-next-offset'),('glob','glob-text-0','glob-invalid','(ert-deftest ogent-agent-ergonomics-glob-recursive-and-stable'),('grep','grep-text-0','grep-invalid','(ert-deftest ogent-agent-ergonomics-grep-errors-invalid-regex')]:
 add('sdk_method__tools__'+name,[750,750,650,250,750,0,1000,750,650,500,750], 'lisp/ogent-tools.el','(defun ogent-tool--'+name+' ',raw+'Read-side safety n/a. Native string output is human text, with no structured raw result mode/schema. Stable fixture text is reproducible, but content snapshots are absent. Existing in-tool guide and docstring describe positional calls; no new API documentation is borrowed.',{
  'agent_intuitiveness':rt('sdk',success,'Canonical first positional call succeeds'),
  'agent_ergonomics':rt('sdk',success,'One SDK call returns requested content/discovery/search slices; same one-call adaptation as current'),
  'error_pedagogy':rt('sdk',err,'Typed user-error names exact valid offset/pattern recovery'),
  'safety_with_recovery':ro('lisp/ogent-tools.el','(defun ogent-tool--'+name+' '),
  'determinism_and_reproducibility':rt('sdk',success,'Two consecutive unchanged-input calls return identical text bytes',repeat_probe=success.replace('-0','-1')),
  'regression_resistance':src('test/ogent-agent-ergonomics-tests.el',regtest,'Baseline already pins canonical legacy output/errors; supplementary ogent-tools-tests covers boundary/empty/mtime/count cases')})
for name,probe,v in [('grep-async','grep-async',[750,750,650,500,650,0,1000,500,500,750,700]),('bash-async','bash-async',[750,750,650,500,650,0,0,250,500,750,700])]:
 add('sdk_method__tools__'+name,v,'lisp/ogent-tools.el','(defun ogent-tool--'+name+' ',raw+'Method definition is exactly equal to current (source_identity.jsonl). Legacy event string/integer callbacks get their own standard-type composability credit; neither baseline nor current receives new terminal-envelope credit. '+('Read-side safety n/a; event strings are not typed error variants.' if name=='grep-async' else 'Safety applies and is 0: raw shell spawn has no approval/review. Random public process names and asynchronous channel interleaving prevent byte determinism.'),{
  'agent_intuitiveness':rt('sdk',probe,'Canonical actual async call returns both matches/channels and one done event'),
  'agent_ergonomics':rt('sdk',probe,'One process registration supplies streaming slices and terminal count/status'),
  'safety_with_recovery':ro('lisp/ogent-tools.el','(defun ogent-tool--'+name+' ') if name=='grep-async' else src('lisp/ogent-tools.el','(defun ogent-tool--bash-async ','Applicable mutator spawns immediately without a helper gate'),
  'composability':rt('sdk',probe,'Native process and standard callback symbols/strings/integers compose; real non-TTY NO_COLOR CI TERM=dumb probe has no prompts')})
add('sdk_method__tools__bash',[750,750,650,250,750,0,0,500,650,500,750],'lisp/ogent-tools.el','(defun ogent-tool--bash ',raw+'Safety applies and is 0: raw shell executes immediately. Human result merges channel sections and terminal exit as prose, with no native result object/JSON selector. Arbitrary command behavior limits reproducibility; no rollback/idempotency exists.',{
 'agent_intuitiveness':rt('sdk','bash-text-0','Canonical shell command succeeds as a call while retaining stdout, stderr and child exit7'),
 'agent_ergonomics':rt('sdk','bash-text-0','One SDK call returns both human channel sections and exit marker'),
 'error_pedagogy':rt('sdk','bash-invalid','Typed timeout user-error gives exact timeout=120 correction'),
 'safety_with_recovery':src('lisp/ogent-tools.el','(defun ogent-tool--bash ','Applicable raw mutator directly spawns command without approval/review'),
 'regression_resistance':src('test/ogent-agent-ergonomics-tests.el','(ert-deftest ogent-agent-ergonomics-bash-contract-exit-survives-truncation','Baseline already pins terminal status after truncated text, timeout validation and async chunk boundaries')})
for name,probe,err,v in [('write-file','write-raw-denied-policy','write-invalid',[750,750,250,250,750,0,0,650,500,500,650]),('edit-file','edit-raw','edit-ambiguous',[750,750,250,250,750,0,0,650,500,500,750])]:
 add('sdk_method__tools__'+name,v,'lisp/ogent-tools.el','(defun ogent-tool--'+name+' ',raw+'Exact method form is unchanged (source_identity.jsonl). Safety applies and is 0: direct mutation writes bytes under policy that refused the wrapper. Input validation earns error/correctness credit, not approval. Return remains human prose; no native typed result, preview, undo, rollback or idempotency.',{
  'agent_intuitiveness':rt('sdk',probe,'Canonical raw write/edit succeeds and names target/count'),
  'agent_ergonomics':rt('sdk',probe,'Canonical mutation is one positional SDK call; read-before-edit control remains caller-owned'),
  'error_pedagogy':rt('sdk',err,'Typed user-error teaches exact text/unique-context/replace_all correction'),
  'safety_with_recovery':rt('sdk','write-raw-denied-policy','Raw write executes under denied wrapper policy; paired wrapper-denied evidence is adjacent'),
  **({'regression_resistance':src('test/ogent-agent-ergonomics-tests.el','(ert-deftest ogent-agent-ergonomics-edit-contract-ambiguous-before-write','Baseline already asserts ambiguous edits leave bytes unchanged and false sentinels; exact-case/review tests also present')} if name=='edit-file' else {})})
for name,method,probe,v in [('tool-get','ogent-tool-get','get-wire-0',[750,750,250,750,250,250,1000,700,500,750,700]),('tool-spec-get','ogent-tool-spec-get','spec-wire-0',[750,750,500,750,250,250,1000,750,750,800,750]),('available-tools','ogent-tools-enabled-list','enabled-0',[750,750,500,750,750,750,1000,700,500,750,700])]:
 e={'agent_intuitiveness':rt('sdk',probe,'Canonical lookup/list returns real gptel object or live metadata'),
    'agent_ergonomics':rt('sdk',probe,'One SDK call registers/filters or retrieves complete spec'),
    'output_parseability':rt('sdk',probe,'Native gptel struct/list or named-key plist is consumed through standard accessors; no human-result parsing'),
    'safety_with_recovery':ro('lisp/ogent-models.el','(defun '+method+' '),
    'composability':rt('sdk',probe,'Real gptel definitions loaded without provider calls; native SDK values compose in non-TTY NO_COLOR/CI/TERM=dumb')}
 if name=='tool-spec-get':e.update(determinism_and_reproducibility=rt('sdk',probe,'Repeated live spec lookup yields identical named-key plist',repeat_probe='spec-wire-1'),self_documentation=rt('sdk',probe,'Endpoint itself exposes live argument names/types/optionalness, descriptions, category/effects'),regression_resistance=src('test/ogent-agent-ergonomics-tests.el','(ert-deftest ogent-agent-ergonomics-tool-names-exact-and-wire-alias','Baseline already pins exact custom names and underscore alias identity'))
 if name=='available-tools':e.update(error_pedagogy=rt('sdk','enabled-typo','Typed error names read-file exact correction and live capabilities form'),intent_inference=rt('sdk','enabled-typo','Actual edit-distance1 read-fiel hint; wire spelling accepted through ensure'))
 add('sdk_method__registry__'+name,v,'lisp/ogent-models.el','(defun '+method+' ','Method form is unchanged (source_identity.jsonl), but baseline live metadata lacks new semantic aliases/examples/structured functions. Read-side safety n/a. Wire underscore aliases work (250 intent for bare lookups); common cat alias is actually nil, and bare typo lookup returns nil without teaching. Listing owns its ensure-path exact typo hint, so intent750 is already earned. Cache history determines object/list order.',e)
add('sdk_method__execution__wrapper',[750,650,500,250,650,0,650,500,650,500,750],'lisp/ogent-tool-execution.el','(defun ogent-tool-execution-wrapper ','Applicable policy owner gates mutations, routes edits to review and checks stale specs. It has no own dry-run/rollback/locks/idempotency, so safety650 rather than perfect. Baseline denial/error/success results are opaque human strings; named dispatch credit is excluded. gptel callback-first/approval can prompt and needs deliberate composition.',{
 'agent_intuitiveness':rt('sdk','wrapper-denied','First canonical wrapper invocation returns explicit denial rather than mutating'),
 'safety_with_recovery':rt('sdk','wrapper-denied','Applicable owner enforces denied write policy; raw helper is deliberately scored separately'),
 'regression_resistance':src('test/ogent-agent-ergonomics-tests.el','(ert-deftest ogent-agent-ergonomics-argument-contract-wrapper-arity','Already pins validation before policy/execution and async failure callback once; registry stale handling has source tests')})
for name,method,v in [('run','ogent-doctor-run',[750,750,500,750,750,0,1000,750,500,750,750]),('batch','ogent-doctor-batch',[750,750,750,800,750,0,1000,750,750,800,750])]:
 e={'agent_intuitiveness':rt('sdk','doctor-run' if name=='run' else 'doctor-json-0','First canonical local check call returns actionable statuses or complete JSON'),
 'agent_ergonomics':rt('sdk','doctor-run','One SDK call aggregates dependency/configuration/store/readiness checks and remediations'),
 'output_parseability':rt('sdk','doctor-run' if name=='run' else 'doctor-json-0','Native check plists or existing contract_version1 JSON preserve named status/detail/remediation; JSON is only stdout data'),
 'error_pedagogy':rt('sdk','doctor-run' if name=='run' else 'doctor-batch-invalid','Check remediations or exact (ogent-doctor-batch nil (quote json)) format recovery are already present'),
 'safety_with_recovery':ro('lisp/ogent-doctor.el','(defun '+method+' ','n/a: default doctor reads only; network checks require opt-in'),
 'determinism_and_reproducibility':rt('sdk','doctor-json-0','Consecutive reports byte-identical under unchanged fixture environment',repeat_probe='doctor-json-1'),
 'composability':rt('sdk','doctor-json-0','Existing valid JSON/std types, severity0/1/2 and no prompt/ANSI in NO_COLOR CI TERM=dumb non-TTY runtime'),
 'regression_resistance':src('test/ogent-agent-ergonomics-tests.el','(ert-deftest ogent-agent-ergonomics-doctor-json-severity-and-schema','Baseline already pins version/status/check array/severity dictionary and invalid-format refusal')}
 if name=='batch':e.update(agent_ease_of_use=src('lisp/ogent-agent.el','"Batch health:','Existing in-tool guide publishes exact invocation and 0/1/2 dictionary'),self_documentation=src('lisp/ogent-agent.el',':doctor_exit_codes (list :ok 0 :warning 1 :error 2)','Existing capabilities publishes full severity dictionary and guide exact form'))
 add('sdk_method__doctor__'+name,v,'lisp/ogent-doctor.el','(defun '+method+' ','Exact method form unchanged (source_identity.jsonl); same scores reflect baseline already having typed native checks, actionable remediations, and versioned JSON doctor reports. Safety n/a for default local read-only diagnosis; probe does not enable network.',e)
add('verb__make__help',[900,750,750,250,500,0,1000,800,750,750,650],'Makefile','help:','Read-side safety n/a. Build-wrapper adaptation assigns human help/basic process status parseability250. Existing help already has targets, variables, examples and live SDK discovery pointers; new build JSON/capabilities flag and NO_COLOR documentation are absent.',{
 'agent_intuitiveness':rt('make','help-1','Bare help first try succeeds and prints targets plus exact next-step SDK examples'),
 'agent_ergonomics':rt('make','help-1','One call combines target/option/example/discovery slices'),
 'agent_ease_of_use':rt('make','help-1','Existing help lists EMACS/dependency environment hints/examples and SDK agent discovery pointer'),
 'safety_with_recovery':ro('Makefile','help:'),
 'determinism_and_reproducibility':rt('make','help-1','Repeated human help is byte-identical, status0',repeat_probe='help-2'),
 'self_documentation':rt('make','help-1','Help points to existing live SDK capabilities; no baseline machine build schema is invented'),
 'composability':rt('make','help-1','Plain stdout, empty stderr, no prompts under NO_COLOR CI TERM=dumb non-TTY')})
for name,probe,fail,erg in [('compile','compile-human-1','compile-human-failure',500),('recompile','recompile-human','recompile-human-failure',750)]:
 add('verb__make__'+name,[750,erg,500,250,650,0,1000,250,500,250,650],'Makefile',name+':','Safety n/a: only regenerable bytecode is created/removed in independent tracked fixture, never shared-project sources. Actual archived helper runs real Emacs. There is no --json support (runtime baseline-json-unavailable). Compile succeeds silently; failure streams human compiler diagnostics and timestamped ANSI logs despite NO_COLOR/CI/TERM=dumb. Basic process-status contract earns build-wrapper parseability250. Determinism250 applies to real timestamped diagnostic logs, not invented JSON PID fields. '+('Existing cleanup+compile macro earns750 ergonomics.' if name=='recompile' else 'Single compile operation has no machine report collecting task/command/diagnostic slices.'),{
 'agent_intuitiveness':rt('make',probe,'First actual compile/recompile invocation succeeds with generated bytecode'),
 'agent_ergonomics':rt('make',probe,'Actual cleanup plus compiler run in one Make call' if name=='recompile' else 'Single operation compiles discovered tracked source; no aggregate report'),
 'error_pedagogy':rt('make',fail,'Actual compiler names broken fixture path and End of file during parsing; no typed corrective rerun/report'),
 'safety_with_recovery':ro('Makefile',name+':','n/a: compilation and clean touch only regenerable bytecode; independent fixture isolates project'),
 'determinism_and_reproducibility':rt('make',fail,'Baseline actual human diagnostic timestamps vary; does not contain any machine JSON/PID report'),
 'composability':rt('make',fail,'Actual failure ignores NO_COLOR=1 CI=true TERM=dumb: ANSI diagnostic logger on stderr, compiler text on stdout, Make status2 preserved')})
add('verb__make__clean',[750,500,500,250,250,0,1000,750,500,750,650],'Makefile','clean:','Safety n/a: scoped regenerable lisp/test .elc deletion only. Same human line/process-status adaptation250 as current. Source recipe continues unchanged in effect; no JSON clean schema/rollback uplift is credited.',{
 'agent_intuitiveness':rt('make','clean-human-1','Canonical clean succeeds, removes only fixture bytecode and prints stable line'),
 'safety_with_recovery':ro('Makefile','clean:','n/a: find lisp/ test/ -name *.elc deletes regenerable bytecode only'),
 'determinism_and_reproducibility':rt('make','clean-human-1','Repeated clean prints identical line/status0',repeat_probe='clean-human-2'),
 'composability':rt('make','clean-human-1','Plain stdout, empty stderr, status0, no prompts under NO_COLOR CI TERM=dumb')})
add('verb__make__offline-test',[750,500,500,250,750,0,1000,250,500,650,750],'Makefile','offline-test:','Safety n/a: own temporary fixture roots and guarded local transport; regenerated bytecode/fixtures isolated. Same criteria/current scores. Actual runtime covers prerequisite refusal only; broad baseline real dependency tests/CI are inspected configuration/test evidence, not newly executed here. ERT output/timing has no JSON schema or deterministic bytes.',{
 'agent_intuitiveness':rt('make','offline-prerequisite','First absent dependency receives exact environment assignment/retry'),
 'error_pedagogy':rt('make','offline-prerequisite','Exact OGENT_ELPA_DIR=/path/to/installed/elpa then make offline-test teaching'),
 'safety_with_recovery':ro('test/offline/run.sh','fixture_root=$(mktemp -d)','n/a: own temporary fixture root, cleanup trap and guarded local transport isolate user stores'),
 'regression_resistance':src('test/offline/workflows.el.in','(ert-deftest ogent-offline-tool-cycle-policy-and-ledger','Baseline already has real dependency transport/tool/edit/async/ledger/adapter workflow assertions; baseline CI matrix is archived alongside')})
ids=[json.loads(x)['surface_id'] for x in (ws/'audit/surface_inventory.jsonl').read_text().splitlines()];by={r['surface_id']:r for r in rows};assert set(ids)==set(by)
(f/'baseline_paired_scores.jsonl').write_text(''.join(json.dumps(by[x],ensure_ascii=False,sort_keys=True)+'\n' for x in ids))
print('Wrote',len(rows),'independent paired baseline rows')
