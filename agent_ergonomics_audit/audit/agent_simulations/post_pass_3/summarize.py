import json,pathlib
root=pathlib.Path(__file__).resolve().parent
load=lambda name:json.loads((root/(name+'.json')).read_text())
def task_from(name):
    return json.loads((root/(name+'.stdout')).read_text().split('TASK_SUMMARY ',1)[1].strip())
tasks=load('task-results')
tasks[2]['exact_fixture_paths']=tasks[2]['paths']==load('fixture-manifest')['glob_paths']
assert tasks[2]['exact_fixture_paths']
tasks[6]=task_from('task7_after_freeze') if (root/'task7_after_freeze.stdout').exists() else task_from('task7_retry')
reports={name:json.loads(load(name)['stdout']) for name in ('build_success_retry','build_compile_failure_retry','build_ert_failure_retry')}
success_report=reports['build_success_retry']
compile_report=reports['build_compile_failure_retry']
ert_report=reports['build_ert_failure_retry']
ert_success=next(c['tests'] for c in success_report['commands'] if 'tests' in c)
ert_failure=next(c['tests'] for c in ert_report['commands'] if 'tests' in c)
ok=(load('build_success_retry')['exit_code']==0 and success_report['status']=='success'
    and success_report['tasks'][0]['name']=='compile' and success_report['tasks'][0]['exit_code']==0
    and ert_success['total']==1 and ert_success['expected']==1 and ert_success['unexpected']==0
    and load('build_compile_failure_retry')['exit_code']==1 and compile_report['exit_kind']=='task_failure'
    and any(c['task']=='compile' and c['exit_code']!=0 for c in compile_report['commands'])
    and load('build_ert_failure_retry')['exit_code']==1 and ert_report['exit_kind']=='task_failure'
    and ert_failure['total']==1 and ert_failure['unexpected']==1)
tasks.append({'task':9,'name':'Discover real makem JSON and run actual minimal compiler/ERT success and failure',
              'success':ok,'attempts':2,'roundtrips':8,'first_strategy_success':False,
              'failure_diagnosis':'Initial host-created fixture Git repositories had different ownership from the Docker runner. makem returned missing_prerequisite exit3 before invoking Emacs. Recreated fixture Git repositories from within Docker; no Git or ogent approval policy changed.',
              'capabilities_exit':load('build_capabilities')['exit_code'],
              'successful_build_exit':load('build_success_retry')['exit_code'],
              'compile_failure_exit':load('build_compile_failure_retry')['exit_code'],
              'ert_failure_exit':load('build_ert_failure_retry')['exit_code'],
              'ert_success_counts':ert_success,'ert_failure_counts':ert_failure,
              'actual_command_count':sum(len(r['commands']) for r in reports.values()),
              'actual_runner':'/work/makem.sh (repository production runner, not replaced)',
              'fixture_tracking':'Independent fixture Git repositories with staged Elisp files, no commits'})
records=[f.stem for f in sorted(root.glob('*.json')) if 'command' in json.loads(f.read_text())]
summary={
 'source_sha':load('source_sha')['stdout'].strip(),
 'source_sha_method':'git rev-parse HEAD only; no history or production/test implementation inspection',
 'source_sha_after_freeze':load('source_sha_after_freeze')['stdout'].strip() if (root/'source_sha_after_freeze.json').exists() else None,
 'environment':{'container':'ogent-fixes','emacs':'30.2','project_mount':'/work','host_root':'/workspace/ogent',
                'source_loader':'emacs -Q --batch -L /work/lisp -L /work/lisp/ui -L /work/test -L /work/test/ui -l /work/test/ogent-test-helper.el -l HARNESS',
                'search_backend_observed':'gnu-grep-null; rg not available'},
 'source_blind_inputs':['AGENTS.md repository instructions','README.org','docs/agent-ergonomics.org','public runtime capability/descriptions/docstrings','makem.sh --capabilities --json','makem.sh --help'],
 'registry_setup':'Public registry was already populated after require ogent. Discovery transcript explicitly called ogent-tools-install-defaults in protected fixture process only; it returned nil.',
 'tasks':tasks,
 'totals':{'tasks':len(tasks),'successful':sum(t['success'] is True for t in tasks),
           'first_strategy_successful':sum(t['first_strategy_success'] is True for t in tasks),
           'canonical_roundtrips':sum(t['roundtrips'] for t in tasks)},
 'roundtrip_definition':'One public SDK method invocation or makem capability/help/task invocation. Setup requires, fixture construction, host transcript recording, and initial broad discovery are excluded. Task7 includes reruns. Task9 has 2 discovery invocations plus 6 real build invocations across 2 fixture strategies.',
 'observations':[
  {'kind':'contract_confusion','task':7,'details':'The guide named batch result fields, but the reader expected every tool result to keep payloads inside :data. Initial batch runtime success was obscured by that verifier assumption. Original and corrected top-level observations are preserved. Parent requested common-envelope alignment and a frozen-source rerun.'},
  {'kind':'lazy_loading','task':8,'details':'documentation for ogent-tool-process-cancel raised void-function before the first async call. The async call loaded support; documented cancellation then worked and produced exactly one cancelled callback.'},
  {'kind':'environment_setup','task':9,'details':'Cross-boundary fixture Git ownership caused missing_prerequisite exit3, correctly separated from real compiler/test failures. Container-owned fixtures resolved setup without modifying safety policy.'},
  {'kind':'reporting_limit','task':9,'details':'Malformed source compiler output carries invalid-read location in message; that source error has no standalone structured location diagnostic. The dependent test compilation has parsed file:line:column. ERT failure message includes at test/audit-build-tests.el:4 but its structured diagnostic file/line/column are null.'},
  {'kind':'harness_setup','details':'The first recorder argparse configuration did not accept command options such as --version. Corrected to argparse.REMAINDER before canonical task invocations.'}
 ],
 'validation_limits':['Actual production SDK source loaded through the protected test helper; gptel may be doubles supplied by that helper. This does not verify real model-facing gptel transport or registration.',
                      'No provider login or inference occurred. Read-only search used observed GNU grep fallback, so this exercise does not establish the ripgrep branch.',
                      'Only isolated tracked fixture projects were compiled/tested; no broad project compilation or test suite was run.',
                      'Other task evidence predates the parent batch-envelope alignment; only task7 is rerun after freeze as requested.'],
 'safety_evidence':{'sdk_prompt_count':0,'unsafe_batch_read_count':0,'shell_file_mutated':False,'write_file_mutated':False,
                    'changes':'Harness and evidence only under post_pass_3; ignored fixtures; no commits/Beads/provider logins/inference/safety-policy changes'},
 'command_transcripts':records,
 'transcript_format':'Each command has .json with argv,cwd,timing,stdout,stderr,exit_code plus exact .stdout/.stderr files. Emacs transcript FORM/RESULT/CALLBACK entries preserve exact public forms and returned values; intentional errors and retries remain recorded.',
 'final_state':'complete' if (root/'task7_after_freeze.stdout').exists() else 'awaiting parent source-freeze notice for task7 rerun'
}
(root/'summary.json').write_text(json.dumps(summary,ensure_ascii=False,indent=2)+'\n')
print(json.dumps(summary['totals']|{'final_state':summary['final_state']},indent=2))
