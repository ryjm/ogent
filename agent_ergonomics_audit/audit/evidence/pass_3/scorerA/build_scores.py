"""Materialize independent qualitative scores; numeric judgment is intentionally explicit."""
import hashlib,json,pathlib,re,subprocess
repo=pathlib.Path('/workspace/ogent'); workspace=repo/'agent_ergonomics_audit'
folder=workspace/'audit/evidence/pass_3/scorerA'
rubric='sha256:'+hashlib.sha256(pathlib.Path('/home/agent/.claude/skills/agent-ergonomics-and-intuitiveness-maximization-for-cli-tools/references/rubric/SCORING-RUBRIC.md').read_bytes()).hexdigest()
sha=subprocess.check_output(['git','-C',str(repo),'rev-parse','HEAD'],text=True).strip()
provenance=json.loads((folder/'current_runtime_provenance.json').read_text())
assert sha==provenance['target_sha'],'Refusing source citations without matching current runtime freeze'
for file,expected in provenance['source_sha256'].items():
 assert hashlib.sha256((repo/file).read_bytes()).hexdigest()==expected,'Source changed after runtime: '+file

dims=['agent_intuitiveness','agent_ergonomics','agent_ease_of_use','output_parseability','error_pedagogy','intent_inference','safety_with_recovery','determinism_and_reproducibility','self_documentation','composability','regression_resistance']
sdk=[json.loads(line) for line in (folder/'sdk_runtime.jsonl').read_text().splitlines()]
reg=[json.loads(line) for line in (folder/'registry_runtime.jsonl').read_text().splitlines()]
build=[json.loads(line) for line in (folder/'make_runtime.jsonl').read_text().splitlines()]
ledger=[json.loads(line) for line in (folder/'ledger_runtime.jsonl').read_text().splitlines()]
def source(path,needle,note):
 lines=(repo/path).read_text().splitlines()
 line=next(i for i,text in enumerate(lines,1) if needle in text)
 return {'file':'../'+path,'line':line,'note':note}
def runtime(kind,probe,note,**extra):
 data,filename={'sdk':(sdk,'sdk_runtime.jsonl'),'registry':(reg,'registry_runtime.jsonl'),'make':(build,'make_runtime.jsonl'),'ledger':(ledger,'ledger_runtime.jsonl')}[kind]
 n=next(i for i,r in enumerate(data,1) if r['probe']==probe);r=data[n-1]
 evidence={'file':'audit/evidence/pass_3/scorerA/'+filename,'line':n,'invocation':r.get('invocation',r.get('argv')),'note':note}
 if kind=='make': evidence.update(exit_code=r['exit_code'],stdout_excerpt=r['stdout'][:1600],stderr_excerpt=r['stderr'][:1000])
 else:
  evidence['outcome']=r['outcome'];evidence['result_excerpt']=r.get('result',r.get('message',''))[:1600]
 evidence.update(extra);return evidence
def readonly(path,needle,note='n/a: read-only surface; no irreversible user operation to gate'):
 e=source(path,needle,note);e['n/a']=True;return e
rows=[]
def add(sid,values,path,needle,note,overrides=None):
 evidence={d:source(path,needle,'Current implementation of the scored surface; see notes for SDK/build applicability') for d in dims}
 if overrides:evidence.update(overrides)
 rows.append({'surface_id':sid,'scorer_id':'scorerA','rubric_version':rubric,'target_sha':sha,
              'scores':dict(zip(dims,values)),'evidence':evidence,
              'notes':'Same-model qualitative judgment, not agent-success measurements. '+note})
# The positional helpers receive only behavior they own. All method-name intent
# scores here are applicable: named-dispatch aliases do not add Lisp defaliases.
common_raw='Positional SDK adaptation: one-call operations earn ergonomics credit; native plist/JSON is optional. Direct method-name aliases/recovery are absent (intent applicable, scored 0); named-dispatch improvements are not credited. '
add('sdk_method__tools__read-file',[750,750,650,700,750,0,1000,850,650,750,750],
 'lisp/ogent-tools.el','(defun ogent-tool--read-file ',common_raw+'Safety n/a for a file read. Structured data is unversioned at this raw boundary; content snapshots and precise continuation positions are real. No perfect determinism or complete method documentation claim.',{
 'agent_intuitiveness':runtime('sdk','read-text-1','Canonical positional read succeeds and prints the exact next offset'),
 'agent_ergonomics':runtime('sdk','read-json-1','One call returns lines, content, counts, snapshot and continuation positions; SDK one-liner adaptation'),
 'error_pedagogy':runtime('sdk','read-invalid','Typed user-error names offset=1 as the exact correction'),
 'intent_inference':runtime('sdk','ogent-tool--read-fiel','Direct misspelling yields void-function; no recovery'),
 'safety_with_recovery':readonly('lisp/ogent-tools.el','(defun ogent-tool--read-file '),
 'determinism_and_reproducibility':runtime('sdk','read-json-1','Rows read-json-1/read-json-2 are byte-identical; SHA256 content snapshot',repeat_probe='read-json-2'),
 'composability':runtime('sdk','read-json-1','NO_COLOR=1 CI=true TERM=dumb non-TTY Emacs; native data or valid JSON returned without prompts; loader diagnostics are stderr'),
 'regression_resistance':source('test/ogent-agent-execution-tests.el','(ert-deftest ogent-agent-execution-read-structured-pages','Assertions pin line array, exact contents and raw JSON response; long-line continuation assertions also cover positions')})
