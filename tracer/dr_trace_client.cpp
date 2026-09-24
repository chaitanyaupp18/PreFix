// dr_trace_client.cpp — streaming alloc / access / dealloc tracer (DynamoRIO).
//
// Emits ONE record per EVENT (not one per object): every allocation, every memory
// access that lands in a tracked heap object, and every free. Each access is
// correlated back to its owning object in O(1) via shadow memory, so you get, per
// object, the exact ordered sequence of touches between alloc and free.
//
// CSV the offline converter produces (trace_to_csv.py):
//   ALLOC :  PC, AllocCounter,  Size, Alloc,   kind(malloc/calloc/realloc), ObjAddr, ts
//   ACCESS:  PC, AccessCount,   Size, Access,  AccessAddr,                   ObjAddr, ts
//   DEALLOC: PC, DeallocCounter,Size, Dealloc, free,                         ObjAddr, ts
//
// Optimized for volume:
//   * Per-thread lock-free output buffers -> per-thread binary files (no hot-path lock).
//   * Hot path stores RAW pc / addr; module:offset is resolved OFFLINE from a dumped
//     module map (no per-access symbolization or module lookup).
//   * Shadow memory (16 B granule -> object slot) attributes an access in O(1).
//   * -sample N : record only 1 in N accesses (alloc/dealloc always kept). Default 1.
//   * Only accesses that hit a tracked heap object are emitted (stack/globals skipped).
//   ts (timestamp) is a single global counter: exact total order for single-threaded
//   apps (mcf, llc -c); for multi-threaded apps it is approximate (see note at g_ts).
//
// Build: cmake -DDynamoRIO_DIR=<DR>/cmake .. && make dr_trace
// Run  : drrun -vm_size 16G -c libdr_trace.so -o /tmp/run [-sample 50] -- <prog> <args>
#include "dr_api.h"
#include "drmgr.h"
#include "drwrap.h"
#include "drutil.h"
#include "drreg.h"
#include <string.h>
#include <stdint.h>

// ----------------------------- record format -------------------------------
enum { EV_ALLOC = 0, EV_ACCESS = 1, EV_DEALLOC = 2 };
enum { TK_MALLOC = 0, TK_CALLOC, TK_REALLOC, TK_FREE };
#pragma pack(push, 1)
typedef struct {
    uint64_t pc;       // raw app PC: alloc/free call site, or the access instruction
    uint64_t counter;  // ALLOC/DEALLOC: global Nth event ; ACCESS: Nth access to this obj
    uint64_t size;     // object size (bytes)
    uint64_t aux;      // ACCESS: access address ; ALLOC/DEALLOC: kind (TK_*)
    uint64_t obj;      // object base address
    uint64_t ts;       // global event timestamp (monotonic)
    uint32_t type;     // EV_*
    uint32_t awidth;   // ACCESS: access width in bytes ; else 0
} TraceRec;
#pragma pack(pop)
#define TRACE_MAGIC 0x5452414345563031ULL  // "TRACEV01"

// ----------------------------- object table --------------------------------
struct Obj { uint64_t base, size, acc; uint32_t kind, nxt; };
#define MAX_OBJS (1u << 24)
static Obj     *objs;
static uint32_t objs_n = 1, free_head = 0;     // slot 0 reserved ("no object")
static uint64_t g_ts;                          // see note: single-thread-exact tick
static uint64_t g_alloc, g_dealloc;            // event counters (under mtx)
static void    *mtx;                           // guards obj table + shadow writes
static char     out_base[1024];
static uint32_t sample_n = 1;
static uint64_t g_ins, g_failreg, g_failaddr;   // instrumentation diagnostics

static inline uint32_t obj_new(void) {
    uint32_t s;
    if (free_head) { s = free_head; free_head = objs[s].nxt; }
    else if (objs_n < MAX_OBJS) s = objs_n++;
    else return 0;
    return s;
}
static inline void obj_del(uint32_t s) { objs[s].base = 0; objs[s].nxt = free_head; free_head = s; }

