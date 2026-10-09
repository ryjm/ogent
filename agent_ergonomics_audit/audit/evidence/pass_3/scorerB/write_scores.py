"""Write independent qualitative scores from scorer B's own final evidence."""
import json
from pathlib import Path
import subprocess

repo = Path('/workspace/ogent')
audit = repo / 'agent_ergonomics_audit'
evidence = audit / 'audit/evidence/pass_3/scorerB'
dimensions = ['agent_intuitiveness','agent_ergonomics','agent_ease_of_use','output_parseability',
              'error_pedagogy','intent_inference','safety_with_recovery','determinism_and_reproducibility',
              'self_documentation','composability','regression_resistance']
rubric = json.loads((audit/'audit/manifest.json').read_text())['rubric_version']
sha = subprocess.check_output(['git','rev-parse','HEAD'],cwd=repo,text=True).strip()
probe_rows = [json.loads(line) for line in (evidence/'probe.stdout.jsonl').read_text().splitlines()]
probe_index = {row['probe']:(index,row) for index,row in enumerate(probe_rows,1)}
build_rows = [json.loads(line) for line in (evidence/'build-runtime.jsonl').read_text().splitlines()]
build_index = {row['probe']:(index,row) for index,row in enumerate(build_rows,1)}
registry_rows = [json.loads(line) for line in (evidence/'registry.stdout.jsonl').read_text().splitlines()]
registry_index = {row['probe']:(index,row) for index,row in enumerate(registry_rows,1)}
object_rows = [json.loads(line) for line in (evidence/'object.stdout.jsonl').read_text().splitlines()]
object_index = {row['probe']:(index,row) for index,row in enumerate(object_rows,1)}
search_rows = [json.loads(line) for line in (evidence/'search.stdout.jsonl').read_text().splitlines()]
search_index = {row['probe']:(index,row) for index,row in enumerate(search_rows,1)}
ledger_rows = [json.loads(line) for line in (evidence/'ledger.stdout.jsonl').read_text().splitlines()]
ledger_index = {row['probe']:(index,row) for index,row in enumerate(ledger_rows,1)}
context_rows = [json.loads(line) for line in (evidence/'context.stdout.jsonl').read_text().splitlines()]
context_index = {row['probe']:(index,row) for index,row in enumerate(context_rows,1)}

def runtime(probe,note):
    index,row = probe_index[probe]
    return {'file':'audit/evidence/pass_3/scorerB/probe.stdout.jsonl','line':index,
            'invocation':row['invocation'],'note':note}

def build(probe,note):
    index,row=build_index[probe]
    return {'file':'audit/evidence/pass_3/scorerB/build-runtime.jsonl','line':index,
            'invocation':' '.join(row['argv']),'note':note}

def registry(probe,note):
    index,row=registry_index[probe]
    return {'file':'audit/evidence/pass_3/scorerB/registry.stdout.jsonl','line':index,'note':note}

def object_runtime(probe,note):
    index,row=object_index[probe]
    return {'file':'audit/evidence/pass_3/scorerB/object.stdout.jsonl','line':index,'note':note}

def search_runtime(probe,note):
    index,row=search_index[probe]
    return {'file':'audit/evidence/pass_3/scorerB/search.stdout.jsonl','line':index,'note':note}

def ledger_runtime(probe,note):
    index,row=ledger_index[probe]
    return {'file':'audit/evidence/pass_3/scorerB/ledger.stdout.jsonl','line':index,'note':note}

def context_runtime(probe,note):
    index,row=context_index[probe]
    return {'file':'audit/evidence/pass_3/scorerB/context.stdout.jsonl','line':index,'note':note}

def source(path,anchor,note):
    lines=(repo/path).read_text().splitlines()
    line=next(index for index,text in enumerate(lines,1) if anchor in text)
    return {'file':'../'+path,'line':line,'note':note}

def test(path,anchor,note):
    return source(path,anchor,note)

def native_read_safety(path,anchor):
    ev=source(path,anchor,'n/a: read-only SDK surface; no irreversible user-data operation to gate.')
    ev['n/a']=True
    return ev

def generated_safety(anchor,note):
    ev=source('Makefile',anchor,'n/a: '+note)
    ev['n/a']=True
    return ev

def stable(probe,second,note):
    a=probe_index[probe][1]['result']['value']; b=probe_index[second][1]['result']['value']
    assert a==b, (probe,second)
    return runtime(probe,note+' Byte-identical returned values in '+second+' at line '+str(probe_index[second][0])+'.')

def entry(sid,values,notes,high):
    assert len(values)==len(dimensions)
    scores=dict(zip(dimensions,values))
    for dimension,value in scores.items():
        assert 0<=value<=1000 and value%50==0
        if value>700:
            assert dimension in high and high[dimension].get('file') and high[dimension].get('line'),(sid,dimension)
    return {'surface_id':sid,'scorer_id':'scorerB','rubric_version':rubric,'target_sha':sha,
            'scores':scores,'evidence':high,'notes':notes}

