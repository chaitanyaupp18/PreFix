# PreFix: Heap Layout Optimization — Reproducibility Guide

Reference implementation of **PreFix** — *Optimizing the Performance of
Heap-Intensive Applications*, CGO '25.
Paper: <https://dl.acm.org/doi/10.1145/3696443.3708960>

PreFix traces a program's heap accesses, identifies the **Hot Data Streams
(HDS)** and **Hot Singleton objects**, generates code that places those objects
in one preallocated memory region, and rewrites the binary's allocation sites
onto it with **LLVM-BOLT**.

![PreFix implementation](docs/prefix-implementation.png)

*Figure 8 from the paper — the pipeline this repository implements.*

On Olden `health` with the paper's input (`5 5000 4`), this repository reproduces:

| metric | baseline | optimized | change |
|---|---|---|---|
| **cycles** | 233,362,484,852 | 134,727,026,048 | **−42.27%** |
| wall time | 67.78 s | 39.14 s | **−42.26%** |
| instructions | 12,108,799,295 | 11,931,741,828 | −1.46% |
| cache-misses | 822,881,717 | 714,326,115 | −13.19% |
| dTLB-load-misses | 401,501,789 | 344,533,710 | −14.19% |
| page-faults | 13,652 | 4,608 | −66.25% |
| IPC | 0.0519 | 0.0886 | +70.68% |

**Speedup: 1.73×.** `perf stat -r 3`, optimized output verified byte-identical
to the baseline. The baseline is the *pristine* binary — no preallocation code,
no BOLT.

Instructions barely move (−1.46%) while cycles drop 42%: the program does the
same work, it just stops waiting on memory.

---

## 1. The Transformation (Before & After Disassembly)

`health` builds its patient lists in `addList`, one 24-byte node per `malloc`.
Those nodes are traversed together but land wherever the allocator puts them.

**Before (baseline):** a plain call into the allocator.

```assembly
0000000000001cb0 <addList>:
    1cb0:       push   %rbp
    1cb1:       mov    %rsi,%rbp
    1cb4:       push   %rbx
    1cb5:       sub    $0x8,%rsp
    1cb9:       test   %rdi,%rdi
    1cbc:       je     1ccb <addList+0x1b>
    1cc0:       mov    %rdi,%rbx
    1cc3:       mov    (%rdi),%rdi
    1cc6:       test   %rdi,%rdi
    1cc9:       jne    1cc0 <addList+0x10>
    1ccb:       mov    $0x18,%edi
    1cd0:       call   1080 <malloc@plt>          # <-- the site PreFix replaces
    1cd5:       mov    %rbp,0x8(%rax)
    1cd9:       movq   $0x0,(%rax)
    1ce0:       mov    %rbx,0x10(%rax)
    1ce4:       mov    %rax,(%rbx)
    1ce7:       add    $0x8,%rsp
    1ceb:       pop    %rbx
    1cec:       pop    %rbp
    1ced:       ret
```

**After (BOLT transformation):** the call is gone. `malloc_wrapper` is inlined
in its place. It advances a cursor through the preallocated region, consulting a
table first for the objects the layout deliberately placed out of allocation
order (the RHDS members):

