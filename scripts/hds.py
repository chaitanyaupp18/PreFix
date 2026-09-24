"""PreFix HDS Finder — Hot Data Streams from a heap access trace.

The paper defines a Hot Data Stream (HDS) as a set of hot objects that are
repeatedly referenced together; an HDS must contain **at least two objects**.

This module implements the "Trace Analysis -> HDS & Hot Singleton Objects" box
of Figure 8 in two steps:

  1. Find candidate HDS by scanning the access sequence for recurring sets of
     distinct objects of a given HDS length (>= 2). The paper identifies HDS
     with the Longest Common Subsequence algorithm rather than Sequitur; this
     implementation uses a recurring-window scan over the same access sequence.
  2. **HDS Reconstitution** (`shrink.py`) turns the Original HDS list (OHDS,
     ordered by memory references) into Reconstituted HDS (RHDS), in which no
     object appears in more than one HDS. Objects left alone become **Hot
     Singleton objects**, placed after the RHDS in the preallocated region.

numpy is used when available (much faster on multi-million-event traces) but is
NOT required — there is an equivalent pure-stdlib path.
"""

from __future__ import annotations

import math
from collections import Counter
from dataclasses import dataclass

from shrink import shrink

try:
    import numpy as np
except ImportError:                                   # pragma: no cover
    np = None


@dataclass
class HDSConfig:
    hds_length: int = 2           # objects per HDS; the paper requires >= 2
    min_frequency: float = 0.05   # recurrence threshold (see freq_mode)
    freq_mode: str = "ratio_max"  # ratio_max | ratio_windows | absolute
    min_count: int = 2            # absolute floor on recurrence count
    max_ohds: int = 50            # cap on OHDS entries fed to reconstitution


def _threshold(counts, num_windows, cfg_min_freq, freq_mode, min_count):
    if freq_mode == "ratio_windows":
        return max(min_count, math.ceil(cfg_min_freq * num_windows))
    if freq_mode == "absolute":
        return min_count
    # ratio_max: a fraction of the hottest stream's recurrence
    return max(min_count, math.ceil(cfg_min_freq * float(max(counts))))


def _streams_py(trace, length, min_frequency, freq_mode, min_count):
    """Pure-stdlib sliding window: count recurring fully-distinct object sets."""
    n = len(trace)
    num_windows = n - length + 1
    tally = Counter()
    for i in range(num_windows):
        w = sorted(trace[i:i + length])
        # all-distinct <=> no two adjacent entries equal once sorted
        distinct = True
        for j in range(length - 1):
            if w[j] == w[j + 1]:
                distinct = False
                break
        if distinct:
            tally[tuple(w)] += 1
    if not tally:
        return [], []
    sets = list(tally.keys())
    counts = [tally[s] for s in sets]
    thr = _threshold(counts, num_windows, min_frequency, freq_mode, min_count)
    keep = [i for i, c in enumerate(counts) if c >= thr]
    return [list(sets[i]) for i in keep], [counts[i] for i in keep]


def _streams_np(trace, length, min_frequency, freq_mode, min_count):
    """Vectorised equivalent of _streams_py."""
    arr = np.asarray(trace, dtype=np.int64)
    windows = np.lib.stride_tricks.sliding_window_view(arr, length)
    num_windows = windows.shape[0]

    ws = np.sort(windows, axis=1)
    if length > 1:
        ws = ws[np.all(ws[:, 1:] != ws[:, :-1], axis=1)]
    if len(ws) == 0:
        return [], []

    # Encode each sorted window as one integer when the alphabet allows it.
    base = int(arr.max()) + 1
    if length * math.log2(max(base, 2)) < 62:
        keys = np.zeros(len(ws), dtype=np.int64)
        for c in range(length):
            keys = keys * base + ws[:, c]
        uniq, counts = np.unique(keys, return_counts=True)
        sets = np.empty((len(uniq), length), dtype=np.int64)
        rem = uniq.copy()
        for c in range(length - 1, -1, -1):
            sets[:, c] = rem % base
            rem //= base
    else:
        sets, counts = np.unique(ws, axis=0, return_counts=True)

    counts = counts.tolist()
    thr = _threshold(counts, num_windows, min_frequency, freq_mode, min_count)
    keep = [i for i, c in enumerate(counts) if c >= thr]
    return [[int(x) for x in sets[i]] for i in keep], [counts[i] for i in keep]


def candidate_hds(trace, length, min_frequency,
                      freq_mode="ratio_max", min_count=2):
    """Return (OHDS candidate sets, memory-reference counts)."""
    if trace is None or len(trace) < length or length < 1:
        return [], []
    if np is not None:
        return _streams_np(trace, length, min_frequency, freq_mode, min_count)
    return _streams_py(trace, length, min_frequency, freq_mode, min_count)


def prefix_layout(trace, cfg: HDSConfig):
    """Find HDS, then reconstitute them — the PreFix layout selection.

    Returns (rhds, rhds_refs, singletons):
      rhds       — Reconstituted HDS: object-id lists with no object in two HDS
      rhds_refs  — memory references attributed to each RHDS
      singletons — Hot Singleton objects left over by reconstitution
    """
    sets, counts = candidate_hds(trace, cfg.hds_length, cfg.min_frequency,
                                     cfg.freq_mode, cfg.min_count)
    if not sets:
        return [], [], []

    # OHDS: all observed HDS in descending order of memory references.
    order = sorted(range(len(counts)), key=lambda i: -counts[i])[: cfg.max_ohds]
    ohds = [sets[i] for i in order]

    rhds, singletons = shrink(ohds).shrink_hds()

    rhds_refs = []
    for g in rhds:
        gset = set(g)
        rhds_refs.append(int(sum(c for s, c in zip(sets, counts)
                                 if set(s) <= gset)))
    return rhds, rhds_refs, singletons
