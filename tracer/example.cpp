// example.cpp — a tiny program with four allocation sites and four DISTINCT
// heap-access patterns. Trace it and read example.csv: every alloc, every access
// (attributed to its object), and every free appears, in time order.
//
//   Build + trace + convert:   make all     then open example.csv
//
// What to look for in the CSV (columns: PC, Counter, Size, Type, kind|AccessAddr, ObjAddr, ts):
//   * site #1 array : many "Access" rows whose AccessAddr climbs by 4 bytes (a[i]).
//   * site #2 scratch: alloc, a few accesses, then a free with a SMALL ts gap
//                      (freed right after last use -> no "memory drag").
//   * site #3 drag  : accessed early, then NOT touched again, but freed only at the
//                      very end -> a LARGE gap between its last Access ts and its
//                      Dealloc ts. That gap is "memory kept longer than needed".
//   * site #4 vec   : a realloc -> you'll see the old block's Dealloc and a new
//                      Alloc (kind=realloc) at the same/!= address.
#include <cstdlib>
#include <cstring>
#include <cstdio>

// A separate function so the malloc here shows its own PC (call site) in the trace.
static int *make_array(int n) { return (int *)malloc(n * sizeof(int)); }

int main(void) {
    // ---- site #1: array filled then summed (lots of accesses, rising offsets) ----
    const int n = 16;
    int *a = make_array(n);                  // ALLOC #1 (malloc, 64 B)
    for (int i = 0; i < n; i++) a[i] = i;    // n writes  -> AccessAddr = base, base+4, ...
    long sum = 0;
    for (int i = 0; i < n; i++) sum += a[i]; // n reads

    // ---- site #2: short-lived scratch, freed right after last use (NO drag) ----
    char *scratch = (char *)calloc(64, 1);   // ALLOC #2 (calloc, 64 B)
    strcpy(scratch, "hello world");          // a few writes
    size_t len = strlen(scratch);            // a few reads
    free(scratch);                           // last use and free are adjacent in ts

    // ---- site #3: "dragged" buffer: used early, kept alive until the very end ----
    double *drag = (double *)malloc(8 * sizeof(double)); // ALLOC #3 (64 B)
    for (int i = 0; i < 8; i++) drag[i] = i * 1.5;       // used HERE ...
    // ... never touched again, but not freed until the end (this is the drag)

    // ---- site #4: a growing vector via realloc (generation change) ----
    int *vec = (int *)malloc(4 * sizeof(int));   // ALLOC #4 (16 B)
    for (int i = 0; i < 4; i++) vec[i] = i;
    vec = (int *)realloc(vec, 32 * sizeof(int)); // REALLOC: old gen freed, new gen opened
    for (int i = 4; i < 32; i++) vec[i] = i;

    // keep the compiler from optimizing the buffers away
    printf("sum=%ld len=%zu vec[31]=%d drag[7]=%g\n", sum, len, vec[31], drag[7]);

    free(a);
    free(vec);
    free(drag);     // freed LAST -> long actual lifetime, big drag vs its last use
    return 0;
}
