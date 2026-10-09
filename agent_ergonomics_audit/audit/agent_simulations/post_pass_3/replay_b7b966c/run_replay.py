import hashlib,json,pathlib,subprocess,sys
root=pathlib.Path(__file__).resolve().parent
expected='b7b966c6ac5acc15d15c8ea0c70d81653072cae9'
for name,command in json.loads((root/'run_commands.json').read_text()):
    result=subprocess.run([sys.executable,str(root/'record.py'),name,*command],capture_output=True,text=True)
    if result.returncode:
        print(result.stdout); print(result.stderr,file=sys.stderr); sys.exit(result.returncode)
    record=json.loads((root/(name+'.json')).read_text())
    allowed=1 if name in ['build_compile_failure','build_ert_failure'] else 0
    print(json.dumps({'record':name,'exit':record['exit_code'],'expected_exit':allowed,'stdout_bytes':len((root/(name+'.stdout')).read_bytes()),'stderr_bytes':len((root/(name+'.stderr')).read_bytes())}),flush=True)
    assert record['exit_code']==allowed,(name,record['exit_code'])
    if name in ['source_sha_start','source_sha_end']:
        assert record['stdout'].strip()==expected,(name,record['stdout'])
subprocess.run([sys.executable,str(root/'summarize.py')],check=True)
manifest=json.loads((root/'preservation_manifest.json').read_text())
for relative,digest in manifest['historical_artifact_byte_hashes'].items():
    assert hashlib.sha256((root.parent/relative).read_bytes()).hexdigest()==digest,relative
manifest['historical_artifacts_verified_unchanged_after_replay']=True
(root/'preservation_manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
print(json.dumps({'historical_artifacts_unchanged':len(manifest['historical_artifact_byte_hashes']),'prior_final_freeze_archived_complete':manifest['prior_final_freeze_file_count']}),flush=True)
