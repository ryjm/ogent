import json
import pathlib

root = pathlib.Path('/workspace/ogent/agent_ergonomics_audit/audit')
partial = root / 'partial'
sha = '72016bb66928a20a49238266645abde583fa595d'
rubric = 'sha256:44e7c00b3dee6be38118f1f40719d814278cb129f9aad34572e0936104b135a4'
dims = ['agent_intuitiveness', 'agent_ergonomics', 'agent_ease_of_use',
        'output_parseability', 'error_pedagogy', 'intent_inference',
        'safety_with_recovery', 'determinism_and_reproducibility',
        'self_documentation', 'composability', 'regression_resistance']
runtime = {o['probe']: o for o in map(json.loads, (partial / 'tiebreaker_runtime.jsonl').read_text().splitlines())}
make_runtime = list(map(json.loads, (partial / 'tiebreaker_make_runtime.jsonl').read_text().splitlines()))
invocation = 'docker exec ogent-fixes timeout 20 emacs -Q --batch -l /work/agent_ergonomics_audit/audit/partial/tiebreaker_probe.el'


def source(path, line, reason):
    return dict(file=path, line=line, target_sha=sha, reason=reason)


def probe(name, reason, repeat=None):
    row = dict(invocation=invocation, transcript='audit/partial/tiebreaker_runtime.jsonl',
               probe=name, stdout_excerpt=runtime[name].get('result', runtime[name].get('error')),
               target_sha=sha, reason=reason)
    if repeat:
        row['repeat_probe'] = repeat
        row['repeat_stdout_excerpt'] = runtime[repeat].get('result')
    return row


def makeprobe(index, reason):
    o = make_runtime[index]
    return dict(invocation=o['invocation'], transcript='audit/partial/tiebreaker_make_runtime.jsonl',
                stdout_excerpt=o['stdout'][:900], stderr_excerpt=o['stderr'][:300],
                exit_code=o['exit_code'], scope=o['scope'], target_sha=sha, reason=reason)


intent_na = dict(n_a=True, reason='n/a — direct positional SDK function; no alternate-name/option decoder is exposed. Shell COMMAND-language repair is outside this SDK surface, and parameter validation is error_pedagogy.')
doctor_intent_na = dict(n_a=True, reason='n/a — canonical no-argument diagnostic SDK call (one optional opt-in boolean); no method-name/argument-spelling/ordering decoder exists. Check-crash containment is error_pedagogy, not intent inference.')
doctor_safety_na = dict(n_a=True, reason='n/a — default doctor call is read-only diagnostic work; opt-in network checks remain excluded. No irreversible operation to gate.')
build_safety_na = dict(n_a=True, reason='n/a — recipe only creates/replaces/removes regenerable bytecode; original .el user/source data is preserved. No irreversible user-state operation to gate.')
bash_safety = source('lisp/ogent-tools.el', 557, 'Direct private function spawns arbitrary shell commands without a method-level gate, dry-run, or rollback (0 anchor). Normal agent entry is separately approval-gated by ogent-tool-execution.el:34 and ogent-tool-approval.el:162; no external agent-runtime approval bypass is asserted.')

rows = []


def add(sid, values, evidence, notes):
    assert len(values) == 11
    assert set(evidence) == set(dims)
    row = dict(surface_id=sid, scorer_id='tiebreaker', rubric_version=rubric,
               scores=dict(zip(dims, values)), weighted_score=round(sum(values)/11, 2),
               evidence=evidence,
               notes='Original SHA '+sha+'. SDK extension applied where applicable; default arithmetic-mean weights retained. '+notes)
    rows.append(row)
    (partial / f'scores_pass1_{sid}_scorertiebreaker.jsonl').write_text(json.dumps(row, sort_keys=True)+'\n')


