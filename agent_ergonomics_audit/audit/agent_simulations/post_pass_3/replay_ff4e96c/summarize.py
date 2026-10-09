import datetime,hashlib,json,pathlib
root=pathlib.Path(__file__).resolve().parent
load=lambda name:json.loads((root/(name+'.json')).read_text())
start=load('source_sha_start')
end=load('source_sha_end')
tasks=load('task-results')
fixture='/work/agent_ergonomics_audit/audit/agent_simulations/post_pass_3/fixtures/'
expected=sorted(fixture+'glob/'+('nested/' if n%2 else '')+f'file-{n:03}.el' for n in range(105))
tasks[2]['exact_fixture_paths']=tasks[2]['paths']==expected
assert tasks[2]['exact_fixture_paths']
reports={name:json.loads(load(name)['stdout']) for name in ('build_success','build_compile_failure','build_ert_failure')}
passed=reports['build_success']
compile_failed=reports['build_compile_failure']
ert_failed=reports['build_ert_failure']
passed_counts=next(c['tests'] for c in passed['commands'] if 'tests' in c)
failed_counts=next(c['tests'] for c in ert_failed['commands'] if 'tests' in c)
compiler_location=next(d for d in compile_failed['diagnostics'] if d['file']=='audit-build.el' and d['line']==14 and d['column']==1)
ert_location=next(d for d in ert_failed['diagnostics'] if d['file']=='test/audit-build-tests.el' and d['line']==4)
build_ok=(load('build_capabilities')['exit_code']==0 and load('build_help')['exit_code']==0
          and passed['status']=='success' and load('build_success')['exit_code']==0
          and any(t['name']=='compile' and t['exit_code']==0 for t in passed['tasks'])
          and passed_counts=={'total':1,'expected':1,'unexpected':0,'skipped':0}
          and load('build_compile_failure')['exit_code']==1 and compile_failed['exit_kind']=='task_failure'
          and any(c['task']=='compile' and c['exit_code']==1 for c in compile_failed['commands'])
          and load('build_ert_failure')['exit_code']==1 and ert_failed['exit_kind']=='task_failure'
          and failed_counts=={'total':1,'expected':0,'unexpected':1,'skipped':0}
          and ert_location['column'] is None)
tasks.append({'task':9,'name':'Discover makem JSON and run actual minimal compiler/ERT success and failure',
              'replay_attempts':1,'regression_roundtrips':5,'success':build_ok,'failure_diagnosis':None,
              'actual_runner':'/work/makem.sh, production runner without replacement',
              'fixtures':'Existing independent container-owned tracked Git fixtures reused; no Git staging or commits during replay',
              'build_success_exit':load('build_success')['exit_code'],
              'compiler_failure_exit':load('build_compile_failure')['exit_code'],
              'ert_failure_exit':load('build_ert_failure')['exit_code'],
              'ert_success_counts':passed_counts,'ert_failure_counts':failed_counts,
              'parsed_compiler_location':compiler_location,'parsed_ert_location':ert_location,
              'actual_emacs_command_count':sum(len(r['commands']) for r in reports.values())})
assert start['stdout'].strip()==end['stdout'].strip()=='ff4e96c21d5fb3ffe79843fbce8392390d1c8bf4'
assert all(t['success'] is True for t in tasks)
assert load('source_worktree_start')['exit_code']==load('source_worktree_end')['exit_code']==0
command_records=[]
for name in ('source_sha_start','source_worktree_start','sdk_tasks','build_capabilities','build_help','build_success','build_compile_failure','build_ert_failure','source_worktree_end','source_sha_end'):
    r=load(name)
    assert (root/(name+'.stdout')).read_bytes().decode('utf-8',errors='replace')==r['stdout']
    assert (root/(name+'.stderr')).read_bytes().decode('utf-8',errors='replace')==r['stderr']
    assert isinstance(r['exit_code'],int)
    command_records.append({'name':name,'record':name+'.json','stdout':name+'.stdout','stderr':name+'.stderr',
                            'exit_code':r['exit_code'],'stdout_bytes':len((root/(name+'.stdout')).read_bytes()),
                            'stderr_bytes':len((root/(name+'.stderr')).read_bytes())})