rows=[]
rows.append(entry('sdk_method__tools__read-file',[850,850,650,850,800,0,1000,950,700,850,850],
    'Raw read earns its explicit structured format, bounded lines, positions and snapshot hash. Legacy default remains numbered text. Direct method-name aliases are absent; dispatcher aliases are separate. Safety n/a applies to reading. No full built-in data JSON Schema or raw method example in its docstring.',{
    'agent_intuitiveness':runtime('read-text','The ordinary direct read succeeds on a canonical text file.'),
    'agent_ergonomics':runtime('read-json-1','One direct call returns lines, content, total count and next line/column positions.'),
    'output_parseability':runtime('read-json-1','Explicit json returns typed line objects and pagination fields, not a parsed text footer; tests pin their types.'),
    'error_pedagogy':runtime('read-invalid','Typed user-error names the invalid offset and the exact offset=1 correction.'),
    'safety_with_recovery':native_read_safety('lisp/ogent-tools.el','(defun ogent-tool--read-file'),
    'determinism_and_reproducibility':stable('read-json-1','read-json-2','Same snapshot yields the same serialized page and content-addressed snapshot.'),
    'composability':runtime('read-json-1','NO_COLOR/CI/TERM=dumb source-forced run returns native/JSON data; no SDK prompt or style escapes.'),
    'regression_resistance':test('test/ogent-agent-execution-tests.el','(ert-deftest ogent-agent-execution-read-structured-pages','Asserts exact content, total_lines, next_offset, vector lines and independently parsed raw JSON; long-line continuation also covered.')}))
rows[-1]['evidence']['agent_ergonomics']['additional_evidence']=runtime('default-read-configured-cap','Default format accepts a configured one-line cap and returns an actionable continuation.')
rows.append(entry('sdk_method__tools__glob',[850,850,650,850,750,0,1000,950,700,850,850],
    'Structured raw glob returns ordered file metadata, totals and continuation position. Text mode stays legacy. Registry find/files aliases are not raw method aliases. Safety n/a applies to file discovery; snapshot hashes cover metadata rather than all file contents.',{
    'agent_intuitiveness':runtime('glob-json-1','Canonical glob with path and explicit format returns matching file objects.'),
    'agent_ergonomics':runtime('glob-json-1','One call supplies file paths, metadata, total_files and next_offset.'),
    'output_parseability':runtime('glob-json-1','Typed file vector and explicit has_more/next_offset replace guessing from prose.'),
    'error_pedagogy':runtime('glob-invalid','A user-error corrects empty pattern with the concrete pattern=**/*.el example.'),
    'safety_with_recovery':native_read_safety('lisp/ogent-tool-results.el','(defun ogent-tool-results-glob'),
    'determinism_and_reproducibility':stable('glob-json-1','glob-json-2','Stable absolute-path ordering and metadata snapshot hash.'),
    'composability':runtime('glob-json-1','JSON/native results compose under nonterminal NO_COLOR/CI/TERM=dumb without prompts.'),
    'regression_resistance':test('test/ogent-agent-execution-tests.el','(ert-deftest ogent-agent-execution-glob-complete-pagination','Asserts 105 total, pages of 100 and 5, final has_more false and equal snapshot identities.')}))
rows.append(entry('sdk_method__tools__grep',[850,850,650,850,750,0,1000,950,700,850,850],
    'Raw synchronous search gets its own explicit structured format, exact match locations, totals, context and paging. Independent runtime exercises GNU fallback, not the installed ripgrep path. Raw direct spelling recovery remains absent. Safety n/a applies to search.',{
    'agent_intuitiveness':runtime('grep-json-1','A canonical file search succeeds and reports its backend explicitly.'),
    'agent_ergonomics':runtime('grep-json-1','One call returns match objects, count, positions, context, engine and next page offset.'),
    'output_parseability':runtime('grep-json-1','Path/line/text objects are independently serialized JSON; truncation and counts are explicit.'),
    'error_pedagogy':runtime('grep-invalid','Typed user-error names a non-empty pattern and supplies pattern=needle.'),
    'safety_with_recovery':native_read_safety('lisp/ogent-tool-process.el','(defun ogent-tool-process-grep'),
    'determinism_and_reproducibility':stable('grep-json-1','grep-json-2','Sorted match page and content-derived snapshot are identical for the same input.'),
    'composability':runtime('grep-json-1','Source-forced nonterminal run returns parseable JSON, with data fields carrying the search engine.'),
    'regression_resistance':test('test/ogent-agent-execution-tests.el','(ert-deftest ogent-agent-execution-process-grep-integration','Asserts raw structured vector plus paged counts, exact path and line. Process tests cover GNU and ripgrep protocols.')}))
rows[-1]['evidence']['regression_resistance']['additional_evidence']=search_runtime('late-nul-and-bom-skipped','Independent actual GNU process fixture skips a match before a late NUL and a UTF-16 BOM/NUL file. Other supplemental records pin ordinary file links, directory-link exclusion and selected/excluded invalid filename handling. This credits the shared raw process owner, not named dispatch aliases or policy.')
rows.append(entry('sdk_method__tools__grep-async',[800,700,600,500,650,0,1000,650,600,850,750],
    'This legacy raw method remains callback-last (type,data) streaming; matches are strings and done is a count, with no result envelope or pagination format. New terminal async APIs do not upgrade this signature. Callback composition is usable, but chunk/recursive order and string errors limit robustness. Safety n/a applies to search.',{
    'agent_intuitiveness':runtime('grep-async','Direct file search returns a process and match events followed by done=2.'),
    'safety_with_recovery':native_read_safety('lisp/ogent-tools.el','(defun ogent-tool--grep-async'),
    'composability':runtime('grep-async','A native process and tagged callbacks compose with Emacs event handling without prompting.'),
    'regression_resistance':test('test/ogent-tools-tests.el','(ert-deftest ogent-tools-grep-async-accepts-file-path','Asserts a process, successful done event, matching line event and cleanup of active processes.')}))