add('sdk_method__doctor__run', [1000, 900, 500, 750, 750, 1000, 1000, 750, 500, 900, 750], {
    'agent_intuitiveness': probe('doctor-run-first', 'One call succeeds, returns all check categories, and includes concrete remediation for failing checks.'),
    'agent_ergonomics': probe('doctor-run-first', 'SDK adaptation: one call bundles all registered checks and actionable results; no CLI mega-command ceremony required.'),
    'agent_ease_of_use': probe('doc-ogent-doctor-run', 'Callable docstring documents return plists and opt-in behavior; lacks public examples and full per-field schema.'),
    'output_parseability': source('lisp/ogent-doctor.el', 565, 'Native result list/plists expose :id/:label/:category/:status/:detail/:remediation. Structured SDK return meets 750; no contract-version/schema export for 1000.'),
    'error_pedagogy': probe('doctor-run-first', 'Crashes are contained in a status=error result, naming failure and retaining exact remediation. No generic stack trace escapes from a registered check.'),
    'intent_inference': doctor_intent_na,
    'safety_with_recovery': doctor_safety_na,
    'determinism_and_reproducibility': probe('doctor-run-first', 'Repeated controlled-input results are byte-identical; registry ordering and stable IDs preserved. This does not promise unchanged output when the diagnosed environment changes.', 'doctor-run-repeat'),
    'self_documentation': probe('doc-ogent-doctor-run', 'Native documentation exists, but field schema is in helper documentation rather than complete public method docs; no generated catalog/examples.'),
    'composability': probe('doctor-run-first', 'Native lists/plists compose directly with standard Lisp sequence/plist functions and produce no report side effect; callable in batch without prompts.'),
    'regression_resistance': source('test/ogent-doctor-tests.el', 705, 'Existing golden full-run report and registry-order assertions protect semantics; .github/workflows/ci.yml:25 tests supported Emacs 29.1/30.2. No public SDK contract-version drift guard for 1000.')
}, 'Applicability reconciliation: intent and safety n/a-as-perfect. Existing native ERT/CI tests count under SDK extension; Pass 1 does not erase tests already present. Fixture results prove deterministic ordering, not static live health state.')

add('sdk_method__doctor__batch', [1000, 900, 650, 350, 750, 1000, 1000, 750, 650, 750, 750], {
    'agent_intuitiveness': probe('doctor-batch-first', 'Canonical call prints complete report with exact repair hints and returns documented worst-health exit code.'),
    'agent_ergonomics': probe('doctor-batch-first', 'One call bundles all health checks/report/status; caller must wrap kill-emacs to map return code to process exit.'),
    'agent_ease_of_use': probe('doc-ogent-doctor-batch', 'Docstring names 0/1/2 meanings, kill-emacs wiring and opt-in behavior. No executable complete invocation example.'),
    'output_parseability': probe('doctor-batch-first', 'Native integer status is machine usable, but report side effect is human Org; full diagnostic data is unavailable as this method structured return. No JSON/schema/contract version.'),
    'error_pedagogy': probe('doctor-batch-first', 'Report preserves exact per-check fix text; check exceptions become named diagnostic errors rather than escaping stack traces.'),
    'intent_inference': doctor_intent_na,
    'safety_with_recovery': doctor_safety_na,
    'determinism_and_reproducibility': probe('doctor-batch-first', 'Controlled identical checks return byte-identical report and exit code; no wall-clock output in rendering.', 'doctor-batch-repeat'),
    'self_documentation': probe('doc-ogent-doctor-batch', 'Detailed native exit-contract documentation; lacks a generated catalog/schema and complete batch-shell example.'),
    'composability': probe('doctor-batch-first', 'Native integer status and report printing work in batch; shell failure detection requires explicit documented kill-emacs wrapper.'),
    'regression_resistance': source('test/ogent-doctor-tests.el', 207, 'Existing test asserts batch codes 0/1/2; full rendered report golden is pinned at :705 and existing required Emacs CI matrix runs it.')
}, 'Applicability reconciliation: intent and safety n/a-as-perfect. Batch human report is assessed separately from core structured-return API; fixture capture plist is the probe wrapper, not a baseline SDK feature.')

