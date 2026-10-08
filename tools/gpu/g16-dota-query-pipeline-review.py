#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Read Dota trace query calls and exact exported SPIR-V matches in Fossilize."""
import argparse, collections, json, mmap, struct, zlib
from pathlib import Path
p=argparse.ArgumentParser(description=__doc__)
p.add_argument('--trace',type=Path,required=True)
p.add_argument('--foz',type=Path,required=True)
p.add_argument('--draw',type=Path,required=True)
p.add_argument('--output',type=Path,required=True)
a=p.parse_args();a.output.mkdir(parents=True,exist_ok=True)
counts=collections.Counter();queries=[];frames=[];rows=0;in_state=False
with a.trace.open() as f:
 for line in f:
  r=json.loads(line);rows+=1
  if 'state' in r:in_state=r['state']['marker_type']=='BeginMarker'
  if 'frame' in r:frames.append(r['frame']['frame_number'])
  fn=r.get('function')
  if fn:
   name=fn['name'];counts[name]+=1
   if 'Query' in name:queries.append({'index':r.get('index'),'state_reconstruction':in_state,**fn})
(a.output/'trace-query-summary.json').write_text(json.dumps({'source':str(a.trace),'rows':rows,'frames':frames,'query_calls':queries,'query_call_count':len(queries),'counts':dict(counts)},indent=2)+'\n')
print('trace rows',rows,'frames',frames,'query calls',len(queries),flush=True)
def encode(data):
 result=bytearray()
 for word, in struct.iter_unpack('<I',data):
  while word>127:result.append((word&127)|128);word>>=7
  result.append(word)
 return bytes(result)
targets={role:(a.draw/(role+'.spv')).read_bytes() for role in ['vertex','fragment']}
encoded={role:encode(data) for role,data in targets.items()}
module_matches={role:[] for role in targets};rp={};pipelines={};tags=collections.Counter()
with a.foz.open('rb') as f:
 m=mmap.mmap(f.fileno(),0,access=mmap.ACCESS_READ)
 assert m[:12]==b'\x81FOSSILIZEDB'
 def entries():
  pos=16
  while pos<len(m):
   assert pos+56<=len(m),('truncated header',pos)
   name=m[pos:pos+40].decode();size,fmt,crc,usize=struct.unpack_from('<4I',m,pos+40);start=pos+56
   assert start+size<=len(m),('truncated payload',pos)
   yield int(name[:-16],16),name[-16:],start,size,fmt,usize
   pos=start+size
 def payload(start,size,fmt,usize):
  data=m[start:start+size]
  assert fmt in [1,2],fmt
  if fmt==2:data=zlib.decompress(data)
  assert len(data)==usize
  return data
 for tag,h,start,size,fmt,usize in entries():
  tags[tag]+=1
  if tag not in [4,5]:continue
  data=payload(start,size,fmt,usize)
  if tag==5:rp.update(json.loads(data.split(b'\0',1)[0]).get('renderPasses',{}));continue
  header,sep,binary=data.partition(b'\0');doc=json.loads(header)
  for key,info in doc.get('shaderModules',{}).items():
   for role,target in targets.items():
    if info['codeSize']!=len(target):continue
    if 'varintSize' in info:
     match=binary[info['varintOffset']:info['varintOffset']+info['varintSize']]==encoded[role]
    else:
     import base64
     match=base64.b64decode(info['code'])==target
    if match:module_matches[role].append(key)
 print('exact SPIR-V matches',module_matches,flush=True)
 needles=[key.encode() for keys in module_matches.values() for key in keys]
 if needles:
  for tag,h,start,size,fmt,usize in entries():
   if tag!=6:continue
   data=payload(start,size,fmt,usize)
   if not any(needle in data for needle in needles):continue
   doc=json.loads(data.split(b'\0',1)[0]);pipelines.update(doc.get('graphicsPipelines',{}))
 wanted={stage['module'] for pipeline in pipelines.values() for stage in pipeline.get('stages',[])}
 candidate_dir=a.output/'candidate-shaders';candidate_dir.mkdir(exist_ok=True)
 for tag,h,start,size,fmt,usize in entries():
  if tag!=4 or h not in wanted:continue
  header,sep,binary=payload(start,size,fmt,usize).partition(b'\0');doc=json.loads(header)
  for key,info in doc['shaderModules'].items():
   if 'varintSize' in info:
    data=binary[info['varintOffset']:info['varintOffset']+info['varintSize']]
    words=[];value=shift=0
    for byte in data:
     value|=(byte&127)<<shift
     if byte&128:shift+=7
     else:words.append(value);value=shift=0
    assert shift==0 and len(words)*4==info['codeSize']
    spv=struct.pack('<'+'I'*len(words),*words)
   else:
    import base64
    spv=base64.b64decode(info['code'])
   (candidate_dir/(key+'.spv')).write_bytes(spv)
 m.close()
renderpass_keys={info.get('renderPass') for info in pipelines.values()}
summary={'source':str(a.foz),'counts':dict(tags),'exact_module_matches':module_matches,'matched_pipeline_count':len(pipelines),'graphicsPipelines':pipelines,'renderPasses':{h:info for h,info in rp.items() if h in renderpass_keys}}
(a.output/'fossilize-exact-spv-pipelines.json').write_text(json.dumps(summary,indent=2)+'\n')
print('pipelines',len(pipelines),'render passes',len(summary['renderPasses']),flush=True)