```assembly
0000000000400cc0 <addList>:
  400cc0:       push   %rbp
  400cc1:       mov    %rsi,%rbp
  400cc4:       push   %rbx
  400cc5:       sub    $0x8,%rsp
  400cc9:       test   %rdi,%rdi
  400ccc:       je     400cd9 <addList+0x19>
  400cce:       mov    %rdi,%rbx
  400cd1:       mov    (%rdi),%rdi
  400cd4:       test   %rdi,%rdi
  400cd7:       jne    400cce <addList+0xe>
  400cd9:       mov    $0x18,%edi
  400cde:       mov    -0x3fbc4d(%rip),%rax     # prefix_malloc_seen
  400ce5:       lea    0x1(%rax),%rdx           #   ++ object id (allocation counter)
  400ce9:       mov    -0x3fbc68(%rip),%rax     # prefix_arena
  400cf0:       mov    %rdx,-0x3fbc5f(%rip)     # prefix_malloc_seen
  400cf7:       test   %rax,%rax
  400cfa:       je     400d60 <addList+0xa0>    #   no region -> real malloc
  400cfc:       jmp    400d17 <addList+0x57>
  400cfe:       mov    %rbp,0x8(%rax)           # ... original node init ...
  400d02:       movq   $0x0,(%rax)
  400d09:       mov    %rbx,0x10(%rax)
  400d0d:       mov    %rax,(%rbx)
  400d10:       add    $0x8,%rsp
  400d14:       pop    %rbx
  400d15:       pop    %rbp
  400d16:       ret
  400d17:       mov    -0x3fbc8d(%rip),%ecx     # next RHDS table slot
  400d1d:       cmp    $0xfc,%ecx
  400d23:       ja     400d39 <addList+0x79>
  400d25:       lea    -0x3febac(%rip),%rsi     # prefix_tbl
  400d2c:       lea    (%rcx,%rcx,2),%r8d
  400d30:       mov    (%rsi,%r8,4),%r9d
  400d34:       cmp    %r9,%rdx                 #   object id == table entry?
  400d37:       je     400d67 <addList+0xa7>    #     yes -> its reserved place
  400d39:       mov    -0x3fbcf0(%rip),%rcx     # cursor
  400d40:       lea    0x7(%rdi),%rdx           #   pack to 8-byte granularity
  400d44:       and    $0xfffffffffffffff8,%rdx
  400d48:       add    %rcx,%rdx
  400d4b:       cmp    $0x4000000,%rdx          #   region exhausted?
  400d52:       ja     400d60 <addList+0xa0>
  400d54:       mov    %rdx,-0x3fbd0b(%rip)     # cursor
  400d5b:       add    %rcx,%rax                #   -> region + cursor
  400d5e:       jmp    400cfe <addList+0x3e>
  400d60:       call   10a0 <malloc@plt>        # fallback, only if region is full
```

Consecutive `addList` nodes now sit 24 bytes apart in one region instead of
being scattered across the allocator's free lists. That is the whole
optimization.

---

## 2. Step-by-Step Commands

**Requires Linux x86-64** — DynamoRIO traces and BOLT rewrites ELF binaries.
Also needs `git cmake ninja cc python3+numpy curl perf` and `llvm-symbolizer`
(or `addr2line`).

### Step 0: Reproduce everything with one command

```bash
./reproduce_prefix_health.sh
```

This pins the configuration that produced the numbers above and runs Steps 1–6.
Everything lands in `./prefix_run/`; nothing is installed system-wide. The first
run builds `llvm-bolt` from source (~30–60 min); later runs reuse it.

The individual stages, as the driver runs them:

### Step 1: Build the baseline (the "Original Executable")