add('sdk_method__tools__bash', [750, 900, 500, 150, 150, 1000, 0, 250, 400, 500, 650], {
    'agent_intuitiveness': probe('bash-first', 'Conventional positional call executes command, captures output and reports status on first try; no next-step guide.'),
    'agent_ergonomics': probe('bash-first', 'One native call runs command with default root/timeout and collects all output; no multi-step builder required.'),
    'agent_ease_of_use': probe('doc-ogent-tool--bash', 'Docstring names arguments/defaults/stream hook, but omits examples and a structured result contract.'),
    'output_parseability': probe('bash-first', 'Opaque result string concatenates stdout/stderr/status/duration, including unsolicited stderr-process lifecycle text; no structured status return.'),
    'error_pedagogy': probe('bash-bad-timeout', 'Raw wrong-type-argument names no TIMEOUT parameter or supported correction; shell stderr provides partial failure context for valid-input commands.'),
    'intent_inference': intent_na,
    'safety_with_recovery': bash_safety,
    'determinism_and_reproducibility': source('lisp/ogent-tools.el', 643, 'Result always embeds measured elapsed duration; stream events also include timing. Two fast identical results do not establish a byte-stable general contract.'),
    'self_documentation': probe('doc-ogent-tool--bash', 'Native documentation describes inputs but not exact output grammar, errors, examples or the private-function trust boundary.'),
    'composability': probe('bash-first', 'Callable in batch without prompts, but prose result requires parsing for exit/status/streams; direct call intentionally delegates policy to caller.'),
    'regression_resistance': source('test/ogent-tools-tests.el', 113, 'Existing tests assert basic output/exit status, stderr, cwd and streaming on supported Emacs CI; no complete structured-return/schema/golden guard.')
}, 'Intent n/a: shell command-language repair is outside SDK intent. Safety applies only to direct private call, not normal approval-gated runtime; recommendation is to document/use policy owner, not invent duplicate approval or claim a new runtime vulnerability.')

async_safety = dict(bash_safety, line=648)
add('sdk_method__tools__bash-async', [750, 900, 650, 750, 250, 1000, 0, 400, 650, 700, 600], {
    'agent_intuitiveness': probe('bash-async-first', 'Conventional one-call asynchronous method emits documented stdout/stderr/done events and integer terminal status.'),
    'agent_ergonomics': probe('bash-async-first', 'One native call starts streaming execution and returns process handle; callbacks provide output without polling ceremony in application code.'),
    'agent_ease_of_use': probe('doc-ogent-tool--bash-async', 'Native docstring documents callback TYPE/DATA alternatives and input defaults; lacks full example and exact typed error variants.'),
    'output_parseability': probe('bash-async-first', 'Event tags distinguish stdout/stderr/done, status is integer and data uses native Lisp values; no output contract version or structured error variants for 1000.'),
    'error_pedagogy': probe('bash-async-timeout', '250 anchor: regular timeout names what failed but gives no correction/safe alternative. Error callback carries an opaque string, not typed timeout/validation variants. Invalid timeout also produces raw generic type text and a second done event (bash-async-bad-timeout).'),
    'intent_inference': intent_na,
    'safety_with_recovery': async_safety,
    'determinism_and_reproducibility': source('lisp/ogent-tools.el', 662, 'Random process handle names, variable stream chunk boundaries/order and timing prevent byte-stable general replay; valid callback payloads have stable tags.'),
    'self_documentation': probe('doc-ogent-tool--bash-async', 'Callback grammar is introspectable natively; no complete usage example, schema/version export or trust-boundary explanation.'),
    'composability': probe('bash-async-bad-timeout', 'Native process/callback pattern composes well for valid inputs, but invalid timeout can emit both error and done; generic errors and cap-related dropping prevent top composability anchors.'),
    'regression_resistance': source('test/ogent-tools-tests.el', 974, 'Existing native timeout test asserts exactly one error, zero done and registry cleanup; supported Emacs CI exists. Malformed-timeout terminal-once case is not pinned and fails in baseline.')
}, '250 error anchor chosen from actual failure semantics, not arithmetic averaging of prior judgments. Intent n/a. Direct-call safety 0 is confined to private helper; normal external runtime remains approval-gated. Fresh malformed-timeout double-terminal finding sent to implementation owner.')

