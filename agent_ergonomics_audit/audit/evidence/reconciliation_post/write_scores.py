"""Write independent post tiebreakers from the paired source/runtime probes."""
import hashlib
import json
from pathlib import Path

out = Path(__file__).parent
audit = out.parents[1]
repo = out.parents[3]
rubric = Path('/home/agent/.claude/skills/agent-ergonomics-and-intuitiveness-maximization-for-cli-tools/references/rubric/SCORING-RUBRIC.md')
version = 'sha256:' + hashlib.sha256(rubric.read_bytes()).hexdigest()
sha = '2401f03bc5d7cd0f2915b88aede9a4444407e2b4'
dims = ['agent_intuitiveness', 'agent_ergonomics', 'agent_ease_of_use', 'output_parseability',
        'error_pedagogy', 'intent_inference', 'safety_with_recovery',
        'determinism_and_reproducibility', 'self_documentation', 'composability', 'regression_resistance']
make_rows = [json.loads(line) for line in (out / 'make_runtime.jsonl').read_text().splitlines()]
edit_rows = [json.loads(line) for line in (out / 'edit_runtime.jsonl').read_text().splitlines()]

def source(file, line, reason):
    return dict(file=file, line=line, reason=reason, target_sha=sha)

def runtime(rows, stage, probe, filename, reason):
    index, row = next((i, r) for i, r in enumerate(rows, 1)
                      if r['stage'] == stage and r['probe'] == probe)
    result = dict(file='audit/evidence/reconciliation_post/' + filename,
                  line=index, reason=reason, target_sha=sha, probe=probe)
    for key in ('invocation', 'exit_code', 'stdout', 'stderr', 'result', 'error_type', 'error_message'):
        if key in row:
            name = key + '_excerpt' if key in ('stdout', 'stderr', 'result') else key
            result[name] = row[key][:1600] if isinstance(row[key], str) else row[key]
    return result

def mr(probe, reason):
    return runtime(make_rows, 'post', probe, 'make_runtime.jsonl', reason)

def er(probe, reason):
    return runtime(edit_rows, 'post', probe, 'edit_runtime.jsonl', reason)

def write(sid, values, evidence, notes):
    scores = dict(zip(dims, values, strict=True))
    assert all(isinstance(v, int) and v % 50 == 0 and 0 <= v <= 1000 for v in values)
    assert all(evidence.get(k) for k, v in scores.items() if v > 700)
    row = dict(surface_id=sid, scorer_id='tiebreaker', rubric_version=version,
               target_sha=sha, scores=scores, weighted_score=sum(values) / 11,
               evidence=evidence, notes=notes + ' Final production freeze2401f03 differs from probed b0945bf only in an unrelated doctor docstring/test. The five scored production surfaces have an empty diff; the shared native test file adds only a doctor-docstring assertion, leaving edit/make/offline assertions unchanged.')
    path = audit / 'partial' / ('scores_pass2_' + sid + '_scorertiebreaker.jsonl')
    path.write_text(json.dumps(row, sort_keys=True) + '\n')
    print(f'scored {sid} as tiebreaker: weighted={row["weighted_score"]:.6f}; wrote {path}')

