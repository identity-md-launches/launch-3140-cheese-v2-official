"""Create a deterministic source ZIP and SHA-256 manifest from a local Git commit.

ZIP_STORED, fixed timestamps, file attributes and ordering avoid zlib/platform
differences. Reads committed blobs, not untracked build output. No network access.
"""
import argparse,hashlib,io,json,pathlib,subprocess,tarfile,zipfile
ROOT=pathlib.Path(__file__).resolve().parents[1]
p=argparse.ArgumentParser();p.add_argument('--commit',default='HEAD');p.add_argument('--output',default='release-output');args=p.parse_args()
commit=subprocess.check_output(['git','rev-parse','--verify',args.commit+'^{commit}'],cwd=ROOT,text=True).strip()
raw=subprocess.check_output(['git','archive','--format=tar',commit],cwd=ROOT)
out=(ROOT/args.output).resolve();out.mkdir(parents=True,exist_ok=True)
archive=out/'cheese-v2-source.zip';files=[]
with tarfile.open(fileobj=io.BytesIO(raw),mode='r:') as source,zipfile.ZipFile(archive,'w',compression=zipfile.ZIP_STORED) as dest:
 for entry in sorted(source.getmembers(),key=lambda e:e.name.encode('utf-8')):
  if entry.isdir():continue
  assert entry.isfile(),'Unsupported symlink or special file: '+entry.name
  name=entry.name
  assert not name.startswith('/') and '..' not in pathlib.PurePosixPath(name).parts
  data=source.extractfile(entry).read()
  z=zipfile.ZipInfo('cheese-v2/'+name,date_time=(2000,1,1,0,0,0));z.create_system=3
  z.external_attr=((0o100755 if entry.mode & 0o111 else 0o100644)<<16)
  z.compress_type=zipfile.ZIP_STORED
  dest.writestr(z,data)
  files.append(dict(path=name,bytes=len(data),sha256=hashlib.sha256(data).hexdigest()))
manifest=dict(format='fixed-metadata ZIP_STORED; UTF-8 byte-sorted Git blobs; prefix cheese-v2/',handoffCommit=commit,auditedCommit='5782775a026662324f0765ea89689afd911741fc',archive=archive.name,archiveBytes=archive.stat().st_size,archiveSha256=hashlib.sha256(archive.read_bytes()).hexdigest(),files=files)
(out/'source-checksums.json').write_bytes((json.dumps(manifest,indent=2,ensure_ascii=False)+'\n').encode())
print(json.dumps({k:v for k,v in manifest.items() if k!='files'}))
