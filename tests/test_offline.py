#!/usr/bin/env python3
"""Offline test of the analysis + codegen stages (no Linux/DynamoRIO/BOLT needed).

Builds a synthetic tracer CSV with a planted hot data stream, runs
hds_layout.py and gen_prefix.py, and compiles the generated prefix.c.

    python3 tests/test_offline.py
"""
import json
import os
import random
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SCRIPTS = os.path.join(ROOT, "scripts")


def write_synthetic_trace(path, seed=0):
    """6 objects; {1,2,3} are a hot data stream, 4 is a hot singleton."""
    rng = random.Random(seed)
    rows, ts = [], 0
    objs = [
        # id, alloc fn, kind, size
        (1, "lzma_alloc", "malloc", 1 << 16),
        (2, "lzma_alloc", "malloc", 1 << 15),
        (3, "lzma_alloc", "malloc", 1 << 14),
        (4, "lzma_alloc", "malloc", 1 << 13),
        (5, "other_init", "calloc", 1 << 10),
        (6, "other_init", "calloc", 1 << 10),
    ]
    base = {}
    for i, (oid, fn, kind, size) in enumerate(objs):
        ts += 1
        addr = 0x100000 + i * 0x100000
        base[oid] = addr
        rows.append(f"{fn}@prog+0x{100+i:x},{i+1},{size},Alloc,{kind},0x{addr:x},{ts}")

    def acc(oid, off=0):
        nonlocal ts
        ts += 1
        rows.append(f"work@prog+0x900,1,0,Access,0x{base[oid]+off:x},"
                    f"0x{base[oid]:x},{ts}")

    for _ in range(4000):
        r = rng.random()
        if r < 0.6:                      # the hot data stream
            for oid in rng.sample([1, 2, 3], 3):
                acc(oid, rng.randrange(0, 64) * 8)
        elif r < 0.85:                   # hot singleton
            acc(4, rng.randrange(0, 64) * 8)
        else:
            acc(rng.choice([5, 6]))

    for oid in (1, 2, 3, 4, 5, 6):       # free everything at the end
        ts += 1
        rows.append(f"main@prog+0xf00,1,0,Dealloc,free,0x{base[oid]:x},{ts}")

    with open(path, "w") as f:
        f.write("\n".join(rows) + "\n")


def run(cmd, **kw):
    print("  $", " ".join(cmd))
    return subprocess.run(cmd, check=True, capture_output=True, text=True, **kw)


def main():
    tmp = tempfile.mkdtemp(prefix="prefix_test_")
    trace = os.path.join(tmp, "trace.csv")
    layout = os.path.join(tmp, "layout.json")
    gen = os.path.join(tmp, "gen")

    print("1. synthetic trace")
    write_synthetic_trace(trace)

    print("2. hds_layout.py")
    out = run([sys.executable, os.path.join(SCRIPTS, "hds_layout.py"),
               "--trace", trace, "--out", layout])
    print(out.stdout.rstrip())

    L = json.load(open(layout))
    placed = [o["id"] for o in L["objects"]]
    assert L["objects"], "no objects placed"
    assert set([1, 2, 3]) <= set(placed), f"HDS {{1,2,3}} not placed: {placed}"
    # the co-accessed trio must be contiguous in the arena (that is the point)
    pos = {o["id"]: i for i, o in enumerate(L["objects"])}
    trio = sorted(pos[i] for i in (1, 2, 3))
    assert trio == list(range(trio[0], trio[0] + 3)), f"HDS not adjacent: {pos}"
    # counters must be unique per allocator and start from a sane base
    for kind in {o["kind"] for o in L["objects"]}:
        cs = [o["count"] for o in L["objects"] if o["kind"] == kind]
        assert len(cs) == len(set(cs)), f"duplicate {kind} counters: {cs}"
    print("   OK: HDS placed adjacently, counters unique")

    print("3. gen_prefix.py")
    out = run([sys.executable, os.path.join(SCRIPTS, "gen_prefix.py"),
               "--layout", layout, "--outdir", gen])
    print(out.stdout.rstrip())

    args = open(os.path.join(gen, "bolt_args.txt")).read()
    assert "--replace-memalloc=lzma_alloc:-malloc" in args, args
    assert "--replace-free=" in args and "--force-inline=" in args, args
    print("   OK: bolt_args.txt has the expected redirects")

    print("4. compile generated prefix.c")
    cc = os.environ.get("CC", "cc")
    run([cc, "-std=c11", "-O2", "-Wall", "-Wextra", "-Wno-unused-parameter",
         "-c", os.path.join(gen, "prefix.c"),
         "-o", os.path.join(gen, "prefix.o")])
    syms = subprocess.run(["nm", os.path.join(gen, "prefix.o")],
                          capture_output=True, text=True).stdout
    for w in ("malloc_wrapper", "free_wrapper"):
        assert w in syms, f"{w} missing from prefix.o:\n{syms}"
    print("   OK: prefix.c compiles and exports the wrapper symbols")

    print("5. measure.sh --compare (perf report parsing)")
    base_txt = os.path.join(tmp, "perf_baseline.txt")
    opt_txt = os.path.join(tmp, "perf_optimized.txt")
    report = """
 Performance counter stats for './bin' (10 runs):

     8,123,456,789      cycles                                    ( +-  0.21%% )
    12,345,678,901      instructions    #  1.52 insn per cycle    ( +-  0.03%% )
     1,000,000,000      L1-dcache-loads                           ( +-  0.05%% )
       %s      L1-dcache-load-misses  #  6.5%% of all accesses    ( +-  0.11%% )

       %s seconds time elapsed                             ( +-  0.18%% )
"""
    open(base_txt, "w").write(report % ("65,000,000", "2.512345678"))
    open(opt_txt, "w").write(
        report.replace("8,123,456,789", "7,731,000,000")
        % ("58,000,000", "2.398100000"))
    out = run(["bash", os.path.join(SCRIPTS, "measure.sh"),
               "--compare", base_txt, opt_txt]).stdout
    assert "speedup (cycles): 1.05" in out, out
    assert "L1D miss rate" in out, out
    assert "-10.77%" in out, out          # 65M -> 58M misses
    print("   OK: perf table parses, speedup and miss rates computed")

    print(f"\nALL OFFLINE TESTS PASSED  (artifacts in {tmp})")


if __name__ == "__main__":
    main()
