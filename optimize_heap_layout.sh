#!/usr/bin/env bash
#
# PreFix — end-to-end heap layout optimization on one real benchmark.
#
# Reproduces Figure 8 of the PreFix paper on **health** (Olden suite), a
# pointer-chasing benchmark that allocates thousands of small linked structs —
# exactly the workload PreFix targets. It is publicly redistributable (it ships
# in llvm-test-suite with its own LICENSE.TXT), so this script can fetch it.
#
#   Original Executable ─┬─> DynamoRIO ──> Mem. Access Trace ──> Trace Analysis
#                        │                                            │
#                        │                          HDS & Hot Singleton Objects
#                        │                                            v
#                        └─> BOLT Transformation <──────────  Gen. Prealloc Code
#                                    │
#                                    v
#                            Optimized Executable ──> perf / DrCacheSim stats
#
# Stages: (i) trace  (ii) HDS + hot-singleton layout  (iii) generate prefix.c
#         (iv) apply the BOLT patch + rewrite  (v) measure with perf stat -r
#
# Requires: Linux x86-64, git, cmake, ninja, cc, python3+numpy, curl, perf.
# Everything lands in ./prefix_run — nothing is installed system-wide.
#
set -euo pipefail

CWD="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR=${PREFIX_BASE_DIR:-${CWD}/prefix_run}

# DynamoRIO traces and BOLT rewrites ELF binaries — check before anything else.
if [[ "$(uname -sm)" != "Linux x86_64" ]]; then
  echo "PreFix needs Linux x86-64 (DynamoRIO + BOLT rewrite ELF binaries)."
  echo "You are on: $(uname -sm)"
  exit 1
fi

# ---- knobs (override from the environment) -----------------------------------
LLVM_COMMIT=${LLVM_COMMIT:-94ae3dd241ad9f1d8cf11720fadd68b50236d4f9}
DR_VERSION=${DR_VERSION:-10.0.0}
JOBS=${JOBS:-$(nproc 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)}
# health <max_level> <max_time> <seed>.
# BENCH_ARGS is what we MEASURE: 5 5000 4 is the size used in the PreFix paper
# (~33 s, 62% L1D miss rate -- enough cache pressure for layout to matter).
# PROFILE_ARGS is the shorter run we TRACE (the paper's "Profiling Run"). The
# allocation sequence is deterministic, so the hot objects -- allocated during
# setup -- get the same allocation counters in both runs.
read -r -a BENCH_ARGS   <<< "${BENCH_ARGS:-5 5000 4}"
read -r -a PROFILE_ARGS <<< "${PROFILE_ARGS:-5 500 4}"
SAMPLE=${SAMPLE:-200}                    # keep 1 in N accesses while tracing;
                                         # alloc/free records are never sampled
RUNS=${RUNS:-3}                          # perf stat -r N (the paper uses 3)
DRCACHESIM=${DRCACHESIM:-}                # set to 1 for drcachesim stats (very slow)
HDS_LENGTH=${HDS_LENGTH:-2}              # objects per HDS (paper: >= 2)
MIN_FREQ=${MIN_FREQ:-0.05}               # HDS recurrence threshold
SELECT=${SELECT:-all}                     # all | coverage
HOT_COVERAGE=${HOT_COVERAGE:-0.97}        # with SELECT=coverage: target HA%
ARENA_MB=${ARENA_MB:-64}                 # arena floor (measured run > profiled run)
EXCLUDE_FUNC=${EXCLUDE_FUNC:-^_}          # allocator callers BOLT cannot rewrite

SRC_DIR=${BASE_DIR}/sources
BENCH_DIR=${SRC_DIR}/health
LLVM_DIR=${SRC_DIR}/llvm-project
GEN_DIR=${BASE_DIR}/gen
DATA_DIR=${BASE_DIR}/data
RESULTS=${BASE_DIR}/results

BIN_BASE=${BASE_DIR}/health.baseline     # original executable
BIN_LINKED=${BASE_DIR}/health.prefix     # + prefix.o (wrapper symbols present)
BIN_OPT=${BASE_DIR}/health.prefix.bolt   # optimized executable
BOLT=${LLVM_DIR}/build/bin/llvm-bolt
DRRUN=${CWD}/tracer/tools/DynamoRIO-Linux-${DR_VERSION}/bin64/drrun
TRACE_BASE=${DATA_DIR}/health_trace
TRACE_CSV=${DATA_DIR}/trace.csv
LAYOUT=${GEN_DIR}/layout.json

BENCH_SRCS=(health.c args.c list.c poisson.c)
BENCH_HDRS=(health.h)
BENCH_EXTRA=(LICENSE.TXT README.txt)
BENCH_CFLAGS=(-O2 -g -DTORONTO)
BENCH_LIBS=(-lm)
RAW=https://raw.githubusercontent.com/llvm/llvm-test-suite/main/MultiSource/Benchmarks/Olden

banner() { printf '\n\033[1m==== %s ====\033[0m\n' "$*"; }
PY=${PYTHON:-python3}
CC=${CC:-cc}