rows.append(entry('sdk_method__tools__bash',[800,850,650,850,750,0,0,750,650,850,850],
    'Direct synchronous shell gains separate structured stdout/stderr, exit, signal, timeout/cancel and truncation flags. It is a trusted raw mutator and performs no approval, preview or rollback. No dispatcher alias credit. Repeated harmless command results are stable; arbitrary caller shell commands need their own reproducibility/idempotency.',{
    'agent_intuitiveness':runtime('bash-json-1','Canonical shell execution returns retained stdout/stderr and the real nonzero exit.'),
    'agent_ergonomics':runtime('bash-json-1','One call returns both channels plus terminal state without footer parsing.'),
    'output_parseability':runtime('bash-json-1','Independent JSON carries stdout, stderr, exit_code, signal, timed_out, cancelled and truncated.'),
    'error_pedagogy':runtime('bash-invalid','Typed validation names command and offers exact command="pwd" correction.'),
    'determinism_and_reproducibility':stable('bash-json-1','bash-json-2','The helper injects no clock/PID/random fields into this controlled shell result.'),
    'composability':runtime('bash-json-1','Programmatic JSON preserves stdout and stderr separately under nonterminal NO_COLOR/CI/TERM=dumb.'),
    'regression_resistance':test('test/ogent-agent-execution-tests.el','(ert-deftest ogent-agent-execution-process-shell-failures-retain-data','Tests real exit=7 stderr and timeout partial stdout; raw primitive delegates to that process-data owner.')}))
rows.append(entry('sdk_method__tools__bash-async',[800,700,600,650,700,0,0,500,600,800,800],
    'Legacy raw async shell remains streaming (type,data), with an integer done event and string error events. There is no typed terminal result envelope on this method. It bypasses approval by design as a trusted helper; new named async behavior earns separate scores. Callback chunk ordering and boundaries can vary.',{
    'agent_intuitiveness':runtime('bash-async','Direct invocation returns a process, tagged stdout/stderr and done=7.'),
    'composability':runtime('bash-async','Native process and distinct channel tags support callback consumers; the terminal code is preserved.'),
    'regression_resistance':test('test/ogent-tools-tests.el','(ert-deftest ogent-tools-bash-async-timeout-callback-once','Pins exactly one terminal error, zero done events on timeout, and cleanup of the process registry.')}))
rows.append(entry('sdk_method__tools__write-file',[800,850,600,250,750,0,0,800,600,800,750],
    'Raw overwrite is concise and validates basic scalar input, but it immediately writes with no gate, preview, rollback or idempotency key. Its reply remains a prose character-count string. Repeating full-content writes is idempotent for the same target/content. Wrapper denial is not raw safety credit.',{
    'agent_intuitiveness':runtime('write-raw','Direct valid write returns count/path and produces the requested bytes.'),
    'agent_ergonomics':runtime('write-raw','One call creates needed parents and writes all content.'),
    'error_pedagogy':runtime('write-invalid','Typed user-error identifies content and explicitly permits text or an empty string.'),
    'determinism_and_reproducibility':stable('write-repeat-1','write-repeat-2','Same full content and target produce the same reply; overwrite sets the requested state.'),
    'composability':source('lisp/ogent-tools.el','(defun ogent-tool--write-file','Returns a normal Emacs string or signals user-error; never starts an interactive prompt.'),
    'regression_resistance':test('test/ogent-tools-tests.el','(ert-deftest ogent-tools-write-file-overwrites-existing','Asserts exact post-write bytes; adjacent tests pin count/path reply and empty writes.')}))
rows.append(entry('sdk_method__tools__edit-file',[800,850,600,250,800,0,0,750,650,800,850],
    'Raw edit refuses empty context, malformed booleans and unintended multiple matches, with exact corrective text. Valid direct edits still overwrite immediately. Reply is prose; no direct method aliases, transaction, approval, rollback or idempotency key. Resetting the same initial bytes gives a reproducible replacement. Wrapper safety is separate.',{
    'agent_intuitiveness':runtime('edit-raw-1','Explicit replace-all performs the intended edit; ambiguous implicit edits receive an exact correction.'),
    'agent_ergonomics':runtime('edit-raw-1','One direct call validates context, replaces it and reports the count.'),
    'error_pedagogy':runtime('edit-ambiguous','user-error names path and two occurrences, with unique-context or replace_all true recovery.'),
    'determinism_and_reproducibility':stable('edit-raw-1','edit-raw-2','After restoring the same original file, both calls produce the same reply and new bytes.'),
    'composability':source('lisp/ogent-tools.el','(defun ogent-tool--edit-file','Normal string result and typed user-error compose with Lisp condition-case; no helper-level prompt.'),
    'regression_resistance':test('test/ogent-agent-ergonomics-tests.el','(ert-deftest ogent-agent-ergonomics-edit-contract-ambiguous-before-write','Pins typed error guidance and unchanged bytes for nil/JSON false; explicit true replaces all.')}))
rows.append(entry('sdk_method__registry__tool-get',[850,850,600,750,250,500,1000,850,650,850,850],
    'Actual supported gptel constructor was loaded from source for this independent probe. Getter resolves canonical/wire/declared aliases and returns a reusable gptel object, refreshing format/schema changes. Unknown names and absent constructors return nil without guidance. Safety n/a is lookup/construction without execution; caching mutates only metadata.',{
    'agent_intuitiveness':registry('actual-constructor','read_file returns a real gptel tool named read-file; invoking its function returns a valid JSON read envelope.'),
    'agent_ergonomics':registry('actual-constructor','Getter performs registration automatically; no separate builder ceremony.'),
    'output_parseability':registry('actual-constructor','A native gptel-tool object exposes standard name/function accessors; JSON wrapper result parses independently.'),
    'safety_with_recovery':native_read_safety('lisp/ogent-models.el','(defun ogent-tool-get'),
    'determinism_and_reproducibility':registry('actual-constructor','read_file and read resolve the same cached object in an unchanged registry.'),
    'composability':registry('actual-constructor','Actual native gptel object/function integrates with ordinary Lisp calls and accessors.'),
    'regression_resistance':test('test/ogent-agent-execution-tests.el','(ert-deftest ogent-agent-execution-model-json-pages-and-cache-refresh','Pins registered schema argument counts, JSON result/continuation, cache reuse and regeneration after format changes.')}))