write('sdk_method__tools__edit-file',
      [750, 750, 700, 250, 750, 0, 0, 650, 750, 750, 750],
      dict(agent_intuitiveness=er('unique-first-try', 'Conventional edit function succeeds on a unique exact context.'),
           agent_ergonomics=er('explicit-replace-all', 'SDK adaptation: one native call applies all requested literal replacements; no builder ceremony.'),
           agent_ease_of_use=er('method-docstring', 'Docstring states operation and optional argument; live specs/handbook add constraints but direct docstring lacks examples.'),
           output_parseability=er('unique-first-try', 'Native result remains count/path prose, with no structured edit result type.'),
           error_pedagogy=er('ambiguous-default', 'Typed user-error names count and exact unique-context/replace_all true correction; missing/empty text additionally names read_file.'),
           intent_inference=dict(file='audit/evidence/reconciliation_post/edit_intent_runtime.jsonl', line=4,
                                 reason='SDK method-alias criterion applies: direct underscore spelling, edit-fiel typo and patch-file alternative have no binding or correction in either state; each signals generic void-function. Named registry alias/typo recovery remains a separate surface. Initial n/a inference from raw bash was overbroad and is explicitly corrected in the reconciliation appendix.', target_sha=sha),
           safety_with_recovery=er('raw-call-under-deny-policy', 'A valid raw private edit overwrites immediately even while the registered tool is denied. The wrapper separately denies and preserves bytes (rows20/21); validation is not approval/dry-run/rollback.'),
           determinism_and_reproducibility=er('unique-first-try', 'Rows9/10 are byte-identical after fixture reset. No idempotency key or native rollback; repeated mutation against changed state is not identical input.'),
           self_documentation=er('live-capabilities', 'Live spec provides arguments/types/effects/confirmation and result contract; handbook explicitly identifies raw API approval boundary.'),
           composability=er('unique-first-try', 'SDK adaptation: native string result and catchable Lisp conditions compose without terminal prompts or stream pollution; NO_COLOR/CI/TERM=dumb source probe.'),
           regression_resistance=source('test/ogent-agent-ergonomics-tests.el', 100, 'Representative assertions pin ambiguity-before-write, JSON false and unchanged file content; rows99-113 of focused_ert.stderr pass all six edit regressions. Native CI loads all test files at .github/workflows/ci.yml:55.')),
      'Independent paired probes of baseline72016bb and frozen postb0945bf. SDK extension applied. Intent0 applies to direct method-name aliases/recovery in both states; extending the earlier raw-bash n/a decision to this edit method was not justified by the SDK rubric and is explicitly corrected after a focused paired name probe. Type/context correction belongs to error pedagogy. Safety0 stays at direct trusted SDK boundary in both states: new preflight prevents ambiguity/empty/context mistakes but does not gate a valid mutation. Agent wrapper has existing separate approval/review policy, verified here. Native success is still a text string and lacks idempotency/rollback. No prior raw scorer values used to choose the initial independent scores; subsequent calibration changes are documented. See audit/rubric_reconciliation_post.md.')

common_help = mr('help', 'make help names all targets, variables including EMACS, examples, and agent discovery/JSON doctor expressions.')
safe_bytecode = dict(reason='n/a — applies to build/clean recipes that only generate/remove regenerable bytecode, with no irreversible user-state operation. Same baseline/post applicability; mutates=true alone is insufficient.')
for target, values in [
    ('clean', [750, 750, 750, 250, 250, 0, 1000, 750, 650, 750, 500]),
    ('compile', [650, 750, 750, 250, 250, 0, 1000, 250, 650, 250, 350]),
    ('recompile', [650, 750, 750, 250, 250, 0, 1000, 250, 650, 250, 500])]:
    probe = 'clean-first' if target == 'clean' else target + '-actual-makem-failure'
    evidence = dict(agent_intuitiveness=mr(probe, 'Conventional named target runs the expected recipe; controlled failure probes do not claim a newly completed real compilation.'),
                    agent_ergonomics=(mr(probe, 'One clean call covers both source and test bytecode.') if target == 'clean' else
                                      source('Makefile' if target == 'recompile' else 'makem.sh', 94 if target == 'recompile' else 930,
                                             'Single target bundles clean+standard compile, or all-source compilation; granular clean and compile remain callable. Actual wrapper failure path invoked in paired fixture.')),
                    agent_ease_of_use=common_help,
                    output_parseability=mr(probe, 'Consistent 250 build-wrapper adaptation: stable basic Make status, human output and no structured result/artifact schema. Paired clean/compile contract unchanged, apart from selected runtime/test-bytecode scope.'),
                    error_pedagogy=mr('typo-' + {'clean': 'cleen', 'compile': 'compiel', 'recompile': 'recompiel'}[target],
                                      'Wrong target names produce Invalid rule without correction; actual compiler failures say Compiling failed and provide underlying diagnostic without next action.'),
                    intent_inference=mr('typo-' + {'clean': 'cleen', 'compile': 'compiel', 'recompile': 'recompiel'}[target],
                                        'No target alias or typo correction exists; catch-all forwards the typo to actual makem.'),
                    safety_with_recovery=safe_bytecode,
                    determinism_and_reproducibility=mr(probe, 'Clean rows11/12 have byte-identical stdout/stderr and status; compile/recompile actual makem has wall-clock ANSI log messages and variable temporary paths.'),
                    self_documentation=common_help,
                    composability=mr(probe, 'Non-TTY NO_COLOR=1 CI=true TERM=dumb: clean is plain/no-prompt; actual compile/recompile honor failure status but copy compiler diagnostics to stdout and emit ANSI/timestamps to stderr, ignoring NO_COLOR.'),
                    regression_resistance=source('test/ogent-agent-ergonomics-tests.el', 359 if target == 'clean' else 348,
                                                'Focused replay passed clean/help and recompile failure assertions. Direct compile EMACS selection/output is not independently pinned by a dedicated native assertion, so compile gets only partial inherited coverage.'))
    write('verb__make__' + target, values, evidence,
          'Independent frozen postb0945bf source and paired baseline72016bb wrapper runtime with actual unchanged makem; fake Emacs writes no bytecode. Safety n/a only regenerable artifacts. Clean/compile parseability250 preserves the earlier baseline third-scorer stable-line/basic-exit adaptation, not an unearned JSON contract. Actual makem failure repeats compiler diagnostic on stdout and emits ANSI/timestamps on stderr despite NO_COLOR/CI/TERM=dumb, so clean-stub-only evidence cannot support high compile/recompile composability. Recompile now returns2 rather than baseline false-success0; its compiler diagnostic remains human. Intent typo recovery absent. See audit/rubric_reconciliation_post.md.')

