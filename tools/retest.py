"""Offline local verification only. Never signs, broadcasts, or connects to an RPC."""
import argparse,hashlib,json,os,pathlib,re,shutil,subprocess,sys
ROOT=pathlib.Path(__file__).resolve().parents[1]
parser=argparse.ArgumentParser();parser.add_argument('--full',action='store_true');args=parser.parse_args()
forge=os.environ.get('FORGE') or shutil.which('forge')
solc=os.environ.get('SOLC') or shutil.which('solc')
if not forge or not solc:sys.exit('Set FORGE and SOLC to installed Foundry 1.8.5 and solc 0.8.26; this script installs nothing.')
fv=subprocess.check_output([forge,'--version'],text=True);sv=subprocess.check_output([solc,'--version'],text=True)
assert '1.8.5' in fv and '0.8.26' in sv, 'Use the audited toolchain, not a silent substitute.'
out=ROOT/'verification-output';out.mkdir(exist_ok=True)
seed='0xdf414340e80273b96b0da0b947078a573285f2d5cb8059314b94cca491a43568'
jobs=[('amsterdam',['test','--hardfork','amsterdam'])]
if args.full:
 jobs += [('cancun',['test']),('isolated-amsterdam',['test','--hardfork','amsterdam','--isolate']),('extended-fuzz',['test','--hardfork','amsterdam','--match-test','testFuzz','--fuzz-runs','4096'])]
 for filename in ['Invariants.t.sol','SystemInvariants.t.sol']:
  for name in re.findall(r'function\s+(invariant_\w+)\s*\(', (ROOT/'test'/filename).read_text()):
   jobs.append((filename.split('.')[0]+'-'+name,['test','--hardfork','amsterdam','--match-path','test/'+filename,'--match-test','^'+name+r'\(']))
 jobs.append(('mock-integration',['script','script/LocalGasPlan.s.sol:LocalGasPlan','--hardfork','amsterdam','--isolate']))
results=[]
for name,command in jobs:
 assert '--broadcast' not in command and '--rpc-url' not in command
 case_seed='0x'+hashlib.sha256(name.encode()).hexdigest() if '-invariant_' in name else seed
 cmd=[forge,*command,'--use',solc,'--offline','--json']
 with (out/(name+'.json')).open('wb')as stdout,(out/(name+'.stderr.log')).open('wb')as stderr:
  p=subprocess.run(cmd,cwd=ROOT,env=dict(os.environ,FOUNDRY_FUZZ_SEED=case_seed),stdout=stdout,stderr=stderr)
 if p.returncode:sys.exit('FAILED '+name+'; inspect verification-output')
 data=json.loads((out/(name+'.json')).read_text(encoding='utf-8'))
 if command[0]=='test':
  tests=[(n,t)for s in data.values()for n,t in s.get('test_results',{}).items()]
  assert tests and all(t['status']=='Success'for n,t in tests),name
  if name in ('amsterdam','cancun','isolated-amsterdam'):assert len(tests)==189
  if '-invariant_' in name:assert len(tests)==1
  runs=sum(t['kind'].get('Fuzz',{}).get('runs',0)for n,t in tests)
  calls=sum(t['kind'].get('Invariant',{}).get('calls',0)for n,t in tests)
  result=dict(name=name,passed=len(tests),failed=0,fuzzCases=runs,invariantCalls=calls,seed=case_seed)
 else:
  assert data['success'];actions=[]
  for phase,arena in data['traces']:
   if phase!='Execution':continue
   for node in arena['arena']:
    t=node['trace']
    if t['depth']==1 and t['kind']in ('CALL','CREATE','CREATE2') and t['caller'].lower() in {
     '0x0000000000000000000000000000000000001001','0x0000000000000000000000000000000000001002','0x0000000000000000000000000000000000001003','0x0000000000000000000000000000000000001004','0x0000000000000000000000000000000000001005','0x0000000000000000000000000000000000001006'}:
     assert t['success'];actions.append(t)
  assert len(actions)==118
  result=dict(name=name,success=True,localUnsignedActions=len(actions))
 results.append(result);print(json.dumps(result),flush=True)
(out/'summary.json').write_text(json.dumps(dict(forgeVersion=fv.strip(),solcVersion=sv.strip(),results=results),indent=2),encoding='utf-8')
subprocess.run([sys.executable,str(ROOT/'tools/verify_release.py'),'--build'],cwd=ROOT,check=True)