rows[-1]['evidence']['determinism_and_reproducibility']['additional_evidence']=object_runtime('object-schema-cache-stable-then-refresh','Actual gptel construction reuses an unchanged object schema and refreshes after in-place schema-table mutation; the old wrapper refuses with unavailable.')
rows.append(entry('sdk_method__registry__tool-spec-get',[850,850,600,800,250,500,1000,850,700,850,750],
    'Spec lookup is a direct native plist lookup without constructing a gptel object. Aliases and exact-name precedence work; unknown names intentionally return nil, so the ensure/dispatcher hint is not this method error pedagogy. Safety n/a applies to metadata lookup. Returned registry plists remain caller-owned mutable data.',{
    'agent_intuitiveness':runtime('registry-spec-alias','read resolves to the actual read-file spec without external setup or constructor.'),
    'agent_ergonomics':registry('spec-shape','One lookup exposes name, argument names/types and optionality without a tool execution.'),
    'output_parseability':source('lisp/ogent-models.el','(defcustom ogent-tool-registry','Registry has explicitly documented plist fields for functions, schemas, aliases, effects and result support.'),
    'safety_with_recovery':native_read_safety('lisp/ogent-models.el','(defun ogent-tool-spec-get'),
    'determinism_and_reproducibility':source('lisp/ogent-models.el','(defun ogent-tool-spec-get','Canonical name and seq-find deterministically return the same spec for the same ordered registry.'),
    'composability':registry('spec-shape','Native plists compose with plist-get and existing discovery metadata conversion.'),
    'regression_resistance':test('test/ogent-agent-ergonomics-tests.el','(ert-deftest ogent-agent-ergonomics-tool-names-exact-and-wire-alias','Pins string/symbol underscore resolution and exact custom-name precedence.')}))
rows.append(entry('sdk_method__registry__available-tools',[800,800,650,800,800,850,1000,800,700,850,800],
    'Enabled list returns ordinary native tool objects, honors nil/all/subset and diagnoses malformed or unknown configured names with exact correction. Real gptel objects were verified. Safety n/a applies to enumeration/construction without execution. Ordering follows the registry/cache, not a separate sorted export.',{
    'agent_intuitiveness':registry('enabled-tools','Default enabled list returns all six constructed built-in tools.'),
    'agent_ergonomics':registry('enabled-tools','One call filters or returns all enabled tool objects.'),
    'output_parseability':registry('enabled-tools','Native list of gptel objects composes with mapcar and public accessors.'),
    'error_pedagogy':runtime('registry-enabled-invalid','Configured read-fiel signals user-error with did you mean read-file and exact available names.'),
    'intent_inference':runtime('registry-enabled-invalid','Configured-name typo is redirected with the exact canonical correction; wire and declared aliases are resolved by ensure.'),
    'safety_with_recovery':native_read_safety('lisp/ogent-models.el','(defun ogent-tools-enabled-list'),
    'determinism_and_reproducibility':registry('enabled-tools-repeat','Two consecutive enabled enumerations return the same ordered names in an unchanged registry.'),
    'composability':registry('enabled-tools','Real native objects are directly usable by gptel and ordinary list consumers.'),
    'regression_resistance':test('test/ogent-agent-ergonomics-tests.el','(ert-deftest ogent-agent-ergonomics-tool-names-typo-refuses-with-hint','Unknown configured names refuse with a typed correction and never execute fuzzy names.')}))
rows.append(entry('sdk_method__execution__wrapper',[800,800,650,850,800,600,650,800,700,750,850],
    'Wrapper now offers explicit JSON envelopes alongside legacy string mode, while retaining schema validation, approval, edit review, ledger and callback adaptation. This is the policy owner, but there is no general rollback/lease/transaction. A gptel path may prompt for policy decisions by design. Wrapper method aliases are absent; tool-name aliases belong to registry dispatch.',{
    'agent_intuitiveness':registry('actual-constructor','The real registered JSON wrapper reads a file successfully through its expected positional interface.'),
    'agent_ergonomics':registry('actual-constructor','A reusable closure hides approval/schema/ledger orchestration behind one invocation.'),
    'output_parseability':runtime('write-denied-wrapper','JSON mode returns versioned status/data/error/next with typed denial and recovery.'),
    'error_pedagogy':runtime('write-denied-wrapper','Denied result identifies current policy and directs the caller to normal user review rather than bypassing policy.'),
    'determinism_and_reproducibility':source('lisp/ogent-tool-execution.el','(defun ogent-tool-execution-wrapper','Captures a registry snapshot and result format, rejecting removed/replaced specs rather than executing a different target.'),
    'composability':source('lisp/ogent-tool-execution.el','(defun ogent-tool-execution--json-call','Maps native positional inputs and callback-first gptel async convention to versioned serialized envelopes; programmatic named calls remain the nonprompting route.'),
    'regression_resistance':test('test/ogent-agent-execution-tests.el','(ert-deftest ogent-agent-execution-model-stale-after-approval','Asserts registry replacement during approval never executes replacement functions, for both legacy and JSON modes.')}))
