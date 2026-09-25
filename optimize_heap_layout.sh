#!/usr/bin/env bash
#
# PreFix — a reproduction of the paper's pipeline on ONE benchmark.
#
# SCOPE: this is an independent reproduction of the PreFix pipeline (CGO '25,
# doi 10.1145/3696443.3708960) on **health** from the Olden suite. It is NOT the
# paper's artifact and does not cover the paper's other 12 benchmarks, its
# object-recycling results, or its multithreading study. health is a
# pointer-chasing benchmark that allocates millions of small linked structs --
# the workload PreFix targets -- and is downloaded from a pinned
# llvm-test-suite commit rather than vendored here.
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
# Stages: DynamoRIO trace -> Trace Analysis (HDS & Hot Singleton objects)
#         -> Gen. Prealloc Code -> BOLT Transformation -> perf stat -r
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
# Pin the benchmark too, not just the compiler: llvm-test-suite/main moves, and
# a changed health.c would silently change both the layout and the numbers.
TESTSUITE_COMMIT=${TESTSUITE_COMMIT:-b93f949ca6c38da7cf2eea708b5a86a4a5c9f30b}
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
RAW=https://raw.githubusercontent.com/llvm/llvm-test-suite/${TESTSUITE_COMMIT}/MultiSource/Benchmarks/Olden

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
# health is NOT vendored in this repository. It is downloaded from a PINNED
# llvm-test-suite commit, together with Olden's LICENSE.TXT, and every file is
# checked against a recorded SHA-256 so the reproduction cannot drift.
banner "1. benchmark: health (Olden @ ${TESTSUITE_COMMIT:0:12})"

# sha256  filename  (from llvm-test-suite @ $TESTSUITE_COMMIT)
BENCH_SHA256="\
d548685cbf528584092ec93dd365b05f8832d772e2f1466279ca6064e3b92d4e  health.c
7c094fc24ba506b042b4e17059afda87087019ea4cfa9aea509ae7b0faf8027b  args.c
261e08675ffc5f2c7d14c3cdd60dde158d588a0b04ccc3273157677bf1300342  list.c
995621b7cef718d158c558bc0f91efde78b3021e33070435202f54331f803a05  poisson.c
f3b2bf0d162d978ed3ab98dcc2358806409419233bac58388b94a233fcb32d74  health.h
7817a8d0ff663a9e68df2556c59f15af9d06f9ecf16fb216a4489a236bc2221a  LICENSE.TXT
ab682333f84a3d0aa57215ca0aa8e1699fbd830421e412e88b6f003316db9b23  README.txt"

SHACMD=$(command -v sha256sum || command -v shasum || true)
verify_sha() {   # $1 = filename (basename, as listed above)
  local want got
  want=$(printf '%s\n' "$BENCH_SHA256" | awk -v f="$1" '$2==f {print $1}')
  [[ -n "$want" ]] || { echo "FAIL: no recorded checksum for $1"; exit 1; }
  [[ -n "$SHACMD" ]] || return 0          # no sha tool: pin still applies
  case "$SHACMD" in
    *shasum) got=$("$SHACMD" -a 256 "${BENCH_DIR}/$1" | cut -d" " -f1) ;;
    *)       got=$("$SHACMD" "${BENCH_DIR}/$1" | cut -d" " -f1) ;;
  esac
  if [[ "$got" != "$want" ]]; then
    echo "FAIL: checksum mismatch for $1"
    echo "  expected ${want}"
    echo "  got      ${got}"
    echo "  source   ${RAW}"
    rm -f "${BENCH_DIR}/$1"
    exit 1
  fi
}

for f in "${BENCH_SRCS[@]}" "${BENCH_HDRS[@]}"; do
  [[ -f "${BENCH_DIR}/${f}" ]] || curl -fsSL -o "${BENCH_DIR}/${f}" "${RAW}/health/${f}"
  verify_sha "$f"
done
# LICENSE.TXT / README.txt live at the Olden suite root, not in health/
for f in "${BENCH_EXTRA[@]}"; do
  [[ -f "${BENCH_DIR}/${f}" ]] || curl -fsSL -o "${BENCH_DIR}/${f}" "${RAW}/${f}"
  verify_sha "$f"
done
echo "benchmark sources verified against recorded SHA-256"
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
  vrc=0
  "$BOLT" "$BIN_LINKED" "${VERIFY_ARGS[@]}" -o "${BASE_DIR}/.verify.bolt" \
        >/dev/null 2>&1 || vrc=$?
  if [[ $vrc -ne 0 ]]; then
    echo "FAIL: verification rewrite failed (llvm-bolt exit ${vrc}) — see ${RESULTS}/bolt.log"
    rm -f "${BASE_DIR}/.verify.bolt"; exit 1
  fi
  n=$(objdump -d "${BASE_DIR}/.verify.bolt" 2>/dev/null | grep -cE 'call.*_wrapper' || true)
  rm -f "${BASE_DIR}/.verify.bolt"
  echo "redirected call sites (verified without --force-inline): $n"
  if [[ "$n" -eq 0 ]]; then
    # Nothing was transformed, so the "optimized" binary is just the linked one.
    # Benchmarking it would report a speedup of ~1.0 and mean nothing.
    echo "FAIL: BOLT redirected no call sites — see ${RESULTS}/bolt.log"
    exit 1
  fi
fi

# ---- 5c. correctness: optimized output must match the baseline ---------------
# This is a hard gate. A heap-layout transformation that changes program output,
# or that produces a binary which crashes, is wrong -- and timing a wrong binary
# would report a meaningless speedup (a program that dies early is very fast).
# Any failure here stops the script before stage 6.
banner "5c. correctness check"

run_checked() {   # $1 = binary, $2 = output file, $3 = label
  local rc=0
  "$1" "${BENCH_ARGS[@]}" > "$2" 2>&1 || rc=$?
  if [[ $rc -ne 0 ]]; then
    echo "FAIL: $3 exited with status ${rc} on: $(basename "$1") ${BENCH_ARGS[*]}"
    echo "--- last 20 lines of its output ---"
    tail -20 "$2"
    exit 1
  fi
}

run_checked "$BIN_BASE" "${RESULTS}/out.baseline"  "baseline"
run_checked "$BIN_OPT"  "${RESULTS}/out.optimized" "optimized"

if ! diff -q "${RESULTS}/out.baseline" "${RESULTS}/out.optimized" >/dev/null; then
  echo "FAIL: optimized output differs from the baseline."
  echo "--- diff (baseline vs optimized, first 20 lines) ---"
  diff "${RESULTS}/out.baseline" "${RESULTS}/out.optimized" | head -20 || true
  echo "---"
  echo "Refusing to benchmark an incorrect binary. Full outputs:"
  echo "  ${RESULTS}/out.baseline"
  echo "  ${RESULTS}/out.optimized"
  exit 1
fi
echo "output identical to the baseline — OK"

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
