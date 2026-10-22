# Straight Python port of Webamp utils.parseIni, regionParser, parseViscolors (MIT, (c) Jordan Eldredge) for reference output
import re, json, sys, os
def parseIni(text):
    data={}; section=None
    for line in re.split(r'[\r\n]+', text):
        m=re.match(r'^\s*([^;][^=]*)\s*=\s*(.*)\s*$', line)
        if m and section is not None:
            key=m.group(1).strip().lower()
            val=re.sub(r'=.*$','',m.group(2)).strip()
            val=re.sub(r'(^")|("$)|(^\')|(\'$)','',val)
            data[section][key]=val
        else:
            m2=re.match(r'^\s*\[(.+?)\]\s*$', line)
            if m2:
                section=m2.group(1).strip().lower(); data[section]={}
    return data
def regionParser(s):
    ini=parseIni(s); out={}
    for sec,d in ini.items():
        if not d.get('numpoints') or not d.get('pointlist'): continue
        counts=[v for v in re.split(r'\s*,\s*', d['numpoints']) if v!='']
        vals=[v for v in re.split(r'\s*[, ]\s*', d['pointlist']) if v!='']
        pts=[f"{vals[i]},{vals[i+1] if i+1<len(vals) else 'undefined'}" for i in range(0,len(vals),2)]
        idx=0; polys=[]
        for c in counts:
            n=int(float(c))
            if n<3: idx+=n; continue
            poly=' '.join(pts[idx:idx+n])
            if not poly: continue
            idx+=n; polys.append(poly)
        if polys: out[sec]=polys
    return out
def parseViscolors(text):
    cols=[None]*24; i=0
    for line in text.split('\n'):
        m=re.match(r'^\s*(\d+)\s*,?\s*(\d+)\s*,?\s*(\d+)', line)
        if m:
            if i < 24: cols[i]=[int(m.group(1)),int(m.group(2)),int(m.group(3))]
            i+=1
    return cols
sw=json.load(open(sys.argv[1]))
for name in sorted(sw):
    text=open(os.path.join(os.path.dirname(sys.argv[1]),name),encoding='latin-1').read()
    if name.lower().startswith('region'):
        ref=regionParser(text)
        refn=ref.get('normal',[])
        w=sw[name]['wamp_normal']; m=sw[name]['macamp']
        mn=m.get('normal',[])
        allsecs_match = all(m.get(k,[])==v for k,v in ref.items()) and all(ref.get(k,[])==v for k,v in m.items() if v)
        print(f"{name:28s} webamp[normal]={len(refn):3d} polys | wamp={'MATCH' if w==refn else 'DIFF ('+str(len(w))+')'} | macamp normal={'MATCH' if mn==refn else 'DIFF ('+str(len(mn))+')'} all-sections={'MATCH' if allsecs_match else 'DIFF'} | sections ref={sorted(ref)} macamp={sorted(k for k,v in m.items() if v)}")
    else:
        ref=parseViscolors(text)
        w=sw[name]['wamp']; m=sw[name]['macamp'][:24]; b=sw[name]['bitamp']
        def eq(a): 
            if a is None: return 'NIL(->all defaults)'
            a=[x if x!=[-1,-1,-1] else None for x in a]+[None]*(24-len(a))
            return 'MATCH' if a[:24]==ref else 'DIFF'
        print(f"{name:28s} webamp parsed={sum(1 for x in ref if x)} | wamp={eq(w)} | macamp={eq(m)} (n={len(sw[name]['macamp'])}) | bitamp={eq(b)}")