// ----------------------------- shadow memory -------------------------------
// Two-level flat shadow: top open-addr hash of 16 MB chunks -> mmap'd uint32 arrays
// at 16-byte granularity. mmap'd (dr_raw_mem_alloc), NOT DR heap, so it is not bound
// by DR's reservation. (Identical scheme to the lifetime oracle client.)
#define SH_GRAN_SHIFT  4
#define SH_CHUNK_SHIFT 24
#define SH_CHUNK_ENTS  ((1ULL << SH_CHUNK_SHIFT) >> SH_GRAN_SHIFT)
#define SH_TOP         (1u << 20)
struct ShEnt { uint64_t idx; uint32_t *l2; };
static ShEnt *sh_top;
static inline uint32_t *sh_chunk(uint64_t addr, bool create) {
    uint64_t ci = addr >> SH_CHUNK_SHIFT;
    size_t i = (size_t)((ci * 2654435761ULL) & (SH_TOP - 1));
    for (;;) {
        ShEnt *e = &sh_top[i];
        if (e->l2 && e->idx == ci) return e->l2;
        if (!e->l2) {
            if (!create) return NULL;
            uint32_t *c = (uint32_t *)dr_raw_mem_alloc(SH_CHUNK_ENTS * sizeof(uint32_t),
                              DR_MEMPROT_READ | DR_MEMPROT_WRITE, NULL);
            if (!c) return NULL;
            memset(c, 0, SH_CHUNK_ENTS * sizeof(uint32_t));
            e->idx = ci; e->l2 = c; return c;
        }
        i = (i + 1) & (SH_TOP - 1);
    }
}
static inline uint32_t sh_get(uint64_t a) {
    uint32_t *c = sh_chunk(a, false);
    return c ? c[(a >> SH_GRAN_SHIFT) & (SH_CHUNK_ENTS - 1)] : 0;
}
static void sh_paint(uint64_t base, uint64_t size, uint32_t id) {
    uint64_t g = base & ~(uint64_t)((1u << SH_GRAN_SHIFT) - 1), end = base + size;
    while (g < end) {
        uint32_t *c = sh_chunk(g, id != 0);
        uint64_t chunk_end = ((g >> SH_CHUNK_SHIFT) + 1) << SH_CHUNK_SHIFT;
        uint64_t stop = end < chunk_end ? end : chunk_end;
        if (c) { for (; g < stop; g += (1u << SH_GRAN_SHIFT))
                     c[(g >> SH_GRAN_SHIFT) & (SH_CHUNK_ENTS - 1)] = id; }
        else g = stop;
    }
}

// ----------------------------- per-thread output ---------------------------
#define BUF_RECS (1u << 18)            // 256K recs * 56 B ~= 14 MB per thread
typedef struct { TraceRec *buf; uint32_t n; file_t f; uint64_t tid, seen; } pt_t;
static int tls_idx;
static inline void pt_flush(pt_t *pt) {
    if (pt->n) { dr_write_file(pt->f, pt->buf, (size_t)pt->n * sizeof(TraceRec)); pt->n = 0; }
}
static inline void pt_emit(pt_t *pt, uint64_t pc, uint64_t counter, uint64_t size,
                           uint64_t aux, uint64_t obj, uint64_t ts, uint32_t type, uint32_t aw) {
    TraceRec *r = &pt->buf[pt->n++];
    r->pc = pc; r->counter = counter; r->size = size; r->aux = aux;
    r->obj = obj; r->ts = ts; r->type = type; r->awidth = aw;
    if (pt->n == BUF_RECS) pt_flush(pt);
}
static pt_t *pt_self(void) { return (pt_t *)drmgr_get_tls_field(dr_get_current_drcontext(), tls_idx); }

// ----------------------------- module map (for offline PC resolve) ---------
#define MAXMOD 256
static uint64_t mod_lo[MAXMOD], mod_hi[MAXMOD];
static char     mod_path[MAXMOD][512];
static int      n_mod;
static void wrap_heap(const module_data_t *m);     // defined below
static void event_module_load(void *dc, const module_data_t *m, bool loaded) {
    dr_mutex_lock(mtx);
    if (n_mod < MAXMOD) {
        mod_lo[n_mod] = (uint64_t)(ptr_uint_t)m->start;
        mod_hi[n_mod] = (uint64_t)(ptr_uint_t)m->end;
        strncpy(mod_path[n_mod], m->full_path ? m->full_path : "?", 511);
        n_mod++;
    }
    dr_mutex_unlock(mtx);
    wrap_heap(m);   // (re)wrap the C heap layer whenever a module that exports it loads
}

