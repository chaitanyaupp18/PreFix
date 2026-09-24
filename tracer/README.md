# DynamoRIO heap tracer

Run any program under [DynamoRIO](https://dynamorio.org/) and get a CSV of **every
heap event** — each allocation, each memory access (attributed back to the heap
object it touched), and each free — in time order. Useful for studying object
lifetimes, access patterns, and "memory drag" (memory kept alive long after its
last use).

## Requirements

- **Linux x86-64** (DynamoRIO requirement). On macOS this folder is just your
  editable source — copy it to a Linux box/server and run `make` there.
- `g++`, `cmake`, `curl`, `python3` with `numpy`.

The `Makefile` downloads DynamoRIO for you; you do not install anything system-wide.

## Quick start

```bash
make all          # download DynamoRIO + build + trace example.cpp -> example.csv
less example.csv
```

That's it. `make` with no target prints the full list of commands.

## What you get

`example.csv` has one row per event, seven columns:

| column | Alloc row | Access row | Dealloc row |
|--------|-----------|------------|-------------|
| 1 PC        | call site of the malloc | the instruction doing the access | call site of the free |
| 2 Counter   | Nth allocation | Nth access **to this object** | Nth deallocation |
| 3 Size      | object size (bytes) | object size | object size |
| 4 Type      | `Alloc` | `Access` | `Dealloc` |
| 5 kind/addr | `malloc`/`calloc`/`realloc` | **access address** | `free` |
| 6 ObjAddr   | object base address | object base address | object base address |
| 7 ts        | timestamp (global order) | timestamp | timestamp |

Example (from `example.cpp`):

```
make_array@example.bin+0x...,1,64,Alloc,malloc,0x7f..10,1
main@example.bin+0x...,1,64,Access,0x7f..10,0x7f..10,2     <- a[0] write
main@example.bin+0x...,2,64,Access,0x7f..14,0x7f..10,3     <- a[1] write (addr +4)
...
main@example.bin+0x...,1,64,Dealloc,free,0x7f..10,123
```

The **drag** idea: compare an object's last `Access` ts with its `Dealloc` ts.
A large gap = memory held long after its last use. `example.cpp`'s `drag` buffer is
built to show this; its `scratch` buffer is built to show the opposite (freed right
after last use).

## Trace your own program

```bash
make trace PROG=./my_prog ARGS="input.txt"
make csv
```

A full access trace can be **enormous** (billions of accesses). Sample it:

```bash
make trace SAMPLE=200      # keep 1 in 200 accesses; allocs and frees are always kept
```

Name the PCs with their functions (needs `llvm-symbolizer` or `addr2line`):

```bash
make csv SYMBOLIZE=$(command -v llvm-symbolizer)
```

## Files

| file | what it is |
|------|------------|
| `dr_trace_client.cpp` | the DynamoRIO client (the tracer itself) |
| `trace_to_csv.py`     | offline: merges the binary trace + module map -> CSV |
| `CMakeLists.txt`      | builds the client into `build/libdr_trace.so` |
| `example.cpp`         | the demo program to trace |
| `Makefile`            | installs DynamoRIO, builds, traces, converts |

## How it works (one paragraph)

DynamoRIO lets the client see every instruction and wrap `malloc`/`free`. On each
allocation the client paints **shadow memory** (a 16-byte-granule map from address →
object id), so when an arbitrary load/store happens it finds the owning object in
O(1). Records are written to **per-thread binary buffers** (no locks on the hot
path) and flushed to `*.t<tid>.bin`; raw PCs and addresses are kept as-is and only
resolved to `module+offset` offline by `trace_to_csv.py` (using the dumped
`*.modules.txt`). That keeps the hot path cheap. `-sample N` thins the access stream
for very large runs.

## Output files (written to this directory, next to the Makefile)

- `example_trace.t<tid>.bin` — one binary file per application thread
- `example_trace.modules.txt` — module load map (for offline PC resolution)
- `example.csv` — the human-readable result

Change the output base with `make trace OUT=/path/to/base`. `make clean` removes
all of these (the downloaded DynamoRIO in `tools/` survives until `make distclean`).



`void *calloc_wrapper(size_t num, size_t ele) {`
    
    current_calloc += 1;

    if ((current_calloc == array[1][current_hds_counter_calloc].count) && ((num * ele) <= OFFSET_HDS)) {
      current_hds_counter_calloc += 1;

      void *ptr = (void *)array[1][current_hds_counter_calloc - 1].addr;

      memset(ptr, 0, OFFSET_HDS);

      return ptr;
      
    }

    return calloc(num, ele);
`}`