add('sdk_method__tools__glob',[750,750,650,700,750,0,1000,800,650,750,750],
 'lisp/ogent-tools.el','(defun ogent-tool--glob ',common_raw+'Safety n/a for discovery. Structured mode sorts by path and snapshots metadata; legacy mode stays human text and sorts by file mtime. Snapshot identity includes file metadata, so cross-machine/content-only reproducibility is not claimed.',{
 'agent_intuitiveness':runtime('sdk','glob-json-1','Canonical glob succeeds in one call'),
 'agent_ergonomics':runtime('sdk','glob-json-1','SDK one-call result combines file records, total, snapshot and page bounds'),
 'error_pedagogy':runtime('sdk','glob-invalid','Typed user-error gives exact non-empty example **/*.el'),
 'safety_with_recovery':readonly('lisp/ogent-tools.el','(defun ogent-tool--glob '),
 'determinism_and_reproducibility':runtime('sdk','glob-json-1','Rows glob-json-1/glob-json-2 are byte-identical for unchanged file metadata',repeat_probe='glob-json-2'),
 'composability':runtime('sdk','glob-json-1','Explicit JSON/native SDK format composes without parsing newline-separated filenames; non-TTY probe returns no prompts'),
 'regression_resistance':source('test/ogent-agent-execution-tests.el','(ert-deftest ogent-agent-execution-glob-json-empty-and-weird-paths','Pins raw JSON path containing a newline and empty arrays; complete pagination also asserted')})
add('sdk_method__tools__grep',[750,750,650,700,750,0,1000,800,650,750,750],
 'lisp/ogent-tools.el','(defun ogent-tool--grep ',common_raw+'Safety n/a for search. Structured results retain file/line/context/count/snapshot and search-engine provenance. Raw text output remains optional and own result has no contract_version envelope.',{
 'agent_intuitiveness':runtime('sdk','grep-text','Canonical positional grep returns both matched lines and count'),
 'agent_ergonomics':runtime('sdk','grep-json-1','One SDK call returns all result metadata and pagination slices'),
 'error_pedagogy':runtime('sdk','grep-invalid','Invalid regex is a user-error with real diagnostic and exact valid-pattern example'),
 'safety_with_recovery':readonly('lisp/ogent-tools.el','(defun ogent-tool--grep '),
 'determinism_and_reproducibility':runtime('sdk','grep-json-1','Repeated structured grep is byte-identical, sorted and hashed; GNU fallback actually exercised',repeat_probe='grep-json-2'),
 'composability':runtime('sdk','grep-json-1','Non-TTY structured return uses standard plists/JSON and no prompts; engine is explicit'),
 'regression_resistance':source('test/ogent-agent-execution-tests.el','(ert-deftest ogent-agent-execution-process-grep-integration','Pins raw plist matches and named pagination; backend semantics/order/odd filenames pinned in test/ogent-tool-process-tests.el')})
add('sdk_method__tools__grep-async',[750,750,650,500,650,0,1000,500,500,750,700],
 'lisp/ogent-tools.el','(defun ogent-tool--grep-async ',common_raw+'Safety n/a for search. This specific legacy method still emits match strings and done counts, not the new terminal data envelope. Process/callback standard types compose, but errors remain event strings and cross-engine/chunk determinism is not asserted.',{
 'agent_intuitiveness':runtime('sdk','grep-async','First canonical async search produces two match events and one done count'),
 'agent_ergonomics':runtime('sdk','grep-async','One callback registration starts search and delivers matches plus terminal count'),
 'safety_with_recovery':readonly('lisp/ogent-tools.el','(defun ogent-tool--grep-async '),
 'composability':runtime('sdk','grep-async','Returns native Emacs process; callback events carry standard symbols/string/integer types under non-TTY without prompts')})
add('sdk_method__tools__bash',[750,750,650,700,750,0,0,500,650,750,750],
 'lisp/ogent-tools.el','(defun ogent-tool--bash ',common_raw+'Safety applies: raw shell command executes immediately with no helper approval, preview, rollback or idempotency key. Validation and cancellation do not supply a mutation gate. Arbitrary command output prevents a general byte-determinism claim.',{
 'agent_intuitiveness':runtime('sdk','bash-json-1','Canonical shell call returns separated stdout/stderr and exit 7 rather than losing process status'),
 'agent_ergonomics':runtime('sdk','bash-json-1','One SDK call returns both channels, terminal exit and timeout/cancel/truncation flags'),
 'error_pedagogy':runtime('sdk','bash-invalid','Typed timeout validation names timeout=120 as exact recovery'),
 'safety_with_recovery':source('lisp/ogent-tools.el','(defun ogent-tool--bash ','Applicable raw mutator directly delegates/spawns command with no policy check'),
 'composability':runtime('sdk','bash-json-1','Explicit structured mode returns standard native data/JSON; child channels are separated and no query prompt occurs'),
 'regression_resistance':source('test/ogent-tool-process-tests.el','(ert-deftest ogent-tool-process-bash-separates-channels-and-exit','Actual structured backend pins channels, exit, partial output, cancellation and JSON-safe invalid UTF8; raw delegation is explicit')})