`health` is fetched from `llvm-test-suite` (see [Benchmark](#benchmark)) and
built with relocations preserved, which BOLT requires:

```bash
cc -O2 -g -DTORONTO -Wl,-q health.c args.c list.c poisson.c -lm -o health.baseline
```

### Step 2: DynamoRIO — allocation, free and access trace

The client in `tracer/` records every allocation, every heap access attributed
back to the object it touched, and every free, in time order:

```bash
drrun -c tracer/libdr_trace_client.so -sample 200 -- ./health.baseline 5 500 4
python3 tracer/trace_to_csv.py health_trace.*.log > trace.csv
```

Accesses are sampled 1-in-200 to keep tracing to minutes; **allocation and free
records are never sampled**, so every object is still placed. `-sample` trades
trace time against how finely HDS can be resolved.

### Step 3: Trace Analysis — HDS & Hot Singleton objects

The HDS Finder scans the access sequence for recurring sets of hot objects, then
HDS Reconstitution turns the OHDS into RHDS:

```bash
python3 scripts/hds_layout.py --trace trace.csv --out layout.json \
    --select all --hds-length 2 --min-freq 0.05 \
    --arena-mb 64 --exclude-func '^_'
```

```
[hds_layout] ignoring 1 allocation(s) from non-rewritable caller(s): _IO_file_doallocate
[hds_layout] 172672 allocations, 286005 accesses
[hds_layout] HA   = 100.0%
[hds_layout] Hot  = 172672 hot objects
[hds_layout] RHDS = 9011 objects in 4184 reconstituted hot data streams
[hds_layout] Hot Singleton objects = 163661
```

### Step 4: Gen. Prealloc Code

```bash
python3 scripts/gen_prefix.py --layout layout.json --outdir gen/
cc -std=c11 -O2 -g -c gen/prefix.c -I gen/ -o gen/prefix.o
cc -c gen/prefix_tables.S -I gen/ -o gen/prefix_tables.o
```

```
[gen_prefix] arena 64.0 MB, 172672 slots: 9011 moved (table 105.6 KB) + 163661 bump-allocated
[gen_prefix] BOLT will redirect malloc() calls in addList()
[gen_prefix] BOLT will redirect malloc() calls in alloc_tree.part.0()
[gen_prefix] BOLT will redirect malloc() calls in generate_patient()
```

### Step 5: BOLT Transformation

`patches/prefix.patch` adds the `--replace-memalloc` / `--replace-free` passes
to upstream BOLT. Re-link the benchmark against `prefix.o`, then transform:

```bash
llvm-bolt health.prefix -o health.prefix.bolt \
    --replace-memalloc=addList:-malloc \
    --replace-memalloc=generate_patient:-malloc \
    --replace-memalloc=alloc_tree.part.0:-malloc \
    --replace-free=enable \
    --force-inline=malloc_wrapper,free_wrapper
```

A wrapper hands out a preallocated address keyed on the **object id** — the Nth
`malloc`, counting only the transformed sites. `free_wrapper` skips returning
objects that live in the preallocated region.

> This is why the traced run and the measured run must be the same program: the
> object ids have to line up. It is also why `--exclude-func '^_'` matters —
> `_IO_file_doallocate` lives in libc, so BOLT cannot transform it, and counting
> its allocation would shift every id by one and silently void the table.

### Step 6: Measure

```bash
scripts/measure.sh 3 health.baseline health.prefix.bolt 5 5000 4
```

Runs `perf stat -r 3 -e cycles:u,instructions:u,cache-misses:u,dTLB-load-misses:u,…`
on both binaries and prints the table at the top. The driver also checks the
optimized binary's output is byte-identical to the baseline's.

To re-analyze saved reports without re-running:

```bash
scripts/measure.sh --compare prefix_run/results/perf_baseline.txt \
                             prefix_run/results/perf_optimized.txt
```

---

## Measurement machine

| | |
|---|---|
| CPU | 2× Intel Xeon Silver 4214R @ 2.40 GHz (24 cores / 48 threads, 2 sockets) |
| Caches | L1d 32 KiB/core, L2 1 MiB/core, **L3 33 MiB (2 instances)** |
| Memory | 94 GiB, 2 NUMA nodes |
| OS | Arch Linux, kernel 6.17.5 |
| Toolchain | GCC 16.1.1, GNU ld 2.46.0, perf 7.0.10 |
| LLVM-BOLT | built from `llvm-project` @ `94ae3dd`, patched with `patches/prefix.patch` |
| THP | `always` |
| Governor | `schedutil` |
| perf | `perf stat -r 3`, `:u` (user-space) counters |

The machine is shared, so *absolute* baseline times vary between sessions
(67–87 s for this workload). Both binaries are always measured back-to-back in
the same session, so the ratio is the stable quantity; the speedup reproduced
between 1.72× and 1.73× across sessions.

## Notes on the configuration

A few choices are worth calling out, because getting them wrong costs most of
the result:

- **`--select all`.** Every traced allocation is preallocated (HA = 100%).
  Preallocating only the hottest objects splits a single traversal between the
  preallocated region and the ordinary heap and gives up essentially the whole
  speedup (measured: 1.00×).
- **Objects are packed at 8-byte granularity.** This is built into the layout,
  not a knob. `health`'s nodes are 24 bytes; rounding them up to the allocator's
  16-byte guarantee would make each occupy 32 and inflate the live footprint by
  a third (measured: 1.24×).
- **Hot Singleton objects keep allocation order.** Ordering them by hotness
  instead scatters traversal neighbours across the region and was dramatically
  worse in testing.
- **`--arena-mb 64`** is a floor, not a target. The trace is collected on a 10×
  shorter run (`5 500 4`) than the measured one (`5 5000 4`), so the region must
  be sized for the long run; allocations past the end fall back to `malloc`.

## Benchmark

**`health`** from the **Olden** suite — a pointer-chasing hospital simulation
that allocates millions of small linked `Village`/`Patient` structs. It is one of
the benchmarks evaluated in the paper, run here on the paper's input
(`max_level=5 max_time=5000 seed=4`).

**No benchmark source is redistributed in this repository.**
`optimize_heap_layout.sh` downloads `health.c`, `args.c`, `list.c`, `poisson.c`
and `health.h` at run time from the LLVM test suite, into the gitignored
`prefix_run/bench/` directory:

> <https://github.com/llvm/llvm-test-suite/tree/main/MultiSource/Benchmarks/Olden/health>

It fetches Olden's `LICENSE.TXT` and `README.txt` alongside them, so the
copyright notice travels with the sources, as that license requires:

> Olden Version 1 Copyright (C) 1994–1996 by Anne Rogers (amr@cs.princeton.edu)
> and Martin Carlisle (mcc@cs.princeton.edu). ALL RIGHTS RESERVED.
> *You may make copies of OLDEN for your own use and modify those copies. All
> copies of OLDEN must retain our names and copyright notice. You may not sell
> OLDEN or distribute OLDEN in conjunction with a commercial product or service
> without the expressed written consent of Anne Rogers and Martin Carlisle.*

This repository is research code and is not sold or distributed with any
commercial product or service.

`ft` (Ptrdist) is the other publicly available benchmark from the paper and can
be swapped in the same way. `analyzer` is not publicly redistributable and is
not included here.

## Third-party components

| component | used as | license |
|---|---|---|
| [LLVM / BOLT](https://github.com/llvm/llvm-project) | built from source at `94ae3dd`, patched by `patches/prefix.patch` | Apache-2.0 WITH LLVM-exception |
| [llvm-test-suite](https://github.com/llvm/llvm-test-suite) (Olden `health`) | downloaded at run time, not vendored | Apache-2.0 WITH LLVM-exception, plus the Olden notice above |
| [DynamoRIO](https://github.com/DynamoRIO/dynamorio) | release tarball downloaded by `tracer/Makefile` | BSD-3-Clause |

`patches/prefix.patch` modifies LLVM BOLT and is offered under the same
Apache-2.0 WITH LLVM-exception terms as the code it patches.
`docs/prefix-implementation.png` is Figure 8 of the PreFix paper, reproduced by
its authors.

## Repository layout

```
reproduce_prefix_health.sh   pinned configuration reproducing −42.27%
optimize_heap_layout.sh      the end-to-end driver
patches/prefix.patch         adds --replace-memalloc / --replace-free to BOLT
tracer/                      DynamoRIO heap tracer (client + trace->CSV)
scripts/
  hds.py                     PreFix HDS Finder — candidate HDS from the trace
  shrink.py                  HDS Reconstitution: OHDS -> RHDS + Hot Singletons
  hds_layout.py              Trace Analysis: trace.csv -> layout.json
  gen_prefix.py              Gen. Prealloc Code: layout.json -> prefix.c / tables
  measure.sh                 perf stat -r comparison (also: --compare a b)
tests/test_offline.py        analysis + codegen on a synthetic trace — no Linux
docs/prefix-implementation.png   Figure 8
```

## Testing without Linux

The analysis and code-generation stages are platform-independent:

```bash
python3 tests/test_offline.py
```

It plants a known hot data stream in a synthetic trace, checks those objects end
up adjacent in the preallocated region, compiles the generated `prefix.c`, and
validates the `perf` comparison table.

## Citation

```bibtex
@inproceedings{prefix-cgo25,
  author    = {Mamatha Ananda, C. and Gupta, R. and Tallam, S. and
               Shen, H. and Li, X. D.},
  title     = {Optimizing the Performance of Heap-Intensive Applications},
  booktitle = {Proceedings of the 23rd ACM/IEEE International Symposium on
               Code Generation and Optimization (CGO '25)},
  year      = {2025},
  doi       = {10.1145/3696443.3708960}
}
```