iso=lambda seconds:datetime.datetime.fromtimestamp(seconds,datetime.timezone.utc).isoformat()
summary={'exercise_type':'repeated known-task regression replay after raw-byte glob and unibyte JSON repairs',
         'prior_workflow_familiarity':True,
         'pass':3,'stage':'post',
         'methodology_reference':'/home/agent/.claude/skills/agent-ergonomics-and-intuitiveness-maximization-for-cli-tools/references/methodology/PHASES.md, Phase 9; explicit parent scope is familiar replay rather than fresh-context simulation',
         'baseline_preservation':'Original post_pass_3 transcripts, summary, report, first-strategy results, and 94 canonical roundtrip metric remain unchanged. This replay is not a new fresh-agent baseline.',
         'source_sha_start':start['stdout'].strip(),'source_sha_end':end['stdout'].strip(),
         'source_sha_method':'git rev-parse HEAD plus git diff --quiet HEAD path guards only; no source, test, history, or other audit implementation inspection',
         'source_worktree_start_guard_exit':load('source_worktree_start')['exit_code'],
         'source_worktree_end_guard_exit':load('source_worktree_end')['exit_code'],
         'execution_started_at_utc':iso(start['started_unix']),
         'execution_ended_at_utc':iso(end['started_unix']+end['duration_seconds']),
         'task_definition_source':'Known nine-task published post_pass_3 replay tasks.el and summarize.py; supplied canonical_tasks_pass_3.md does not exist, older audit/canonical_tasks.md describes seven earlier tasks',
         'native_gate_or_remote_ci_claim':False,
         'tasks':tasks,'totals':{'canonical_tasks':9,'actual_successful_tasks':sum(t['success'] is True for t in tasks),
                                'regression_roundtrips':sum(t['regression_roundtrips'] for t in tasks)},
         'roundtrip_definition':'One public SDK method invocation or makem capability/help/task invocation. Setup, transcript packaging, and source SHA probes excluded. No fresh first-strategy metric assigned.',
         'environment':{'container':'ogent-fixes','emacs':'30.2','mount':'/work','search_backend':'observed GNU grep fallback',
                        'source_loading':'Protected /work/test/ogent-test-helper.el; -Q --batch with lisp/lisp-ui/test/test-ui load paths; require ogent',
                        'registry':'Public tool specs already populated; no fixture registry installation needed during replay'},
         'public_inputs':['Known prior public guide (not re-read this replay)','README.org canonical read task','public SDK discovery/runtime/docstrings','makem --capabilities --json','makem --help'],
         'parser_limits_rechecked':{'prior_invalid_source_location_limit_fixed':True,'prior_ert_location_limit_fixed':True,
                                    'compiler_file':'audit-build.el','compiler_line':14,'compiler_column':1,
                                    'ert_file':'test/audit-build-tests.el','ert_line':4,'ert_column':None,
                                    'note':'ERT emitted file/line only, so null column is correct.'},
         'safety_results':{'sdk_prompt_count':0,'unsafe_batch_read_count':0,'shell_mutation':False,'write_mutation':False,
                           'policy_configuration_changed':False,'provider_login_or_inference':False,
                           'commits_or_staging':False,'full_project_build_test_compile':False},
         'limits':['This replay reused known public workflow and existing fixtures; familiarity makes it unsuitable as a fresh discovery baseline.',
                   'Actual production SDK source loaded via protected helper, which may supply gptel doubles; no live provider transport/registration proof.',
                   'Observed GNU grep fallback only; no ripgrep branch execution in this replay.',
                   'Only independent minimal tracked fixture projects compiled and ran ERT. Root owns broad native validation.'],
         'transcripts':command_records,
         'transcript_format':'Each record contains complete argv/cwd/timing/stdout/stderr/exit_code, with byte-complete stdout/stderr companion files. SDK stdout logs full FORM/RESULT/CALLBACK values; no retained output truncation.',
         'final_state':'complete'}
summary.update({'preserved_interim_replays':['../replay_90818f8/','../replay_9ac13b2/','../replay_967eb05/','../replay_10f86bb/','../replay_a2fa8ce/','../replay_021cca4/'],
                'fresh_discovery_or_efficiency_claim':False,
                'original_fresh_metrics_preserved':{'tasks':9,'successful':9,'first_strategy_successful':7,'canonical_roundtrips':94},
                'observed_intentional_failure_causes':{'compiler':'Owned fixture has an unmatched closing parenthesis at audit-build.el:14:1; actual compiler exited 1.',
                                                       'ert':'Owned fixture expects 3 from audit-build-add(1,1), which returns 2; actual ERT runner reported one unexpected failure and exited 1.'}})
manifest=json.loads((root/'preservation_manifest.json').read_text())
for relative,digest in manifest['historical_artifact_byte_hashes'].items():
    assert hashlib.sha256((root.parent/relative).read_bytes()).hexdigest()==digest,relative
summary['artifact_preservation']={'manifest':'preservation_manifest.json','prior_final_freeze_archive':'../replay_021cca4/','prior_final_freeze_complete_file_count':manifest['prior_final_freeze_file_count'],'historical_artifact_file_count':manifest['historical_artifact_file_count'],'historical_artifacts_byte_unchanged':True}
summary['build_invocation_scope']='Production makem.sh directly invoked in independent tracked Git fixture projects; no Makefile invocation or broad native gate claimed.'
(root/'summary.json').write_text(json.dumps(summary,ensure_ascii=False,indent=2)+'\n')
print(json.dumps({'source_sha':summary['source_sha_end'],**summary['totals'],'transcript_validation':'complete stdout/stderr/argv/exit records verified'},indent=2))