add('sdk_method__tools__bash-async',[750,750,650,500,650,0,0,250,500,750,700],
 'lisp/ogent-tools.el','(defun ogent-tool--bash-async ',common_raw+'Safety applies: this raw mutator spawns the command with no gate. Legacy callbacks expose strings/integer exits; no structured terminal envelope is credited. Public process name is random and stdout/stderr event interleaving can differ; named async fixes are scored separately.',{
 'agent_intuitiveness':runtime('sdk','bash-async','Canonical async command returns both channels and done 7'),
 'agent_ergonomics':runtime('sdk','bash-async','One process registration delivers output channels and exit status'),
 'safety_with_recovery':source('lisp/ogent-tools.el','(defun ogent-tool--bash-async ','Applicable mutator: direct spawn after scalar validation, without policy ownership'),
 'determinism_and_reproducibility':source('lisp/ogent-tools.el','(proc-name (format "ogent-bash-%d" (random 100000)))','Raw process handle name is explicitly random; event order is asynchronous'),
 'composability':runtime('sdk','bash-async','Native process and callback events compose; noquery prevents process-exit prompt, and channels remain separate')})
add('sdk_method__tools__write-file',[750,750,250,250,750,0,0,650,500,500,650],
 'lisp/ogent-tools.el','(defun ogent-tool--write-file ',common_raw+'Safety applies and is 0: valid direct call overwrites under the same policy that denied the wrapper. Return value remains human prose; docstring is a one-line overwrite description. Input validation protects malformed calls but does not implement approval or rollback.',{
 'agent_intuitiveness':runtime('sdk','write-raw-denied-policy','Canonical raw call writes fixture content and names path/count'),
 'agent_ergonomics':runtime('sdk','write-raw-denied-policy','Write and parent-directory creation are one positional SDK call'),
 'error_pedagogy':runtime('sdk','write-invalid','Typed error names content and permits text or empty string'),
 'safety_with_recovery':runtime('sdk','write-raw-denied-policy','Raw call writes immediately; preceding wrapper-denied probe records policy denial for the same write')})
add('sdk_method__tools__edit-file',[750,750,250,250,750,0,0,650,500,500,750],
 'lisp/ogent-tools.el','(defun ogent-tool--edit-file ',common_raw+'Safety applies and is 0: valid direct call writes immediately, with no preview/approval/rollback owner. Ambiguity/type validation earns teaching and correctness credit only. Existing docstring still says non-nil replace_all despite explicit sentinel normalization; output remains prose.',{
 'agent_intuitiveness':runtime('sdk','edit-raw','Canonical unique-context edit succeeds and reports count/path'),
 'agent_ergonomics':runtime('sdk','edit-raw','A direct edit is one call after the required source read'),
 'error_pedagogy':runtime('sdk','edit-ambiguous','Typed user-error includes path, occurrence count and exact unique-context/replace_all true recovery'),
 'intent_inference':runtime('sdk','ogent-tool--edit-fiel','Direct name typo remains generic void-function'),
 'safety_with_recovery':source('lisp/ogent-tools.el','(with-temp-file path','This raw file helper writes directly after validation; its own function contains no review/approval owner'),
 'regression_resistance':source('test/ogent-agent-ergonomics-tests.el','(ert-deftest ogent-agent-ergonomics-edit-contract-ambiguous-before-write','Pins exact recovery phrase and unchanged bytes for false sentinels; exact-case and UI failures are separately asserted')})
add('sdk_method__registry__tool-get',[750,750,250,750,250,500,1000,700,500,750,700],
 'lisp/ogent-models.el','(defun ogent-tool-get ','Read-side safety n/a: cache construction is regenerable metadata, not irreversible user data. One call returns a real gptel struct. Registered aliases resolve, while unknown/typo lookup returns documented nil without recovery; no wrapper teaching is borrowed. Cache order/object construction varies with registry history, so no high determinism claim.',{
 'agent_intuitiveness':runtime('registry','get-alias-0','Real cached gptel implementation loaded without provider calls; cat resolves to read-file'),
 'agent_ergonomics':runtime('registry','get-alias-0','Registration and lookup collapse into one SDK call'),
 'output_parseability':source('lisp/ogent-models.el','(defun ogent-tool-get ','Returns native gptel object or nil, directly usable through gptel struct accessors; no string parsing'),
 'safety_with_recovery':readonly('lisp/ogent-models.el','(defun ogent-tool-get '),
 'composability':runtime('registry','get-alias-0','Real result composes directly with gptel-tool-name; no prompt or provider call')})
add('sdk_method__registry__tool-spec-get',[750,750,500,750,250,500,1000,750,750,800,750],
 'lisp/ogent-models.el','(defun ogent-tool-spec-get ','Read-side safety n/a. Native metadata plist is directly inspectable and includes arguments, effects, example args and structured result functions. Registered aliases work; typo lookup intentionally returns nil and gets no diagnostic credit. No perfect versioned schema or typo inference claim.',{
 'agent_intuitiveness':runtime('registry','spec-alias-0','Canonical/alias spec lookup succeeds without tool execution'),
 'agent_ergonomics':runtime('registry','spec-alias-0','One call returns complete live spec rather than requiring construction'),
 'output_parseability':runtime('registry','spec-alias-0','Native plist with stable named argument/effect fields; SDK structured-return adaptation'),
 'safety_with_recovery':readonly('lisp/ogent-models.el','(defun ogent-tool-spec-get '),
 'determinism_and_reproducibility':runtime('registry','spec-alias-0','Repeated spec-alias-0/spec-alias-1 are byte-identical under unchanged live registry',repeat_probe='spec-alias-1'),
 'self_documentation':runtime('registry','spec-alias-0','This method itself returns live names, descriptions, args/types, effect metadata and examples'),
 'composability':runtime('registry','spec-alias-0','Native plist can be consumed with plist-get/seq without subprocesses or text parsing'),
 'regression_resistance':source('test/ogent-agent-ergonomics-tests.el','(ert-deftest ogent-agent-ergonomics-tool-names-exact-and-wire-alias','Exact-name versus underscore-alias identity asserted; live discovery tests assert call-shape metadata')})
