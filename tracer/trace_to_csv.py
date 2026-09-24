#!/usr/bin/env python3
# trace_to_csv.py <out_base> [--symbolize <symbolizer>] [--obj 0xBASE]
#                           [--sample N] [--limit N]
#
# Streams the per-thread <base>.t*.bin files in CHUNKS (constant memory — handles
# traces far larger than RAM) and writes the alloc/access/dealloc CSV. A single
# thread's records are already in timestamp order; with several threads each file
# is emitted in turn (ordered within itself).
#
# Tame a HUGE trace without re-running it:
#   --limit 2000000    only the first 2M events  (a quick look)
#   --obj 0x7f..       only ONE object's events  (its full access pattern)
#   --sample 1000      keep 1 in 1000 ACCESSES   (allocs/frees always kept)
import sys, glob, os, bisect, subprocess, numpy as np

if len(sys.argv) < 2:
    sys.exit("usage: trace_to_csv.py <out_base> [--symbolize S] [--obj 0xB] [--sample N] [--limit N]")
base = sys.argv[1]; a = sys.argv[2:]
g = lambda k, d=None: a[a.index(k) + 1] if k in a else d
symb   = g("--symbolize")
only   = int(g("--obj"), 16) if "--obj" in a else None
sample = int(g("--sample", 1))
limit  = int(g("--limit")) if "--limit" in a else None

DT = np.dtype([("pc","<u8"),("counter","<u8"),("size","<u8"),("aux","<u8"),
               ("obj","<u8"),("ts","<u8"),("type","<u4"),("awidth","<u4")])
REC, CHUNK = DT.itemsize, 1 << 20         # read 1M records (~56 MB) at a time

# ---- module map: resolve a raw PC to module + offset ----
lo=[]; hi=[]; pth=[]
mfile = base + ".modules.txt"
if os.path.exists(mfile):
    for line in open(mfile):
        p = line.rstrip("\n").split("\t")
        if len(p) >= 3: lo.append(int(p[0],16)); hi.append(int(p[1],16)); pth.append(p[2])
order = np.argsort(lo); lo=[lo[i] for i in order]; hi=[hi[i] for i in order]; pth=[pth[i] for i in order]
def resolve(pc):
    i = bisect.bisect_right(lo, pc) - 1
    if 0 <= i and pc < hi[i]: return os.path.basename(pth[i]), pc - lo[i], pth[i]
    return "?", pc, None

TYPE = {0:"Alloc",1:"Access",2:"Dealloc"}; KIND = {0:"malloc",1:"calloc",2:"realloc",3:"free"}
cache = {}
def sym(mp, off):
    if not symb or not mp: return None
    k = (mp, off)
    if k not in cache:
        out = subprocess.run([symb, "--obj="+mp, "-f", "-C", "--output-style=LLVM"],
                             input="0x%x\n"%off, capture_output=True, text=True).stdout.splitlines()
        cache[k] = out[0] if out and out[0] not in ("", "??") else None
    return cache[k]
def pcstr(pc):
    mod, off, mp = resolve(int(pc))
    s = sym(mp, off) if symb else None
    return "%s@%s+0x%x" % (s, mod, off) if s else "%s+0x%x" % (mod, off)

files = sorted(glob.glob(base + ".t*.bin"))
if not files: sys.exit("no trace files match " + base + ".t*.bin")

# friendly heads-up before converting a huge trace with no thinning
total = sum(max(0, os.path.getsize(f) - 16) // REC for f in files)
if sample == 1 and only is None and limit is None and total > 50_000_000:
    sys.stderr.write("note: %d events and no --sample/--obj/--limit -> CSV will be ~%.0f GB.\n"
                     "      Ctrl-C and add e.g. --sample 1000  or  --obj 0x...  (see README).\n"
                     % (total, total * 70 / 1e9))

w = sys.stdout.write
written = seen = acc_seen = 0; done = False
for fn in files:
    f = open(fn, "rb"); f.read(16)               # skip 16-byte header
    while not done:
        c = np.fromfile(f, DT, count=CHUNK)
        if len(c) == 0: break
        keep = np.ones(len(c), bool)
        if only is not None: keep &= (c["obj"] == only)
        if sample > 1:                            # sample accesses only; keep allocs/frees
            isacc = c["type"] == 1
            aidx  = np.cumsum(isacc) - 1 + acc_seen
            keep &= (~isacc) | (aidx % sample == 0)
        acc_seen += int((c["type"] == 1).sum()); seen += len(c)
        for x in c[keep]:
            t = int(x["type"])
            if t == 1:
                w("%s,%d,%d,Access,0x%x,0x%x,%d\n" % (pcstr(x["pc"]), x["counter"], x["size"], x["aux"], x["obj"], x["ts"]))
            else:
                w("%s,%d,%d,%s,%s,0x%x,%d\n" % (pcstr(x["pc"]), x["counter"], x["size"], TYPE[t], KIND.get(int(x["aux"]),"?"), x["obj"], x["ts"]))
            written += 1
            if limit and written >= limit: done = True; break
        if seen % (64 * CHUNK) == 0:              # progress every ~64M events
            sys.stderr.write("\r  scanned %d events, wrote %d ..." % (seen, written)); sys.stderr.flush()
    f.close()
    if done: break
sys.stderr.write("\rwrote %d rows (scanned %d events)        \n" % (written, seen))
