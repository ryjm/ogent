import json,pathlib,subprocess
root=pathlib.Path('/work/agent_ergonomics_audit/audit/agent_simulations/post_pass_3/fixtures')
records=[]
for name in ['build_success','build_compile_failure','build_ert_failure']:
    source=root/name
    target=root/(name+'_container')
    target.mkdir(exist_ok=True)
    (target/'test').mkdir(exist_ok=True)
    for filename in ['audit-build.el','test/audit-build-tests.el']:
        (target/filename).write_text((source/filename).read_text())
    for cmd in [['git','init','--quiet',str(target)],['git','-C',str(target),'add','audit-build.el','test/audit-build-tests.el']]:
        r=subprocess.run(cmd,capture_output=True,text=True)
        records.append(dict(command=cmd,stdout=r.stdout,stderr=r.stderr,exit_code=r.returncode))
print(json.dumps(records,indent=2))