add('sdk_method__registry__available-tools',[750,750,500,750,750,750,1000,700,500,750,700],
 'lisp/ogent-models.el','(defun ogent-tools-enabled-list ','Read-side safety n/a: enabled tool-object listing only. One native list is returned; exact/underscore/common tool aliases are resolved via ensure. Misspelled selected tool gets precise corrective error owned by this call path. List order follows registry/cache history; no sort/hash claim.',{
 'agent_intuitiveness':runtime('registry','enabled-0','Real gptel-backed listing returns all six installed tools'),
 'agent_ergonomics':runtime('registry','enabled-0','Registration plus enabled filtering occur in one SDK call'),
 'output_parseability':runtime('registry','enabled-0','Returns a native list of gptel structs; probe consumes it with standard mapcar/accessor'),
 'error_pedagogy':runtime('registry','enabled-typo','Typed error names exact read-file correction and capabilities recovery'),
 'intent_inference':runtime('registry','enabled-typo','Selected read-fiel receives did you mean read-file rather than silently disappearing'),
 'safety_with_recovery':readonly('lisp/ogent-models.el','(defun ogent-tools-enabled-list '),
 'composability':runtime('registry','enabled-0','Actual tool objects compose with gptel accessors/mapcar; no prompts')})
add('sdk_method__execution__wrapper',[750,650,500,750,750,0,650,500,650,500,750],
 'lisp/ogent-tool-execution.el','(defun ogent-tool-execution-wrapper ','Safety applicable: wrapper really owns approval, edit review, stale-spec checks and ledger, but general dry-run/rollback/locks are absent. Native method-name alias recovery is absent. Explicit json gets a versioned envelope; text remains default. gptel execution path can prompt through its interactive policy owner, so composability is capped despite the named API no-prompt behavior.',{
 'agent_intuitiveness':runtime('sdk','wrapper-denied','Canonical wrapper invocation returns an explicit denied terminal result'),
 'output_parseability':runtime('sdk','wrapper-denied','Explicit JSON returns contract_version/tool/status/data/error/next matching exported envelope schema'),
 'error_pedagogy':runtime('ledger','actual-ledger-failure-wrapper','Actual completed result is retained with a visible ledger warning naming writable ogent-ledger-file and Do not rerun; no helper was stubbed'),
 'regression_resistance':source('test/ogent-agent-execution-tests.el','(ert-deftest ogent-agent-execution-model-stale-after-approval','Both formats pin refusal of registry changes during approval; callback-first exactly-once and JSON-page shape tested')})
add('sdk_method__doctor__run',[750,750,500,750,750,0,1000,750,500,750,750],
 'lisp/ogent-doctor.el','(defun ogent-doctor-run ','Read-side safety n/a for default local probes; opt-in network probes remain opt-in. SDK one-call diagnosis returns check metadata/status/detail/remediation plists and contains individual probe failures. Introspection/docs are basic at this native method; no alias recovery. Determinism is for unchanged observed setup, not a promise that live health never changes.',{
 'agent_intuitiveness':runtime('sdk','doctor-run','Bare SDK invocation returns all local check status/remediation entries'),
 'agent_ergonomics':runtime('sdk','doctor-run','One call aggregates environment, registry, auth-presence and store health with remediations; no provider request'),
 'output_parseability':source('lisp/ogent-doctor.el','(defun ogent-doctor--run-checks ','Native list of result plists has id/label/category/status/detail/remediation; individual crashes become result rows'),
 'error_pedagogy':runtime('sdk','doctor-run','Actual failed checks name concrete upgrade/configuration/install recoveries'),
 'safety_with_recovery':readonly('lisp/ogent-doctor.el','(defun ogent-doctor-run ','n/a: default checks are read-only and omit opt-in network operations'),
 'determinism_and_reproducibility':runtime('sdk','doctor-json-1','Two successive reports built from doctor-run are byte-identical for the unchanged local setup',repeat_probe='doctor-json-2'),
 'composability':source('lisp/ogent-doctor.el','(defun ogent-doctor--run-checks ','Native result plists contain errors instead of aborting composition; no prompts in default run'),
 'regression_resistance':source('test/ogent-doctor-tests.el','(ert-deftest ogent-doctor-full-run-matches-golden','Golden complete native run plus malformed/crashing check isolation and opt-in omission tests')})
