import csv, sys
d = sys.argv[1]
T = [dict((k, float(v)) for k, v in r.items()) for r in csv.DictReader(open(d + "/ticks.csv"))]
M = [{k: (float(v) if v != 'nan' else None) for k, v in r.items()} for r in csv.DictReader(open(d + "/monitor.csv"))]
posA = lambda r: (r + 0.9) / 1.8 * 60
posB = lambda r: (0.9 - r) / 1.8 * 30
def first(cond, a):
    for t in T:
        if t['t'] >= a and cond(t): return t
for tc, target in [(8.003, 40), (14.010, 10)]:
    nw = first(lambda t: t['consumed'] > 0 and abs(posA(t['rFirst']) - target) < 3, tc)
    stale = sum(t['consumed'] for t in T if tc <= t['t'] < nw['t'])
    sil = sum(t['underrun'] for t in T if tc <= t['t'] <= nw['t'])
    print(f"seek {target} (discard until SEEK event): new audio after {nw['t']-tc:.3f} s, stale consumed {stale/48000:.3f} s, silence {sil/48000:.3f} s, first new pos {posA(nw['rFirst']):.4f} (head lost {posA(nw['rFirst'])-target:+.4f} s)")
tc = 20.003
nw = first(lambda t: t['consumed'] > 0 and t['rFirst'] > t['rLast'] + 1e-6, tc)
stale = sum(t['consumed'] for t in T if tc <= t['t'] < nw['t'])
print(f"loadfile b (discard until END_FILE): B after {nw['t']-tc:.3f} s, stale A {stale/48000:.3f} s, first B pos {posB(nw['rFirst']):.4f}")
b0 = [t for t in T if 25 < t['t'] < 26.01 and t['consumed'] > 0][-1]
b1 = first(lambda t: t['consumed'] > 0, 29.0)
print(f"pause/resume with headroom: pos before {posB(b0['rLast']):.4f} after {posB(b1['rFirst']):.4f}; max ring fill during pause {max(t['fill'] for t in T if 26 < t['t'] < 29)/48000:.3f} s")
lat = sorted(m['latency_ms'] for m in M if 2 < m['t'] < 7.9)
print(f"get_property latency (normal play, 100 ms target ring): p50 {lat[len(lat)//2]:.1f} ms max {lat[-1]:.1f} ms n={len(lat)}")
un = sum(t['underrun'] for t in T if 2 < t['t'] < 7.9)
print("underruns normal play:", un)