rows[-1]['evidence']['determinism_and_reproducibility']['additional_evidence']=object_runtime('object-schema-wrapper-rejects-in-place-change','Independent wrapper refuses after an in-place object-schema change, before executing the extension.')
rows[-1]['evidence']['determinism_and_reproducibility']['additional_evidence']['additional_evidence']=context_runtime('json-wrapper-relative-destination-survives-project-switch','Actual JSON wrapper records both terminal events at the original relative ledger destination despite switching projects and disabling/changing future ledger settings during execution; caller changes remain visible afterward. Legacy async is independently checked too.')
rows[-1]['evidence']['error_pedagogy']['additional_evidence']=ledger_runtime('sync-completion-io-failure-retains-mutation','Actual completion ledger write to a directory fails after one fixture mutation. Shared owner retains data and gives the exact writable-ledger correction with explicit do-not-rerun guidance; legacy UI also retains result plus a visible warning.')
rows[-1]['evidence']['error_pedagogy']['additional_evidence']['additional_evidence']=source('lisp/ui/ogent-ui-toolcalls.el','(ledger-error (ogent-tool-execution-record-finish','Actual UI execution owner retains completed data and original execution error across failed completion recording, supporting typed SDK recovery and the visible legacy warning.')
for sid,method,batch in [('sdk_method__doctor__run','ogent-doctor-run',False),('sdk_method__doctor__batch','ogent-doctor-batch',True)]:
    values=[850,850,650,850,750,0,1000,800,750,850,850] if batch else [850,850,600,800,700,0,1000,800,700,850,850]
    high={
        'agent_intuitiveness':runtime('doctor-batch-1' if batch else 'doctor-run','Default local health invocation succeeds with a report; severity is explicit rather than a hidden exception.'),
        'agent_ergonomics':runtime('doctor-run','One call returns nineteen local check statuses, detail and remediation; opt-in probes are omitted.'),
        'output_parseability':runtime('doctor-batch-1' if batch else 'doctor-run','JSON batch selects a versioned check array and documented severity code; native run returns result plists.'),
        'safety_with_recovery':native_read_safety('lisp/ogent-doctor.el','(defun '+method),
        'determinism_and_reproducibility':stable('doctor-batch-1','doctor-batch-2','Same protected process/environment produces identical ordered health data.'),
        'composability':runtime('doctor-batch-1','JSON health output independently parses; explicit exit severity matches native return code, no interactive prompt.'),
        'regression_resistance':test('test/ogent-agent-ergonomics-tests.el','(ert-deftest ogent-agent-ergonomics-doctor-json-severity-and-schema','Pins data-only JSON, contract version, vector checks and every 0/1/2 severity; default opt-in exclusion also tested.')}
    if batch:
        high['error_pedagogy']=runtime('doctor-batch-invalid','Typed format error prints the exact (ogent-doctor-batch nil (quote json)) correction.')
        high['self_documentation']=runtime('guide','Embedded handbook names JSON batch health and its complete 0/1/2 dictionary.')
    rows.append(entry(sid,values,'Read-only local diagnostics, safety n/a. Default runs do not invoke opt-in MCP handshakes. Run returns plists; batch defaults to Org unless JSON is selected and the caller must wire its return code to kill-emacs. No direct method typo aliases. Runtime bootstrap uses protected helper metadata, not an actual provider environment. Fresh processes have distinct sandbox paths, so only same-environment repeated data earns deterministic credit.',high))
rows.append(entry('verb__make__help',[850,700,850,250,350,250,1000,850,850,900,650],
    'Help is rich, plain and successful, with examples, EMACS/format/NO_COLOR and machine discovery pointers. Its own output remains human text; format=json is for makem-backed targets, not this recipe. Safety n/a applies to a read-only menu. Existing help assertions protect key pointers but do not pin the full menu.',{
    'agent_intuitiveness':build('make-help','make help exits zero with a complete target/options/examples menu.'),
    'agent_ease_of_use':build('make-help','Lists EMACS, format=json, NO_COLOR and exact ./makem.sh --capabilities --json plus embedded SDK discovery calls.'),
    'safety_with_recovery':generated_safety('help:','read-only help output performs no irreversible operation.'),
    'determinism_and_reproducibility':source('Makefile','help:','Fixed echo recipes contain no timestamps, randomness or environment interpolation.'),
    'self_documentation':build('make-help','The menu exposes both live SDK contracts/guide and actual build capabilities with command examples.'),
    'composability':build('make-help','NO_COLOR/CI/TERM=dumb nonterminal invocation exits zero with plain stdout and empty stderr.')}))
for sid,task in [('verb__make__compile','compile'),('verb__make__recompile','recompile')]:
    success='compile-success-1' if task=='compile' else 'recompile-success'
    failure='compile-syntax-failure' if task=='compile' else 'recompile-syntax-failure'
    rows.append(entry(sid,[850,850,850,850,850,500,1000,500,800,900,850],
        'Real Make/makem/Emacs fixture, never a substituted runner. format=json yields one versioned JSON with real task/command status and diagnostics; Make recipe failure remains nonzero while JSON keeps the helper exit. Recompile only removes generated bytecode before standard compile. PIDs and temporary argv paths vary across repeats; ERT timing text also remains in raw output, so determinism stays below 750. Known task typo hints work, but general method/option typo recovery is limited. Safety n/a applies to regenerable bytecode.',{
        'agent_intuitiveness':build(success,'Canonical Make target executes the actual Emacs compiler and reports success.'),
        'agent_ergonomics':build(success,'One target invocation returns requested task, completed status, real commands/exits and diagnostics.'),
        'agent_ease_of_use':build('make-help','Help names format=json, EMACS selection, examples and exact capability discovery.'),
        'output_parseability':build(success,'One JSON stdout document has contract_version=1, tasks, command argv/exit/output, diagnostics and exit dictionary.'),
        'error_pedagogy':build(failure,'Real syntax failure preserves source location/raw diagnostic and the exact rerun command in next_actions.'),
        'safety_with_recovery':generated_safety(task+':','the target creates/removes only regenerable bytecode, as verified in the owned fixture.'),
        'self_documentation':build('build-capabilities','Actual helper discovery returns supported rules, requirements, environment convention and the published exit dictionary.'),
        'composability':build(failure,'NO_COLOR/CI/TERM=dumb real failure has JSON-only stdout, plain diagnostics stderr, and nonzero Make exit; recompile does not swallow failures.'),
        'regression_resistance':test('test/makem-report-tests.sh','run-report 0 make --no-print-directory recompile','CI shell suite uses actual compiler/ERT fixtures and independently parses reports, including Make recompile and real failures.')}))