add('sdk_method__doctor__batch',[750,750,750,800,750,0,1000,750,750,800,750],
 'lisp/ogent-doctor.el','(defun ogent-doctor-batch ','Read-side safety n/a for default probes. The function prints JSON on explicit format and returns severity; callers must wire it through kill-emacs as documented. Stable local report is verified twice. SDK adaptation treats docstring/example and agent capabilities exit dictionary as in-tool discovery; no method aliases or automatic shell exit claim.',{
 'agent_intuitiveness':runtime('sdk','doctor-json-1','Canonical JSON invocation produces full versioned checks report'),
 'agent_ergonomics':runtime('sdk','doctor-json-1','One call returns diagnostics plus summary severity and structured check remediations'),
 'agent_ease_of_use':source('lisp/ogent-doctor.el','(defun ogent-doctor-batch ','Docstring gives format example, network opt-in, exact 0/1/2 dictionary and kill-emacs integration'),
 'output_parseability':runtime('sdk','doctor-json-1','One data-only versioned JSON report; exit_code is explicit; actual loader diagnostics remain stderr'),
 'error_pedagogy':runtime('sdk','doctor-batch-invalid','Invalid format names exact (ogent-doctor-batch nil (quote json)) correction'),
 'safety_with_recovery':readonly('lisp/ogent-doctor.el','(defun ogent-doctor-batch ','n/a: local default doctor is read-only; network probes require explicit opt-in'),
 'determinism_and_reproducibility':runtime('sdk','doctor-json-1','doctor-json-1/doctor-json-2 return byte-identical output for unchanged fixture setup',repeat_probe='doctor-json-2'),
 'self_documentation':source('lisp/ogent-agent.el',':doctor_exit_codes (list :ok 0 :warning 1 :error 2)','Capabilities exposes severity dictionary and discovery advertises exact JSON doctor form; native docstring explains exit wiring'),
 'composability':runtime('sdk','doctor-json-1','Non-TTY NO_COLOR/CI/TERM=dumb path has no prompt/ANSI; printf-style output and returned severity compose as documented'),
 'regression_resistance':source('test/ogent-agent-ergonomics-tests.el','(ert-deftest ogent-agent-ergonomics-doctor-json-severity-and-schema','Pins severity, contract_version, status and checks array; invalid format is rejected before checks')})
add('verb__make__help',[900,750,800,250,500,0,1000,800,800,750,650],
 'Makefile','help:','Read-side safety n/a. Stable human help includes target list, variables, examples and both CLI/SDK discovery pointers. It has no JSON help mode or typo handling of its own; delegated task hints do not repair make hlep. Build-wrapper parseability adaptation gives basic process/human-output partial credit only.',{
 'agent_intuitiveness':runtime('make','help-1','First make help invocation succeeds and embeds exact next-step examples/discovery forms'),
 'agent_ergonomics':runtime('make','help-1','One help call bundles targets, options, examples and automation discovery'),
 'agent_ease_of_use':runtime('make','help-1','Help includes EMACS, NO_COLOR, format=json, offline dependency variable and actual capabilities command'),
 'safety_with_recovery':readonly('Makefile','help:'),
 'determinism_and_reproducibility':runtime('make','help-1','help-1/help-2 are byte-identical without volatile timestamps',repeat_probe='help-2'),
 'self_documentation':runtime('make','capabilities-1','Help points to actual makem capabilities returning rules, prerequisites, environment, examples and exit dictionary'),
 'composability':runtime('make','help-1','Non-TTY NO_COLOR/CI/TERM=dumb output is plain stdout with empty stderr and no prompt')})
for name,success,failure,erg in [('compile','compile-json-1','compile-json-failure',750),('recompile','recompile-json','recompile-json-failure',800)]:
 add('verb__make__'+name,[750,erg,750,750,750,650 if name=='compile' else 0,1000,250,750,750,750],
 'Makefile',name+':','Safety n/a: only regenerable bytecode is mutated; scoped independent fixture protects project sources. Actual copied helper executes real Emacs, emits one JSON report and retains compiler failure/nonzero Make status. Make process failure code is 2 while embedded helper task_failure is 1. Report PID/temp argv paths and diagnostic timestamps prevent byte determinism. '+('Compilation has a limited hand-maintained typo/build-hint table, not general typo inference.' if name=='compile' else 'Recompile composes cleanup and standard compile, but has no own typo hint/alias.'),{
 'agent_intuitiveness':runtime('make',success,'Canonical command actually compiles tracked fixture source successfully'),
 'agent_ergonomics':runtime('make',success,'One command supplies task/command/diagnostic/exit report slices'+(' after clean plus compile' if name=='recompile' else ' for all discovered source')),
 'agent_ease_of_use':runtime('make','help-1','Target is listed beside format=json, EMACS, NO_COLOR, examples and actual capability pointer'),
 'output_parseability':runtime('make',failure,'Actual helper prints one versioned JSON stdout document with typed task/command diagnostics and exit dictionary; all human/Make diagnostics stay stderr'),
 'error_pedagogy':runtime('make',failure,'Real compiler identifies broken source; JSON retains raw diagnostics and copyable rerun command, not just a swallowed failure'),
 'safety_with_recovery':readonly('Makefile',name+':','n/a: scoped compilation/cleanup touches regenerable bytecode only; no irreversible user data'),
 'determinism_and_reproducibility':runtime('make',success,'Reports retain actual child PID and random temporary helper argv paths; compile-json-1/2 differ'),
 'self_documentation':runtime('make','capabilities-1','Actual capability output publishes rule list, reporting option, requirements, examples and helper exit dictionary'),
 'composability':runtime('make',failure,'NO_COLOR=1 CI=true TERM=dumb non-TTY real helper: valid JSON stdout, plain stderr, no prompts, failure preserved'),
 'regression_resistance':source('test/makem-report-tests.sh','run-report 0 make --no-print-directory recompile','Actual-runner fixture verifies JSON, generated bytecode and recompile; real compiler/ERT failure assertions and CI Build report contracts step protect contract')})