add('verb__make__clean', [750, 750, 250, 400, 250, 0, 1000, 750, 250, 750, 0], {
    'agent_intuitiveness': makeprobe(5, 'Conventional make clean succeeds and removes generated bytecode; no rebuild next-step hint.'),
    'agent_ergonomics': makeprobe(5, 'One target removes all generated .elc files under source directories.'),
    'agent_ease_of_use': makeprobe(0, 'Top-level make help exists, but clean is omitted; no target-specific examples or cross-links.'),
    'output_parseability': makeprobe(5, 'One stable human success line and basic Make exit convention; no artifact manifest/schema.'),
    'error_pedagogy': source('Makefile', 89, 'Delegated find diagnostics name failing path; no repository-root correction or rebuild guidance.'),
    'intent_inference': source('Makefile', 131, 'Misspelled targets pass through catch-all to makem; no correction or common alias for clean.'),
    'safety_with_recovery': dict(build_safety_na, file='Makefile', line=89, target_sha=sha),
    'determinism_and_reproducibility': makeprobe(5, 'Two controlled consecutive clean invocations emit identical bytes and succeed; cleanup is idempotent.',),
    'self_documentation': makeprobe(0, 'Own help omits clean; only source comment documents deleted bytecode scope.'),
    'composability': makeprobe(5, 'Non-TTY fixture with no prompt or ANSI escapes; stable exit status, plain stdout message and normal find stderr errors.'),
    'regression_resistance': source('Makefile', 88, 'No baseline test pins clean recipe, generated-file scope or success output.')
}, 'Safety n/a-as-perfect because bytecode is regenerable; being marked mutates=true alone does not make an operation irreversible. Repeated clean evidence is rows6/7 of make transcript.')

add('verb__make__compile', [750, 750, 500, 250, 250, 0, 1000, 500, 400, 500, 0], {
    'agent_intuitiveness': makeprobe(2, 'Conventional target routes to makem compile as expected; dry-run confirms routing, not a full successful baseline compilation.'),
    'agent_ergonomics': source('makem.sh', 919, 'Single target delegates batch/all-source compilation rather than per-file agent calls; repeated granular control remains in makem.'),
    'agent_ease_of_use': makeprobe(0, 'Own help names compile and generic options/examples but no compile-specific runtime/environment example.'),
    'output_parseability': makeprobe(7, 'Recipe forwards compiler failure with Make exit2 and stderr; runtime human text has no structured artifact schema.'),
    'error_pedagogy': source('makem.sh', 948, 'Compilation errors propagate and are named, but wrapper lacks targeted dependency/runtime corrective guidance.'),
    'intent_inference': source('Makefile', 131, 'Misspelled target is delegated through catch-all; no alias/typo correction in Make wrapper.'),
    'safety_with_recovery': dict(build_safety_na, file='Makefile', line=84, target_sha=sha),
    'determinism_and_reproducibility': source('makem.sh', 837, 'Compiler/runtime environment affects generated bytecode and diagnostics; log timestamps can occur. No reproducible-output contract or controlled two-real-compile proof claimed.'),
    'self_documentation': makeprobe(0, 'Compile target and general knobs exposed; EMACS variable does not get passed to makem recipe or documented as a consistent selector.'),
    'composability': source('makem.sh', 1192, 'Automation and failure propagation exist, but makem colors by default even outside TTY and has --no-color rather than NO_COLOR detection.'),
    'regression_resistance': source('Makefile', 84, 'No baseline test pins compile recipe forwarding, runtime selector or wrapper diagnostics/schema.')
}, 'Safety n/a-as-perfect: generated bytecode only. Runtime scope is dry-run and failure forwarding with injected makem stub; no claim to have completed real compilation in this review.')

