#!/usr/bin/env python3
"""Trace Analysis: trace -> HDS & Hot Singleton objects -> heap layout.

The "Trace Analysis" box of Figure 8. Reads the DynamoRIO allocation/free/access
trace, runs the PreFix HDS Finder and HDS Reconstitution, and writes
`layout.json` describing where each object should live in the preallocated
memory region: the Reconstituted HDS (RHDS) first, then the Hot Singleton
objects.

Tracer CSV columns (no header):
    PC, counter, size, TYPE, aux, OBJBASE, ts
      TYPE=Alloc    aux = malloc|calloc|realloc   OBJBASE = returned pointer
      TYPE=Access   aux = accessed address        OBJBASE = owning object
      TYPE=Dealloc  aux = free                    OBJBASE = freed pointer

Usage:
    python3 hds_layout.py --trace trace.csv --out layout.json
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import re
from collections import Counter

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from hds import HDSConfig, prefix_layout  # noqa: E402

ALLOC_KINDS = ("malloc", "calloc", "realloc")

# Arena packing granularity (see main()).
ALIGN = 8


def pc_function(pc: str) -> str:
    """'func@mod+0x12' -> 'func';  'mod+0x12' -> '' (unsymbolized)."""
    return pc.split("@", 1)[0] if "@" in pc else ""


def parse_trace(path):
    """One pass over the CSV -> (allocs, access_sequence).

    allocs: list of dicts {id, kind, size, func, pc, ts}
    access_sequence: object ids in time order
    """
    allocs, access_seq = [], []
    first_access = {}    # object id -> index of its first access (temporal order)
    live = {}            # object base address -> object id
    next_id = 1

    with open(path) as f:
        for line in f:
            p = line.rstrip("\n").split(",")
            if len(p) < 7:
                continue
            pc, _counter, size, typ, aux, objbase, _ts = p[:7]

            if typ == "Alloc":
                if aux not in ALLOC_KINDS:
                    continue
                oid = next_id
                next_id += 1
                live[objbase] = oid
                allocs.append({
                    "id": oid, "kind": aux, "size": int(size),
                    "func": pc_function(pc), "pc": pc,
                })
            elif typ == "Access":
                oid = live.get(objbase)
                if oid is not None:
                    if oid not in first_access:
                        first_access[oid] = len(access_seq)
                    access_seq.append(oid)
            elif typ == "Dealloc":
                live.pop(objbase, None)

    return allocs, access_seq, first_access


def select_hot(access_count, coverage):
    """Smallest set of objects covering >= `coverage` of all heap accesses.

    This is the paper's "Hot" column (and HA% = the coverage actually reached).
    For pointer-chasing codes like health almost every object is hot, so this
    set is large; for mcf it is a handful.
    """
    ranked = sorted(access_count.items(), key=lambda kv: -kv[1])
    total = sum(access_count.values())
    hot, acc = [], 0
    for oid, c in ranked:
        if total and acc >= coverage * total:
            break
        hot.append(oid)
        acc += c
    ha = (100.0 * acc / total) if total else 0.0
    return hot, ha, ranked


def build_layout_order(rhds, rhds_refs, hot_set, ranked, first_access, mode):
    """RHDS first (most-referenced HDS first, its objects adjacent), then the
    remaining hot objects -- the Hot Singleton objects.

    Hot Singleton ORDER matters enormously. For a traversal-heavy program the
    objects touched close together in time are the ones that must sit close
    together in memory. Ordering them by hotness instead scatters
    traversal-neighbours across the region and destroys locality.
    """
    order, seen = [], set()
    for g, _f in sorted(zip(rhds, rhds_refs), key=lambda gf: -gf[1]):
        for o in g:
            if o not in seen:
                order.append(o)
                seen.add(o)

    singles = [o for o in hot_set if o not in seen]
    if mode == "alloc":                          # allocation order (default)
        singles.sort()
    elif mode == "hot":
        rank = {o: i for i, (o, _c) in enumerate(ranked)}
        singles.sort(key=lambda o: rank.get(o, 1 << 62))
    else:                                        # first access, then alloc order
        singles.sort(key=lambda o: (first_access.get(o, 1 << 62), o))
    order.extend(singles)
    return order


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--trace", required=True, help="tracer CSV")
    ap.add_argument("--out", default="layout.json")
    ap.add_argument("--hds-length", type=int, default=2,
                    help="objects per candidate HDS; the paper requires that an "
                         "HDS contain at least two objects")
    ap.add_argument("--min-freq", type=float, default=0.05)
    ap.add_argument("--freq-mode", default="ratio_max",
                    choices=["ratio_max", "ratio_windows", "absolute"])
    ap.add_argument("--select", default="all", choices=["all", "coverage"],
                    help="'all' preallocates every traced allocation (what the "
                         "paper does for health: Hot ~= every object); "
                         "'coverage' keeps only the hottest objects")
    ap.add_argument("--hot-coverage", type=float, default=0.97,
                    help="preallocate the hottest objects until they cover this "
                         "fraction of all heap accesses (the paper's HA%)")
    ap.add_argument("--arena-mb", type=int, default=64,
                    help="minimum arena size; the measured run allocates more "
                         "than the profiling run, so the arena must be sized for "
                         "the long run (the paper uses 42 MB for health)")
    ap.add_argument("--max-arena", type=int, default=512 * 1024 * 1024,
                    help="cap on total arena bytes")
    ap.add_argument("--exclude-func", default=r"^_",
                    help="regex of allocator CALLERS to leave alone. Default "
                         "skips reserved-namespace names (_IO_file_doallocate "
                         "etc.): those live in libc, so BOLT cannot redirect "
                         "them, yet counting their allocations here would shift "
                         "every wrapper counter and silently break the table")
    ap.add_argument("--max-streams", type=int, default=20000,
                    help="cap on OHDS entries fed to HDS Reconstitution")
    ap.add_argument("--singleton-order", default="alloc",
                    choices=["alloc", "first-access", "hot"],
                    help="arena order for non-HDS hot objects")
    args = ap.parse_args()
    # Objects are packed back-to-back at 8-byte granularity -- the same stride
    # the allocator's own bookkeeping would use for these structs. This is not a
    # tuning knob: rounding up to malloc's 16-byte guarantee would round health's
    # 24-byte nodes to 32 and inflate the live footprint by a third for nothing.
    align = ALIGN

    allocs, access_seq, first_access = parse_trace(args.trace)
    if not allocs:
        sys.exit("no allocations in trace — is the CSV from the DynamoRIO tracer?")
    if len(access_seq) < args.hds_length:
        sys.exit("not enough accesses to mine hot data streams")

    # Drop allocations made from functions BOLT will not rewrite (see
    # --exclude-func). Must happen BEFORE counters are assigned.
    skip = re.compile(args.exclude_func) if args.exclude_func else None
    if skip:
        dropped = {a["id"] for a in allocs if skip.match(a["func"] or "")}
        if dropped:
            funcs = sorted({a["func"] for a in allocs if a["id"] in dropped})
            print(f"[hds_layout] ignoring {len(dropped)} allocation(s) from "
                  f"non-rewritable caller(s): {', '.join(funcs)}")
            allocs = [a for a in allocs if a["id"] not in dropped]
            access_seq = [o for o in access_seq if o not in dropped]

    by_id = {a["id"]: a for a in allocs}
    access_count = Counter(access_seq)

    # --- Hot objects: the paper's "Hot" column / HA% coverage --------------
    # Access rows are sampled, but alloc rows never are -- so with --select all
    # we can place every allocation even from a sparse access trace. Partial
    # coverage is actively harmful: it splits a traversal between the arena and
    # malloc's heap, costing more locality than the layout gains.
    ranked = sorted(access_count.items(), key=lambda kv: -kv[1])
    if args.select == "all":
        hot = [a["id"] for a in allocs]
        total = sum(access_count.values())
        ha_pct = 100.0 if total else 0.0
    else:
        hot, ha_pct, ranked = select_hot(access_count, args.hot_coverage)
    hot_set = set(hot)

    # --- HDS among the hot objects: the paper's "HDS" column ---------------
    if args.hds_length < 2:
        sys.exit("--hds-length must be >= 2: an HDS must contain at least two objects")
    cfg = HDSConfig(hds_length=args.hds_length, min_frequency=args.min_freq,
                    freq_mode=args.freq_mode, max_ohds=args.max_streams)
    rhds, rhds_refs, _leftover = prefix_layout(access_seq, cfg)
    rhds = [[o for o in g if o in hot_set] for g in rhds]
    # an HDS must still have at least two objects after the hot-set filter
    kept = [(g, f) for g, f in zip(rhds, rhds_refs) if len(g) > 1]
    rhds = [g for g, _ in kept]
    rhds_refs = [f for _, f in kept]
    hds_objs = {o for g in rhds for o in g}

    order = build_layout_order(rhds, rhds_refs, hot_set, ranked,
                               first_access, args.singleton_order)
    # Objects we can actually place: allocated by a known allocator, and the
    # function that allocated them must be known (needed for the BOLT spec).
    order = [o for o in order if o in by_id and by_id[o]["func"]]
    if not order:
        sys.exit("no placeable hot objects found (are PCs symbolized?)")

    # ---- select, honouring the caps --------------------------------------
    selected, cursor = [], 0
    for oid in order:
        sz = by_id[oid]["size"]
        pad = (-cursor) % align
        if cursor + pad + sz > args.max_arena:
            continue
        cursor += pad
        selected.append({"id": oid, "offset": cursor, **by_id[oid]})
        cursor += sz
    # Pad so the longer measured run keeps bump-allocating into the arena
    # instead of spilling to malloc once the profiled objects run out.
    arena_bytes = max(cursor, args.arena_mb * 1024 * 1024)

    # ---- which (function, allocator) pairs BOLT must redirect -------------
    redirect = sorted({(o["func"], o["kind"]) for o in selected})
    redirect_set = set(redirect)

    # ---- allocation counters, restricted to the redirected call sites -----
    # The wrapper counts only the allocations that BOLT routes through it, so
    # the counters must be computed over exactly that same set, in time order.
    counters, per_obj = {k: 0 for k in ALLOC_KINDS}, {}
    for a in allocs:
        if (a["func"], a["kind"]) in redirect_set:
            counters[a["kind"]] += 1
            per_obj[a["id"]] = counters[a["kind"]]
    for o in selected:
        o["count"] = per_obj[o["id"]]

    layout = {
        "arena_bytes": arena_bytes,
        "align": align,
        "objects": [
            {"id": o["id"], "kind": o["kind"], "size": o["size"],
             "offset": o["offset"], "count": o["count"], "func": o["func"],
             "hds": o["id"] in hds_objs}
            for o in selected
        ],
        "redirect": [{"func": f, "kind": k} for f, k in redirect],
        "stats": {
            "allocations": len(allocs),
            "accesses": len(access_seq),
            "ha_percent": round(ha_pct, 2),
            "hot_objects": len(hot),
            "hds_objects": len(hds_objs),
            "rhds": len(rhds),
            "hot_singletons": len(selected) - len([o for o in selected
                                                   if o["id"] in hds_objs]),
        },
    }
    with open(args.out, "w") as f:
        json.dump(layout, f, indent=2)

    n_hds_sel = len([o for o in selected if o["id"] in hds_objs])
    print(f"[hds_layout] {len(allocs)} allocations, {len(access_seq)} accesses")
    print(f"[hds_layout] HA   = {ha_pct:.1f}%  (heap accesses covered by "
          f"preallocated objects)")
    print(f"[hds_layout] Hot  = {len(hot)} hot objects "
          f"({len(selected)} placed in the preallocated region)")
    print(f"[hds_layout] RHDS = {len(hds_objs)} objects in {len(rhds)} "
          f"reconstituted hot data streams")
    print(f"[hds_layout] Hot Singleton objects = {len(selected) - n_hds_sel}")
    print(f"[hds_layout] arena = {arena_bytes/1048576.0:.1f} MB")
    for o in selected[:8]:
        tag = "RHDS" if o["id"] in hds_objs else "hot singleton"
        print(f"    obj {o['id']:>8}  {o['kind']:<7} size={o['size']:>8}  "
              f"offset={o['offset']:>10}  {o['kind']}#{o['count']:<8} {tag}")
    if len(selected) > 8:
        print(f"    ... and {len(selected) - 8} more")
    print(f"[hds_layout] wrote {args.out}")


if __name__ == "__main__":
    main()