add('verb__make__clean',[750,500,500,250,250,0,1000,750,500,750,650],
 'Makefile','clean:','Safety n/a: removal is limited to regenerable lisp/test .elc files; source files are preserved. The stable basic Make process/human-line contract earns the disclosed 250 build-wrapper parseability anchor. format=json only moves this human message to stderr and does not produce a clean JSON report. No unsupported output-schema uplift is assigned.',{
 'agent_intuitiveness':runtime('make','clean-human-1','Canonical clean succeeds and reports bytecode removal'),
 'output_parseability':runtime('make','clean-json','format=json clean has empty stdout and human stderr, without a structured result'),
 'safety_with_recovery':readonly('Makefile','clean:','n/a: find is scoped to generated lisp/ and test/ bytecode; no irreversible user-data deletion'),
 'determinism_and_reproducibility':runtime('make','clean-human-1','clean-human-1/clean-human-2 are byte-identical stable lines/exit0',repeat_probe='clean-human-2'),
 'composability':runtime('make','clean-human-1','Non-TTY plain stdout, empty stderr, status0 and no prompts; source recipe has no styling')})
add('verb__make__offline-test',[750,500,500,250,750,0,1000,250,500,650,750],
 'Makefile','offline-test:','Safety n/a: workflow stores/transport are isolated in temporary fixture roots with guarded loopback transport; bytecode and fixture cleanup do not affect user stores. Actual independent probe covers preflight only, not a full suite replay. Successful ERT output/timing has no JSON schema or deterministic bytes. Broad CI workflow tests are inspected as configuration/test evidence, not newly rerun here.',{
 'agent_intuitiveness':runtime('make','offline-prerequisite','Missing dependency variable receives an exact environment assignment/retry rather than stack trace'),
 'error_pedagogy':runtime('make','offline-prerequisite','Preflight names OGENT_ELPA_DIR=/path/to/installed/elpa then make offline-test'),
 'safety_with_recovery':readonly('test/offline/run.sh','fixture_root=$(mktemp -d)','n/a: own temporary fixture root, cleanup traps and loopback fixture transport isolate regenerable state'),
 'regression_resistance':source('test/offline/workflows.el.in','(ert-deftest ogent-offline-structured-tool-contract','Real dependency workflow pins structured tool schema/page semantics; CI config declares Emacs29.1/30.2 x minimum/current-gptel coverage')})
original_ids=[json.loads(line)['surface_id'] for line in (workspace/'audit/surface_inventory.jsonl').read_text().splitlines()]
original={r['surface_id']:r for r in rows};assert set(original)==set(original_ids)
(workspace/'audit/partial').mkdir(exist_ok=True)
(workspace/'audit/partial/scores_pass4_current_scorerA.jsonl').write_text(''.join(json.dumps(original[sid],ensure_ascii=False,sort_keys=True)+'\n' for sid in original_ids))
rows=[]
base_new='New API extension: no baseline exists, and these values are not paired uplift. '
add('sdk_method__agent__call',[800,800,800,850,800,750,650,650,800,850,750],
 'lisp/ogent-agent.el','(defun ogent-agent-call ',base_new+'Structured named dispatch earns its own alias/type/error/result credits. Approval and edit review are preserved without prompting; general dry-run, rollback, locks and mutation idempotency are absent, so safety/determinism are not perfect.',{
 'agent_intuitiveness':runtime('sdk','call-json-1','First named read_file call succeeds with exact continuation call in result'),
 'agent_ergonomics':runtime('sdk','call-json-1','One named call returns typed data, metadata, error and executable continuation slices'),
 'agent_ease_of_use':source('lisp/ogent-agent.el','(defun ogent-agent-call ','Docstring includes executable example; guide/capabilities/describe expose exact named args and explicit JSON format'),
 'output_parseability':runtime('sdk','call-json-1','Versioned native/JSON envelope matches exported schema; data and typed errors separate'),
 'error_pedagogy':runtime('sdk','call-arg-typo','Exact file_path correction plus specific describe recovery accompanies typed invalid_arguments'),
 'intent_inference':runtime('sdk','call-typo','read-fiel yields exact read-file suggestion; registered read_file/read/cat aliases accepted'),
 'self_documentation':source('lisp/ogent-agent.el','(defun ogent-agent-guide ','In-tool guide plus live capabilities/describe and JSON Schema explicitly document named calls'),
 'composability':runtime('sdk','call-shell-required','Non-TTY call returns explicit approval_required envelope without interaction; read plists/JSON compose'),
 'regression_resistance':source('test/ogent-agent-execution-tests.el','(ert-deftest ogent-agent-execution-validates-before-policy','Pins validation before approval, named JSON envelope and alias/policy consistency')})
