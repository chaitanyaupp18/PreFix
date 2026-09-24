#!/usr/bin/env bash
# Stage (v): measure the baseline vs the PreFix-optimized binary.
#
#   measure.sh <runs> <baseline-bin> <optimized-bin> [args...]
#   measure.sh --compare <perf_baseline.txt> <perf_optimized.txt>
#
# For each binary this runs exactly:
#
#   perf stat -r <runs> -e <EVENTS> -- <binary> <args...>
#
# so perf itself does the repetition and reports mean +- stddev. Both full perf
# reports are printed, followed by a side-by-side table with the % change and
# the derived L1D / LLC / dTLB miss rates — what PreFix actually targets by
# packing co-accessed heap objects together.
#
# Override counters with EVENTS=... ; set DRRUN=/path/to/drrun to also collect
# drcachesim cache statistics (the "DrCacheSim Cache Stats" box in Figure 8).
set -euo pipefail

EVENTS=${EVENTS:-cycles:u,instructions:u,cache-references:u,cache-misses:u,L1-dcache-loads:u,L1-dcache-load-misses:u,L1-dcache-stores:u,dTLB-load-misses:u,dTLB-store-misses:u,L1-icache-misses:u,iTLB-misses:u,branches:u,branch-misses:u,page-faults:u}

# ---- side-by-side table from two perf reports --------------------------------
compare() {
  awk -v events="$EVENTS" '
    # "   1,234,567      cycles   # 3.4 GHz  ( +- 0.12% )"  ->  cycles = 1234567
    function num(   v) { v=$1; gsub(/,/,"",v); return v }
    function pct(x,y)  { return (x>0) ? (y-x)*100.0/x : 0 }
    FNR==NR {
      v=num(); if (v ~ /^[0-9]+$/ && $2 != "") b[$2]=v+0
      if ($0 ~ /seconds time elapsed/) bt=$1+0
      next
    }
    {
      v=num(); if (v ~ /^[0-9]+$/ && $2 != "") o[$2]=v+0
      if ($0 ~ /seconds time elapsed/) ot=$1+0
    }
    function row(name, x, y) {
      if (x == "" || y == "") return
      printf "%-24s %18.0f %18.0f  %+8.2f%%\n", name, x, y, pct(x,y)
    }
    function rate(name, loads, misses) {
      if (b[loads]>0 && o[loads]>0 && (misses in b) && (misses in o))
        printf "%-24s %17.3f%% %17.3f%%  %+8.2f%%\n", name,
               b[misses]*100.0/b[loads], o[misses]*100.0/o[loads],
               pct(b[misses]/b[loads], o[misses]/o[loads])
    }
    END {
      printf "%-24s %18s %18s %9s\n", "metric", "baseline", "optimized", "change"
      n = split(events, E, ",")
      for (i=1; i<=n; i++) row(E[i], b[E[i]], o[E[i]])
      if (bt>0 && ot>0)
        printf "%-24s %18.6f %18.6f  %+8.2f%%\n", "seconds elapsed", bt, ot, pct(bt,ot)
      print "------------------------------- derived -------------------------------"
      rate("cache miss rate", "cache-references:u", "cache-misses:u")
      rate("L1D miss rate",  "L1-dcache-loads", "L1-dcache-load-misses")
      rate("L1D miss rate",  "L1-dcache-loads:u", "L1-dcache-load-misses:u")
      rate("LLC miss rate",  "LLC-loads",       "LLC-load-misses")
      rate("dTLB miss rate", "dTLB-loads",      "dTLB-load-misses")
      cyc = ("cycles" in b) ? "cycles" : "cycles:u"
      ins = ("instructions" in b) ? "instructions" : "instructions:u"
      if (b[cyc]>0 && o[cyc]>0 && (ins in b)) {
        bi = b[ins]/b[cyc]; oi = o[ins]/o[cyc]
        printf "%-24s %18.4f %18.4f  %+8.2f%%\n", "IPC", bi, oi, pct(bi,oi)
        printf "\nspeedup (cycles): %.4fx\n", b[cyc]/o[cyc]
      }
      print "\n(negative change = fewer cycles/misses = better)"
    }
  ' "$BASE_TXT" "$OPT_TXT"
}

# ---- re-analyze two saved perf reports ---------------------------------------
if [[ "${1:-}" == "--compare" ]]; then
  BASE_TXT=${2:?need perf_baseline.txt}; OPT_TXT=${3:?need perf_optimized.txt}
  compare
  exit 0
fi

RUNS=${1:?usage: measure.sh <runs> <baseline> <optimized> [args...]}
BASE=${2:?}
OPT=${3:?}
shift 3
ARGS=("$@")

OUTDIR=${OUTDIR:-$(mktemp -d)}
BASE_TXT=${OUTDIR}/perf_baseline.txt
OPT_TXT=${OUTDIR}/perf_optimized.txt

# ---- no perf? fall back to wall-clock so we still report something -----------
if ! command -v perf >/dev/null 2>&1 || ! perf stat -e cycles true >/dev/null 2>&1; then
  echo "NOTE: perf unavailable (install linux-perf, or lower kernel.perf_event_paranoid)."
  echo "      Falling back to wall-clock timing over $RUNS runs."
  med() { sort -n | awk '{v[NR]=$1} END{print (NR%2)?v[(NR+1)/2]:(v[NR/2]+v[NR/2+1])/2}'; }
  timeit() {
    local bin=$1 s e out=()
    "$bin" "${ARGS[@]}" >/dev/null 2>&1 || true          # warm the page cache
    for _ in $(seq 1 "$RUNS"); do
      s=$(date +%s%N); "$bin" "${ARGS[@]}" >/dev/null 2>&1; e=$(date +%s%N)
      out+=($(( (e - s) / 1000000 )))
    done
    printf '%s\n' "${out[@]}" | med
  }
  b=$(timeit "$BASE"); o=$(timeit "$OPT")
  echo "baseline : ${b} ms (median of $RUNS)"
  echo "optimized: ${o} ms (median of $RUNS)"
  awk -v b="$b" -v o="$o" 'BEGIN{if(o>0) printf "speedup  : %.4fx (%+.2f%%)\n", b/o, (b-o)*100/b}'
  exit 0
fi

# ---- the real measurement ----------------------------------------------------
echo "events: ${EVENTS}"
echo "runs  : ${RUNS}   (perf stat -r ${RUNS})"

measure() {   # $1 = binary, $2 = report file
  echo
  echo "### perf stat -r ${RUNS} -e ${EVENTS} -- $(basename "$1") ${ARGS[*]}"
  perf stat -r "$RUNS" -e "$EVENTS" -- "$1" "${ARGS[@]}" >/dev/null 2>"$2"
  cat "$2"
}

measure "$BASE" "$BASE_TXT"
measure "$OPT"  "$OPT_TXT"

echo
echo "================ baseline vs PreFix-optimized ================"
compare
echo "raw perf reports: $BASE_TXT , $OPT_TXT"

# ---- optional drcachesim cache stats (Figure 8) ------------------------------
if [[ -n "${DRRUN:-}" && -x "${DRRUN}" ]]; then
  echo
  echo "================ drcachesim cache stats ================"
  for pair in "baseline:$BASE" "optimized:$OPT"; do
    label=${pair%%:*}; bin=${pair#*:}
    echo "--- $label ---"
    "$DRRUN" -t drcachesim -- "$bin" "${ARGS[@]}" 2>&1 >/dev/null \
      | grep -E "L1D|LLC|Miss rate|Hit rate" | head -14 \
      || echo "  (drcachesim produced no stats)"
  done
fi