# ---- 0. prerequisites --------------------------------------------------------
banner "0. prerequisites"
for t in git cmake ninja curl make "$PY" "$CC"; do
  command -v "$t" >/dev/null || { echo "missing required tool: $t"; exit 1; }
done
"$PY" -c 'import numpy' 2>/dev/null || { echo "python3 needs numpy: pip install numpy"; exit 1; }
SYMBOLIZER=$(command -v llvm-symbolizer || command -v addr2line || true)
[[ -n "$SYMBOLIZER" ]] || { echo "need llvm-symbolizer or addr2line (to name alloc sites)"; exit 1; }
command -v perf >/dev/null || echo "NOTE: perf not found — stage 6 falls back to wall-clock timing."
mkdir -p "$SRC_DIR" "$BENCH_DIR" "$GEN_DIR" "$DATA_DIR" "$RESULTS"
echo "workspace: ${BASE_DIR}"

# ---- 1. fetch + build the benchmark (the "Original Executable") --------------
banner "1. benchmark: health (Olden)"
for f in "${BENCH_SRCS[@]}" "${BENCH_HDRS[@]}"; do
  [[ -f "${BENCH_DIR}/${f}" ]] || curl -fsSL -o "${BENCH_DIR}/${f}" "${RAW}/health/${f}"
done
# LICENSE.TXT / README.txt live at the Olden suite root, not in health/
for f in "${BENCH_EXTRA[@]}"; do
  [[ -f "${BENCH_DIR}/${f}" ]] || curl -fsSL -o "${BENCH_DIR}/${f}" "${RAW}/${f}"
done
if [[ ! -x "$BIN_BASE" ]]; then
  # -Wl,-q keeps relocations in the binary, which BOLT requires.
  ( cd "$BENCH_DIR" && "$CC" "${BENCH_CFLAGS[@]}" -Wl,-q \
       "${BENCH_SRCS[@]}" "${BENCH_LIBS[@]}" -o "$BIN_BASE" )
fi
echo "baseline binary: $BIN_BASE"
echo "profile: health ${PROFILE_ARGS[*]}    measure: health ${BENCH_ARGS[*]}"

# ---- 2. (i) DynamoRIO memory access trace ------------------------------------
banner "2. (i) DynamoRIO heap trace"
if [[ ! -s "$TRACE_CSV" ]]; then
  make -C "${CWD}/tracer" client DR_VERSION="$DR_VERSION" >/dev/null
  rm -f "${TRACE_BASE}".t*.bin "${TRACE_BASE}.modules.txt"
  "$DRRUN" -c "${CWD}/tracer/build/libdr_trace.so" -o "$TRACE_BASE" \
           -sample "$SAMPLE" -- "$BIN_BASE" "${PROFILE_ARGS[@]}" >/dev/null
  "$PY" "${CWD}/tracer/trace_to_csv.py" "$TRACE_BASE" --symbolize "$SYMBOLIZER" > "$TRACE_CSV"
fi
echo "trace: $TRACE_CSV ($(wc -l < "$TRACE_CSV") rows)"

# ---- 3. (ii) HDS + Hot Singleton layout --------------------------------------
banner "3. (ii) HDS + hot-singleton layout"
"$PY" "${CWD}/scripts/hds_layout.py" --trace "$TRACE_CSV" --out "$LAYOUT" \
      --hds-length "$HDS_LENGTH" --min-freq "$MIN_FREQ" \
      --select "$SELECT" --hot-coverage "$HOT_COVERAGE" \
      --arena-mb "$ARENA_MB" \
      --exclude-func "$EXCLUDE_FUNC" \
      | tee "${RESULTS}/layout.log"

# ---- 4. (iii) generate the preallocation code --------------------------------
banner "4. Gen. Prealloc Code"
"$PY" "${CWD}/scripts/gen_prefix.py" --layout "$LAYOUT" --outdir "$GEN_DIR" \
      | tee "${RESULTS}/gen_prefix.log"
"$CC" -std=c11 -O2 -g -c "${GEN_DIR}/prefix.c" -I"${GEN_DIR}" -o "${GEN_DIR}/prefix.o"
# the slot tables are a binary blob pulled in with .incbin (-I lets gas find it)
"$CC" -c "${GEN_DIR}/prefix_tables.S" -I"${GEN_DIR}" -o "${GEN_DIR}/prefix_tables.o"
echo "compiled ${GEN_DIR}/prefix.o + prefix_tables.o"

# ---- 5. (iv) BOLT: apply the PreFix patch, build, rewrite --------------------
banner "5. (iv) BOLT transformation"
if [[ ! -x "$BOLT" ]]; then
  if [[ ! -d "$LLVM_DIR" ]]; then
    git clone https://github.com/llvm/llvm-project.git "$LLVM_DIR"
    git -C "$LLVM_DIR" checkout --detach "$LLVM_COMMIT"
    git -C "$LLVM_DIR" apply "${CWD}/patches/prefix.patch"
    echo "applied patches/prefix.patch (adds --replace-memalloc / --replace-free)"
  fi
  cmake -G Ninja -S "${LLVM_DIR}/llvm" -B "${LLVM_DIR}/build" \
        -DCMAKE_BUILD_TYPE=Release -DLLVM_TARGETS_TO_BUILD=X86 \
        -DLLVM_ENABLE_PROJECTS=bolt -DLLVM_ENABLE_RTTI=On \
        -DLLVM_INCLUDE_TESTS=Off >/dev/null
  ninja -C "${LLVM_DIR}/build" llvm-bolt