add('sdk_method__agent__next',[800,850,750,850,750,0,650,850,800,850,750],
 'lisp/ogent-agent.el','(defun ogent-agent-next ',base_new+'Pagination accepts native/JSON results, freezes targets and rejects changed snapshots. Intent applies to method aliases (none), not input-shape validation. Safety remains applicable at 650 because dispatch can follow extension-provided tool continuations through the policy owner; the method does not independently restrict them to read effects. High determinism describes the canonical unchanged read snapshot.',{
 'agent_intuitiveness':runtime('sdk','next-json','First next call produces the next real file line and continuation'),
 'agent_ergonomics':runtime('sdk','next-json','One call follows named args from native/JSON prior result, resolves target and verifies snapshot'),
 'agent_ease_of_use':source('lisp/ogent-agent.el','(defun ogent-agent-next ','Docstring explains result forms, snapshot refusal and terminal done; handbook supplies exact next form'),
 'output_parseability':runtime('sdk','next-json','Returns the same versioned result envelope/schema as named call'),
 'error_pedagogy':runtime('sdk','next-changed','Typed snapshot_changed tells the caller to restart original call, avoiding mixed pages'),
 'determinism_and_reproducibility':runtime('sdk','next-json','next-json/next-repeat-json are byte-identical and tied to a SHA256 content snapshot',repeat_probe='next-repeat-json'),
 'self_documentation':source('lisp/ogent-agent.el','(defun ogent-agent-guide ','Handbook and capabilities document native/JSON continuation, target freezing and snapshot consistency'),
 'composability':runtime('sdk','next-json','Previous native/JSON result feeds directly into next; standard versioned result returns without prompting'),
 'regression_resistance':source('test/ogent-agent-execution-tests.el','(ert-deftest ogent-agent-execution-next-freezes-path-and-follows-json','Pins JSON/native chaining, frozen target, terminal done, snapshot refusal and long-line reconstruction')})
add('sdk_method__agent__batch',[800,850,750,850,750,750,1000,800,800,850,750],
 'lisp/ogent-agent.el','(defun ogent-agent-batch ',base_new+'One call composes independent reads with whole-batch preflight, ordered results/counts and explicit fail-fast. Common envelope/schema includes partial status. Safety n/a as perfect only because every accepted tool must declare exclusively read effects; writes/shell/unknown effects are rejected before execution. No general concurrent/transactional batching claim.',{
 'agent_intuitiveness':runtime('sdk','batch-json-1','First batch of files/search/read aliases succeeds with all three results'),
 'agent_ergonomics':runtime('sdk','batch-json-1','Read-only macro bundles three tool calls, schema/policy checks and result/count slices into one SDK round trip'),
 'agent_ease_of_use':source('lisp/ogent-agent.el','(defun ogent-agent-batch ','Docstring specifies list/vector shapes, 20-call cap, whole preflight and fail-fast; handbook includes executable batch example'),
 'output_parseability':runtime('sdk','batch-json-1','Versioned common result envelope with ordered nested results and counts under data; partial is declared by schema'),
 'error_pedagogy':runtime('sdk','batch-unsafe','Typed unsafe_batch names bash individual approval as the exact safe alternative'),
 'intent_inference':runtime('sdk','batch-json-1','Nested named operations accept files/search/read aliases through actual registry resolution'),
 'safety_with_recovery':readonly('lisp/ogent-agent.el','(defun ogent-agent-batch ','n/a: method explicitly rejects any tool lacking exclusively declared read effects before executing any batch prefix'),
 'determinism_and_reproducibility':runtime('sdk','batch-json-1','Two unchanged read batches are byte-identical; results follow call order and content snapshots',repeat_probe='batch-json-2'),
 'self_documentation':source('lisp/ogent-agent.el','(defun ogent-agent-guide ','Guide/capabilities describe safe batch API and named-call metadata; schema exports common envelope'),
 'composability':runtime('sdk','batch-json-1','Native arrays/plists or valid JSON return all per-call statuses without interactive approval'),
 'regression_resistance':source('test/ogent-agent-execution-tests.el','(ert-deftest ogent-agent-execution-batch-preflight-prevents-unsafe-prefix','Native tests assert no execution before unsafe/invalid tail rejection; ordered results, common envelope, fail-fast counts and empty array tested')})
add('sdk_method__agent__call-async',[750,800,750,850,800,750,650,650,800,850,750],
 'lisp/ogent-agent.el','(defun ogent-agent-call-async ',base_new+'Terminal callback returns one versioned result, including denied/invalid/timeout/cancel/error; real async process can be cancelled. General mutation idempotency/rollback/preview are absent. Raw legacy async event methods do not inherit these credits. Backend ordinary success/failure was independently exercised; deeper cancel/startup cases are source/test evidence.',{
 'agent_intuitiveness':runtime('sdk','call-async','Canonical allowed shell returns one callback with retained stdout/stderr and nonzero exit'),
 'agent_ergonomics':runtime('sdk','call-async','One call yields native process control plus one terminal complete typed result'),
 'agent_ease_of_use':source('lisp/ogent-agent.el','(defun ogent-agent-call-async ','Docstring names exact one-argument callback, immediate nil/process return and cancellation method; guide has exact invocation'),
 'output_parseability':runtime('sdk','call-async','Callback carries common versioned result with separated process fields and typed command_failed'),
 'error_pedagogy':runtime('sdk','call-async-invalid-callback','Callback validation names exactly one terminal-result callback signature'),
 'intent_inference':runtime('sdk','call-async','Registered shell alias selects bash through shared canonical named dispatch'),
 'self_documentation':source('lisp/ogent-agent.el','(defun ogent-agent-guide ','Guide plus describe metadata publish actual async_sdk support, callback/cancel and schema'),
 'composability':runtime('ledger','actual-ledger-failure-async','Real completion IO failure retains typed JSON and completed data; callback occurs once, immediate non-process extension return becomes nil. NO_COLOR CI TERM=dumb non-TTY; ordinary native process behavior is independently in call-async'),
 'regression_resistance':source('test/ogent-agent-execution-tests.el','(ert-deftest ogent-agent-execution-async-real-process-and-ledger','Pins asynchronous real process, one callback and one ledger terminal; denial/cancel/custom duplicate completion tested')})