rows.append(entry('verb__make__clean',[850,800,650,250,350,250,1000,850,650,800,750],
    'Cleans generated lisp and test bytecode and preserves source. Stable text/basic process status retains the existing build-wrapper partial parseability anchor; format=json moves the message to stderr but creates no JSON result. No generic gate is needed for regenerable artifacts. Safety n/a is generated-bytecode cleanup.',{
    'agent_intuitiveness':build('clean-default','make clean succeeds and removes both fixture lisp/test bytecode.'),
    'agent_ergonomics':source('Makefile','clean:','One find invocation covers lisp/ and test/ bytecode recursively.'),
    'safety_with_recovery':generated_safety('clean:','scope is generated .elc in lisp/ and test/, not user source; clean-state.json independently confirms preserved source.'),
    'determinism_and_reproducibility':build('clean-default','Fixed Removed all .elc files message and zero status contain no timestamp or random identifier.'),
    'composability':build('clean-json','Under requested machine report mode, cleanup diagnostics stay on stderr; ordinary output is plain and nonprompting.'),
    'regression_resistance':test('test/ogent-agent-ergonomics-tests.el','(ert-deftest ogent-agent-ergonomics-make-contract-clean-and-help','Asserts cleanup removes test bytecode as well as the lisp fixture and keeps help discovery usable.')}))
rows.append(entry('verb__make__offline-test',[750,500,650,250,750,250,1000,250,600,650,750],
    'The prerequisite correction is independently replayed; no broad offline suite was run while shared native verification was active. The target still uses human ERT logs and timing rather than the makem JSON result. Safety n/a is local isolated fixture/store behavior, not merely absence of a confirmation flag. Existing runtime-dependency CI matrix and preflight tests protect it.',{
    'agent_intuitiveness':build('offline-prerequisite-1','Missing prerequisite refuses immediately with exact OGENT_ELPA_DIR assignment and make offline-test retry.'),
    'error_pedagogy':build('offline-prerequisite-1','Data-free stdout and stderr tell the caller exactly which environment variable and command to use.'),
    'safety_with_recovery':source('test/offline/run.sh','fixture_root=$(mktemp -d)','n/a: temporary fixture root, loopback transport, cleanup traps and source-forced store-protected test bootstrap isolate regenerable test state.'),
    'regression_resistance':test('test/ogent-agent-ergonomics-tests.el','(ert-deftest ogent-agent-ergonomics-offline-contract-missing-dependencies','Asserts missing deps fail with empty stdout, exact ELPA/retry text and no backtrace; CI adds real-dependency Emacs/gptel matrix.') }))
rows[-1]['evidence']['safety_with_recovery']['n/a']=True

api_rows=[]
common_docs=runtime('guide','Embedded handbook names call/next/batch/async/describe/schema and concrete local SDK examples, with capability and schema discovery pointers.')
common_selfdoc=runtime('capabilities','Live contract contains exact argument schemas, aliases, examples, effect/approval metadata, result schema, continuation and async entry points.')
call_high={
    'agent_intuitiveness':runtime('named-read','The expected read alias and named args succeed on first call.'),
    'agent_ergonomics':runtime('named-read','One call bundles typed data, status, recovery fields and copyable continuation.'),
    'agent_ease_of_use':common_docs,
    'output_parseability':runtime('named-json-1','One independently parsed versioned JSON envelope contains status/data/error/next and explicit native-null/false serialization.'),
    'error_pedagogy':runtime('named-key-typo','Typed invalid_arguments names file_pth, suggests file_path, and links exact ogent-agent-describe usage.'),
    'intent_inference':runtime('named-typo','Tool alias works and raed receives did you mean read without executing a fuzzy match; named-key typo also gets exact correction.'),
    'determinism_and_reproducibility':stable('named-json-1','named-json-2','Same read input yields a byte-identical envelope with snapshot and continuation.'),
    'self_documentation':common_selfdoc,
    'composability':runtime('named-denied','Programmatic policy denial returns a typed envelope without prompting; format is validated before execution.'),
    'regression_resistance':test('test/ogent-agent-execution-tests.el','(ert-deftest ogent-agent-execution-validates-before-policy','Pins format/type validation before policy, plus JSON scalar preservation and denial preventing file creation.')}
api_rows.append(entry('sdk_method__agent__call',[850,900,850,900,850,850,650,900,900,900,850],
    'New API; no baseline method exists. Named input, aliases, typed results and exact continuation are practical improvements. Shared approval/edit review prevents automatic dangerous execution, but no generic lease/rollback/dry-run for every mutation exists, so safety is 650. Arbitrary provider/extension and shell data may be volatile; deterministic credit is for a controlled read.',call_high))
