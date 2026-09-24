"""HDS Reconstitution: OHDS -> RHDS + Hot Singleton objects.

Implements the paper's reconstitution algorithm. Its input is the OHDS
(Original HDS) -- every observed Hot Data Stream, in descending order of memory
references. Because the same object may appear in several OHDS entries, not all
of them are exploitable. Reconstitution produces the RHDS (Reconstituted HDS),
constructed so that **no object appears in more than one HDS**, and every HDS
retains at least two objects.

Each OHDS entry is resolved one of three ways:
    * unchanged inclusion  - added to RHDS as is;
    * merge                - merged with one existing RHDS entry (the paper does
      not merge three or more, since a layout good for two rarely generalizes);
    * split                - the novel objects are separated out; the remainder
      becomes its own HDS if at least two objects are left.
An object left on its own is not an HDS: it becomes a **Hot Singleton object**,
placed after the RHDS in the preallocated region.

    * ``shrink``      - the reconstitution pass described above.
    * ``merge_sites`` - merges allocation-site lists that share any PC.

The logic is self-contained and free of I/O so it can be exposed to OpenEvolve.
"""

from __future__ import annotations


class Node:
    __slots__ = ("data", "next", "prev")

    def __init__(self, data=None):
        self.data = data
        self.next = None
        self.prev = None


class DoublyLinkedList:
    """Ordered, set-like container. Order encodes intended placement order."""

    def __init__(self, items=None):
        self.head = None
        if items:
            for item in items:
                self.append(item)

    def append(self, data):
        node = Node(data)
        if not self.head:
            self.head = node
            return
        cur = self.head
        while cur.next:
            cur = cur.next
        cur.next = node
        node.prev = cur

    def prepend(self, data):
        node = Node(data)
        if self.head is not None:
            self.head.prev = node
            node.next = self.head
        self.head = node

    def to_set(self):
        """Return contents as an ordered list (name kept for compatibility)."""
        out, cur = [], self.head
        while cur:
            out.append(cur.data)
            cur = cur.next
        return out

    def is_mergeable(self, other):
        """True unless the two lists are non-empty and completely disjoint."""
        a, b = self.to_set(), other.to_set()
        if (len(a) == 0) != (len(b) == 0):      # exactly one is empty
            return False
        if a and b and len(set(a) | set(b)) == len(a) + len(b):
            return False                        # both non-empty, no overlap
        return True

    def union(self, other):
        """Ordered union: shared members first, then self's, then other's."""
        a, b = self.to_set(), other.to_set()
        merged = [x for x in a if x in b]       # common, in self's order
        for x in a:
            if x not in merged:
                merged.append(x)
        for x in b:
            if x not in merged:
                merged.insert(0, x)
        return DoublyLinkedList(merged)

    def remove_common(self, other):
        """Return a new list of self's members that are absent from other."""
        b = set(other.to_set())
        return DoublyLinkedList([x for x in self.to_set() if x not in b])


class shrink:
    """PreFix shrink heuristic.

    Returns ``(rhds, singleton_H)`` where ``rhds`` are the Reconstituted HDS
    (ordered, no object in two of them) and ``singleton_H`` holds the Hot
    Singleton objects -- hot objects that collapsed to a
    single member (the hot-singleton objects used for the data layout).
    """

    def __init__(self, H):
        self.H = H
        self.singleton_H = []

    def _note_singleton(self, value):
        if value not in self.singleton_H:
            self.singleton_H.append(value)

    def shrink_hds(self):
        if not self.H:
            return [], []

        regions = [DoublyLinkedList(self.H[0])]
        merged_flag = [False]                    # has region[j] absorbed a stream?

        for stream in self.H[1:]:
            cur = DoublyLinkedList(stream)
            no_common = True
            shrunk = False

            for j, region in enumerate(regions):
                if not cur.is_mergeable(region):
                    continue
                if not merged_flag[j]:
                    # Strip everything already placed in *other* regions.
                    remaining = cur
                    for k, other in enumerate(regions):
                        if k != j:
                            remaining = remaining.remove_common(other)
                    rem = remaining.to_set()
                    if len(rem) > 1:
                        if sorted(rem) != sorted(region.to_set()):
                            regions[j] = region.union(remaining)
                            merged_flag[j] = True
                    elif len(rem) == 1:
                        self._note_singleton(rem[0])
                    shrunk = True
                    break
                else:
                    no_common = False            # overlaps an already-merged region

            if not shrunk and no_common:
                regions.append(DoublyLinkedList(stream))
                merged_flag.append(False)
            elif not shrunk and not no_common:
                remaining = cur
                for region in regions:
                    if cur.is_mergeable(region):
                        remaining = remaining.remove_common(region)
                rem = remaining.to_set()
                if len(rem) > 1:
                    regions.append(remaining)
                    merged_flag.append(False)
                elif len(rem) == 1:
                    self._note_singleton(rem[0])

        return [r.to_set() for r in regions], self.singleton_H


class merge_sites:
    """Merge allocation-site (PC) lists that share at least one site."""

    def __init__(self, regions):
        self.regions = regions

    def merge(self):
        if not self.regions:
            return []
        sources = [DoublyLinkedList(r) for r in self.regions]
        out = [DoublyLinkedList(self.regions[0])]
        for i in range(1, len(sources)):
            merged = False
            for j in range(len(out)):
                if out[j].is_mergeable(sources[i]):
                    out[j] = out[j].union(sources[i])
                    merged = True
            if not merged:
                out.append(DoublyLinkedList(self.regions[i]))
        return [r.to_set() for r in out]
