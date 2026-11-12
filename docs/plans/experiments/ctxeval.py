import sys, subprocess, re, os, warnings
warnings.filterwarnings("ignore")
import jieba, logging
jieba.setLogLevel(logging.ERROR)
from pypinyin import lazy_pinyin
S=os.path.dirname(os.path.abspath(__file__))
sents=[l.strip() for l in open(sys.argv[2]) if l.strip() and not l.startswith('#')]
cases=[]; whole=[]
for s in sents:
    ws=list(jieba.cut(s, HMM=False))
    whole.append(("".join(lazy_pinyin(s)).replace("ü","v"), s))
    for i in range(1,len(ws)):
        cases.append(("".join(ws[:i]), "".join(lazy_pinyin(ws[i])).replace("ü","v"), ws[i]))
def run(args):
    out=subprocess.run([S+"/run.sh", sys.argv[1]]+args,capture_output=True,text=True).stdout
    res=[]
    for line in out.splitlines():
        m=re.match(r"^\S+ \[[^\]]*\]: 1\.(.*?)[句词首原]( |$)", line)
        res.append(m.group(1) if m else "")
    return res
hit=0; miss=[]
args=[]
for c in cases: args += ["ctx="+c[0], c[1]]
flat=run(args)
results=[[x] for x in flat]
for (ctx,py,exp),r in zip(cases,results):
    if r and r[0]==exp: hit+=1
    else: miss.append(f"{ctx}|{py}->{r[0] if r else ''}(want {exp})")
print(f"context word-by-word top1: {hit}/{len(cases)} = {hit/len(cases):.1%}")
r=run(["ctx="]+[p for p,_ in whole]); h=sum(1 for a,(_,s) in zip(r,whole) if a==s)
print(f"whole sentence top1: {h}/{len(whole)} = {h/len(whole):.1%}")
open(sys.argv[3],"w").write("\n".join(miss))