// ----------------------------- hot path: access ----------------------------
static void record_ref(app_pc addr, uint sz, app_pc pc) {
    uint32_t s = sh_get((uint64_t)(ptr_uint_t)addr);
    if (!s) return;                                   // not a tracked heap object
    pt_t *pt = pt_self();
    if (sample_n > 1 && (++pt->seen % sample_n) != 0) return;
    Obj *o = &objs[s];
    uint64_t ts = ++g_ts;                             // single-thread-exact (see header)
    pt_emit(pt, (uint64_t)(ptr_uint_t)pc, ++o->acc, o->size,
            (uint64_t)(ptr_uint_t)addr, o->base, ts, EV_ACCESS, sz);
}

// ----------------------------- alloc / free emit ---------------------------
static void on_alloc(uint64_t base, uint64_t size, uint32_t kind, app_pc site) {
    if (!base || !size) return;
    dr_mutex_lock(mtx);
    uint32_t s = obj_new();
    if (!s) { dr_mutex_unlock(mtx); return; }
    Obj *o = &objs[s]; o->base = base; o->size = size; o->acc = 0; o->kind = kind;
    sh_paint(base, size, s);
    uint64_t c = ++g_alloc, ts = ++g_ts;
    dr_mutex_unlock(mtx);
    pt_emit(pt_self(), (uint64_t)(ptr_uint_t)site, c, size, kind, base, ts, EV_ALLOC, 0);
}
static void on_free(uint64_t base, app_pc site) {
    if (!base) return;
    dr_mutex_lock(mtx);
    uint32_t s = sh_get(base);
    if (!s || objs[s].base != base) { dr_mutex_unlock(mtx); return; }
    uint64_t size = objs[s].size;
    sh_paint(base, size, 0); obj_del(s);
    uint64_t c = ++g_dealloc, ts = ++g_ts;
    dr_mutex_unlock(mtx);
    pt_emit(pt_self(), (uint64_t)(ptr_uint_t)site, c, size, TK_FREE, base, ts, EV_DEALLOC, 0);
}

// ----------------------------- allocator wrappers --------------------------
static void pre_size(void *wc, void **ud) { *ud = drwrap_get_arg(wc, 0); }            // malloc(sz)
static void pre_calloc(void *wc, void **ud) {
    size_t a = (size_t)(ptr_uint_t)drwrap_get_arg(wc, 0);
    size_t b = (size_t)(ptr_uint_t)drwrap_get_arg(wc, 1);
    *ud = (void *)(ptr_uint_t)(a * b);
}
static void post_malloc(void *wc, void *ud) {
    on_alloc((uint64_t)(ptr_uint_t)drwrap_get_retval(wc), (uint64_t)(ptr_uint_t)ud,
             TK_MALLOC, (app_pc)drwrap_get_retaddr(wc));
}
static void post_calloc(void *wc, void *ud) {
    on_alloc((uint64_t)(ptr_uint_t)drwrap_get_retval(wc), (uint64_t)(ptr_uint_t)ud,
             TK_CALLOC, (app_pc)drwrap_get_retaddr(wc));
}
static uint64_t realloc_newsz;
static void pre_realloc(void *wc, void **ud) {
    uint64_t old = (uint64_t)(ptr_uint_t)drwrap_get_arg(wc, 0);
    realloc_newsz = (uint64_t)(ptr_uint_t)drwrap_get_arg(wc, 1);
    if (old) on_free(old, (app_pc)drwrap_get_retaddr(wc));   // retire old generation
    *ud = (void *)(ptr_uint_t)realloc_newsz;
}
static void post_realloc(void *wc, void *ud) {
    on_alloc((uint64_t)(ptr_uint_t)drwrap_get_retval(wc), (uint64_t)(ptr_uint_t)ud,
             TK_REALLOC, (app_pc)drwrap_get_retaddr(wc));
}
static void pre_free(void *wc, void **ud) {
    (void)ud; on_free((uint64_t)(ptr_uint_t)drwrap_get_arg(wc, 0), (app_pc)drwrap_get_retaddr(wc));
}
static void wrap1(const module_data_t *m, const char *n,
                  void (*pre)(void *, void **), void (*post)(void *, void *)) {
    app_pc f = (app_pc)dr_get_proc_address(m->handle, n);
    if (f) drwrap_wrap(f, pre, post);
}
static void wrap_heap(const module_data_t *m) {
    // Wrap only the C heap layer: operator new -> malloc, delete -> free, so every
    // block is captured exactly once (wrapping new too would double-count).
    wrap1(m, "malloc",  pre_size,    post_malloc);
    wrap1(m, "calloc",  pre_calloc,  post_calloc);
    wrap1(m, "realloc", pre_realloc, post_realloc);
    wrap1(m, "free",    pre_free,    NULL);
}

