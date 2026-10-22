import csv, sys, statistics as st
d = sys.argv[1]
T = [dict((k, float(v)) for k, v in r.items()) for r in csv.DictReader(open(d + "/ticks.csv"))]
M = []
for r in csv.DictReader(open(d + "/monitor.csv")):
    M.append({k: (float(v) if v != 'nan' else None) for k, v in r.items()})
posA = lambda r: (r + 0.9) / 1.8 * 60
posB = lambda r: (0.9 - r) / 1.8 * 30
def win(a, b): return [t for t in T if a <= t['t'] < b]
# 1 steady rate
w = win(5, 25)
br = sum(t['bytesRead'] for t in w); co = sum(t['consumed'] for t in w); un = sum(t['underrun'] for t in w)
print(f"steady 5-25 s: pipe read {br/20:.0f} B/s (real-time = 384000), consumed {co/20:.1f} frames/s, underrun frames {un:.0f}")
# per-second read rate distribution
per = []
for s in range(5, 25):
    per.append(sum(t['bytesRead'] for t in win(s, s + 1)))
print("  per-second bytes read min/max:", min(per), max(per))
# bursts: max bytes in one tick
print("  max bytes read in one 10 ms tick:", max(t['bytesRead'] for t in w), " ring fill mean", st.mean(t['fill'] for t in w))
# 2 lead time-pos vs consumer position
mw = [m for m in M if 5 <= m['t'] < 25 and m['timepos'] is not None]
leads = [m['timepos'] - posA(m['lastR']) for m in mw]
print(f"time-pos minus consumed position 5-25 s: mean {st.mean(leads):.3f} s, min {min(leads):.3f}, max {max(leads):.3f}")
lat = sorted(m['latency_ms'] for m in mw)
print(f"get_property(time-pos) latency 5-25 s: p50 {lat[len(lat)//2]:.2f} ms, p90 {lat[int(len(lat)*.9)]:.1f} ms, max {lat[-1]:.1f} ms, n={len(lat)}")
# time-pos update cadence: distinct values per second
tps = [m['timepos'] for m in mw]
steps = [b - a for a, b in zip(tps, tps[1:]) if b != a]
print(f"  time-pos changes between 100ms samples: {len(steps)} of {len(tps)-1}; step sizes min {min(steps):.3f} max {max(steps):.3f} s")
# 4 pause (a) at 25.004
def first(cond, a, b=1e9):
    for t in T:
        if a <= t['t'] < b and cond(t): return t
    return None
pa = 25.004
u = first(lambda t: t['underrun'] > 0, pa)
cons_after = sum(t['consumed'] for t in T if pa <= t['t'] < (u['t'] if u else pa))
print(f"pause(a) mpv-only @25.004: consumer kept receiving audio for {u['t']-pa:.3f} s ({cons_after/48000:.3f} s of audio) before underrun")
lastdata = max(t['t'] for t in T if pa <= t['t'] < 28 and t['bytesRead'] > 0)
print(f"   last pipe bytes during pause at t={lastdata:.3f} (pause cmd returned at 26.944)")
res = first(lambda t: t['bytesRead'] > 0, 28.0)
print(f"   unpause @28.010: first pipe data at {res['t']:.3f}")
lastpos = [t for t in T if 24 < t['t'] < 28 and t['consumed'] > 0][-1]
firstpos = first(lambda t: t['consumed'] > 0, 28.0)
print(f"   source pos at last consumed before resume {posA(lastpos['rLast']):.4f}, first after {posA(firstpos['rFirst']):.4f} (continuity)")
# 5 pause (b)
b0 = [t for t in T if 32 < t['t'] < 33.004 and t['consumed'] > 0][-1]
b1 = first(lambda t: t['consumed'] > 0, 33.004)
print(f"pause(b) consumer stop @33.004 / resume 36.006: pos before {posA(b0['rLast']):.4f}, after {posA(b1['rFirst']):.4f} at t={b1['t']:.3f}")
und_b = sum(t['underrun'] for t in win(36.0, 40))
print(f"   underrun frames 36-40 s: {und_b}")
# 6 seeks
for (tc, target, label) in [(40.004, 10, "no flush"), (46.010, 40, "flush after cmd"), (52.001, 10, "flush on playback-restart"), (58.007, 40, "flush on seek event")]:
    nw = first(lambda t: t['consumed'] > 0 and abs(posA(t['rFirst']) - target) < 3, tc)
    stale = sum(t['consumed'] for t in T if tc <= t['t'] < nw['t'] and t['consumed'] > 0)
    silence = sum(t['underrun'] for t in T if tc <= t['t'] < nw['t'] + 0.5)
    # stale after new
    late = [t for t in T if nw['t'] < t['t'] < tc + 5.5 and t['consumed'] > 0 and abs(posA(t['rFirst']) - target) > 6]
    print(f"seek {target} ({label}) @{tc}: new audio reaches consumer after {nw['t']-tc:.3f} s; stale audio consumed {stale/48000:.3f} s; "
          f"underrun {silence/48000:.3f} s; first new pos {posA(nw['rFirst']):.4f} (head lost {posA(nw['rFirst'])-target:+.4f} s); stale-after-new ticks {len(late)}")
# 7 loadfile b
tc = 64.010
nw = first(lambda t: t['consumed'] > 0 and t['rFirst'] > t['rLast'] + 1e-6, tc)
stale = sum(t['consumed'] for t in T if tc <= t['t'] < nw['t'])
print(f"loadfile b (flush on end-file) @64.010: B reaches consumer after {nw['t']-tc:.3f} s, stale A consumed {stale/48000:.3f} s, first B pos {posB(nw['rFirst']):.4f}")
# 8 stuck reader
u = sum(t['underrun'] for t in win(70, 75.5))
print(f"stuck reader 70-75: underrun {u/48000:.2f} s; monitor samples with latency >1 s:",
      [(round(m['t'],2), round(m['latency_ms'])) for m in M if 69 < m['t'] < 77 and m['latency_ms'] > 1000])
# EOF tail
tail = [t for t in T if 95 < t['t'] < 101 and t['consumed'] > 0]
print(f"b.wav tail: last consumed B pos {posB(tail[-1]['rLast']):.4f} s at t={tail[-1]['t']:.3f} (file length 30 s)")