api_rows[-1]['evidence']['determinism_and_reproducibility']['additional_evidence']=runtime('copy-before-policy','A synthetic policy hook changes the caller string during approval; the actual result still reads the original copied path. This probes input ownership, not policy strength.')
api_rows[-1]['evidence']['agent_ergonomics']['additional_evidence']=object_runtime('object-input-copied-before-policy','Nested object-table input is supported directly; changing both the caller string and nested table during policy leaves the original input visible to the function.')
api_rows[-1]['evidence']['error_pedagogy']['additional_evidence']=ledger_runtime('sync-completion-io-failure-retains-mutation','Real completion file I/O failure returns ledger_write_failed with retained completed data, a writable-ledger correction and explicit guidance against rerunning the already-completed mutation.')
api_rows[-1]['evidence']['composability']['additional_evidence']=context_runtime('sdk-project-switch-and-future-settings','Ledger capture binds settings only while recording: changing project and future ledger settings inside the tool does not split the current event pair or erase caller changes; later disabled/enabled calls use the updated settings.')
api_rows.append(entry('sdk_method__agent__next',[850,850,850,900,800,0,650,900,850,900,850],
    'New API; no baseline method exists. Native or JSON continuations freeze targets and snapshot identities, stop explicitly and refuse changed pages. No direct method alias recovery. A hand-built continuation can name any registered tool, so safety is applicable and inherited from dispatch approval rather than n/a/read-only. Tests prove its denial path.',{
    'agent_intuitiveness':runtime('next','One next call naturally follows the prior read result and returns the next line.'),
    'agent_ergonomics':runtime('next','Caller supplies only the previous result; offset/column/path reconstruction is internal.'),
    'agent_ease_of_use':common_docs,
    'output_parseability':runtime('next-json-1','Page returns the same versioned status/data/error/next contract; JSON input/output works without footer decoding.'),
    'error_pedagogy':runtime('next-changed','snapshot_changed tells the caller to restart the original call rather than mix pages.'),
    'determinism_and_reproducibility':stable('next-json-1','next-json-2','An unchanged snapshot gives the same continuation result; altered input is rejected explicitly.'),
    'self_documentation':common_docs,
    'composability':runtime('next-safety-owner','Even a hand-built shell continuation passes through shared denial and returns a typed result without prompting.'),
    'regression_resistance':test('test/ogent-agent-execution-tests.el','(ert-deftest ogent-agent-execution-next-refuses-changed-snapshot','Pins snapshot_changed and absent result data; adjacent tests pin changed-directory target and long-line reconstruction.')}))
api_rows.append(entry('sdk_method__agent__batch',[850,950,850,900,800,850,1000,900,850,900,850],
    'New API; no baseline method exists. A single batch combines discovery/search/read, preserves result order and reports completion/stop state. All calls preflight before any execute, and shell/write effects are refused. Safety n/a is enforced read-only batching. Shared schema covers the common envelope, while batch data contents are documented and tested.',{
    'agent_intuitiveness':runtime('batch','Read/glob/grep batch returns a single ok envelope with ordered results and completion counts.'),
    'agent_ergonomics':runtime('batch','One round trip returns three useful local data slices, preserving independent result envelopes and their follow-ups.'),
    'agent_ease_of_use':common_docs,
    'output_parseability':runtime('batch','Versioned status/data/error/next envelope stores typed ordered results, requested/completed and stopped under data.'),
    'error_pedagogy':runtime('batch-unsafe','unsafe_batch names the offending bash tool and directs individual invocation through approval.'),
    'intent_inference':source('lisp/ogent-agent.el','(defun ogent-agent-batch','Each named tool/key is resolved through the shared exact/alias/typo contract before execution; unsafe calls get explicit route guidance.'),
    'safety_with_recovery':native_read_safety('lisp/ogent-agent.el','(defun ogent-agent-batch'),
    'determinism_and_reproducibility':stable('batch-json-1','batch-json-2','Same protected read/glob inputs return byte-identical ordered batch envelopes.'),
    'self_documentation':common_docs,
    'composability':runtime('batch-json-1','One JSON document can be consumed with the ordinary envelope parser, with per-call statuses preserved.'),
    'regression_resistance':test('test/ogent-agent-execution-tests.el','(ert-deftest ogent-agent-execution-batch-preflight-prevents-unsafe-prefix','Pins zero execution for unsafe/invalid later calls, ordered composition, continue/fail-fast and empty batch.')}))
api_rows[-1]['evidence']['safety_with_recovery']['additional_evidence']=runtime('batch-frozen-later-call','Earlier declared-read extension mutates the caller\'s later target into shell and alters its args; batch executes the frozen original read. Read-only classification relies on honest extension effect metadata, not an OS sandbox.')
api_rows.append(entry('sdk_method__agent__call-async',[850,850,850,900,800,850,650,650,850,900,850],
    'New API; no baseline method exists. Asynchronous work returns a native cancellable process and one terminal envelope rather than legacy chunk callbacks. Timeout/cancel/nonzero exit retain partial data; immediate validation/denial delivers once. Shared policy prevents implicit dangerous execution but has no generic transaction rollback. Timing/chunk-budget races limit broad determinism claims.',{
    'agent_intuitiveness':runtime('named-async','Explicitly approved harmless real shell call returns a process and exactly one terminal JSON callback.'),
    'agent_ergonomics':runtime('named-async','One callback gets complete separate channels, exit and typed failure without assembling streaming footers.'),
    'agent_ease_of_use':common_docs,
    'output_parseability':runtime('named-async','Terminal JSON carries command_failed and retained stdout/stderr/exit in the common envelope.'),
    'error_pedagogy':runtime('named-async-denied','Denial is a typed terminal envelope directing normal policy review, with one callback and no process.'),
    'intent_inference':runtime('named-async','shell alias resolves the same declared bash contract and policy; shared name/key hints apply before starting a process.'),
    'self_documentation':common_docs,
    'composability':runtime('named-async-denied','Immediate denial and actual process completion both deliver one terminal result; explicit cancellation API is documented.'),
    'regression_resistance':test('test/ogent-agent-execution-tests.el','(ert-deftest ogent-agent-execution-async-real-process-and-ledger','Pins true asynchronous return, exactly one callback and ledger start/finish; denial/cancel and custom double-callback cases also covered.')}))
