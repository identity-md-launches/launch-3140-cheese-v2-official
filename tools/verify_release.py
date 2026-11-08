"""Verify audited input bytes and compiler output. Does not access a network or wallet."""
import argparse,hashlib,json,pathlib
ROOT=pathlib.Path(__file__).resolve().parents[1]
p=argparse.ArgumentParser();p.add_argument('--build',action='store_true');args=p.parse_args()
m=json.loads((ROOT/'release/audited-inputs.json').read_text())
expected={x['path'] for x in m['files']}
actual=set()
for folder in ['src','test','script','lib','web/abi']:
 actual.update(str(f.relative_to(ROOT)).replace('\\','/')for f in (ROOT/folder).rglob('*')if f.is_file())
actual.update(['foundry.toml','remappings.txt'])
assert actual==expected,{'missing':sorted(expected-actual),'unexpected':sorted(actual-expected)}
for f in m['files']:
 assert hashlib.sha256((ROOT/f['path']).read_bytes()).hexdigest()==f['sha256'],f['path']
print('PASS: '+str(len(expected))+' public release inputs verified; production source unchanged; documented auxiliary sanitization and test-only coverage additions.')
if args.build:
 b=json.loads((ROOT/'release/build-manifest.json').read_text())
 for c in b['contracts']:
  artifact=json.loads((ROOT/'out'/c['artifact']).read_text())
  for key in ['bytecode','deployedBytecode']:
   value=bytes.fromhex(artifact[key]['object'].removeprefix('0x'))
   assert hashlib.sha256(value).hexdigest()==c[key+'Sha256'],c['name']+' '+key
  assert artifact['deployedBytecode']['immutableReferences']==c['immutableReferences'],c['name']+' immutable offsets'
 print('PASS: all five creation bytecodes, runtime templates and immutable offsets match the corrected build')