// ----------------------------- instrumentation -----------------------------
static void instrument_ref(void *dc, instrlist_t *bb, instr_t *where, opnd_t ref) {
    reg_id_t reg_addr, reg_scratch, swap = DR_REG_NULL;
    if (drreg_reserve_aflags(dc, bb, where) != DRREG_SUCCESS) { g_failreg++; return; }
    if (drreg_reserve_register(dc, bb, where, NULL, &reg_addr) != DRREG_SUCCESS) {
        drreg_unreserve_aflags(dc, bb, where); g_failreg++; return; }
    if (drreg_reserve_register(dc, bb, where, NULL, &reg_scratch) != DRREG_SUCCESS) {
        drreg_unreserve_register(dc, bb, where, reg_addr);
        drreg_unreserve_aflags(dc, bb, where); g_failreg++; return; }
    // Put the operand's address registers back to their APP values before the meta
    // address computation. Without this, a base register that drreg has spilled (e.g.
    // for the mangling of an adjacent call) yields a WRONG address -> shadow miss ->
    // the access is silently dropped. This was the "last ref before a call" bug.
    if (drreg_restore_app_values(dc, bb, where, ref, &swap) != DRREG_SUCCESS) swap = DR_REG_NULL;
    if (drutil_insert_get_mem_addr(dc, bb, where, ref, reg_addr, reg_scratch)) {
        dr_insert_clean_call(dc, bb, where, (void *)record_ref, false, 3,
                             opnd_create_reg(reg_addr),
                             OPND_CREATE_INT32(drutil_opnd_mem_size_in_bytes(ref, where)),
                             OPND_CREATE_INTPTR(instr_get_app_pc(where)));
        g_ins++;
    } else g_failaddr++;
    if (swap != DR_REG_NULL) drreg_unreserve_register(dc, bb, where, swap);
    drreg_unreserve_register(dc, bb, where, reg_scratch);
    drreg_unreserve_register(dc, bb, where, reg_addr);
    drreg_unreserve_aflags(dc, bb, where);
}
static dr_emit_flags_t event_bb(void *dc, void *tag, instrlist_t *bb, instr_t *instr,
                                bool for_trace, bool translating, void *ud) {
    if (!instr_is_app(instr)) return DR_EMIT_DEFAULT;
    if (!instr_reads_memory(instr) && !instr_writes_memory(instr)) return DR_EMIT_DEFAULT;
    for (int i = 0; i < instr_num_srcs(instr); i++)
        if (opnd_is_memory_reference(instr_get_src(instr, i)))
            instrument_ref(dc, bb, instr, instr_get_src(instr, i));
    for (int i = 0; i < instr_num_dsts(instr); i++)
        if (opnd_is_memory_reference(instr_get_dst(instr, i)))
            instrument_ref(dc, bb, instr, instr_get_dst(instr, i));
    return DR_EMIT_DEFAULT;
}