write('verb__make__offline-test',
      [750, 750, 750, 250, 750, 0, 1000, 250, 650, 650, 750],
      dict(agent_intuitiveness=mr('offline-missing-prerequisite', 'First prerequisite failure gives exact environment assignment and retry command, with empty stdout and Make exit2.'),
           agent_ergonomics=source('test/offline/run.sh', 51, 'One target runs dependency-backed wire/transport/policy/store workflows, after package-directory setup; current source .github/workflows/ci.yml:94 calls this whole suite.'),
           agent_ease_of_use=common_help,
           output_parseability=mr('offline-missing-prerequisite', 'Early prerequisite contract now separates stdout/stderr and retains nonzero status. Success still emits ordinary ERT/human diagnostics; no full JSON result/schema is asserted.'),
           error_pedagogy=mr('offline-missing-prerequisite', 'Exact Set OGENT_ELPA_DIR=/path/to/installed/elpa, then run make offline-test replaces baseline stdout Lisp stack trace.'),
           intent_inference=mr('typo-ofline-test', 'Inventoried Make target still has no alias or wrong-target correction; runner -h/--help is documentation, not Make target typo inference.'),
           safety_with_recovery=source('test/offline/run.sh', 31, 'n/a — applies to isolated temporary stores, cleanup-trapped fixture processes and loopback HTTP. Current test/offline/workflows.el.in:38 rejects non-loopback transport, same as baseline; no irreversible user-state operation.'),
           determinism_and_reproducibility=mr('offline-missing-prerequisite', 'Rows20/21 preflight bytes match, but the successful ERT contract includes durations/timestamps and concurrent fixture scheduling; full suite determinism is not established by preflight repeat.'),
           self_documentation=source('test/offline/run.sh', 4, 'Runner help has environment settings/no-provider/exit dictionary, recorded in offline_help.stdout; no machine result schema for test target.'),
           composability=mr('offline-missing-prerequisite', 'Batch preflight is noninteractive, clean stdout and stderr diagnostics under NO_COLOR/CI/TERM=dumb. Complete dependency execution was not repeated here, so preflight alone does not establish every full-success stream invariant.'),
           regression_resistance=source('test/ogent-agent-ergonomics-tests.el', 457, 'Assertions pin nonzero prerequisite failure, empty stdout, exact assignment/retry hints and no stacktrace; focused_ert.stderr:119 passes. Existing required Emacs29.1/30.2 × minimum/current-gptel offline CI is .github/workflows/ci.yml:66.')),
      'Independent paired baseline/post missing-prerequisite probe confirms source-level preflight change. Safety remains n/a1000 in both states because loopback/temp fixtures are isolated; reduced post median from omitting baseline third reviewer would be sampling/applicability drift. Successful ERT output remains human and volatile; repeat identical setup failure does not prove full suite reproducibility or JSON output. Native focused contract replay9/9; no complete successful dependency matrix newly claimed by this reviewer. See audit/rubric_reconciliation_post.md.')