api_rows[-1]['evidence']['composability']['additional_evidence']=ledger_runtime('immediate-async-io-failure-delivers-once-and-returns-nil','Actual ledger completion I/O failure preserves data plus original tool_error, delivers exactly once despite a duplicate callback, and normalizes an immediate non-process return to nil. Start I/O failure separately prevents execution and delivers once.')
api_rows.append(entry('sdk_method__agent__describe',[850,850,850,900,850,850,1000,900,950,900,800],
    'New API; no baseline method exists. Metadata-only description returns one live exact schema, aliases, examples, policy and asynchronous support without construction/execution. Native and JSON results are typed. Tool-name alias and typo recovery are real on this named surface. Safety n/a is metadata lookup.',{
    'agent_intuitiveness':runtime('describe-1','read alias returns the exact read-file call contract as JSON.'),
    'agent_ergonomics':runtime('describe-1','One call supplies legacy/named schemas, executable example, effect policy and async information.'),
    'agent_ease_of_use':runtime('describe-1','Self-describing argument descriptions and executable example let callers proceed without external docs.'),
    'output_parseability':runtime('describe-1','Versioned JSON tool description uses arrays/booleans and explicit call_arguments with a result_schema pointer.'),
    'error_pedagogy':runtime('describe-typo','Unknown raed signals user-error with did you mean read and available names/discovery pointer.'),
    'intent_inference':runtime('describe-typo','Alias spelling succeeds; nearby typo receives an exact suggestion instead of fuzzy execution.'),
    'safety_with_recovery':native_read_safety('lisp/ogent-agent.el','(defun ogent-agent-describe'),
    'determinism_and_reproducibility':stable('describe-1','describe-2','Unchanged live registry produces byte-identical description JSON.'),
    'self_documentation':runtime('describe-1','Exports live arguments, aliases, examples and metadata; links the machine schema and embedded guide/capabilities route.'),
    'composability':runtime('describe-1','Pure native/JSON metadata returns without printing diagnostics or prompting under nonterminal env.'),
    'regression_resistance':test('test/ogent-agent-execution-tests.el','(ert-deftest ogent-agent-execution-discovery-exposes-real-call-shapes','Pins named column/limit fields, actual async_sdk vs legacy async, executable examples and metadata-only purity.')}))
api_rows.append(entry('sdk_method__agent__schema',[850,850,750,900,750,0,1000,900,850,900,700],
    'New API; no baseline method exists. Exports a real JSON Schema for the common envelope, including partial batch status, error and continuation objects. Built-in/extension data is intentionally open and not fully machine-described. No direct method typo aliases. Safety n/a is pure metadata generation. Existing schema tests cover core shapes but lack a full schema/version-drift guard.',{
    'agent_intuitiveness':runtime('schema-1','Expected no-argument/intended JSON-format introspection succeeds.'),
    'agent_ergonomics':runtime('schema-1','One call exports a directly usable envelope schema.'),
    'agent_ease_of_use':common_docs,
    'output_parseability':runtime('schema-1','JSON Schema declares required envelope fields, status enum, data/error types and next item properties.'),
    'error_pedagogy':runtime('schema-invalid','Typed format error names exact nil/plist/json format values before any further work.'),
    'safety_with_recovery':native_read_safety('lisp/ogent-agent.el','(defun ogent-agent-schema'),
    'determinism_and_reproducibility':stable('schema-1','schema-2','Pure schema constants serialize identically across calls.'),
    'self_documentation':runtime('schema-1','Machine introspection includes envelope definitions; guide describes the built-in data fields and extension limits.'),
    'composability':runtime('schema-1','Native plist or JSON Schema value feeds ordinary Lisp or external validators without prompts or terminal formatting.')}))

inventory=[json.loads(line)['surface_id'] for line in (audit/'audit/surface_inventory.jsonl').read_text().splitlines()]
assert len(rows)==19 and {row['surface_id'] for row in rows}==set(inventory)
assert len(api_rows)==6 and len({r['surface_id'] for r in api_rows})==6
assert all(r['target_sha']==sha for r in rows+api_rows)
assert all(row['target_sha']==sha for row in build_rows), 'Build probe freeze does not match score freeze'
assert (evidence/'probe.target_sha').read_text().strip()==sha
assert (evidence/'registry.target_sha').read_text().strip()==sha
assert (evidence/'object.target_sha').read_text().strip()==sha
assert (evidence/'search.target_sha').read_text().strip()==sha
assert (evidence/'ledger.target_sha').read_text().strip()==sha
assert (evidence/'context.target_sha').read_text().strip()==sha
for path,records in [(audit/'audit/partial/scores_pass4_current_scorerB.jsonl',rows),
                     (evidence/'new_api_scores.jsonl',api_rows)]:
    path.parent.mkdir(parents=True,exist_ok=True)
    path.write_text(''.join(json.dumps(row,sort_keys=True)+'\n' for row in records))
    print(path, 'rows', len(records))