add('verb__make__offline-test', [750, 750, 500, 100, 500, 0, 1000, 250, 500, 750, 650], {
    'agent_intuitiveness': makeprobe(13, 'Missing prerequisite names exact OGENT_ELPA_DIR variable and needed directory, permitting one corrective step; stdout also contains raw Lisp traceback.'),
    'agent_ergonomics': source('test/offline/run.sh', 27, 'One target runs canonical real-dependency workflows across loopback/CLI fixtures after package prerequisites are supplied.'),
    'agent_ease_of_use': makeprobe(0, 'Make help names OGENT_ELPA_DIR prerequisite; optional pinned gptel/runtime setup is only in source/CI, not a complete help example.'),
    'output_parseability': makeprobe(13, '100 anchor adaptation: basic nonzero process status exists, but prerequisite failure dumps a raw variable-path Lisp traceback to stdout and diagnostics to stderr. No stable machine result/schema; dry-run command string is not runtime result evidence.'),
    'error_pedagogy': makeprobe(13, 'Failure names exact prerequisite correction, but raw stack trace obscures it and no dependency-install command/path recipe is supplied.'),
    'intent_inference': source('Makefile', 131, 'Unknown target spellings are forwarded; no offline-test alias or typo correction.'),
    'safety_with_recovery': source('test/offline/run.sh', 5, 'n/a — local fixture temp-root with EXIT cleanup, no irreversible user-state target; workflow transport guard test/offline/workflows.el.in:38 rejects non-loopback HTTP.'),
    'determinism_and_reproducibility': source('test/offline/run.sh', 5, 'Temporary paths/ports and ERT wall-clock timing vary; prerequisites and fixture lifecycle are bounded but output is not byte reproducible.'),
    'self_documentation': makeprobe(0, 'Own help names target/environment prerequisite; no output schema, stage catalog or complete dependency bootstrap recipe.'),
    'composability': source('test/offline/run.sh', 3, 'Batch/timeout execution and shell strict mode provide normal script failure behavior; loopback fixture EXIT cleanup prevents a normal failure leaving a live server. No non-TTY prompts or ANSI renderer required.'),
    'regression_resistance': source('.github/workflows/ci.yml', 66, 'Required offline matrix covers Emacs29.1/30.2 and minimum/current gptel; native workflow assertions pin application behavior. Harness help/preflight/stdout contract is not itself pinned, so below750.')
}, 'Disputed parseability resolved with fresh missing-prerequisite runtime, not dry-run output. Test semantic assertions and existing required dependency matrix count; no new full-success workflow run claimed. Safety n/a for isolated loopback/temporary fixtures.')

add('verb__make__recompile', [500, 750, 250, 0, 0, 0, 1000, 500, 250, 100, 0], {
    'agent_intuitiveness': makeprobe(8, 'Conventional target executes its cleanup/compile recipe, but even compiler failure reports success; first useful outcome requires independent artifact verification.'),
    'agent_ergonomics': makeprobe(3, 'Single target bundles clean plus compile, though actual success must be independently checked.'),
    'agent_ease_of_use': makeprobe(0, 'Own help omits recompile and clean; no runtime/dependency examples.'),
    'output_parseability': makeprobe(8, 'Injected compiler exit23 is discarded; Make exits0 and claims Recompiled all .el files. No trustworthy machine failure signal.'),
    'error_pedagogy': makeprobe(8, 'stderr is redirected to /dev/null and ||true suppresses compiler failure; no failure message or correction reaches agent.'),
    'intent_inference': source('Makefile', 131, 'Misspelled target delegates to makem catch-all; no alias/correction.'),
    'safety_with_recovery': dict(build_safety_na, file='Makefile', line=93, target_sha=sha),
    'determinism_and_reproducibility': source('Makefile', 94, 'Recipe/glob ordering is stable, but output claims success for multiple artifact outcomes and no reproducibility metadata exists; no two successful real-compile proof claimed.'),
    'self_documentation': makeprobe(0, 'Source comment exists; own help omits target, dependency requirements and EMACS selector.'),
    'composability': makeprobe(8, 'No prompt/ANSI but unconditional exit0 defeats shell pipeline failure detection.'),
    'regression_resistance': source('Makefile', 93, 'No baseline test pins compiler exit propagation, stderr visibility or regenerated artifact result.')
}, 'Safety n/a-as-perfect: lost bytecode can be regenerated and source files stay intact. Hidden compiler failure is scored under parseability/error/composability; it is not irreversible user-data destruction.')

for row in rows:
    for dim, score in row['scores'].items():
        assert isinstance(score, int) and 0 <= score <= 1000 and score % 50 == 0
        assert row['evidence'][dim]
    print(f"scored {row['surface_id']} as tiebreaker: weighted={row['weighted_score']}; wrote scores_pass1_{row['surface_id']}_scorertiebreaker.jsonl")