// ----------------------------- thread + exit -------------------------------
static void thread_init(void *dc) {
    pt_t *pt = (pt_t *)dr_thread_alloc(dc, sizeof(pt_t));
    pt->buf = (TraceRec *)dr_raw_mem_alloc((size_t)BUF_RECS * sizeof(TraceRec),
                  DR_MEMPROT_READ | DR_MEMPROT_WRITE, NULL);
    pt->n = 0; pt->seen = 0; pt->tid = dr_get_thread_id(dc);
    char p[1100]; dr_snprintf(p, sizeof p, "%s.t%llu.bin", out_base, (unsigned long long)pt->tid);
    pt->f = dr_open_file(p, DR_FILE_WRITE_OVERWRITE);
    uint64_t hdr[2] = { TRACE_MAGIC, sizeof(TraceRec) };
    dr_write_file(pt->f, hdr, sizeof hdr);
    drmgr_set_tls_field(dc, tls_idx, pt);
}
static void thread_exit(void *dc) {
    pt_t *pt = (pt_t *)drmgr_get_tls_field(dc, tls_idx);
    if (!pt) return;
    pt_flush(pt); dr_close_file(pt->f);
    dr_raw_mem_free(pt->buf, (size_t)BUF_RECS * sizeof(TraceRec));
    dr_thread_free(dc, pt, sizeof(pt_t));
}
static void event_exit(void) {
    char mp[1100]; dr_snprintf(mp, sizeof mp, "%s.modules.txt", out_base);
    file_t mf = dr_open_file(mp, DR_FILE_WRITE_OVERWRITE);
    if (mf != INVALID_FILE) {
        for (int i = 0; i < n_mod; i++) {
            char line[700];
            int n = dr_snprintf(line, sizeof line, "0x%llx\t0x%llx\t%s\n",
                                (unsigned long long)mod_lo[i], (unsigned long long)mod_hi[i], mod_path[i]);
            if (n > 0) dr_write_file(mf, line, n);
        }
        dr_close_file(mf);
    }
    dr_fprintf(STDERR, "[trace] events: alloc=%llu access_ts=%llu dealloc=%llu (sample=1/%u)\n",
               (unsigned long long)g_alloc, (unsigned long long)g_ts,
               (unsigned long long)g_dealloc, sample_n);
    dr_fprintf(STDERR, "[trace] instrumented refs=%llu  drreg_fail=%llu  getaddr_fail=%llu\n",
               (unsigned long long)g_ins, (unsigned long long)g_failreg, (unsigned long long)g_failaddr);
    drmgr_unregister_tls_field(tls_idx);
    drutil_exit(); drwrap_exit(); drreg_exit(); drmgr_exit();
}

DR_EXPORT void dr_client_main(client_id_t id, int argc, const char *argv[]) {
    const char *base = "/tmp/trace";
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "-o") && i + 1 < argc) base = argv[++i];
        else if (!strcmp(argv[i], "-sample") && i + 1 < argc) {
            long v = 0; for (const char *p = argv[++i]; *p >= '0' && *p <= '9'; p++) v = v * 10 + (*p - '0');
            if (v > 0) sample_n = (uint32_t)v;
        }
    }
    dr_snprintf(out_base, sizeof out_base, "%s", base);

    objs   = (Obj *)dr_raw_mem_alloc((size_t)MAX_OBJS * sizeof(Obj),
                 DR_MEMPROT_READ | DR_MEMPROT_WRITE, NULL);
    sh_top = (ShEnt *)dr_raw_mem_alloc((size_t)SH_TOP * sizeof(ShEnt),
                 DR_MEMPROT_READ | DR_MEMPROT_WRITE, NULL);
    if (!objs || !sh_top) { dr_fprintf(STDERR, "[trace] ALLOC FAILED\n"); dr_abort(); }
    memset(sh_top, 0, (size_t)SH_TOP * sizeof(ShEnt));

    drreg_options_t ops = { sizeof(ops), 4, false };
    // conservative=false above; we request extra spill slots because the memory
    // instruction right before a mangled call competes with DR's own scratch reg.
    ops.num_spill_slots = 8;
    mtx = dr_mutex_create();
    drmgr_init(); drwrap_init(); drutil_init(); drreg_init(&ops);
    tls_idx = drmgr_register_tls_field();
    drmgr_register_module_load_event(event_module_load);
    drmgr_register_thread_init_event(thread_init);
    drmgr_register_thread_exit_event(thread_exit);
    drmgr_register_bb_instrumentation_event(NULL, event_bb, NULL);
    dr_register_exit_event(event_exit);
    dr_fprintf(STDERR, "[trace] streaming alloc/access/dealloc -> %s.t<tid>.bin  sample=1/%u\n",
               out_base, sample_n);
}