fi
echo "llvm-bolt: $BOLT"

# 5a. re-link the benchmark so the wrapper symbols exist in the binary
( cd "$BENCH_DIR" && "$CC" "${BENCH_CFLAGS[@]}" -Wl,-q \
     "${BENCH_SRCS[@]}" "${GEN_DIR}/prefix.o" "${GEN_DIR}/prefix_tables.o" \
     "${BENCH_LIBS[@]}" -o "$BIN_LINKED" )
echo "re-linked with prefix.o -> $BIN_LINKED"

# 5b. rewrite the chosen allocation call sites onto the wrappers
mapfile -t BOLT_ARGS < "${GEN_DIR}/bolt_args.txt"
echo "bolt args: ${BOLT_ARGS[*]}"
"$BOLT" "$BIN_LINKED" "${BOLT_ARGS[@]}" --update-debug-sections -o "$BIN_OPT" \
      > "${RESULTS}/bolt.log" 2>&1 || { tail -30 "${RESULTS}/bolt.log"; exit 1; }
grep -E "BOLT-INFO: Running|Local IDs" "${RESULTS}/bolt.log" | head || true
echo "optimized binary: $BIN_OPT"

# Sanity: confirm BOLT really redirected the call sites. --force-inline splices
# the wrapper body in and ERASES the `call <alloc>_wrapper` instruction, so we
# verify on a throwaway rewrite done WITHOUT inlining.
if command -v objdump >/dev/null; then
  VERIFY_ARGS=()
  for a in "${BOLT_ARGS[@]}"; do [[ "$a" == --force-inline=* ]] || VERIFY_ARGS+=("$a"); done
  "$BOLT" "$BIN_LINKED" "${VERIFY_ARGS[@]}" -o "${BASE_DIR}/.verify.bolt" >/dev/null 2>&1 || true
  n=$(objdump -d "${BASE_DIR}/.verify.bolt" 2>/dev/null | grep -cE 'call.*_wrapper' || true)
  rm -f "${BASE_DIR}/.verify.bolt"
  echo "redirected call sites (verified without --force-inline): $n"
  [[ "$n" -gt 0 ]] || echo "WARNING: BOLT redirected nothing — see ${RESULTS}/bolt.log"
fi

# ---- 5c. correctness: optimized output must match the baseline ---------------
banner "5c. correctness check"
"$BIN_BASE" "${BENCH_ARGS[@]}" > "${RESULTS}/out.baseline"  2>&1 || true
"$BIN_OPT"  "${BENCH_ARGS[@]}" > "${RESULTS}/out.optimized" 2>&1 || true
if diff -q "${RESULTS}/out.baseline" "${RESULTS}/out.optimized" >/dev/null; then
  echo "output identical to the baseline — OK"
else
  echo "WARNING: output differs from the baseline!"
  diff "${RESULTS}/out.baseline" "${RESULTS}/out.optimized" | head -20 || true
fi

# ---- 6. (v) measure ----------------------------------------------------------
# Headline comparison: PRISTINE binary (no prefix.c, no BOLT) vs the PreFix
# heap-layout optimized binary (prefix.o linked + BOLT-rewritten call sites).
banner "6. (v) performance — pristine vs PreFix-optimized"
echo "baseline : $BIN_BASE   (pristine: no prefix.c, no BOLT)"
echo "optimized: $BIN_OPT   (prefix.o linked + BOLT rewrite)"
OUTDIR="$RESULTS" DRRUN="${DRCACHESIM:+$DRRUN}" "${CWD}/scripts/measure.sh" \
      "$RUNS" "$BIN_BASE" "$BIN_OPT" "${BENCH_ARGS[@]}" \
      | tee "${RESULTS}/performance.txt"

# Extra data point for attribution: the same binary with prefix.o linked in but
# WITHOUT the BOLT rewrite (so the wrappers exist but are never called). The gap
# pristine -> this is the cost of just linking prefix.o; this -> optimized is the
# benefit of the layout itself.
if command -v perf >/dev/null 2>&1; then
  perf stat -r "$RUNS" -e "${EVENTS:-cycles,instructions,L1-dcache-loads,L1-dcache-load-misses,LLC-loads,LLC-load-misses,dTLB-loads,dTLB-load-misses}" \
       -- "$BIN_LINKED" "${BENCH_ARGS[@]}" > /dev/null 2> "${RESULTS}/perf_prefix_linked_nobolt.txt" || true
  echo
  echo "attribution reports saved; compare any pair with, e.g.:"
  echo "  scripts/measure.sh --compare ${RESULTS}/perf_prefix_linked_nobolt.txt ${RESULTS}/perf_optimized.txt"
fi

banner "done"
echo "results: ${RESULTS}"