add('sdk_method__agent__describe',[850,800,800,850,800,750,1000,850,850,850,750],
 'lisp/ogent-agent.el','(defun ogent-agent-describe ',base_new+'Read-side safety n/a. Exact live metadata combines legacy/named call arguments, aliases, effects/confirmation, actual async support and executable examples without constructing/executing tools. The data shape is versioned but not a full JSON Schema for every extension-specific result.',{
 'agent_intuitiveness':runtime('sdk','describe-json-1','First read alias description returns complete live tool contract and result-schema pointer'),
 'agent_ergonomics':runtime('sdk','describe-json-1','One metadata call combines both argument forms, aliases, effects, examples and async support'),
 'agent_ease_of_use':source('lisp/ogent-agent.el','(defun ogent-agent-describe ','Docstring lists contract slices; in-tool guide names exact description/JSON examples'),
 'output_parseability':runtime('sdk','describe-json-1','Versioned native plist/JSON description has named arrays/booleans and schema pointer; no human log contamination'),
 'error_pedagogy':runtime('sdk','describe-typo','Unknown name receives exact correction, available names and capabilities recovery'),
 'intent_inference':runtime('sdk','describe-typo','read-fiel typo gets read-file hint; read alias succeeds'),
 'safety_with_recovery':readonly('lisp/ogent-agent.el','(defun ogent-agent-describe '),
 'determinism_and_reproducibility':runtime('sdk','describe-json-1','describe-json-1/2 are byte-identical for unchanged registry; no timestamps or process IDs',repeat_probe='describe-json-2'),
 'self_documentation':runtime('sdk','describe-json-1','Method is itself a live introspection endpoint with exact arguments, executable examples and related schema'),
 'composability':runtime('sdk','describe-json-1','Standard plist/JSON returns without constructing tool objects, approval prompts or provider calls'),
 'regression_resistance':source('test/ogent-agent-execution-tests.el','(ert-deftest ogent-agent-execution-discovery-exposes-real-call-shapes','Pins real pagination args, exact async capability and examples; curated example executes and discovery purity asserted')})
add('sdk_method__agent__schema',[800,750,750,850,750,0,1000,850,800,850,700],
 'lisp/ogent-agent.el','(defun ogent-agent-schema ',base_new+'Read-side safety n/a. Exports JSON Schema for common envelope/typed error/continuation, allowing additive fields and unconstrained extension-specific data objects. No method aliases. Tests cover representative schema structure but do not require a version bump for every schema drift, so regression resistance is capped.',{
 'agent_intuitiveness':runtime('sdk','schema-json-1','First schema call returns a valid JSON Schema object'),
 'agent_ergonomics':runtime('sdk','schema-json-1','One call yields complete common envelope, error and continuation requirements'),
 'agent_ease_of_use':source('lisp/ogent-agent.el','(defun ogent-agent-schema ','Docstring identifies version and additive/extension policy; handbook and capabilities name exact schema JSON invocation'),
 'output_parseability':runtime('sdk','schema-json-1','JSON Schema draft2020-12 pins contract1 and required status/data/error/next field types; partial status included'),
 'error_pedagogy':runtime('sdk','schema-invalid','Invalid format names nil/plist/json as exact valid forms'),
 'safety_with_recovery':readonly('lisp/ogent-agent.el','(defun ogent-agent-schema '),
 'determinism_and_reproducibility':runtime('sdk','schema-json-1','schema-json-1/2 are byte-identical static schema output',repeat_probe='schema-json-2'),
 'self_documentation':source('lisp/ogent-agent.el','(defun ogent-agent-schema ','In-tool JSON Schema plus guide explains common results; extension data objects are intentionally not individually typed'),
 'composability':runtime('sdk','schema-json-1','Returns standard native plist or serialized JSON without prompts/environment-dependent output')})
(folder/'new_api_scores.jsonl').write_text(''.join(json.dumps(r,ensure_ascii=False,sort_keys=True)+'\n' for r in rows))
for filename,count in [(workspace/'audit/partial/scores_pass4_current_scorerA.jsonl',19),(folder/'new_api_scores.jsonl',6)]:
 records=[json.loads(line) for line in filename.read_text().splitlines()];assert len(records)==count
 assert len({r['surface_id'] for r in records})==count
 for record in records:
  assert set(record['scores'])==set(dims)
  assert not {'pass','scored_at','weighted_score','score_confidence'} & record.keys()
  for dim,value in record['scores'].items():
   assert isinstance(value,int) and 0<=value<=1000 and value%50==0
   if value>700:assert record['evidence'].get(dim) and 'file' in record['evidence'][dim] and 'line' in record['evidence'][dim]
 print(filename.relative_to(workspace),len(records),'validated')
