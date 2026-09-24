#!/usr/bin/env bash
#
# Reproduce the PreFix result on Olden `health`: -42.27% cycles (1.73x).
#
# This pins every knob to the configuration that produced the numbers in
# README.md, so a fresh checkout on a Linux x86-64 box reproduces them with:
#
#     ./reproduce_prefix_health.sh
#
# Everything is built under ./prefix_run/ — nothing is installed system-wide,
# and no benchmark source is redistributed here (see "Benchmark" in README.md:
# health is fetched from llvm-test-suite at run time, together with Olden's
# LICENSE.TXT).
#
# First run builds llvm-bolt from source (~30-60 min); later runs reuse it.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

# ---- the configuration that produced the published numbers -------------------
# Workload. The paper's health input (max_level=5 max_time=5000 seed=4); the
# trace is collected on a 10x shorter run so tracing finishes in minutes, and
# the preallocated region is sized for the long run.
export BENCH_ARGS="${BENCH_ARGS:-5 5000 4}"      # measured run
export PROFILE_ARGS="${PROFILE_ARGS:-5 500 4}"   # traced run
export SAMPLE="${SAMPLE:-200}"                   # keep 1 in N accesses; tune to trade
                                                 # trace time against HDS resolution.
                                                 # Allocation and free records are
                                                 # never sampled, so every object is
                                                 # still placed.

# Layout. See README.md "Notes on the configuration".
export SELECT="${SELECT:-all}"        # preallocate every traced allocation (HA=100%);
                                      # partial coverage splits one traversal between
                                      # the preallocated region and the heap, and loses.
export ARENA_MB="${ARENA_MB:-64}"     # floor: the measured run allocates ~1.7M nodes
export HDS_LENGTH="${HDS_LENGTH:-2}"  # objects per HDS (the paper requires >= 2)
export MIN_FREQ="${MIN_FREQ:-0.05}"   # HDS recurrence threshold
export EXCLUDE_FUNC="${EXCLUDE_FUNC:-^_}"  # skip libc-internal allocator callers

# Measurement.
export RUNS="${RUNS:-3}"              # perf stat -r N
export JOBS="${JOBS:-$(nproc 2>/dev/null || echo 4)}"

exec ./optimize_heap_layout.sh "$@"
