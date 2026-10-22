import re, json, sys
src = open(sys.argv[1]).read()
flat = re.sub(r'\s+', ' ', src)
# sheets
out = {}
for m in re.finditer(r'([A-Z_]+): \[(.*?)\],', flat):
    sheet = m.group(1)
    for s in re.finditer(r'\{ name: "([A-Z0-9_]+)", x: (\d+), y: (\d+), width: (\d+), height: (\d+),? \}', m.group(2)):
        out[s.group(1)] = dict(sheet=sheet, x=int(s.group(2)), y=int(s.group(3)), w=int(s.group(4)), h=int(s.group(5)))
json.dump(out, open(sys.argv[2], 'w'), indent=0, sort_keys=True)
from collections import Counter
print(len(out), Counter(v['sheet'] for v in out.values()))
