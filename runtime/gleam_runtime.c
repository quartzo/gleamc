/* gleamc kernel implementation (see gleam_runtime.h). */
#define _POSIX_C_SOURCE 200809L /* nanosleep / fileno / fstat (scheduler+libuv) */
#include "gleam_runtime.h"

static size_t codepoint_offset(GleamcString s, int64_t index);

#include <math.h>
#include <pthread.h>
#include <uv.h>
#include <fcntl.h>
#include <string.h>
#include <stdint.h>
#include <unistd.h>

#include <unicode/ustring.h>
#include <utf8proc.h>

#ifdef GLEAMC_RC_AUDIT
/* Refcount audit: never free on 0/negative (allow negative), and report at
 * exit every block whose refcount ended <0 or >0, with the last touch site. */
typedef struct GleamcAudit {
    void* p;      /* NULL marks an empty slot */
    long rc;
    int warned;
    const char* site;
} GleamcAudit;
static GleamcAudit* _audit = NULL;
static size_t _audit_cap = 0;   /* power of two */
static size_t _audit_used = 0;

static size_t _audit_hash(void* p) {
    uint64_t x = (uint64_t)(uintptr_t)p;
    x ^= x >> 33;
    x *= 0xff51afd7ed558ccdULL;
    x ^= x >> 33;
    return (size_t)x;
}

static void _audit_grow(void) {
    size_t nc = _audit_cap ? _audit_cap * 2 : 1024;
    GleamcAudit* nt = (GleamcAudit*)calloc(nc, sizeof(GleamcAudit));
    if (nt == NULL) return;
    for (size_t i = 0; i < _audit_cap; i++) {
        if (_audit[i].p == NULL) continue;
        size_t j = _audit_hash(_audit[i].p) & (nc - 1);
        while (nt[j].p != NULL) j = (j + 1) & (nc - 1);
        nt[j] = _audit[i];
    }
    free(_audit);
    _audit = nt;
    _audit_cap = nc;
}

static GleamcAudit* _audit_get(void* p) {
    if (p == NULL) return NULL;
    if (_audit_used * 10 >= _audit_cap * 7) _audit_grow();
    if (_audit == NULL) return NULL;
    size_t i = _audit_hash(p) & (_audit_cap - 1);
    while (_audit[i].p != NULL && _audit[i].p != p) {
        i = (i + 1) & (_audit_cap - 1);
    }
    if (_audit[i].p == NULL) {
        _audit[i].p = p;
        _audit[i].rc = 0;
        _audit[i].warned = 0;
        _audit[i].site = "?";
        _audit_used++;
    }
    return &_audit[i];
}

static void _audit_init(void* p, const char* site) {
    GleamcAudit* e = _audit_get(p);
    if (e != NULL) {
        e->rc = 1; /* allocation starts at refcount 1 */
        e->site = site;
    }
}

static void _audit_touch(void* p, const char* site, long delta) {
    GleamcAudit* e = _audit_get(p);
    if (e == NULL) return;
    e->rc += delta;
    if (site != NULL) e->site = site;
    if (e->rc < 0 && !e->warned) {
        e->warned = 1;
        fprintf(stderr, "gleamc: rc underflow (rc=%ld) at %s p=%p\n", e->rc, e->site, p);
    }
}

void Gleamc_rc_retain(void* p, const char* site) {
    if (p == NULL) return;
    GleamcHdr* h = (GleamcHdr*)((uint8_t*)p - sizeof(GleamcHdr));
    if (h->refcount == GLEAMC_RC_STATIC) return;
    h->refcount++;
    _audit_touch(p, site, 1);
}

void Gleamc_rc_release(void* p, const char* site) {
    if (p == NULL) return;
    GleamcHdr* h = (GleamcHdr*)((uint8_t*)p - sizeof(GleamcHdr));
    if (h->refcount == GLEAMC_RC_STATIC) return;
    h->refcount--;
    _audit_touch(p, site, -1);
    /* Audit mode: never free (allow negative). */
}
#else
void Gleamc_rc_retain(void* p, const char* site) {
    (void)site;
    if (p == NULL) return;
    GleamcHdr* h = (GleamcHdr*)((uint8_t*)p - sizeof(GleamcHdr));
    if (h->refcount != GLEAMC_RC_STATIC) h->refcount++;
}

void Gleamc_rc_release(void* p, const char* site) {
    (void)site;
    if (p == NULL) return;
    GleamcHdr* h = (GleamcHdr*)((uint8_t*)p - sizeof(GleamcHdr));
    if (h->refcount != GLEAMC_RC_STATIC && --h->refcount == 0) {
        gleamc_release_slow(h);
    }
}
#endif

static size_t _gleamc_live = 0;

/* Call-depth probe (emitted only when the backend is asked to instrument with
 * GLEAMC_CALL_DEPTH). The generated code bumps the `@__gleamc_depth` global
 * directly (load/add/store) on entry and (load/sub/store) before each return;
 * when the depth reaches `gleamc_depth_max` (settable at run time through
 * GLEAMC_CALL_DEPTH) it calls this to name the function that went deepest and
 * abort. */
int64_t gleamc_depth_max = 100;

void gleamc_depth_die(const char* fn) {
    fprintf(stderr, "gleamc: call depth %lld reached in %s\n",
            (long long)gleamc_depth_max, fn != NULL ? fn : "?");
    fflush(stderr);
    abort();
}

/* Optional counters for the BigDict evaluation (GLEAMC_BIGDICT_STATS=1). */
static int _bd_stats = 0;
static size_t _bd_cow_calls = 0, _bd_cow_copies = 0, _bd_cow_bytes = 0;
static size_t _bd_take_calls = 0, _bd_take_moves = 0, _bd_take_retains = 0;

static void _gleamc_report_leaks(void) {
    const char* flag = getenv("GLEAMC_MEM_REPORT");
    if (flag != NULL) {
        fprintf(stderr, "gleamc: live blocks = %zu\n", _gleamc_live);
    }
    if (_bd_stats) {
        fprintf(stderr, "bigdict stats: cow calls=%zu copies=%zu bytes=%zu\n",
                _bd_cow_calls, _bd_cow_copies, _bd_cow_bytes);
        fprintf(stderr, "bigdict stats: take calls=%zu moves=%zu retains=%zu\n",
                _bd_take_calls, _bd_take_moves, _bd_take_retains);
    }
#ifdef GLEAMC_RC_AUDIT
    {
        size_t bad = 0;
        for (size_t i = 0; i < _audit_cap; i++) {
            if (_audit[i].p == NULL) continue;
            if (_audit[i].rc != 0) {
                fprintf(stderr, "gleamc: rc=%ld at %s p=%p\n", _audit[i].rc,
                        _audit[i].site, _audit[i].p);
                bad++;
            }
        }
        fprintf(stderr, "gleamc: rc audit: %zu blocks with rc != 0\n", bad);
    }
#endif
}

__attribute__((constructor)) static void _gleamc_init(void) {
    atexit(_gleamc_report_leaks);
    if (getenv("GLEAMC_BIGDICT_STATS") != NULL) _bd_stats = 1;
    {
        const char* depth = getenv("GLEAMC_CALL_DEPTH");
        if (depth != NULL) {
            long v = atol(depth);
            if (v > 0) gleamc_depth_max = (int64_t)v;
        }
    }
}

void* gleamc_alloc(size_t size) {
    GleamcHdr* h = (GleamcHdr*)malloc(sizeof(GleamcHdr) + size);
    if (h == NULL) {
        fputs("gleamc: out of memory\n", stderr);
        abort();
    }
    h->refcount = 1;
    _gleamc_live++;
#ifdef GLEAMC_RC_AUDIT
    _audit_init((uint8_t*)h + sizeof(GleamcHdr), "(alloc)");
#endif
    return (uint8_t*)h + sizeof(GleamcHdr);
}

/* Like `gleamc_alloc` but zeroes the payload (used for frames, whose fields
 * may be released before they are ever assigned). */
void* gleamc_alloc0(size_t size) {
    void* p = gleamc_alloc(size);
    memset(p, 0, size);
    return p;
}

void* gleamc_alloc_site(size_t size, const char* site) {
    void* p = gleamc_alloc(size);
#ifdef GLEAMC_RC_AUDIT
    {
        GleamcAudit* e = _audit_get(p);
        if (e != NULL) {
            e->rc = 1;
            e->site = site;
        }
    }
#else
    (void)site;
#endif
    return p;
}

void* gleamc_alloc0_site(size_t size, const char* site) {
    void* p = gleamc_alloc_site(size, site);
    memset(p, 0, size);
    return p;
}

void gleamc_release_slow(GleamcHdr* h) {
    if (h->refcount == GLEAMC_RC_STATIC) return;
    _gleamc_live--;
    free(h);
}

/* Release a refcounted handle that owns sub-references: at refcount 0 run
 * `dtor` (which releases the sub-references) and free the cell. Under the audit
 * build the cell is never freed, but the destructor still runs so the audit
 * sees the sub-references drop to 0. */
void gleamc_release_with(void* p, void (*dtor)(void*), const char* site) {
    if (p == NULL) return;
    GleamcHdr* h = (GleamcHdr*)((uint8_t*)p - sizeof(GleamcHdr));
    if (h->refcount == GLEAMC_RC_STATIC) return;
#ifdef GLEAMC_RC_AUDIT
    h->refcount--;
    _audit_touch(p, site, -1);
    if (h->refcount == 0 && dtor != NULL) dtor(p);
#else
    (void)site;
    if (--h->refcount == 0) {
        if (dtor != NULL) dtor(p);
        _gleamc_live--;
        free(h);
    }
#endif
}

size_t gleamc_live_blocks(void) { return _gleamc_live; }

GleamcString gleamc_string_lit(const char* data, size_t len) {
    char* buf = (char*)gleamc_alloc_site(len + 1, "string");
    memcpy(buf, data, len);
    buf[len] = '\0';
    return (GleamcString){buf, len};
}

GleamcString gleamc_string_concat(GleamcString a, GleamcString b) {
    size_t len = a.len + b.len;
    char* buf = (char*)gleamc_alloc_site(len + 1, "runtime:concat");
    memcpy(buf, a.data, a.len);
    memcpy(buf + a.len, b.data, b.len);
    buf[len] = '\0';
    return (GleamcString){buf, len};
}

/* FNV-1a over bytes, exposed as the `gleamc.hash` builtin used by `std/dict`.
 * Returns a non-negative 31-bit value so the HAMT's base-32 index arithmetic
 * stays in range. */
static uint64_t gleamc_fnv1a(const uint8_t* data, size_t len) {
    uint64_t h = 1469598103934665603ULL;
    for (size_t i = 0; i < len; i++) {
        h ^= data[i];
        h *= 1099511628211ULL;
    }
    return h;
}

/* splitmix64 finalizer: FNV's low bits are weak, but the HAMT consumes the
 * hash from the least-significant base-32 digit first, so avalanche the bits
 * before returning (and keep the result non-negative). */
static uint64_t gleamc_mix64(uint64_t x) {
    x ^= x >> 30;
    x *= 0xbf58476d1ce4e5b9ULL;
    x ^= x >> 27;
    x *= 0x94d049bb133111ebULL;
    x ^= x >> 31;
    return x & 0x3fffffffffffffffULL;
}

int64_t Gleamc_hash_string(GleamcString s) {
    return (int64_t)gleamc_mix64(gleamc_fnv1a((const uint8_t*)s.data, s.len));
}

int64_t Gleamc_hash_i64(int64_t v) {
    uint8_t b[8];
    memcpy(b, &v, sizeof(v));
    return (int64_t)gleamc_mix64(gleamc_fnv1a(b, sizeof(b)));
}

int64_t Gleamc_hash_f64(double v) {
    uint8_t b[8];
    memcpy(b, &v, sizeof(v));
    return (int64_t)gleamc_mix64(gleamc_fnv1a(b, sizeof(b)));
}

/* ------------------------------------------------------------------ */
/* Buffer(a): a refcounted, fixed-length, copy-on-write array. Opaque  */
/* to Gleam; the compiler supplies the element size and glue.          */
/* ------------------------------------------------------------------ */

typedef struct {
    size_t len;
    size_t elem_size;
    void (*elem_drop)(void*); /* in-place drop of one element, or NULL */
} GleamcBufferHdr;

static size_t gleamc_refcount_of(void* p) {
    GleamcHdr* h = (GleamcHdr*)((uint8_t*)p - sizeof(GleamcHdr));
    return (size_t)h->refcount;
}

/* Allocates a zero-filled buffer of `len` elements. `elem_drop` runs on each
 * element when the buffer's last reference is released. */
void* Gleamc_buffer_new(int64_t len, int64_t elem_size,
                        void (*elem_drop)(void*)) {
    if (len < 0) len = 0;
    size_t n = (size_t)len;
    size_t es = (size_t)elem_size;
    GleamcBufferHdr* h =
        (GleamcBufferHdr*)gleamc_alloc0(sizeof(GleamcBufferHdr) + n * es);
    h->len = n;
    h->elem_size = es;
    h->elem_drop = elem_drop;
    return h;
}

int64_t Gleamc_buffer_len(void* buf) {
    return (int64_t)((GleamcBufferHdr*)buf)->len;
}

void* Gleamc_buffer_slot(void* buf, int64_t i) {
    GleamcBufferHdr* h = (GleamcBufferHdr*)buf;
    return (uint8_t*)h + sizeof(GleamcBufferHdr) + (size_t)i * h->elem_size;
}

void Gleamc_buffer_retain(void* buf) {
    if (buf == NULL) return;
    Gleamc_rc_retain(buf, NULL);
}

void Gleamc_buffer_release(void* buf) {
    if (buf == NULL) return;
    GleamcBufferHdr* h = (GleamcBufferHdr*)buf;
    if (gleamc_refcount_of(buf) == 1 && h->elem_drop != NULL) {
        for (size_t i = 0; i < h->len; i++)
            h->elem_drop((uint8_t*)h + sizeof(GleamcBufferHdr) +
                         i * h->elem_size);
    }
    Gleamc_rc_release(buf, NULL);
}

/* Copy-on-write: returns a buffer the caller owns. When the buffer is shared
 * (rc > 1) a fresh copy is made with each element retained; when unique it is
 * reused in place (a reference is added for the caller, whose old reference is
 * released by ownership). */
void* Gleamc_buffer_cow(void* buf, size_t elem_size,
                        void (*elem_retain)(void*), void (*elem_drop)(void*)) {
    GleamcBufferHdr* h = (GleamcBufferHdr*)buf;
    if (_bd_stats) _bd_cow_calls++;
    if (gleamc_refcount_of(buf) > 1) {
        if (_bd_stats) {
            _bd_cow_copies++;
            _bd_cow_bytes += h->len * elem_size;
        }
        GleamcBufferHdr* nh = (GleamcBufferHdr*)gleamc_alloc0(
            sizeof(GleamcBufferHdr) + h->len * elem_size);
        nh->len = h->len;
        nh->elem_size = elem_size;
        nh->elem_drop = elem_drop;
        uint8_t* src = (uint8_t*)h + sizeof(GleamcBufferHdr);
        uint8_t* dst = (uint8_t*)nh + sizeof(GleamcBufferHdr);
        for (size_t i = 0; i < h->len; i++) {
            memcpy(dst + i * elem_size, src + i * elem_size, elem_size);
            if (elem_retain) elem_retain(dst + i * elem_size);
        }
        return nh;
    }
    Gleamc_rc_retain(buf, NULL);
    return buf;
}

bool Gleamc_buffer_is_null(void* buf) { return buf == NULL; }

void Gleamc_buffer_take(void* buf, int64_t i, void (*elem_retain)(void*),
                        void* out) {
    GleamcBufferHdr* h = (GleamcBufferHdr*)buf;
    uint8_t* slot =
        (uint8_t*)h + sizeof(GleamcBufferHdr) + (size_t)i * h->elem_size;
    if (_bd_stats) _bd_take_calls++;
    memcpy(out, slot, h->elem_size);
    if (gleamc_refcount_of(buf) == 1) {
        /* Unique owner: move the reference out and leave the default sentinel. */
        if (_bd_stats) _bd_take_moves++;
        memset(slot, 0, h->elem_size);
    } else {
        /* Shared owner: the container keeps its reference; hand out a new one. */
        if (_bd_stats) _bd_take_retains++;
        if (elem_retain != NULL) elem_retain(out);
    }
}

bool gleamc_string_eq(GleamcString a, GleamcString b) {
    return a.len == b.len && (a.len == 0 || memcmp(a.data, b.data, a.len) == 0);
}

int Gleamc_io_print(GleamcString s) {
    if (s.len > 0) fwrite(s.data, 1, s.len, stdout);
    return 0;
}

int Gleamc_io_println(GleamcString s) {
    Gleamc_io_print(s);
    fputc('\n', stdout);
    return 0;
}

GleamcBitArray Gleamc_bit_array_new(size_t len) {
    uint8_t* data = (uint8_t*)gleamc_alloc_site(len + 1, "runtime:from_cstr");
    memset(data, 0, len + 1);
    return (GleamcBitArray){data, len};
}

GleamcBitArray Gleamc_bit_array_from_bytes(const int64_t* values, size_t count) {
    GleamcBitArray result = Gleamc_bit_array_new(count);
    for (size_t i = 0; i < count; i++) {
        result.data[i] = (uint8_t)(values[i] & 0xFF);
    }
    return result;
}

GleamcBitArray Gleamc_bit_array_from_string(GleamcString s) {
    GleamcBitArray result = Gleamc_bit_array_new(s.len);
    memcpy(result.data, s.data, s.len);
    return result;
}

GleamcString Gleamc_bit_array_raw_to_string(GleamcBitArray a) {
    char* buf = (char*)gleamc_alloc(a.len + 1);
    memcpy(buf, a.data, a.len);
    buf[a.len] = '\0';
    return (GleamcString){buf, a.len};
}

int64_t Gleamc_bit_array_byte_size(GleamcBitArray a) {
    return (int64_t)a.len;
}

int64_t Gleamc_bit_array_byte(GleamcBitArray a, size_t index) {
    if (index >= a.len) return 0;
    return (int64_t)a.data[index];
}

GleamcBitArray Gleamc_bit_array_append(GleamcBitArray a, GleamcBitArray b) {
    GleamcBitArray result = Gleamc_bit_array_new(a.len + b.len);
    memcpy(result.data, a.data, a.len);
    memcpy(result.data + a.len, b.data, b.len);
    return result;
}

bool Gleamc_bit_array_eq(GleamcBitArray a, GleamcBitArray b) {
    if (a.len != b.len) return false;
    return memcmp(a.data, b.data, a.len) == 0;
}

void Gleamc_bit_array_retain(GleamcBitArray a) {
    if (a.data != NULL) gleamc_retain(a.data);
}

void Gleamc_bit_array_release(GleamcBitArray a) {
    if (a.data != NULL) gleamc_release(a.data);
}

GleamcString Gleamc_show_concat(GleamcString a, GleamcString b) {
    GleamcString result = gleamc_string_concat(a, b);
    gleamc_string_release(a);
    gleamc_string_release(b);
    return result;
}

GleamcString Gleamc_string_show(GleamcString value) {
    size_t extra = 0;
    for (size_t i = 0; i < value.len; i++) {
        char c = value.data[i];
        if (c == '"' || c == '\\' || c == '\n' || c == '\t' || c == '\r') extra++;
    }
    size_t total = value.len + extra + 2;
    char* buf = (char*)gleamc_alloc(total + 1);
    size_t out = 0;
    buf[out++] = '"';
    for (size_t i = 0; i < value.len; i++) {
        char c = value.data[i];
        switch (c) {
            case '"': buf[out++] = '\\'; buf[out++] = '"'; break;
            case '\\': buf[out++] = '\\'; buf[out++] = '\\'; break;
            case '\n': buf[out++] = '\\'; buf[out++] = 'n'; break;
            case '\t': buf[out++] = '\\'; buf[out++] = 't'; break;
            case '\r': buf[out++] = '\\'; buf[out++] = 'r'; break;
            default: buf[out++] = c; break;
        }
    }
    buf[out++] = '"';
    buf[out] = '\0';
    return (GleamcString){buf, out};
}

int Gleamc_io_debug(GleamcString value) {
    fwrite(value.data, 1, value.len, stderr);
    fputc('\n', stderr);
    gleamc_string_release(value);
    return 0;
}

void Gleamc_panic(GleamcString message) {
    fputs("panic: ", stderr);
    fwrite(message.data, 1, message.len, stderr);
    fputc('\n', stderr);
    abort();
}

int64_t Gleamc_string_byte_size(GleamcString value) {
    return (int64_t)value.len;
}

static uint32_t decode_codepoint_at(GleamcString s, size_t i) {
    unsigned char c = (unsigned char)s.data[i];
    if (c < 0x80) return c;
    if ((c & 0xE0) == 0xC0 && i + 1 < s.len) {
        return ((uint32_t)(c & 0x1F) << 6) | (s.data[i + 1] & 0x3F);
    }
    if ((c & 0xF0) == 0xE0 && i + 2 < s.len) {
        return ((uint32_t)(c & 0x0F) << 12) | ((s.data[i + 1] & 0x3F) << 6) |
               (s.data[i + 2] & 0x3F);
    }
    if ((c & 0xF8) == 0xF0 && i + 3 < s.len) {
        return ((uint32_t)(c & 0x07) << 18) | ((s.data[i + 1] & 0x3F) << 12) |
               ((s.data[i + 2] & 0x3F) << 6) | (s.data[i + 3] & 0x3F);
    }
    return 0xFFFD;
}

int64_t Gleamc_string_raw_codepoint_at(GleamcString value, size_t index) {
    size_t offset = codepoint_offset(value, (int64_t)index);
    if (offset >= value.len) return -1;
    return (int64_t)decode_codepoint_at(value, offset);
}

GleamcString Gleamc_string_raw_codepoint_to_string(int64_t codepoint) {
    if (codepoint < 0) codepoint = 0xFFFD;
    unsigned char buf[4];
    int n = 0;
    if (codepoint <= 0x7F) {
        buf[0] = (unsigned char)codepoint;
        n = 1;
    } else if (codepoint <= 0x7FF) {
        buf[0] = (unsigned char)(0xC0 | (codepoint >> 6));
        buf[1] = (unsigned char)(0x80 | (codepoint & 0x3F));
        n = 2;
    } else if (codepoint <= 0xFFFF) {
        buf[0] = (unsigned char)(0xE0 | (codepoint >> 12));
        buf[1] = (unsigned char)(0x80 | ((codepoint >> 6) & 0x3F));
        buf[2] = (unsigned char)(0x80 | (codepoint & 0x3F));
        n = 3;
    } else {
        buf[0] = (unsigned char)(0xF0 | (codepoint >> 18));
        buf[1] = (unsigned char)(0x80 | ((codepoint >> 12) & 0x3F));
        buf[2] = (unsigned char)(0x80 | ((codepoint >> 6) & 0x3F));
        buf[3] = (unsigned char)(0x80 | (codepoint & 0x3F));
        n = 4;
    }
    char* out = (char*)gleamc_alloc((size_t)n + 1);
    memcpy(out, buf, (size_t)n);
    out[n] = '\0';
    return (GleamcString){out, (size_t)n};
}

int64_t Gleamc_string_compare_bytes(GleamcString a, GleamcString b) {
    size_t n = a.len < b.len ? a.len : b.len;
    int cmp = memcmp(a.data, b.data, n);
    if (cmp < 0) return -1;
    if (cmp > 0) return 1;
    if (a.len < b.len) return -1;
    if (a.len > b.len) return 1;
    return 0;
}

static size_t grapheme_offset(GleamcString s, int64_t index) {
    if (index <= 0) return 0;
    utf8proc_int32_t state = 0;
    utf8proc_int32_t prev = 0;
    int first = 1;
    int64_t count = 0;
    size_t i = 0;
    while (i < s.len) {
        size_t start = i;
        utf8proc_int32_t cp;
        utf8proc_ssize_t n = utf8proc_iterate(
            (const utf8proc_uint8_t*)s.data + i,
            (utf8proc_ssize_t)(s.len - i),
            &cp
        );
        if (n < 0) { cp = 0xFFFD; n = 1; }
        if (first || utf8proc_grapheme_break_stateful(prev, cp, &state)) {
            count++;
            if (count > index) return start;
        }
        first = 0;
        prev = cp;
        i += (size_t)n;
    }
    return s.len;
}

int64_t Gleamc_string_length(GleamcString s) {
    /* counts Unicode grapheme clusters (UAX #29, via utf8proc) */
    utf8proc_int32_t state = 0;
    utf8proc_int32_t prev = 0;
    int first = 1;
    int64_t n = 0;
    size_t i = 0;
    while (i < s.len) {
        utf8proc_int32_t cp;
        utf8proc_ssize_t consumed = utf8proc_iterate(
            (const utf8proc_uint8_t*)s.data + i,
            (utf8proc_ssize_t)(s.len - i),
            &cp
        );
        if (consumed < 0) { cp = 0xFFFD; consumed = 1; }
        if (first || utf8proc_grapheme_break_stateful(prev, cp, &state)) n++;
        first = 0;
        prev = cp;
        i += (size_t)consumed;
    }
    return n;
}

GleamcString Gleamc_string_append(GleamcString a, GleamcString b) {
    return gleamc_string_concat(a, b);
}

/* Full Unicode case mapping via ICU (handles expansions like ss -> SS). The
 * FFI declares the argument `Owned`, so the input reference is consumed. */
static GleamcString unicode_case_map(GleamcString s, int upper) {
    UErrorCode error = U_ZERO_ERROR;
    int32_t u16_len = 0;
    u_strFromUTF8(NULL, 0, &u16_len, (const char*)s.data, (int32_t)s.len, &error);
    error = U_ZERO_ERROR;
    UChar* u16 = (UChar*)malloc(((size_t)u16_len + 1) * sizeof(UChar));
    int32_t u16_len2 = 0;
    u_strFromUTF8(u16, u16_len + 1, &u16_len2, (const char*)s.data, (int32_t)s.len, &error);
    error = U_ZERO_ERROR;
    int32_t mapped_len = upper
        ? u_strToUpper(NULL, 0, u16, u16_len2, NULL, &error)
        : u_strToLower(NULL, 0, u16, u16_len2, NULL, &error);
    error = U_ZERO_ERROR;
    UChar* mapped = (UChar*)malloc(((size_t)mapped_len + 1) * sizeof(UChar));
    int32_t mapped_len2 = upper
        ? u_strToUpper(mapped, mapped_len + 1, u16, u16_len2, NULL, &error)
        : u_strToLower(mapped, mapped_len + 1, u16, u16_len2, NULL, &error);
    error = U_ZERO_ERROR;
    int32_t bytes_len = 0;
    u_strToUTF8(NULL, 0, &bytes_len, mapped, mapped_len2, &error);
    error = U_ZERO_ERROR;
    char* buf = (char*)gleamc_alloc((size_t)bytes_len + 1);
    int32_t bytes_len2 = 0;
    u_strToUTF8(buf, bytes_len + 1, &bytes_len2, mapped, mapped_len2, &error);
    buf[bytes_len2] = '\0';
    free(u16);
    free(mapped);
    gleamc_string_release(s);
    return (GleamcString){buf, (size_t)bytes_len2};
}

GleamcString Gleamc_string_uppercase(GleamcString s) {
    return unicode_case_map(s, 1);
}

GleamcString Gleamc_string_lowercase(GleamcString s) {
    return unicode_case_map(s, 0);
}

GleamcString Gleamc_string_reverse(GleamcString s) {
    /* reverses grapheme clusters */
    size_t* starts = (size_t*)malloc((s.len + 1) * sizeof(size_t));
    if (starts == NULL) return (GleamcString){s.data, s.len};
    int64_t count = 0;
    utf8proc_int32_t state = 0;
    utf8proc_int32_t prev = 0;
    int first = 1;
    size_t i = 0;
    while (i < s.len) {
        size_t start = i;
        utf8proc_int32_t cp;
        utf8proc_ssize_t n = utf8proc_iterate(
            (const utf8proc_uint8_t*)s.data + i,
            (utf8proc_ssize_t)(s.len - i),
            &cp
        );
        if (n < 0) { cp = 0xFFFD; n = 1; }
        if (first || utf8proc_grapheme_break_stateful(prev, cp, &state)) {
            starts[count++] = start;
        }
        first = 0;
        prev = cp;
        i += (size_t)n;
    }
    starts[count] = s.len;
    char* buf = (char*)gleamc_alloc(s.len + 1);
    size_t out = 0;
    for (int64_t g = count - 1; g >= 0; g--) {
        size_t a = starts[g];
        size_t b = starts[g + 1];
        memcpy(buf + out, s.data + a, b - a);
        out += b - a;
    }
    buf[out] = '\0';
    free(starts);
    return (GleamcString){buf, out};
}

bool Gleamc_string_contains(GleamcString haystack, GleamcString needle) {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;
    for (size_t i = 0; i + needle.len <= haystack.len; i++) {
        if (memcmp(haystack.data + i, needle.data, needle.len) == 0) return true;
    }
    return false;
}

bool Gleamc_string_starts_with(GleamcString value, GleamcString prefix) {
    if (prefix.len > value.len) return false;
    return memcmp(value.data, prefix.data, prefix.len) == 0;
}

bool Gleamc_string_ends_with(GleamcString value, GleamcString suffix) {
    if (suffix.len > value.len) return false;
    return memcmp(value.data + (value.len - suffix.len), suffix.data, suffix.len) == 0;
}

static int is_space_byte(char c) {
    return c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == '\f' || c == '\v';
}

GleamcString Gleamc_string_trim(GleamcString value) {
    size_t start = 0;
    size_t end = value.len;
    while (start < end && is_space_byte(value.data[start])) start++;
    while (end > start && is_space_byte(value.data[end - 1])) end--;
    size_t len = end - start;
    char* buf = (char*)gleamc_alloc(len + 1);
    memcpy(buf, value.data + start, len);
    buf[len] = '\0';
    return (GleamcString){buf, len};
}

static size_t codepoint_offset(GleamcString s, int64_t index) {
    size_t i = 0;
    int64_t n = 0;
    while (i < s.len && n < index) {
        i++;
        while (i < s.len && ((unsigned char)s.data[i] & 0xC0) == 0x80) i++;
        n++;
    }
    return i;
}

GleamcString Gleamc_string_trim_start(GleamcString value) {
    size_t start = 0;
    while (start < value.len && is_space_byte(value.data[start])) start++;
    size_t len = value.len - start;
    char* buf = (char*)gleamc_alloc(len + 1);
    memcpy(buf, value.data + start, len);
    buf[len] = '\0';
    return (GleamcString){buf, len};
}

GleamcString Gleamc_string_trim_end(GleamcString value) {
    size_t end = value.len;
    while (end > 0 && is_space_byte(value.data[end - 1])) end--;
    char* buf = (char*)gleamc_alloc(end + 1);
    memcpy(buf, value.data, end);
    buf[end] = '\0';
    return (GleamcString){buf, end};
}

GleamcString Gleamc_string_slice(GleamcString value, int64_t idx, int64_t len) {
    if (len <= 0) {
        char* empty = (char*)gleamc_alloc(1);
        empty[0] = '\0';
        return (GleamcString){empty, 0};
    }
    int64_t count = Gleamc_string_length(value);
    if (idx < 0) {
        idx = count + idx;
        if (idx < 0) {
            char* empty = (char*)gleamc_alloc(1);
            empty[0] = '\0';
            return (GleamcString){empty, 0};
        }
    }
    if (idx > count) idx = count;
    int64_t end = idx + len;
    if (end > count) end = count;
    size_t start = grapheme_offset(value, idx);
    size_t finish = grapheme_offset(value, end);
    size_t n = finish - start;
    char* buf = (char*)gleamc_alloc(n + 1);
    memcpy(buf, value.data + start, n);
    buf[n] = '\0';
    return (GleamcString){buf, n};
}

GleamcString Gleamc_string_replace(
    GleamcString value,
    GleamcString pattern,
    GleamcString substitute
) {
    if (pattern.len == 0) {
        char* copy = (char*)gleamc_alloc(value.len + 1);
        memcpy(copy, value.data, value.len);
        copy[value.len] = '\0';
        return (GleamcString){copy, value.len};
    }
    size_t matches = 0;
    for (size_t i = 0; i + pattern.len <= value.len;) {
        if (memcmp(value.data + i, pattern.data, pattern.len) == 0) {
            matches++;
            i += pattern.len;
        } else {
            i++;
        }
    }
    long delta = (long)substitute.len - (long)pattern.len;
    size_t new_len = (size_t)((long)value.len + (long)matches * delta);
    char* buf = (char*)gleamc_alloc(new_len + 1);
    size_t out = 0;
    size_t i = 0;
    while (i < value.len) {
        if (i + pattern.len <= value.len &&
            memcmp(value.data + i, pattern.data, pattern.len) == 0) {
            memcpy(buf + out, substitute.data, substitute.len);
            out += substitute.len;
            i += pattern.len;
        } else {
            buf[out++] = value.data[i++];
        }
    }
    buf[out] = '\0';
    return (GleamcString){buf, out};
}

static GleamcString from_cstr(const char* text) {
    return gleamc_string_lit(text, strlen(text));
}

GleamcString Gleamc_int_to_string(int64_t v) {
    char buf[32];
    snprintf(buf, sizeof buf, "%lld", (long long)v);
    return from_cstr(buf);
}

int64_t Gleamc_int_min(int64_t a, int64_t b) { return a < b ? a : b; }
int64_t Gleamc_int_max(int64_t a, int64_t b) { return a > b ? a : b; }
int64_t Gleamc_int_absolute_value(int64_t a) { return a < 0 ? -a : a; }

GleamcString Gleamc_int_raw_to_base_string(int64_t value, int64_t base) {
    if (base < 2) base = 2;
    if (base > 36) base = 36;
    char tmp[72];
    int n = 0;
    int negative = value < 0;
    uint64_t magnitude =
        negative ? (uint64_t)(-(value + 1)) + 1 : (uint64_t)value;
    if (magnitude == 0) tmp[n++] = '0';
    while (magnitude > 0) {
        int digit = (int)(magnitude % (uint64_t)base);
        tmp[n++] = (char)(digit < 10 ? '0' + digit : 'A' + (digit - 10));
        magnitude /= (uint64_t)base;
    }
    if (negative) tmp[n++] = '-';
    char* buf = (char*)gleamc_alloc((size_t)n + 1);
    for (int i = 0; i < n; i++) buf[i] = tmp[n - 1 - i];
    buf[n] = '\0';
    return (GleamcString){buf, (size_t)n};
}

double Gleamc_int_to_float(int64_t value) { return (double)value; }

double Gleamc_float_min(double a, double b) { return a < b ? a : b; }
double Gleamc_float_max(double a, double b) { return a > b ? a : b; }
double Gleamc_float_absolute_value(double a) { return fabs(a); }
double Gleamc_float_floor(double a) { return floor(a); }
double Gleamc_float_ceiling(double a) { return ceil(a); }
int64_t Gleamc_float_round(double a) { return (int64_t)llround(a); }
int64_t Gleamc_float_truncate(double a) { return (int64_t)trunc(a); }
double Gleamc_float_raw_power(double base, double exponent) { return pow(base, exponent); }
double Gleamc_float_raw_square_root(double value) { return sqrt(value); }

GleamcString Gleamc_float_to_string(double v) {
    /* Matches Gleam/Erlang `float_to_string`: the shortest decimal string that
       round-trips, rendered in whichever of fixed/scientific notation is
       shorter (ties go to fixed). */
    if (v != v) return from_cstr("nan");
    int neg = 0;
    if (v < 0) {
        neg = 1;
        v = -v;
    }
    if (v == 0.0) return from_cstr(neg ? "-0.0" : "0.0");

    /* shortest precision that round-trips, via scientific notation */
    char sci[64];
    int prec = 17;
    for (int p = 0; p <= 17; p++) {
        snprintf(sci, sizeof sci, "%.*e", p, v);
        if (strtod(sci, NULL) == v) {
            prec = p;
            break;
        }
    }
    (void)prec;

    /* split "d.dddde±XX" into digits and a power of ten */
    char digits[64];
    int nd = 0;
    int exp = 0;
    const char* q = sci;
    while (*q != 'e' && *q != 'E' && *q != '\0') {
        if (*q >= '0' && *q <= '9') digits[nd++] = *q;
        q++;
    }
    if (*q != '\0') {
        q++;
        int eneg = 0;
        if (*q == '+' || *q == '-') {
            eneg = (*q == '-');
            q++;
        }
        while (*q >= '0' && *q <= '9') {
            exp = exp * 10 + (*q - '0');
            q++;
        }
        if (eneg) exp = -exp;
    }
    digits[nd] = '\0';

    /* fixed notation */
    char fixed[400];
    int fn = 0;
    if (exp >= 0) {
        int intlen = exp + 1;
        for (int i = 0; i < intlen; i++) fixed[fn++] = (i < nd) ? digits[i] : '0';
        fixed[fn++] = '.';
        if (nd > intlen) {
            for (int i = intlen; i < nd; i++) fixed[fn++] = digits[i];
        } else {
            fixed[fn++] = '0';
        }
    } else {
        fixed[fn++] = '0';
        fixed[fn++] = '.';
        for (int i = 0; i < -exp - 1; i++) fixed[fn++] = '0';
        for (int i = 0; i < nd; i++) fixed[fn++] = digits[i];
    }
    fixed[fn] = '\0';

    /* scientific notation */
    char scin[400];
    int sn = 0;
    scin[sn++] = digits[0];
    scin[sn++] = '.';
    if (nd > 1) {
        for (int i = 1; i < nd; i++) scin[sn++] = digits[i];
    } else {
        scin[sn++] = '0';
    }
    sn += snprintf(scin + sn, sizeof scin - sn, "e%d", exp);
    scin[sn] = '\0';

    const char* chosen = (strlen(fixed) <= strlen(scin)) ? fixed : scin;
    char out[512];
    int n = 0;
    if (neg) out[n++] = '-';
    strcpy(out + n, chosen);
    return from_cstr(out);
}

GleamcString Gleamc_bool_to_string(bool v) {
    return from_cstr(v ? "True" : "False");
}

/* ------------------------------------------------------------------ */
/* Futures + scheduler + libuv (ported from Vesper docs 09/11/14)      */
/* ------------------------------------------------------------------ */

#include <time.h>
#include <sys/stat.h>

uint64_t gleamc_now_ms(void) {
    struct timespec ts;
    timespec_get(&ts, TIME_UTC);
    return (uint64_t)ts.tv_sec * 1000 + (uint64_t)ts.tv_nsec / 1000000;
}

void gleamc_sleep_ms(int64_t ms) {
    struct timespec ts;
    ts.tv_sec = ms / 1000;
    ts.tv_nsec = (ms % 1000) * 1000000L;
    nanosleep(&ts, NULL);
}

GleamcFuture* Gleamc_std_time_timer(int64_t ms) {
    GleamcFuture* f = gleamc_alloc_site(sizeof(GleamcFuture), "future:timer");
    f->deadline = (int64_t)gleamc_now_ms() + ms;
    f->done = false;
    f->has_error = false;
    f->error_code = 0;
    f->value_i = 0;
    f->value_p = NULL;
    f->uv_armed = false;
    return f;
}

/* Maximum number of live tasks on the cooperative driver. */
#define GLEAMC_TASKS_MAX 4096

/* ------------------------------------------------------------------ */
/* Cooperative driver.                                                 */
/*                                                                     */
/* One loop drives every machine: an async call starts the callee as a */
/* task and suspends on a future that completes when the callee does,  */
/* so control always returns to this loop (no per-wrapper `sched_run`).*/
/* ------------------------------------------------------------------ */

/* The mailbox struct is defined below; a task owns up to two inboxes (one for
 * `Down` monitor messages, one for `ExitMessage`). */
typedef struct GleamcMailbox GleamcMailbox;

/* Constructor helpers emitted by the backend for the std process types; weak so
 * a program that never imports `process` links. */
extern void* Gleamc_make_process_Down_ProcessDown(int64_t, int64_t, int64_t)
    __attribute__((weak));
extern void* Gleamc_make_process_ExitMessage_ExitMessage(int64_t, int64_t)
    __attribute__((weak));

typedef struct {
    bool (*step)(void*);
    void* frame;
    GleamcFuture** fut_slot;
    /* Copies the machine's result out of its frame into the caller's slot
     * before the frame is released; NULL for a nil result. */
    void (*copy_result)(void*, void*);
    void* result_dst;
    /* Releases the values owned by the frame (the generated `__frame_*_drop`);
     * `gleamc_release` only frees the cell, so the driver must run this first. */
    void (*frame_drop)(void*);
    /* Completed when the machine finishes. */
    GleamcFuture* done;
    bool finished;
    /* Set while this task's `step` is on the C stack, so a nested
     * `gleamc_run_until` (a synchronous call into an async closure) never
     * re-enters a task that is already running. */
    bool running;
    /* Fire-and-forget (`process.spawn`): the driver owns the completion
     * future and releases it when the task finishes. */
    bool detached;
    /* Stable process identifier (`Pid`); never reused. */
    int64_t id;
    /* Monitor (`Down`) and trapped-exit (`ExitMessage`) inboxes, created on
     * demand. */
    GleamcMailbox* inbox_down;
    GleamcMailbox* inbox_exit;
    /* Monitors watching this task: pairs of (monitor id, watcher task id). */
    int64_t* monitors;
    int nmon;
    int moncap;
    /* Tasks linked to this one (Pids). */
    int64_t* links;
    int nlink;
    int linkcap;
    bool trap_exit;
    /* Set by `kill`/link propagation; the driver terminates the task. */
    bool kill_requested;
    int64_t kill_reason;
    /* Subjects this task owns (their mailboxes), for `select_other`. */
    GleamcMailbox** owned;
    int nowned;
    int ocap;
} GleamcTask2;

static GleamcTask2* gleamc_task_by_id(int64_t id);
static GleamcMailbox* gleamc_mailbox_new(void);
static void gleamc_task_add_owned(GleamcTask2* t, GleamcMailbox* mb);
static void gleamc_task_remove_owned(GleamcTask2* t, GleamcMailbox* mb);

static GleamcTask2 gleamc_tasks2[GLEAMC_TASKS_MAX];
static int gleamc_tasks2_n = 0;
/* Monotonic `Pid` allocator and the id of the task currently being stepped
 * (`process.self()`). */
static int64_t gleamc_next_task_id = 1;
static int64_t gleamc_current_task_id = 0;
/* Nesting depth of the driver: > 0 means a synchronous call from inside a
 * machine is driving the loop for its own completion future. Nested runs never
 * compact the task table (they must not move a running task). */
static int gleamc_run_depth = 0;

/* A tail call delegates the current task to the callee: the step records the
 * next machine here and returns "suspended"; `gleamc_run` retargets the task
 * instead of waiting, so a tail-call chain keeps a constant number of tasks. */
static GleamcTask2 gleamc_delegate;
static bool gleamc_delegated = false;

void gleamc_task_tail(bool (*step)(void*), void* frame,
                      void (*copy_result)(void*, void*),
                      GleamcFuture** fut_slot,
                      void (*frame_drop)(void*)) {
    gleamc_delegate.step = step;
    gleamc_delegate.frame = frame;
    gleamc_delegate.copy_result = copy_result;
    gleamc_delegate.fut_slot = fut_slot;
    gleamc_delegate.frame_drop = frame_drop;
    gleamc_delegated = true;
}

static GleamcFuture* gleamc_future_new(void) {
    GleamcFuture* f = (GleamcFuture*)gleamc_alloc_site(sizeof(GleamcFuture), "future:new");
    f->deadline = 0;
    f->done = false;
    f->has_error = false;
    f->error_code = 0;
    f->value_i = 0;
    f->value_p = NULL;
    f->uv_armed = false;
    f->notify = NULL;
    return f;
}

static GleamcFuture* gleamc_task_push(bool (*step)(void*), void* frame,
                                      GleamcFuture** fut_slot,
                                      void (*copy_result)(void*, void*),
                                      void* result_dst,
                                      void (*frame_drop)(void*),
                                      bool detached) {
    GleamcFuture* done = gleamc_future_new();
    if (gleamc_tasks2_n >= GLEAMC_TASKS_MAX) {
        fprintf(stderr, "gleamc: task overflow (%d)\n", GLEAMC_TASKS_MAX);
        /* `frame_drop` releases `frame` itself (it ends in an rc_release). */
        if (frame_drop != NULL) frame_drop(frame);
        else gleamc_release(frame);
        done->done = true;
        return done;
    }
    GleamcTask2* t = &gleamc_tasks2[gleamc_tasks2_n++];
    t->step = step;
    t->frame = frame;
    t->fut_slot = fut_slot;
    t->copy_result = copy_result;
    t->result_dst = result_dst;
    t->frame_drop = frame_drop;
    t->done = done;
    t->finished = false;
    t->running = false;
    t->detached = detached;
    t->id = gleamc_next_task_id++;
    return done;
}

/* The stable id of the task whose completion future is `done` (-1 if gone). */
int64_t gleamc_task_id(GleamcFuture* done) {
    if (done == NULL) return -1;
    for (int i = 0; i < gleamc_tasks2_n; i++) {
        if (gleamc_tasks2[i].done == done) return gleamc_tasks2[i].id;
    }
    return -1;
}

int64_t Gleamc_process_ffi_self(void) {
    return gleamc_current_task_id;
}

bool Gleamc_process_ffi_is_alive(int64_t pid) {
    for (int i = 0; i < gleamc_tasks2_n; i++) {
        if (gleamc_tasks2[i].id == pid && !gleamc_tasks2[i].finished)
            return true;
    }
    return false;
}

int64_t Gleamc_task_ffi_pid(GleamcFuture* task) {
    return gleamc_task_id(task);
}

static void gleamc_task_dtor(void* p) {
    GleamcFuture* f = (GleamcFuture*)p;
    if (f->value_p != NULL) {
        gleamc_box_free(f->value_p);
        f->value_p = NULL;
    }
}

void Gleamc_task_ffi_retain(GleamcFuture* task) {
    if (task != NULL) gleamc_retain(task);
}

void Gleamc_task_ffi_release(GleamcFuture* task) {
    gleamc_release_with((void*)task, gleamc_task_dtor, "task");
}

bool Gleamc_task_ffi_crashed(GleamcFuture* task) {
    return task != NULL && task->crashed;
}

int64_t Gleamc_process_ffi_pid_of_int(int64_t pid) {
    return pid;
}

GleamcFuture* gleamc_task_start(bool (*step)(void*), void* frame,
                                GleamcFuture** fut_slot,
                                void (*copy_result)(void*, void*),
                                void* result_dst,
                                void (*frame_drop)(void*)) {
    GleamcFuture* done = gleamc_task_push(
        step, frame, fut_slot, copy_result, result_dst, frame_drop, false
    );
    /* The task holds one reference (dropped at finish); the caller holds
     * another (dropped by the generated wrapper). */
    gleamc_retain(done);
    return done;
}

GleamcFuture* gleamc_task_async(bool (*step)(void*), void* frame,
                                GleamcFuture** fut_slot,
                                void (*copy_result)(void*, void*),
                                void (*frame_drop)(void*), void* box) {
    GleamcFuture* done = gleamc_task_push(
        step, frame, fut_slot, copy_result, box, frame_drop, false
    );
    /* The worker's `copy_result` writes its result into `box`; publish the box
     * on the completion future so `task.await` can move the value out. */
    done->value_p = box;
    /* The task holds one reference (dropped at finish); the `Task(a)` handle
     * holds another (dropped by the compiler). */
    gleamc_retain(done);
    return done;
}

GleamcFuture* gleamc_task_spawn(bool (*step)(void*), void* frame,
                                GleamcFuture** fut_slot,
                                void (*frame_drop)(void*)) {
    return gleamc_task_push(
        step, frame, fut_slot, NULL, NULL, frame_drop, true
    );
}

/* A box is a refcounted heap cell holding an arbitrary Gleam value. The sender
 * moves the value in; the receiver moves it out and frees the cell (no payload
 * drop: ownership was transferred). */
void* gleamc_box_alloc(int64_t size) {
    return gleamc_alloc_site(size > 0 ? (size_t)size : 1, "box");
}

void gleamc_box_free(void* box) {
    gleamc_release(box);
}

static void gleamc_future_wait(GleamcFuture* f);

void* Gleamc_uv_await_box(GleamcFuture* f) {
    gleamc_future_wait(f);
    if (f == NULL) return NULL;
    void* box = f->value_p;
    f->value_p = NULL;
    return box;
}

/* ------------------------------------------------------------------ */
/* Processes and mailboxes.                                            */
/*                                                                     */
/* A mailbox is a FIFO of boxed messages plus a FIFO of pending        */
/* `receive` futures. `send` hands the box to the oldest waiter,       */
/* completing its future; the cooperative driver then re-steps that    */
/* task because a step made progress (`progressed = 1`). With no       */
/* waiter it enqueues. `receive` returns an already-done future when a  */
/* box is queued, so it never suspends on a non-empty mailbox.         */
/* ------------------------------------------------------------------ */

typedef struct GleamcMailbox {
    GleamcHdr hdr;
    void** msgs;
    int nmsg;
    int mcap;
    /* `receive` waiters: the box is handed to the oldest one. */
    GleamcFuture** waiters;
    int nwait;
    int wcap;
    /* `wait_any` notifiers: they are signalled (value_i = 1) but the box stays
     * queued, so the following `receive` claims it. */
    GleamcFuture** notifiers;
    int nnotify;
    int ncap;
    void** deferred;
    int ndef;
    int dcap;
    /* The task that created the subject (its owner), for `subject_owner`. */
    int64_t owner;
} GleamcMailbox;

static void gleamc_task_add_owned(GleamcTask2* t, GleamcMailbox* mb) {
    if (t == NULL) return;
    if (t->nowned == t->ocap) {
        int cap = t->ocap == 0 ? 8 : t->ocap * 2;
        GleamcMailbox** grown =
            (GleamcMailbox**)realloc(t->owned, (size_t)cap * sizeof(GleamcMailbox*));
        if (grown == NULL) return;
        t->owned = grown;
        t->ocap = cap;
    }
    t->owned[t->nowned++] = mb;
}

static void gleamc_task_remove_owned(GleamcTask2* t, GleamcMailbox* mb) {
    if (t == NULL || t->owned == NULL) return;
    for (int i = 0; i < t->nowned; i++) {
        if (t->owned[i] == mb) {
            for (int j = i + 1; j < t->nowned; j++) t->owned[j - 1] = t->owned[j];
            t->nowned--;
            return;
        }
    }
}

static void gleamc_task_register_subject(GleamcTask2* t, GleamcMailbox* mb) {
    if (mb == NULL) return;
    mb->owner = (t != NULL) ? t->id : gleamc_current_task_id;
    gleamc_task_add_owned(t, mb);
}

/* Lazily create a task's monitor/exit inbox, owned by the task (so
 * `select_other` can see its messages). */
static GleamcMailbox* gleamc_task_inbox(GleamcTask2* t, GleamcMailbox** slot) {
    if (*slot == NULL) {
        *slot = gleamc_mailbox_new();
        if (t != NULL) gleamc_task_register_subject(t, *slot);
        else if (*slot != NULL) (*slot)->owner = gleamc_current_task_id;
    }
    return *slot;
}

int64_t Gleamc_process_ffi_new_subject(void) {
    GleamcMailbox* mb = (GleamcMailbox*)gleamc_alloc0_site(sizeof(GleamcMailbox), "mailbox");
    gleamc_task_register_subject(gleamc_task_by_id(gleamc_current_task_id), mb);
    return (int64_t)(intptr_t)mb;
}

/* The compiler refcounts `Subject(a)` handles: retain copies, release at death.
 * Queued boxes are freed (their payload references are abandoned — the runtime
 * has no per-message drop). The refcount lives in the allocator header, so use
 * the `gleamc_retain`/`gleamc_release` macros rather than the struct's (vestigial)
 * `hdr` field. */
void Gleamc_subject_retain(int64_t handle) {
    GleamcMailbox* mb = (GleamcMailbox*)(intptr_t)handle;
    if (mb != NULL) gleamc_retain(mb);
}

void Gleamc_subject_release(int64_t handle) {
    GleamcMailbox* mb = (GleamcMailbox*)(intptr_t)handle;
    if (mb == NULL) return;
    GleamcHdr* h = (GleamcHdr*)((uint8_t*)mb - sizeof(GleamcHdr));
    if (h->refcount != GLEAMC_RC_STATIC && h->refcount == 1) {
        gleamc_task_remove_owned(gleamc_task_by_id(mb->owner), mb);
        for (int i = 0; i < mb->nmsg; i++) gleamc_box_free(mb->msgs[i]);
        for (int i = 0; i < mb->ndef; i++) gleamc_box_free(mb->deferred[i]);
        free(mb->msgs);
        free(mb->deferred);
        free(mb->waiters);
        free(mb->notifiers);
    }
    gleamc_release(mb);
}

static void gleamc_mailbox_add_notifier(GleamcMailbox* mb, GleamcFuture* f) {
    if (mb->nnotify == mb->ncap) {
        int cap = mb->ncap == 0 ? 4 : mb->ncap * 2;
        GleamcFuture** grown = (GleamcFuture**)realloc(
            mb->notifiers, (size_t)cap * sizeof(GleamcFuture*));
        if (grown == NULL) return;
        mb->notifiers = grown;
        mb->ncap = cap;
    }
    if (mb->nnotify < mb->ncap) mb->notifiers[mb->nnotify++] = f;
}

static void gleamc_mailbox_remove_notifier(GleamcMailbox* mb, GleamcFuture* f) {
    for (int i = 0; i < mb->nnotify; i++) {
        if (mb->notifiers[i] == f) {
            for (int j = i + 1; j < mb->nnotify; j++)
                mb->notifiers[j - 1] = mb->notifiers[j];
            mb->nnotify--;
            return;
        }
    }
}

static GleamcMailbox* gleamc_mailbox_new(void) {
    return (GleamcMailbox*)gleamc_alloc0_site(sizeof(GleamcMailbox), "mailbox");
}

/* Enqueue a box, handing it to a waiting `receive` or signalling a `wait_any`.
 * Takes ownership of `box` either way. */
static void gleamc_mailbox_send_box(GleamcMailbox* mb, void* box) {
    if (mb == NULL) {
        gleamc_box_free(box);
        return;
    }
    if (mb->nwait > 0) {
        GleamcFuture* f = mb->waiters[0];
        for (int i = 1; i < mb->nwait; i++)
            mb->waiters[i - 1] = mb->waiters[i];
        mb->nwait--;
        f->value_p = box;
        f->done = true;
        return;
    }
    if (mb->nmsg == mb->mcap) {
        int cap = mb->mcap == 0 ? 8 : mb->mcap * 2;
        void** grown = (void**)realloc(mb->msgs, (size_t)cap * sizeof(void*));
        if (grown == NULL) {
            gleamc_box_free(box);
            return;
        }
        mb->msgs = grown;
        mb->mcap = cap;
    }
    mb->msgs[mb->nmsg++] = box;
    /* Wake the oldest `wait_any`, if any; the box stays queued. */
    if (mb->nnotify > 0) {
        GleamcFuture* f = mb->notifiers[0];
        for (int i = 1; i < mb->nnotify; i++)
            mb->notifiers[i - 1] = mb->notifiers[i];
        mb->nnotify--;
        f->value_i = 1;
        f->done = true;
    }
}

int32_t Gleamc_process_ffi_send(int64_t handle, void* box) {
    gleamc_mailbox_send_box((GleamcMailbox*)(intptr_t)handle, box);
    return 0;
}

static void* gleamc_mailbox_take(GleamcMailbox* mb) {
    if (mb->ndef > 0) {
        void* box = mb->deferred[0];
        for (int i = 1; i < mb->ndef; i++)
            mb->deferred[i - 1] = mb->deferred[i];
        mb->ndef--;
        return box;
    }
    if (mb->nmsg > 0) {
        void* box = mb->msgs[0];
        for (int i = 1; i < mb->nmsg; i++)
            mb->msgs[i - 1] = mb->msgs[i];
        mb->nmsg--;
        return box;
    }
    return NULL;
}

GleamcFuture* Gleamc_process_ffi_receive(int64_t handle) {
    GleamcMailbox* mb = (GleamcMailbox*)(intptr_t)handle;
    GleamcFuture* f = (GleamcFuture*)gleamc_alloc0_site(sizeof(GleamcFuture), "future:recv");
    if (mb != NULL && (mb->ndef > 0 || mb->nmsg > 0)) {
        f->value_p = gleamc_mailbox_take(mb);
        f->done = true;
        return f;
    }
    if (mb != NULL) {
        if (mb->nwait == mb->wcap) {
            int cap = mb->wcap == 0 ? 4 : mb->wcap * 2;
            GleamcFuture** grown = (GleamcFuture**)realloc(
                mb->waiters, (size_t)cap * sizeof(GleamcFuture*));
            if (grown != NULL) {
                mb->waiters = grown;
                mb->wcap = cap;
            }
        }
        if (mb->nwait < mb->wcap) mb->waiters[mb->nwait++] = f;
    }
    return f;
}

/* ------------------------------------------------------------------ */
/* Timed waits: a wait future completed by a message/task or a timer.   */
/* ------------------------------------------------------------------ */

typedef struct {
    uv_timer_t timer;
    GleamcFuture* fut;  /* owned reference while the timer lives       */
    GleamcMailbox* mb;  /* `wait_any`: remove the notifier on timeout  */
    GleamcFuture* task; /* `await_timeout`: clear `task->notify`       */
} GleamcWaitTimer;

static void gleamc_wait_timer_close_cb(uv_handle_t* h) {
    free((GleamcWaitTimer*)h->data);
}

static void gleamc_wait_timer_cb(uv_timer_t* t) {
    GleamcWaitTimer* wt = (GleamcWaitTimer*)t->data;
    if (!wt->fut->done) {
        if (wt->mb != NULL) gleamc_mailbox_remove_notifier(wt->mb, wt->fut);
        if (wt->task != NULL && wt->task->notify == wt->fut)
            wt->task->notify = NULL;
        wt->fut->value_i = 0;
        wt->fut->done = true;
    }
    /* Release the timer's reference now, so it is gone even if the loop stops
     * before the close callback runs. */
    gleamc_release(wt->fut);
    wt->fut = NULL;
    uv_close((uv_handle_t*)t, gleamc_wait_timer_close_cb);
}

static void gleamc_wait_timer_new(GleamcFuture* fut, GleamcMailbox* mb,
                                  GleamcFuture* task, int64_t ms) {
    GleamcWaitTimer* wt = (GleamcWaitTimer*)calloc(1, sizeof(GleamcWaitTimer));
    if (wt == NULL) return;
    wt->fut = fut;
    wt->mb = mb;
    wt->task = task;
    gleamc_retain(fut);
    uv_timer_init((uv_loop_t*)gleamc_uv_loop(), &wt->timer);
    wt->timer.data = wt;
    uv_timer_start(
        &wt->timer, gleamc_wait_timer_cb, ms < 0 ? 0 : (uint64_t)ms, 0);
    fut->uv_armed = true;
}

GleamcFuture* Gleamc_process_ffi_wait_any(int64_t handle, int64_t ms) {
    GleamcMailbox* mb = (GleamcMailbox*)(intptr_t)handle;
    GleamcFuture* f = (GleamcFuture*)gleamc_alloc0_site(sizeof(GleamcFuture), "future:waitany");
    if (mb != NULL && mb->nmsg > 0) {
        f->value_i = 1;
        f->done = true;
        return f;
    }
    if (mb == NULL) {
        f->value_i = 0;
        f->done = true;
        return f;
    }
    gleamc_mailbox_add_notifier(mb, f);
    gleamc_wait_timer_new(f, mb, NULL, ms);
    return f;
}

GleamcFuture* Gleamc_task_ffi_await_timeout(GleamcFuture* task, int64_t ms) {
    GleamcFuture* w = (GleamcFuture*)gleamc_alloc0_site(sizeof(GleamcFuture), "future:await");
    if (task == NULL || task->done) {
        w->value_i = 1;
        w->done = true;
        return w;
    }
    task->notify = w;
    gleamc_wait_timer_new(w, NULL, task, ms);
    return w;
}

/* ------------------------------------------------------------------ */
/* Scheduled sends (`send_after` / `cancel_timer`).                     */
/* ------------------------------------------------------------------ */

/* Number of live libuv timers not attached to a task's pending future, so the
 * driver knows to poll the loop (`send_after`). */
static int gleamc_uv_pending = 0;

typedef struct {
    uv_timer_t timer;
    int64_t subject;
    void* box; /* owned until sent */
    int64_t deadline;
    bool done; /* fired or cancelled */
} GleamcSendTimer;

static void gleamc_send_timer_close_cb(uv_handle_t* h) {
    free((GleamcSendTimer*)h->data);
    if (gleamc_uv_pending > 0) gleamc_uv_pending--;
}

static void gleamc_send_timer_cb(uv_timer_t* t) {
    GleamcSendTimer* st = (GleamcSendTimer*)t->data;
    st->done = true;
    Gleamc_process_ffi_send(st->subject, st->box); /* transfers the box */
    st->box = NULL;
    Gleamc_subject_release(st->subject);
    uv_close((uv_handle_t*)t, gleamc_send_timer_close_cb);
}

int64_t Gleamc_process_ffi_send_after(int64_t subject, int64_t delay, void* box) {
    GleamcSendTimer* st = (GleamcSendTimer*)calloc(1, sizeof(GleamcSendTimer));
    if (st == NULL) {
        Gleamc_process_ffi_send(subject, box);
        return 0;
    }
    st->subject = subject;
    st->box = box;
    st->done = false;
    Gleamc_subject_retain(subject);
    st->deadline = (int64_t)gleamc_now_ms() + (delay < 0 ? 0 : delay);
    uv_timer_init((uv_loop_t*)gleamc_uv_loop(), &st->timer);
    st->timer.data = st;
    uv_timer_start(
        &st->timer, gleamc_send_timer_cb, delay < 0 ? 0 : (uint64_t)delay, 0);
    gleamc_uv_pending++;
    return (int64_t)(intptr_t)st;
}

int64_t Gleamc_process_ffi_cancel_timer(int64_t handle) {
    GleamcSendTimer* st = (GleamcSendTimer*)(intptr_t)handle;
    if (st == NULL || st->done) return -1;
    int64_t remaining = st->deadline - (int64_t)gleamc_now_ms();
    if (remaining < 0) remaining = 0;
    uv_timer_stop(&st->timer);
    if (st->box != NULL) {
        gleamc_box_free(st->box);
        st->box = NULL;
    }
    Gleamc_subject_release(st->subject);
    st->done = true;
    uv_close((uv_handle_t*)&st->timer, gleamc_send_timer_close_cb);
    return remaining;
}

/* ------------------------------------------------------------------ */
/* Selectors: wait for a message on any of several subjects.           */
/*                                                                     */
/* `selector_wait` registers one future as a notifier on every subject */
/* (the boxes stay queued); the first `send` completes it, then        */
/* `selector_ready` finds the queued subject and clears the remaining  */
/* notifier entries. A timer covers the timeout.                       */
/* ------------------------------------------------------------------ */

typedef struct {
    GleamcHdr hdr;
    int64_t* subjects;
    int nsub, cap;
    GleamcFuture* wait_fut;
} GleamcSelector;

static void gleamc_selector_clear_wait(GleamcSelector* sel) {
    if (sel == NULL || sel->wait_fut == NULL) return;
    GleamcFuture* f = sel->wait_fut;
    for (int i = 0; i < sel->nsub; i++) {
        GleamcMailbox* mb = (GleamcMailbox*)(intptr_t)sel->subjects[i];
        if (mb != NULL) gleamc_mailbox_remove_notifier(mb, f);
    }
    sel->wait_fut = NULL;
}

typedef struct {
    uv_timer_t timer;
    GleamcFuture* fut;
    GleamcSelector* sel;
} GleamcSelectorTimer;

static void gleamc_selector_timer_close_cb(uv_handle_t* h) {
    free((GleamcSelectorTimer*)h->data);
}

static void gleamc_selector_timer_cb(uv_timer_t* t) {
    GleamcSelectorTimer* st = (GleamcSelectorTimer*)t->data;
    if (!st->fut->done) {
        st->fut->value_i = 0;
        st->fut->done = true;
    }
    gleamc_selector_clear_wait(st->sel);
    gleamc_release(st->fut);
    st->fut = NULL;
    uv_close((uv_handle_t*)t, gleamc_selector_timer_close_cb);
}

static void gleamc_selector_dtor(void* p) {
    GleamcSelector* sel = (GleamcSelector*)p;
    gleamc_selector_clear_wait(sel);
    for (int i = 0; i < sel->nsub; i++)
        Gleamc_subject_release(sel->subjects[i]);
    free(sel->subjects);
}

void Gleamc_selector_retain(int64_t handle) {
    GleamcSelector* sel = (GleamcSelector*)(intptr_t)handle;
    if (sel != NULL) gleamc_retain(sel);
}

void Gleamc_selector_release(int64_t handle) {
    gleamc_release_with((void*)(intptr_t)handle, gleamc_selector_dtor, "selector");
}

int64_t Gleamc_process_ffi_selector_new(void) {
    GleamcSelector* sel = (GleamcSelector*)gleamc_alloc0_site(sizeof(GleamcSelector), "selector");
    return (int64_t)(intptr_t)sel;
}

static void gleamc_selector_add_subject(GleamcSelector* sel, int64_t subject) {
    if (sel == NULL) return;
    for (int i = 0; i < sel->nsub; i++) {
        if (sel->subjects[i] == subject) return;
    }
    if (sel->nsub == sel->cap) {
        int cap = sel->cap == 0 ? 4 : sel->cap * 2;
        int64_t* grown =
            (int64_t*)realloc(sel->subjects, (size_t)cap * sizeof(int64_t));
        if (grown == NULL) return;
        sel->subjects = grown;
        sel->cap = cap;
    }
    sel->subjects[sel->nsub++] = subject;
    Gleamc_subject_retain(subject);
}

/* The selector functions return the same handle; the caller receives a new
 * owned reference, so the result is retained. */
int64_t Gleamc_process_ffi_selector_add(int64_t handle, int64_t subject) {
    gleamc_selector_add_subject((GleamcSelector*)(intptr_t)handle, subject);
    Gleamc_selector_retain(handle);
    return handle;
}

int64_t Gleamc_process_ffi_selector_remove(int64_t handle, int64_t subject) {
    GleamcSelector* sel = (GleamcSelector*)(intptr_t)handle;
    if (sel != NULL) {
        for (int i = 0; i < sel->nsub; i++) {
            if (sel->subjects[i] == subject) {
                for (int j = i + 1; j < sel->nsub; j++)
                    sel->subjects[j - 1] = sel->subjects[j];
                sel->nsub--;
                Gleamc_subject_release(subject);
                break;
            }
        }
    }
    Gleamc_selector_retain(handle);
    return handle;
}

/* Copies `b`'s subjects into `a` (deduplicated) and returns `a` (retained). */
int64_t Gleamc_process_ffi_selector_merge(int64_t a, int64_t b) {
    GleamcSelector* sa = (GleamcSelector*)(intptr_t)a;
    GleamcSelector* sb = (GleamcSelector*)(intptr_t)b;
    if (sb != NULL) {
        for (int i = 0; i < sb->nsub; i++)
            gleamc_selector_add_subject(sa, sb->subjects[i]);
    }
    Gleamc_selector_retain(a);
    return a;
}

/* Add every subject the current task owns to the selector, so `select_other`
 * watches them (a process only receives messages sent to subjects it owns). */
int64_t Gleamc_process_ffi_selector_watch_owned(int64_t handle) {
    GleamcTask2* me = gleamc_task_by_id(gleamc_current_task_id);
    GleamcSelector* sel = (GleamcSelector*)(intptr_t)handle;
    if (me != NULL) {
        for (int i = 0; i < me->nowned; i++)
            gleamc_selector_add_subject(sel, (int64_t)(intptr_t)me->owned[i]);
    }
    Gleamc_selector_retain(handle);
    return handle;
}

/* Take the oldest message from any subject the selector watches and return it
 * as a `Dynamic` (class "other", i.e. the raw box), or 0 when none is queued. */
int64_t Gleamc_process_ffi_selector_other_raw(int64_t handle) {
    GleamcSelector* sel = (GleamcSelector*)(intptr_t)handle;
    if (sel == NULL) return 0;
    for (int i = 0; i < sel->nsub; i++) {
        GleamcMailbox* mb = (GleamcMailbox*)(intptr_t)sel->subjects[i];
        if (mb == NULL) continue;
        void* box = gleamc_mailbox_take(mb);
        if (box != NULL) return (int64_t)(intptr_t)Gleamc_dynamic_new(9, box, NULL);
    }
    return 0;
}

int64_t Gleamc_process_ffi_selector_subject(int64_t handle, int64_t index) {
    GleamcSelector* sel = (GleamcSelector*)(intptr_t)handle;
    if (sel == NULL || index < 0 || index >= sel->nsub) return 0;
    /* The caller owns the returned handle, so take a reference. */
    Gleamc_subject_retain(sel->subjects[index]);
    return sel->subjects[index];
}

GleamcFuture* Gleamc_process_ffi_selector_wait(int64_t handle, int64_t ms) {
    GleamcSelector* sel = (GleamcSelector*)(intptr_t)handle;
    GleamcFuture* f = (GleamcFuture*)gleamc_alloc0_site(sizeof(GleamcFuture), "future:selector");
    if (sel == NULL) {
        f->value_i = 0;
        f->done = true;
        return f;
    }
    for (int i = 0; i < sel->nsub; i++) {
        GleamcMailbox* mb = (GleamcMailbox*)(intptr_t)sel->subjects[i];
        if (mb != NULL && (mb->nmsg > 0 || mb->ndef > 0)) {
            f->value_i = 1;
            f->done = true;
            return f;
        }
    }
    sel->wait_fut = f;
    for (int i = 0; i < sel->nsub; i++) {
        GleamcMailbox* mb = (GleamcMailbox*)(intptr_t)sel->subjects[i];
        if (mb != NULL) gleamc_mailbox_add_notifier(mb, f);
    }
    if (ms >= 0) {
        GleamcSelectorTimer* st =
            (GleamcSelectorTimer*)calloc(1, sizeof(GleamcSelectorTimer));
        if (st != NULL) {
            st->fut = f;
            st->sel = sel;
            gleamc_retain(f);
            uv_timer_init((uv_loop_t*)gleamc_uv_loop(), &st->timer);
            st->timer.data = st;
            uv_timer_start(&st->timer, gleamc_selector_timer_cb, (uint64_t)ms, 0);
            f->uv_armed = true;
        }
    }
    return f;
}

/* The index of the subject with a queued message, or -1 on timeout. Also
 * clears the selector's pending wait and notifier entries. */
int64_t Gleamc_process_ffi_selector_ready(int64_t handle) {
    GleamcSelector* sel = (GleamcSelector*)(intptr_t)handle;
    if (sel == NULL) return -1;
    int64_t index = -1;
    for (int i = 0; i < sel->nsub; i++) {
        GleamcMailbox* mb = (GleamcMailbox*)(intptr_t)sel->subjects[i];
        if (mb != NULL && mb->nmsg > 0) {
            index = i;
            break;
        }
    }
    gleamc_selector_clear_wait(sel);
    return index;
}

/* ------------------------------------------------------------------ */
/* Names: a registered name is a subject handle bound to a task.       */
/* ------------------------------------------------------------------ */

#define GLEAMC_NAMES_MAX 1024
static struct {
    int64_t name;
    int64_t pid;
} gleamc_names[GLEAMC_NAMES_MAX];
static int gleamc_names_n = 0;

int64_t Gleamc_process_ffi_new_name(void) {
    return (int64_t)(intptr_t)gleamc_mailbox_new();
}

int32_t Gleamc_process_ffi_register(int64_t pid, int64_t name) {
    for (int i = 0; i < gleamc_names_n; i++) {
        if (gleamc_names[i].name == name) {
            gleamc_names[i].pid = pid;
            return 1;
        }
    }
    if (gleamc_names_n >= GLEAMC_NAMES_MAX) return 0;
    gleamc_names[gleamc_names_n].name = name;
    gleamc_names[gleamc_names_n].pid = pid;
    gleamc_names_n++;
    return 1;
}

int32_t Gleamc_process_ffi_unregister(int64_t name) {
    for (int i = 0; i < gleamc_names_n; i++) {
        if (gleamc_names[i].name == name) {
            for (int j = i + 1; j < gleamc_names_n; j++)
                gleamc_names[j - 1] = gleamc_names[j];
            gleamc_names_n--;
            return 1;
        }
    }
    return 0;
}

/* The registered task id, or -1 if the name is not registered. */
int64_t Gleamc_process_ffi_named(int64_t name) {
    for (int i = 0; i < gleamc_names_n; i++) {
        if (gleamc_names[i].name == name) return gleamc_names[i].pid;
    }
    return -1;
}

/* `named_subject` returns the name's subject handle; the caller owns the
 * returned reference, so take one. */
int64_t Gleamc_process_ffi_named_subject(int64_t name) {
    Gleamc_subject_retain(name);
    return name;
}

/* ------------------------------------------------------------------ */
/* Monitors and links.                                                 */
/* ------------------------------------------------------------------ */

static GleamcTask2* gleamc_task_by_id(int64_t id) {
    for (int i = 0; i < gleamc_tasks2_n; i++) {
        if (gleamc_tasks2[i].id == id) return &gleamc_tasks2[i];
    }
    return NULL;
}

static int64_t gleamc_next_monitor_id = 1;

bool Gleamc_process_ffi_monitor_eq(int64_t a, int64_t b) {
    return a == b;
}

int64_t Gleamc_process_ffi_monitor(int64_t pid) {
    int64_t mid = gleamc_next_monitor_id++;
    GleamcTask2* me = gleamc_task_by_id(gleamc_current_task_id);
    GleamcTask2* target = gleamc_task_by_id(pid);
    if (target == NULL) {
        if (me != NULL && Gleamc_make_process_Down_ProcessDown != NULL) {
            gleamc_task_inbox(me, &me->inbox_down);
            void* box = Gleamc_make_process_Down_ProcessDown(mid, pid, 1);
            gleamc_mailbox_send_box(me->inbox_down, box);
        }
        return mid;
    }
    if (target->nmon == target->moncap) {
        int cap = target->moncap == 0 ? 4 : target->moncap * 2;
        int64_t* grown =
            (int64_t*)realloc(target->monitors, (size_t)cap * 2 * sizeof(int64_t));
        if (grown == NULL) return mid;
        target->monitors = grown;
        target->moncap = cap;
    }
    target->monitors[target->nmon * 2] = mid;
    target->monitors[target->nmon * 2 + 1] = gleamc_current_task_id;
    target->nmon++;
    return mid;
}

int32_t Gleamc_process_ffi_demonitor(int64_t mid) {
    for (int i = 0; i < gleamc_tasks2_n; i++) {
        GleamcTask2* t = &gleamc_tasks2[i];
        for (int j = 0; j < t->nmon; j++) {
            if (t->monitors[j * 2] == mid) {
                for (int k = j + 1; k < t->nmon; k++) {
                    t->monitors[(k - 1) * 2] = t->monitors[k * 2];
                    t->monitors[(k - 1) * 2 + 1] = t->monitors[k * 2 + 1];
                }
                t->nmon--;
                return 0;
            }
        }
    }
    return 0;
}

/* The task holds one reference to its monitor/exit inbox for its whole
 * lifetime; each `self_*_inbox` call returns another owned reference. */
int64_t Gleamc_process_ffi_self_down_inbox(void) {
    GleamcTask2* me = gleamc_task_by_id(gleamc_current_task_id);
    if (me == NULL) return 0;
    gleamc_task_inbox(me, &me->inbox_down);
    Gleamc_subject_retain((int64_t)(intptr_t)me->inbox_down);
    return (int64_t)(intptr_t)me->inbox_down;
}

int64_t Gleamc_process_ffi_self_exit_inbox(void) {
    GleamcTask2* me = gleamc_task_by_id(gleamc_current_task_id);
    if (me == NULL) return 0;
    gleamc_task_inbox(me, &me->inbox_exit);
    Gleamc_subject_retain((int64_t)(intptr_t)me->inbox_exit);
    return (int64_t)(intptr_t)me->inbox_exit;
}

int32_t Gleamc_process_ffi_trap_exits(bool on) {
    GleamcTask2* me = gleamc_task_by_id(gleamc_current_task_id);
    if (me != NULL) me->trap_exit = on;
    return 0;
}

bool Gleamc_process_ffi_traps(int64_t pid) {
    GleamcTask2* t = gleamc_task_by_id(pid);
    return t != NULL && !t->finished && t->trap_exit;
}

static void gleamc_task_link_push(GleamcTask2* t, int64_t pid) {
    if (t->nlink == t->linkcap) {
        int cap = t->linkcap == 0 ? 4 : t->linkcap * 2;
        int64_t* grown = (int64_t*)realloc(t->links, (size_t)cap * sizeof(int64_t));
        if (grown == NULL) return;
        t->links = grown;
        t->linkcap = cap;
    }
    t->links[t->nlink++] = pid;
}

bool Gleamc_process_ffi_link(int64_t pid) {
    GleamcTask2* me = gleamc_task_by_id(gleamc_current_task_id);
    GleamcTask2* target = gleamc_task_by_id(pid);
    if (me == NULL || target == NULL) return false;
    gleamc_task_link_push(me, pid);
    gleamc_task_link_push(target, me->id);
    return true;
}

static void gleamc_task_unlink_one(GleamcTask2* t, int64_t pid) {
    for (int i = 0; i < t->nlink; i++) {
        if (t->links[i] == pid) {
            for (int j = i + 1; j < t->nlink; j++) t->links[j - 1] = t->links[j];
            t->nlink--;
            return;
        }
    }
}

int32_t Gleamc_process_ffi_unlink(int64_t pid) {
    GleamcTask2* me = gleamc_task_by_id(gleamc_current_task_id);
    GleamcTask2* target = gleamc_task_by_id(pid);
    if (me == NULL) return 0;
    gleamc_task_unlink_one(me, pid);
    if (target != NULL) gleamc_task_unlink_one(target, me->id);
    return 0;
}

/* Notify a finishing task's monitors (a `Down` to each watcher's inbox) and its
 * links (an `ExitMessage` to each trapping linked task's exit inbox). */
static void gleamc_task_notify_exit(GleamcTask2* t, int64_t reason) {
    for (int i = 0; i < t->nmon; i++) {
        int64_t mid = t->monitors[i * 2];
        int64_t watcher = t->monitors[i * 2 + 1];
        GleamcTask2* w = gleamc_task_by_id(watcher);
        if (w == NULL || Gleamc_make_process_Down_ProcessDown == NULL) continue;
        gleamc_task_inbox(w, &w->inbox_down);
        void* box = Gleamc_make_process_Down_ProcessDown(mid, t->id, reason);
        gleamc_mailbox_send_box(w->inbox_down, box);
    }
    for (int i = 0; i < t->nlink; i++) {
        GleamcTask2* l = gleamc_task_by_id(t->links[i]);
        if (l == NULL) continue;
        if (l->trap_exit && Gleamc_make_process_ExitMessage_ExitMessage != NULL) {
            gleamc_task_inbox(l, &l->inbox_exit);
            void* box = Gleamc_make_process_ExitMessage_ExitMessage(t->id, reason);
            gleamc_mailbox_send_box(l->inbox_exit, box);
        } else {
            /* Not trapping: propagate the exit by terminating the linked task. */
            l->kill_requested = true;
            l->kill_reason = reason;
        }
        gleamc_task_unlink_one(l, t->id);
    }
}

/* Final bookkeeping for a task that ends (normally, `copy` true, or because it
 * was killed, `copy` false and the result discarded). */
static void gleamc_task_finish(GleamcTask2* t, int64_t reason, bool copy) {
    if (copy && t->copy_result != NULL && t->result_dst != NULL)
        t->copy_result(t->frame, t->result_dst);
    if (t->done != NULL) {
        t->done->done = true;
        t->done->crashed = !copy;
        if (t->done->notify != NULL) {
            t->done->notify->value_i = 1;
            t->done->notify->done = true;
            t->done->notify = NULL;
        }
    }
    gleamc_task_notify_exit(t, reason);
    /* The subject list is only used by the owning task's `select_other`. */
    free(t->owned);
    t->owned = NULL;
    t->nowned = 0;
    t->ocap = 0;
    free(t->monitors);
    t->monitors = NULL;
    t->nmon = 0;
    t->moncap = 0;
    free(t->links);
    t->links = NULL;
    t->nlink = 0;
    t->linkcap = 0;
    /* Drop the task's own reference to its monitor/exit inboxes. */
    if (t->inbox_down != NULL) {
        Gleamc_subject_release((int64_t)(intptr_t)t->inbox_down);
        t->inbox_down = NULL;
    }
    if (t->inbox_exit != NULL) {
        Gleamc_subject_release((int64_t)(intptr_t)t->inbox_exit);
        t->inbox_exit = NULL;
    }
    if (t->frame_drop != NULL) t->frame_drop(t->frame);
    else gleamc_release(t->frame);
    if (t->done != NULL) gleamc_release(t->done);
    t->finished = true;
}

int32_t Gleamc_process_ffi_kill(int64_t pid) {
    GleamcTask2* t = gleamc_task_by_id(pid);
    if (t != NULL && !t->finished) {
        t->kill_requested = true;
        t->kill_reason = 1; /* Killed */
    }
    return 0;
}

/* `exit(pid, Normal)`: a trapping target gets an `ExitMessage`, a non-trapping
 * one ignores the signal. */
int32_t Gleamc_process_ffi_send_exit(int64_t pid) {
    GleamcTask2* t = gleamc_task_by_id(pid);
    if (t == NULL || t->finished) return 0;
    if (t->trap_exit && Gleamc_make_process_ExitMessage_ExitMessage != NULL) {
        gleamc_task_inbox(t, &t->inbox_exit);
        void* box =
            Gleamc_make_process_ExitMessage_ExitMessage(gleamc_current_task_id, 0);
        gleamc_mailbox_send_box(t->inbox_exit, box);
    }
    return 0;
}

/* Deliver a pre-built `ExitMessage` box to a trapping target's exit inbox; a
 * non-trapping target is terminated. */
int32_t Gleamc_process_ffi_send_exit_message(int64_t pid, void* box) {
    GleamcTask2* t = gleamc_task_by_id(pid);
    if (t == NULL || t->finished) {
        gleamc_box_free(box);
        return 0;
    }
    if (t->trap_exit) {
        gleamc_task_inbox(t, &t->inbox_exit);
        gleamc_mailbox_send_box(t->inbox_exit, box);
    } else {
        gleamc_box_free(box);
        t->kill_requested = true;
        t->kill_reason = 1; /* Killed */
    }
    return 0;
}

int32_t Gleamc_process_ffi_unreceive(int64_t handle, void* box) {
    GleamcMailbox* mb = (GleamcMailbox*)(intptr_t)handle;
    if (mb == NULL) { gleamc_box_free(box); return 0; }
    if (mb->ndef == mb->dcap) {
        int cap = mb->dcap == 0 ? 8 : mb->dcap * 2;
        void** grown = (void**)realloc(mb->deferred, (size_t)cap * sizeof(void*));
        if (grown == NULL) { gleamc_box_free(box); return 0; }
        mb->deferred = grown; mb->dcap = cap;
    }
    mb->deferred[mb->ndef++] = box;
    return 0;
}

bool Gleamc_process_ffi_has_message(int64_t handle) {
    GleamcMailbox* mb = (GleamcMailbox*)(intptr_t)handle;
    return mb != NULL && (mb->ndef > 0 || mb->nmsg > 0);
}

int64_t Gleamc_process_ffi_mailbox_len(int64_t handle) {
    GleamcMailbox* mb = (GleamcMailbox*)(intptr_t)handle;
    return mb == NULL ? 0 : (int64_t)(mb->ndef + mb->nmsg);
}

int64_t Gleamc_process_ffi_subject_handle(int64_t handle) { return handle; }

/* ------------------------------------------------------------------ */
/* Dynamic values: a class tag plus a boxed payload.                   */
/* ------------------------------------------------------------------ */

typedef struct {
    int32_t tag;
    int32_t _pad;
    void* box;
    void (*drop)(void*);
} GleamcDynamic;

static void gleamc_dynamic_dtor(void* p) {
    GleamcDynamic* d = (GleamcDynamic*)p;
    if (d->drop != NULL) d->drop(d->box);
    gleamc_box_free(d->box);
}

void* Gleamc_dynamic_new(int32_t tag, void* box, void (*drop)(void*)) {
    GleamcDynamic* d =
        (GleamcDynamic*)gleamc_alloc0_site(sizeof(GleamcDynamic), "dynamic");
    d->tag = tag;
    d->box = box;
    d->drop = drop;
    return d;
}

void Gleamc_dynamic_retain(void* p) { gleamc_retain(p); }

void Gleamc_dynamic_release(void* p) {
    gleamc_release_with(p, gleamc_dynamic_dtor, "dynamic");
}

int64_t Gleamc_dynamic_ffi_classify(void* dynamic) {
    if (dynamic == NULL) return -1;
    return ((GleamcDynamic*)dynamic)->tag;
}

void* Gleamc_dynamic_bits(void* dynamic) {
    if (dynamic == NULL) return NULL;
    return ((GleamcDynamic*)dynamic)->box;
}

/* The owning task id of a subject, or the pid registered for a named subject,
 * or -1. */
int64_t Gleamc_process_ffi_subject_owner(int64_t handle) {
    for (int i = 0; i < gleamc_names_n; i++) {
        if (gleamc_names[i].name == handle) return gleamc_names[i].pid;
    }
    GleamcMailbox* mb = (GleamcMailbox*)(intptr_t)handle;
    return mb == NULL ? -1 : mb->owner;
}

/* The name handle a subject was created from, or -1 if it has no name. */
int64_t Gleamc_process_ffi_subject_name(int64_t handle) {
    for (int i = 0; i < gleamc_names_n; i++) {
        if (gleamc_names[i].name == handle) return handle;
    }
    return -1;
}

int64_t Gleamc_process_ffi_name_of_int(int64_t handle) { return handle; }

/* Free a mailbox's queued boxes and its arrays (the cell itself is left to the
 * subject's own refcount / the OS). Used only at shutdown. */
static void gleamc_mailbox_drain(GleamcMailbox* mb) {
    if (mb == NULL) return;
    for (int i = 0; i < mb->nmsg; i++) gleamc_box_free(mb->msgs[i]);
    for (int i = 0; i < mb->ndef; i++) gleamc_box_free(mb->deferred[i]);
    free(mb->msgs);
    free(mb->deferred);
    free(mb->waiters);
    free(mb->notifiers);
    mb->msgs = NULL;
    mb->deferred = NULL;
    mb->waiters = NULL;
    mb->notifiers = NULL;
    mb->nmsg = mb->mcap = 0;
    mb->ndef = mb->dcap = 0;
    mb->nwait = mb->wcap = 0;
    mb->nnotify = mb->ncap = 0;
    /* Drop the cell's allocation reference (the arrays are already freed, so
     * `Gleamc_subject_release`'s teardown is a no-op if another owner calls it). */
    gleamc_release(mb);
}

/* Called from the generated `main` once `Gleamc_main` returns: terminate every
 * still-pending task (drop its frame and completion future, drain its
 * mailboxes) so a short-lived program releases what it left running. */
void gleamc_shutdown(void) {
    for (int i = 0; i < gleamc_tasks2_n; i++) {
        GleamcTask2* t = &gleamc_tasks2[i];
        if (t->finished) continue;
        for (int j = 0; j < t->nowned; j++) gleamc_mailbox_drain(t->owned[j]);
        free(t->owned);
        t->owned = NULL;
        t->nowned = 0;
        free(t->monitors);
        t->monitors = NULL;
        t->nmon = 0;
        free(t->links);
        t->links = NULL;
        t->nlink = 0;
        if (t->frame_drop != NULL) t->frame_drop(t->frame);
        else if (t->frame != NULL) gleamc_release(t->frame);
        if (t->done != NULL) gleamc_release(t->done);
    }
    gleamc_tasks2_n = 0;
}

void gleamc_run_until(GleamcFuture* target) {
    void* loop = gleamc_uv_loop();
    int nested = gleamc_run_depth++;
    for (;;) {
        if (target != NULL && target->done) break;
        if (target == NULL && gleamc_tasks2_n == 0) break;
        int progressed = 0;
        int have_uv = 0;
        int64_t next_deadline = 0;
        for (int i = 0; i < gleamc_tasks2_n; i++) {
            GleamcTask2* t = &gleamc_tasks2[i];
            if (t->finished) {
                /* A nested run only marks tasks finished (it must not move a
                 * running task); the outermost run compacts them. */
                if (!nested) {
                    gleamc_tasks2[i] = gleamc_tasks2[gleamc_tasks2_n - 1];
                    gleamc_tasks2_n--;
                    i--;
                }
                continue;
            }
            if (t->kill_requested) {
                gleamc_task_finish(t, t->kill_reason, false);
                if (!nested) {
                    gleamc_tasks2[i] = gleamc_tasks2[gleamc_tasks2_n - 1];
                    gleamc_tasks2_n--;
                    i--;
                }
                continue;
            }
            if (t->running) continue;
            /* A suspended task is only re-stepped once its pending future is
             * done. */
            GleamcFuture* pending = t->fut_slot != NULL ? *t->fut_slot : NULL;
            if (pending != NULL && !pending->done) {
                if (pending->uv_armed) {
                    have_uv = 1;
                } else if (pending->deadline > 0) {
                    if (next_deadline == 0 || pending->deadline < next_deadline)
                        next_deadline = pending->deadline;
                }
                continue;
            }
            t->running = true;
            int64_t saved_id = gleamc_current_task_id;
            gleamc_current_task_id = t->id;
            int done = t->step(t->frame);
            gleamc_current_task_id = saved_id;
            t->running = false;
            if (done) {
                gleamc_task_finish(t, 0, true);
                if (!nested) {
                    gleamc_tasks2[i] = gleamc_tasks2[gleamc_tasks2_n - 1];
                    gleamc_tasks2_n--;
                    i--;
                }
            } else if (gleamc_delegated) {
                /* Tail call: reuse this task for the callee's machine. */
                t->step = gleamc_delegate.step;
                t->frame = gleamc_delegate.frame;
                t->copy_result = gleamc_delegate.copy_result;
                t->fut_slot = gleamc_delegate.fut_slot;
                t->frame_drop = gleamc_delegate.frame_drop;
                gleamc_delegated = false;
            } else {
                /* It suspended: note the future it is now waiting on. */
                pending = t->fut_slot != NULL ? *t->fut_slot : NULL;
                if (pending == NULL || pending->done) {
                    /* Already runnable again: keep the driver going. */
                    progressed = 1;
                } else if (pending->uv_armed) {
                    have_uv = 1;
                } else if (pending->deadline > 0) {
                    if (next_deadline == 0 || pending->deadline < next_deadline)
                        next_deadline = pending->deadline;
                }
            }
            progressed = 1;
            if (target != NULL && target->done) break;
        }
        if (target != NULL && target->done) break;
        if (progressed) continue;
        if (have_uv || gleamc_uv_pending > 0) {
            uv_run((uv_loop_t*)loop, UV_RUN_ONCE);
        } else if (next_deadline > 0) {
            int64_t now = (int64_t)gleamc_now_ms();
            if (next_deadline > now) gleamc_sleep_ms(next_deadline - now);
            for (int i = 0; i < gleamc_tasks2_n; i++) {
                GleamcTask2* t = &gleamc_tasks2[i];
                if (t->finished) continue;
                GleamcFuture* f = t->fut_slot != NULL ? *t->fut_slot : NULL;
                if (f != NULL && !f->done && !f->uv_armed && f->deadline > 0)
                    f->done = true;
            }
        } else {
            break;  /* no progress possible */
        }
    }
    gleamc_run_depth--;
}

/* ------------------------------------------------------------------ */
/* libuv wrappers: the request callback completes the future. The loop */
/* is the scheduler's; handles are born on it. Without libuv, sync.    */
/* ------------------------------------------------------------------ */

void gleamc_sched_poll(void) {
    uv_run((uv_loop_t*)gleamc_uv_loop(), UV_RUN_ONCE);
}

void* gleamc_uv_loop(void) {
    static uv_loop_t loop;
    static bool init = false;
    if (!init) { uv_loop_init(&loop); init = true; }
    return &loop;
}

static void gleamc_timer_close_cb(uv_handle_t* h) {
    gleamc_release(h);   /* the timer handle leaves with the shot */
}

static void gleamc_timer_cb(uv_timer_t* t) {
    GleamcFuture* f = (GleamcFuture*)t->data;
    if (f != NULL) { f->done = true; f->value_i = 0; }
    uv_close((uv_handle_t*)t, gleamc_timer_close_cb);
}

void* gleamc_uv_timer_init(void* loop) {
    uv_timer_t* t = (uv_timer_t*)gleamc_alloc(sizeof(uv_timer_t));
    uv_timer_init((uv_loop_t*)loop, t);
    return t;
}

GleamcFuture* gleamc_uv_timer_start(void* timer, int64_t ms) {
    GleamcFuture* f = gleamc_alloc_site(sizeof(GleamcFuture), "future");
    f->done = false; f->has_error = false;
    f->error_code = 0; f->value_i = 0; f->value_p = NULL;
    f->deadline = 0;  /* armed on libuv: the wake is by callback */
    f->uv_armed = true;
    ((uv_timer_t*)timer)->data = f;
    uv_timer_start((uv_timer_t*)timer, gleamc_timer_cb,
                   (uint64_t)(ms > 0 ? ms : 0), 0);
    return f;
}

/* One-shot timer on the scheduler loop: the returned future completes in
 * `ms` (libuv callback), and `Gleamc_uv_await_nil` drives the loop until it
 * does. This is the Vesper async base: `timer(ms): Future(())`. */
GleamcFuture* Gleamc_uv_timer(int64_t ms) {
    return gleamc_uv_timer_start(gleamc_uv_timer_init(gleamc_uv_loop()), ms);
}

/* Timer whose future carries a value (the scheduled `ms`). Used to exercise
 * value-carrying suspensions: `time.timer_count(ms): Int`. */
static void gleamc_timer_keep_cb(uv_timer_t* t) {
    GleamcFuture* f = (GleamcFuture*)t->data;
    if (f != NULL) f->done = true;
    uv_close((uv_handle_t*)t, gleamc_timer_close_cb);
}

GleamcFuture* Gleamc_time_timer_count(int64_t ms) {
    uv_timer_t* t = (uv_timer_t*)gleamc_uv_timer_init(gleamc_uv_loop());
    GleamcFuture* f = gleamc_alloc_site(sizeof(GleamcFuture), "future");
    f->done = false; f->has_error = false; f->error_code = 0;
    f->value_i = ms; f->value_p = NULL; f->deadline = 0; f->uv_armed = true;
    t->data = f;
    uv_timer_start(t, gleamc_timer_keep_cb, (uint64_t)(ms > 0 ? ms : 0), 0);
    return f;
}

int64_t Gleamc_uv_value_int(GleamcFuture* f) {
    return f == NULL ? 0 : f->value_i;
}

/* Scalar await: the value on success, `-errno` on failure (uniform across the
 * async I/O builtins, so the Gleam side just checks `< 0`). */
int64_t Gleamc_uv_result(GleamcFuture* f) {
    if (f == NULL) return 0;
    return f->has_error ? -(int64_t)f->error_code : f->value_i;
}

/* `time.timer(ms)`: the builtin the Gleam caller sees returns the Future, which
 * the caller awaits (suspends on) and releases on wake — same shape as
 * `time.timer_count`. */
GleamcFuture* Gleamc_time_timer(int64_t ms) {
    return Gleamc_uv_timer(ms);
}

#define GLEAMC_FS_MAX 64
static struct { uv_fs_t* req; GleamcFuture* fut; } gleamc_fs_map[GLEAMC_FS_MAX];
static int gleamc_fs_map_n = 0;

static void gleamc_fs_bind(uv_fs_t* req, GleamcFuture* fut) {
    if (gleamc_fs_map_n < GLEAMC_FS_MAX) {
        gleamc_fs_map[gleamc_fs_map_n].req = req;
        gleamc_fs_map[gleamc_fs_map_n].fut = fut;
        gleamc_fs_map_n++;
    }
}

static GleamcFuture* gleamc_fs_fut_of(uv_fs_t* req) {
    for (int i = 0; i < gleamc_fs_map_n; i++)
        if (gleamc_fs_map[i].req == req) return gleamc_fs_map[i].fut;
    return NULL;
}

static void gleamc_fs_unbind(uv_fs_t* req) {
    for (int i = 0; i < gleamc_fs_map_n; i++)
        if (gleamc_fs_map[i].req == req) {
            gleamc_fs_map[i] = gleamc_fs_map[gleamc_fs_map_n - 1];
            gleamc_fs_map_n--;
            return;
        }
}

static void gleamc_fs_cb(uv_fs_t* req) {
    GleamcFuture* f = gleamc_fs_fut_of(req);
    gleamc_fs_unbind(req);
    if (f == NULL) { uv_fs_req_cleanup(req); return; }
    ssize_t n = uv_fs_get_result(req);
    f->has_error = n < 0;
    f->error_code = n < 0 ? (int32_t)(-n) : 0;
    /* The bytes block is f->value_p (allocated by read); the read length
     * goes in value_i — the wake TRANSFERS ownership of the block. */
    if (n >= 0) f->value_i = (int64_t)n;
    uv_fs_req_cleanup(req);
    gleamc_release(req);   /* the request leaves when the op finishes */
    f->done = true;
}

GleamcFuture* gleamc_uv_fs_open(void* loop, const char* path,
                                int32_t flags, int32_t mode) {
    GleamcFuture* f = gleamc_alloc_site(sizeof(GleamcFuture), "future");
    f->done = false; f->has_error = false;
    f->error_code = 0; f->value_i = 0; f->value_p = NULL;
    f->uv_armed = true;
    uv_fs_t* req = (uv_fs_t*)gleamc_alloc(uv_req_size(UV_FS));
    gleamc_fs_bind(req, f);
    uv_fs_open((uv_loop_t*)loop, req, path, flags, mode, gleamc_fs_cb);
    return f;
}

GleamcFuture* gleamc_uv_fs_read(void* loop, void* fd, int64_t n) {
    GleamcFuture* f = gleamc_alloc_site(sizeof(GleamcFuture), "future");
    f->done = false; f->has_error = false;
    f->error_code = 0; f->value_i = 0; f->value_p = NULL;
    f->uv_armed = true;
    /* The bytes block is born here (rc=1: the future owns it until the
     * wake TRANSFERS ownership to the destination, without a copy). */
    uint8_t* buf = (uint8_t*)gleamc_alloc((size_t)(n > 0 ? n : 1));
    f->value_p = buf;
    uv_buf_t iov = uv_buf_init((char*)buf, (size_t)n);
    uv_fs_t* req = (uv_fs_t*)gleamc_alloc(uv_req_size(UV_FS));
    gleamc_fs_bind(req, f);
    uv_fs_read((uv_loop_t*)loop, req, (uv_file)(intptr_t)fd, &iov, 1, -1,
               gleamc_fs_cb);
    return f;
}

/* File size (the uv_fs_open fd is an OS fd) — synchronous. */
GleamcFuture* gleamc_uv_fs_fstat(void* loop, void* fd) {
    (void)loop;
    GleamcFuture* f = gleamc_alloc_site(sizeof(GleamcFuture), "future");
    f->done = false; f->has_error = false;
    f->error_code = 0; f->value_i = 0; f->value_p = NULL;
    f->uv_armed = false;
    struct stat st;
    if (fstat((int)(intptr_t)fd, &st) != 0) {
        f->has_error = true; f->error_code = 5;
    } else {
        f->value_i = (int64_t)st.st_size;
    }
    f->done = true;
    return f;
}

GleamcFuture* gleamc_uv_fs_close(void* loop, void* fd) {
    GleamcFuture* f = gleamc_alloc_site(sizeof(GleamcFuture), "future");
    f->done = false; f->has_error = false;
    f->error_code = 0; f->value_i = 0; f->value_p = NULL;
    f->uv_armed = true;
    uv_fs_t* req = (uv_fs_t*)gleamc_alloc(uv_req_size(UV_FS));
    gleamc_fs_bind(req, f);
    uv_fs_close((uv_loop_t*)loop, req, (uv_file)(intptr_t)fd,
                gleamc_fs_cb);
    return f;
}


/* ------------------------------------------------------------------ */
/* File I/O: synchronous libuv wrappers returning a fixed result.      */
/* The Gleam wrapper (std/simplifile.gleam) maps code -> FileError.    */
/* ------------------------------------------------------------------ */

bool Gleamc_bit_array_is_utf8(GleamcBitArray a) {
    if (a.data == NULL) return true;
    size_t i = 0;
    while (i < a.len) {
        utf8proc_int32_t cp;
        utf8proc_ssize_t n =
            utf8proc_iterate(a.data + i, (utf8proc_ssize_t)(a.len - i), &cp);
        if (n < 0) return false;
        i += (size_t)n;
    }
    return true;
}

static GleamcFileResult fs_ok(void) {
    GleamcFileResult r;
    r.code = 0;
    r.data.data = NULL;
    r.data.len = 0;
    r.size = 0;
    return r;
}

static GleamcFileResult fs_error(int64_t code) {
    GleamcFileResult r = fs_ok();
    r.code = code;
    return r;
}

int64_t Gleamc_fs_result_code(GleamcFileResult result) {
    return result.code;
}

GleamcBitArray Gleamc_fs_result_data(GleamcFileResult result) {
    return result.data;
}

int64_t Gleamc_fs_result_size(GleamcFileResult result) {
    return result.size;
}

static char* gleamc_to_cstr(GleamcString s) {
    char* p = (char*)malloc(s.len + 1);
    if (p == NULL) return NULL;
    if (s.len > 0) memcpy(p, s.data, s.len);
    p[s.len] = '\0';
    return p;
}

int64_t Gleamc_fs_int64_at(GleamcBitArray blob, int64_t index) {
    size_t off = (size_t)index * 8;
    if (blob.data == NULL || off + 8 > blob.len) return 0;
    uint64_t v = 0;
    for (int i = 0; i < 8; i++) {
        v |= ((uint64_t)blob.data[off + i]) << (8 * i);
    }
    return (int64_t)v;
}

/* Same reader under the `bit_array` surface (binary decoding, not I/O). */
int64_t Gleamc_bit_array_int64_at(GleamcBitArray blob, int64_t index) {
    return Gleamc_fs_int64_at(blob, index);
}

/* Packs the ten FileInfo fields as little-endian int64s (80 bytes). */
static GleamcFileResult fs_info_from_ints(const int64_t* values) {
    uint8_t* out = (uint8_t*)gleamc_alloc(80);
    for (int i = 0; i < 10; i++) {
        uint64_t v = (uint64_t)values[i];
        for (int j = 0; j < 8; j++) out[i * 8 + j] = (uint8_t)(v >> (8 * j));
    }
    GleamcFileResult r = fs_ok();
    r.data.data = out;
    r.data.len = 80;
    r.size = 10;
    return r;
}

GleamcFileResult Gleamc_fs_read(GleamcString path) {
    char* cpath = gleamc_to_cstr(path);
    if (cpath == NULL) return fs_error(12); /* ENOMEM */
    uv_fs_t req;
    uv_file fd = uv_fs_open(NULL, &req, cpath, O_RDONLY, 0, NULL);
    free(cpath);
    if (fd < 0) { uv_fs_req_cleanup(&req); return fs_error(-fd); }
    uv_fs_req_cleanup(&req);

    uv_fs_t sreq;
    int sres = uv_fs_fstat(NULL, &sreq, fd, NULL);
    if (sres < 0) {
        int64_t code = -sres;
        uv_fs_req_cleanup(&sreq);
        uv_fs_close(NULL, &req, fd, NULL);
        uv_fs_req_cleanup(&req);
        return fs_error(code);
    }
    size_t size = (size_t)sreq.statbuf.st_size;
    uv_fs_req_cleanup(&sreq);

    uint8_t* buf = (uint8_t*)gleamc_alloc(size > 0 ? size : 1);
    size_t off = 0;
    while (off < size) {
        uv_buf_t iov = uv_buf_init((char*)(buf + off), size - off);
        uv_fs_t rreq;
        ssize_t n = uv_fs_read(NULL, &rreq, fd, &iov, 1, (int64_t)off, NULL);
        uv_fs_req_cleanup(&rreq);
        if (n < 0) {
            int64_t code = -n;
            gleamc_release(buf);
            uv_fs_close(NULL, &req, fd, NULL);
            uv_fs_req_cleanup(&req);
            return fs_error(code);
        }
        if (n == 0) break;
        off += (size_t)n;
    }
    uv_fs_close(NULL, &req, fd, NULL);
    uv_fs_req_cleanup(&req);

    GleamcFileResult r = fs_ok();
    r.data.data = buf;
    r.data.len = off;
    r.size = (int64_t)off;
    return r;
}

static GleamcFileResult fs_write_flags(GleamcString path, GleamcBitArray data,
                                       int flags) {
    char* cpath = gleamc_to_cstr(path);
    if (cpath == NULL) return fs_error(12); /* ENOMEM */
    uv_fs_t req;
    uv_file fd = uv_fs_open(NULL, &req, cpath, flags, 0644, NULL);
    free(cpath);
    if (fd < 0) { uv_fs_req_cleanup(&req); return fs_error(-fd); }
    uv_fs_req_cleanup(&req);

    size_t off = 0;
    while (off < data.len) {
        uv_buf_t iov = uv_buf_init((char*)(data.data + off), data.len - off);
        uv_fs_t wreq;
        ssize_t n = uv_fs_write(NULL, &wreq, fd, &iov, 1, (int64_t)off, NULL);
        uv_fs_req_cleanup(&wreq);
        if (n < 0) {
            int64_t code = -n;
            uv_fs_close(NULL, &req, fd, NULL);
            uv_fs_req_cleanup(&req);
            return fs_error(code);
        }
        off += (size_t)n;
    }
    uv_fs_close(NULL, &req, fd, NULL);
    uv_fs_req_cleanup(&req);
    return fs_ok();
}

GleamcFileResult Gleamc_fs_write(GleamcString path, GleamcBitArray data) {
    return fs_write_flags(path, data, O_WRONLY | O_CREAT | O_TRUNC);
}

GleamcFileResult Gleamc_fs_append(GleamcString path, GleamcBitArray data) {
    return fs_write_flags(path, data, O_WRONLY | O_CREAT | O_APPEND);
}

GleamcFileResult Gleamc_fs_delete(GleamcString path) {
    char* cpath = gleamc_to_cstr(path);
    if (cpath == NULL) return fs_error(12);
    uv_fs_t req;
    int res = uv_fs_unlink(NULL, &req, cpath, NULL);
    uv_fs_req_cleanup(&req);
    if (res == 0) { free(cpath); return fs_ok(); }
    /* A directory needs rmdir; it must be empty. */
    if (-res == 21 /* EISDIR */) {
        res = uv_fs_rmdir(NULL, &req, cpath, NULL);
        uv_fs_req_cleanup(&req);
    }
    free(cpath);
    return res == 0 ? fs_ok() : fs_error(-res);
}

GleamcFileResult Gleamc_fs_create_directory(GleamcString path) {
    char* cpath = gleamc_to_cstr(path);
    if (cpath == NULL) return fs_error(12);
    uv_fs_t req;
    int res = uv_fs_mkdir(NULL, &req, cpath, 0755, NULL);
    uv_fs_req_cleanup(&req);
    free(cpath);
    return res == 0 ? fs_ok() : fs_error(-res);
}

GleamcFileResult Gleamc_fs_create_file(GleamcString path) {
    char* cpath = gleamc_to_cstr(path);
    if (cpath == NULL) return fs_error(12);
    uv_fs_t req;
    uv_file fd = uv_fs_open(NULL, &req, cpath, O_WRONLY | O_CREAT | O_EXCL,
                            0644, NULL);
    free(cpath);
    if (fd < 0) { uv_fs_req_cleanup(&req); return fs_error(-fd); }
    uv_fs_req_cleanup(&req);
    uv_fs_close(NULL, &req, fd, NULL);
    uv_fs_req_cleanup(&req);
    return fs_ok();
}

GleamcFileResult Gleamc_fs_rename(GleamcString path, GleamcString new_path) {
    char* cpath = gleamc_to_cstr(path);
    char* cnew = gleamc_to_cstr(new_path);
    if (cpath == NULL || cnew == NULL) {
        free(cpath);
        free(cnew);
        return fs_error(12);
    }
    uv_fs_t req;
    int res = uv_fs_rename(NULL, &req, cpath, cnew, NULL);
    uv_fs_req_cleanup(&req);
    free(cpath);
    free(cnew);
    return res == 0 ? fs_ok() : fs_error(-res);
}

GleamcFileResult Gleamc_fs_symlink(GleamcString target, GleamcString path) {
    char* ctarget = gleamc_to_cstr(target);
    char* cpath = gleamc_to_cstr(path);
    if (ctarget == NULL || cpath == NULL) {
        free(ctarget);
        free(cpath);
        return fs_error(12);
    }
    uv_fs_t req;
    int res = uv_fs_symlink(NULL, &req, ctarget, cpath, 0, NULL);
    uv_fs_req_cleanup(&req);
    free(ctarget);
    free(cpath);
    return res == 0 ? fs_ok() : fs_error(-res);
}

GleamcFileResult Gleamc_fs_link(GleamcString target, GleamcString path) {
    char* ctarget = gleamc_to_cstr(target);
    char* cpath = gleamc_to_cstr(path);
    if (ctarget == NULL || cpath == NULL) {
        free(ctarget);
        free(cpath);
        return fs_error(12);
    }
    uv_fs_t req;
    int res = uv_fs_link(NULL, &req, ctarget, cpath, NULL);
    uv_fs_req_cleanup(&req);
    free(ctarget);
    free(cpath);
    return res == 0 ? fs_ok() : fs_error(-res);
}

GleamcFileResult Gleamc_fs_touch(GleamcString path) {
    char* cpath = gleamc_to_cstr(path);
    if (cpath == NULL) return fs_error(12);
    uv_fs_t req;
    uv_file fd = uv_fs_open(NULL, &req, cpath, O_WRONLY | O_CREAT, 0644, NULL);
    if (fd < 0) {
        int64_t code = -fd;
        uv_fs_req_cleanup(&req);
        free(cpath);
        return fs_error(code);
    }
    uv_fs_req_cleanup(&req);
    uv_fs_close(NULL, &req, fd, NULL);
    uv_fs_req_cleanup(&req);
    double now = (double)gleamc_now_ms() / 1000.0;
    int res = uv_fs_utime(NULL, &req, cpath, now, now, NULL);
    uv_fs_req_cleanup(&req);
    free(cpath);
    return res == 0 ? fs_ok() : fs_error(-res);
}

GleamcFileResult Gleamc_fs_realpath(GleamcString path) {
    char* cpath = gleamc_to_cstr(path);
    if (cpath == NULL) return fs_error(12);
    uv_fs_t req;
    int res = uv_fs_realpath(NULL, &req, cpath, NULL);
    free(cpath);
    if (res < 0) {
        int64_t code = -res;
        uv_fs_req_cleanup(&req);
        return fs_error(code);
    }
    const char* resolved = (const char*)req.ptr;
    size_t len = resolved != NULL ? strlen(resolved) : 0;
    uint8_t* out = (uint8_t*)gleamc_alloc(len > 0 ? len : 1);
    if (len > 0) memcpy(out, resolved, len);
    uv_fs_req_cleanup(&req);
    GleamcFileResult r = fs_ok();
    r.data.data = out;
    r.data.len = len;
    r.size = (int64_t)len;
    return r;
}

GleamcFileResult Gleamc_fs_chmod(GleamcString path, int64_t mode) {
    char* cpath = gleamc_to_cstr(path);
    if (cpath == NULL) return fs_error(12);
    uv_fs_t req;
    int res = uv_fs_chmod(NULL, &req, cpath, (int)mode, NULL);
    uv_fs_req_cleanup(&req);
    free(cpath);
    return res == 0 ? fs_ok() : fs_error(-res);
}

static GleamcFileResult fs_stat_mode(GleamcString path, int want) {
    char* cpath = gleamc_to_cstr(path);
    if (cpath == NULL) return fs_error(12);
    uv_fs_t req;
    int res = uv_fs_stat(NULL, &req, cpath, NULL);
    free(cpath);
    if (res < 0) { uv_fs_req_cleanup(&req); return fs_error(-res); }
    uv_stat_t st = req.statbuf;
    uv_fs_req_cleanup(&req);
    GleamcFileResult r = fs_ok();
    r.size = (int64_t)st.st_size;
    if (want == 1) r.size = S_ISREG(st.st_mode) ? 1 : 0;
    if (want == 2) r.size = S_ISDIR(st.st_mode) ? 1 : 0;
    return r;
}

GleamcFileResult Gleamc_fs_exists(GleamcString path) {
    return fs_stat_mode(path, 0);
}

GleamcFileResult Gleamc_fs_is_file(GleamcString path) {
    return fs_stat_mode(path, 1);
}

GleamcFileResult Gleamc_fs_is_directory(GleamcString path) {
    return fs_stat_mode(path, 2);
}

GleamcFileResult Gleamc_fs_file_size(GleamcString path) {
    return fs_stat_mode(path, 0);
}

GleamcFileResult Gleamc_fs_current_directory(void) {
    size_t size = 4096;
    char* buf = (char*)malloc(size);
    if (buf == NULL) return fs_error(12);
    int res = uv_cwd(buf, &size);
    if (res < 0) { free(buf); return fs_error(-res); }
    size_t len = strlen(buf);
    uint8_t* out = (uint8_t*)gleamc_alloc(len > 0 ? len : 1);
    if (len > 0) memcpy(out, buf, len);
    free(buf);
    GleamcFileResult r = fs_ok();
    r.data.data = out;
    r.data.len = len;
    r.size = (int64_t)len;
    return r;
}

GleamcFileResult Gleamc_fs_read_directory(GleamcString path) {
    char* cpath = gleamc_to_cstr(path);
    if (cpath == NULL) return fs_error(12);
    uv_fs_t req;
    int res = uv_fs_scandir(NULL, &req, cpath, 0, NULL);
    free(cpath);
    if (res < 0) {
        int64_t code = -res;
        uv_fs_req_cleanup(&req);
        return fs_error(code);
    }
    size_t cap = 64, len = 0;
    char* buf = (char*)malloc(cap);
    if (buf == NULL) { uv_fs_req_cleanup(&req); return fs_error(12); }
    uv_dirent_t ent;
    int first = 1;
    int status = uv_fs_scandir_next(&req, &ent);
    while (status != UV_EOF) {
        if (status < 0) {
            int64_t code = -status;
            free(buf);
            uv_fs_req_cleanup(&req);
            return fs_error(code);
        }
        if (strcmp(ent.name, ".") != 0 && strcmp(ent.name, "..") != 0) {
            size_t nlen = strlen(ent.name);
            size_t need = len + nlen + 1;
            if (need > cap) {
                while (cap < need) cap *= 2;
                char* nbuf = (char*)realloc(buf, cap);
                if (nbuf == NULL) {
                    free(buf);
                    uv_fs_req_cleanup(&req);
                    return fs_error(12);
                }
                buf = nbuf;
            }
            if (!first) buf[len++] = '/';
            first = 0;
            memcpy(buf + len, ent.name, nlen);
            len += nlen;
        }
        status = uv_fs_scandir_next(&req, &ent);
    }
    uv_fs_req_cleanup(&req);
    uint8_t* out = (uint8_t*)gleamc_alloc(len > 0 ? len : 1);
    if (len > 0) memcpy(out, buf, len);
    free(buf);
    GleamcFileResult r = fs_ok();
    r.data.data = out;
    r.data.len = len;
    r.size = (int64_t)len;
    return r;
}


GleamcFileResult Gleamc_fs_file_info(GleamcString path) {
    char* cpath = gleamc_to_cstr(path);
    if (cpath == NULL) return fs_error(12);
    uv_fs_t req;
    int res = uv_fs_stat(NULL, &req, cpath, NULL);
    free(cpath);
    if (res < 0) {
        int64_t code = -res;
        uv_fs_req_cleanup(&req);
        return fs_error(code);
    }
    uv_stat_t st = req.statbuf;
    uv_fs_req_cleanup(&req);
    int64_t v[10] = {
        (int64_t)st.st_size, (int64_t)st.st_mode, (int64_t)st.st_nlink,
        (int64_t)st.st_ino, (int64_t)st.st_uid, (int64_t)st.st_gid,
        (int64_t)st.st_dev, (int64_t)st.st_atim.tv_sec,
        (int64_t)st.st_mtim.tv_sec, (int64_t)st.st_ctim.tv_sec,
    };
    return fs_info_from_ints(v);
}

GleamcFileResult Gleamc_fs_link_info(GleamcString path) {
    char* cpath = gleamc_to_cstr(path);
    if (cpath == NULL) return fs_error(12);
    uv_fs_t req;
    int res = uv_fs_lstat(NULL, &req, cpath, NULL);
    free(cpath);
    if (res < 0) {
        int64_t code = -res;
        uv_fs_req_cleanup(&req);
        return fs_error(code);
    }
    uv_stat_t st = req.statbuf;
    uv_fs_req_cleanup(&req);
    int64_t v[10] = {
        (int64_t)st.st_size, (int64_t)st.st_mode, (int64_t)st.st_nlink,
        (int64_t)st.st_ino, (int64_t)st.st_uid, (int64_t)st.st_gid,
        (int64_t)st.st_dev, (int64_t)st.st_atim.tv_sec,
        (int64_t)st.st_mtim.tv_sec, (int64_t)st.st_ctim.tv_sec,
    };
    return fs_info_from_ints(v);
}



double Gleamc_float_raw_exponential(double value) {
    return exp(value);
}

double Gleamc_float_raw_logarithm(double value) {
    return log(value);
}

int64_t Gleamc_int_bitwise_and(int64_t a, int64_t b) {
    return a & b;
}

int64_t Gleamc_int_bitwise_or(int64_t a, int64_t b) {
    return a | b;
}

int64_t Gleamc_int_bitwise_exclusive_or(int64_t a, int64_t b) {
    return a ^ b;
}

int64_t Gleamc_int_bitwise_not(int64_t a) {
    return ~a;
}

int64_t Gleamc_int_bitwise_shift_left(int64_t a, int64_t b) {
    return a << b;
}

int64_t Gleamc_int_bitwise_shift_right(int64_t a, int64_t b) {
    return a >> b;
}

/* ------------------------------------------------------------------ */
/* Host: process/env/argv. `run` returns a blob: an 8-byte little-     */
/* endian exit status followed by the combined stdout/stderr.          */
/* ------------------------------------------------------------------ */

#include <sys/wait.h>

static int gleamc_argc = 0;
static char** gleamc_argv = NULL;

void Gleamc_set_args(int argc, char** argv) {
    gleamc_argc = argc;
    gleamc_argv = argv;
}

GleamcString Gleamc_host_get_env(GleamcString name) {
    char* cname = gleamc_to_cstr(name);
    if (cname == NULL) return gleamc_string_lit("", 0);
    const char* value = getenv(cname);
    free(cname);
    if (value == NULL) return gleamc_string_lit("", 0);
    return gleamc_string_lit(value, strlen(value));
}

GleamcString Gleamc_host_which(GleamcString name) {
    char* cname = gleamc_to_cstr(name);
    if (cname == NULL) return gleamc_string_lit("", 0);
    GleamcString result = gleamc_string_lit("", 0);
    if (strchr(cname, '/') != NULL) {
        if (access(cname, X_OK) == 0) {
            result = gleamc_string_lit(cname, strlen(cname));
        }
    } else {
        const char* path = getenv("PATH");
        if (path != NULL) {
            size_t len = strlen(path);
            char* copy = (char*)malloc(len + 1);
            if (copy != NULL) {
                memcpy(copy, path, len + 1);
                char* save = NULL;
                for (char* dir = strtok_r(copy, ":", &save);
                     dir != NULL;
                     dir = strtok_r(NULL, ":", &save)) {
                    size_t need = strlen(dir) + strlen(cname) + 2;
                    char* full = (char*)malloc(need);
                    if (full == NULL) break;
                    snprintf(full, need, "%s/%s", dir, cname);
                    if (access(full, X_OK) == 0) {
                        result = gleamc_string_lit(full, strlen(full));
                        free(full);
                        break;
                    }
                    free(full);
                }
                free(copy);
            }
        }
    }
    free(cname);
    return result;
}

GleamcBitArray Gleamc_host_run(GleamcString command) {
    char* ccmd = gleamc_to_cstr(command);
    if (ccmd == NULL) {
        uint8_t* out = (uint8_t*)gleamc_alloc(8);
        memset(out, 0, 8);
        return (GleamcBitArray){out, 8};
    }
    size_t clen = strlen(ccmd);
    char* full = (char*)malloc(clen + 7);
    if (full == NULL) {
        free(ccmd);
        uint8_t* out = (uint8_t*)gleamc_alloc(8);
        memset(out, 0, 8);
        return (GleamcBitArray){out, 8};
    }
    memcpy(full, ccmd, clen);
    memcpy(full + clen, " 2>&1", 6); /* include stderr, like Vesper */
    free(ccmd);

    FILE* fp = popen(full, "r");
    free(full);
    if (fp == NULL) {
        uint8_t* out = (uint8_t*)gleamc_alloc(8);
        memset(out, 0, 8);
        return (GleamcBitArray){out, 8};
    }
    size_t cap = 256, len = 0;
    char* buf = (char*)malloc(cap);
    if (buf == NULL) {
        pclose(fp);
        uint8_t* out = (uint8_t*)gleamc_alloc(8);
        memset(out, 0, 8);
        return (GleamcBitArray){out, 8};
    }
    for (;;) {
        if (len + 4096 > cap) {
            cap *= 2;
            char* nbuf = (char*)realloc(buf, cap);
            if (nbuf == NULL) break;
            buf = nbuf;
        }
        size_t got = fread(buf + len, 1, 4096, fp);
        len += got;
        if (got == 0) break;
    }
    int status = pclose(fp);
    int code = WIFEXITED(status) ? WEXITSTATUS(status) : -1;

    uint8_t* out = (uint8_t*)gleamc_alloc(8 + (len > 0 ? len : 1));
    uint64_t ucode = (uint64_t)(int64_t)code;
    for (int i = 0; i < 8; i++) out[i] = (uint8_t)(ucode >> (8 * i));
    if (len > 0) memcpy(out + 8, buf, len);
    free(buf);
    return (GleamcBitArray){out, 8 + len};
}

GleamcBitArray Gleamc_host_argv(void) {
    size_t cap = 64, len = 0;
    char* buf = (char*)malloc(cap);
    if (buf == NULL) return (GleamcBitArray){NULL, 0};
    int first = 1;
    for (int i = 1; i < gleamc_argc; i++) {
        const char* arg = gleamc_argv[i];
        if (arg == NULL) continue;
        size_t alen = strlen(arg);
        size_t need = len + alen + 1;
        if (need > cap) {
            while (cap < need) cap *= 2;
            char* nbuf = (char*)realloc(buf, cap);
            if (nbuf == NULL) { free(buf); return (GleamcBitArray){NULL, 0}; }
            buf = nbuf;
        }
        if (!first) buf[len++] = (char)31; /* unit separator */
        first = 0;
        memcpy(buf + len, arg, alen);
        len += alen;
    }
    uint8_t* out = (uint8_t*)gleamc_alloc(len > 0 ? len : 1);
    if (len > 0) memcpy(out, buf, len);
    free(buf);
    return (GleamcBitArray){out, len};
}

int64_t Gleamc_host_int64_at(GleamcBitArray blob, int64_t index) {
    return Gleamc_fs_int64_at(blob, index);
}

/* Monotonic milliseconds (uv_hrtime), for phase timing. */
int64_t Gleamc_host_now_ms(void) {
    return (int64_t)(uv_hrtime() / 1000000ULL);
}

GleamcBitArray Gleamc_host_blob_slice(GleamcBitArray blob, int64_t offset) {
    if (offset < 0 || (size_t)offset > blob.len) return (GleamcBitArray){NULL, 0};
    size_t len = blob.len - (size_t)offset;
    uint8_t* out = (uint8_t*)gleamc_alloc(len > 0 ? len : 1);
    if (len > 0) memcpy(out, blob.data + offset, len);
    return (GleamcBitArray){out, len};
}

/* ------------------------------------------------------------------ */
/* Host async surface (Vesper docs 09/11/14). I/O starts return a      */
/* Future; `await` drives the scheduler to completion. There is no      */
/* synchronous disk path.                                              */
/* ------------------------------------------------------------------ */

static void gleamc_future_wait(GleamcFuture* f) {
    if (f == NULL) return;
    while (!f->done) uv_run((uv_loop_t*)gleamc_uv_loop(), UV_RUN_ONCE);
}

static GleamcFuture* gleamc_future_err(GleamcFuture* f, int32_t code) {
    f->done = true; f->has_error = true; f->error_code = code;
    f->value_i = 0; f->value_p = NULL; f->uv_armed = false;
    return f;
}

GleamcFuture* Gleamc_uv_fs_open(GleamcString path, int64_t flags, int64_t mode) {
    char* cpath = gleamc_to_cstr(path);
    if (cpath == NULL)
        return gleamc_future_err(gleamc_alloc_site(sizeof(GleamcFuture), "future"), 12);
    GleamcFuture* f = gleamc_uv_fs_open(gleamc_uv_loop(), cpath,
                                        (int32_t)flags, (int32_t)mode);
    free(cpath);
    return f;
}

GleamcFuture* Gleamc_uv_fs_read(int64_t fd, int64_t n) {
    return gleamc_uv_fs_read(gleamc_uv_loop(), (void*)(intptr_t)fd, n);
}

GleamcFuture* Gleamc_uv_fs_fstat(int64_t fd) {
    return gleamc_uv_fs_fstat(gleamc_uv_loop(), (void*)(intptr_t)fd);
}

GleamcFuture* Gleamc_uv_fs_close(int64_t fd) {
    return gleamc_uv_fs_close(gleamc_uv_loop(), (void*)(intptr_t)fd);
}

GleamcFuture* Gleamc_uv_fs_write(int64_t fd, GleamcBitArray data) {
    GleamcFuture* f = gleamc_alloc_site(sizeof(GleamcFuture), "future");
    f->done = false; f->has_error = false; f->error_code = 0;
    f->value_i = 0; f->uv_armed = true;
    size_t n = data.len;
    uint8_t* buf = (uint8_t*)malloc(n > 0 ? n : 1);
    if (n > 0 && data.data != NULL) memcpy(buf, data.data, n);
    f->value_p = buf;
    uv_buf_t iov = uv_buf_init((char*)buf, n);
    uv_fs_t* req = (uv_fs_t*)gleamc_alloc(uv_req_size(UV_FS));
    gleamc_fs_bind(req, f);
    uv_fs_write((uv_loop_t*)gleamc_uv_loop(), req, (uv_file)(intptr_t)fd,
                &iov, 1, -1, gleamc_fs_cb);
    return f;
}

GleamcFuture* Gleamc_uv_fs_unlink(GleamcString path) {
    char* cpath = gleamc_to_cstr(path);
    if (cpath == NULL)
        return gleamc_future_err(gleamc_alloc_site(sizeof(GleamcFuture), "future"), 12);
    GleamcFuture* f = gleamc_alloc_site(sizeof(GleamcFuture), "future");
    f->done = false; f->has_error = false; f->error_code = 0;
    f->value_i = 0; f->value_p = NULL; f->uv_armed = true;
    uv_fs_t* req = (uv_fs_t*)gleamc_alloc(uv_req_size(UV_FS));
    gleamc_fs_bind(req, f);
    uv_fs_unlink((uv_loop_t*)gleamc_uv_loop(), req, cpath, gleamc_fs_cb);
    free(cpath);
    return f;
}

/* Remaining async fs surface for `std/simplifile`: every op returns a
 * Future armed on the scheduler loop (no synchronous disk path). */
static GleamcFuture* fs_new(void) {
    GleamcFuture* f = gleamc_alloc_site(sizeof(GleamcFuture), "future");
    f->done = false; f->has_error = false; f->error_code = 0;
    f->value_i = 0; f->value_p = NULL; f->deadline = 0; f->uv_armed = true;
    return f;
}

static uv_fs_t* fs_new_req(GleamcFuture* f) {
    uv_fs_t* req = (uv_fs_t*)gleamc_alloc(uv_req_size(UV_FS));
    gleamc_fs_bind(req, f);
    return req;
}

GleamcFuture* Gleamc_uv_fs_mkdir(GleamcString path, int64_t mode) {
    char* c = gleamc_to_cstr(path);
    if (c == NULL) return gleamc_future_err(fs_new(), 12);
    GleamcFuture* f = fs_new();
    uv_fs_t* req = fs_new_req(f);
    uv_fs_mkdir((uv_loop_t*)gleamc_uv_loop(), req, c, (int)mode, gleamc_fs_cb);
    free(c);
    return f;
}

GleamcFuture* Gleamc_uv_fs_rmdir(GleamcString path) {
    char* c = gleamc_to_cstr(path);
    if (c == NULL) return gleamc_future_err(fs_new(), 12);
    GleamcFuture* f = fs_new();
    uv_fs_t* req = fs_new_req(f);
    uv_fs_rmdir((uv_loop_t*)gleamc_uv_loop(), req, c, gleamc_fs_cb);
    free(c);
    return f;
}

GleamcFuture* Gleamc_uv_fs_rename(GleamcString from, GleamcString to) {
    char* cf = gleamc_to_cstr(from);
    char* ct = gleamc_to_cstr(to);
    if (cf == NULL || ct == NULL) {
        free(cf); free(ct);
        return gleamc_future_err(fs_new(), 12);
    }
    GleamcFuture* f = fs_new();
    uv_fs_t* req = fs_new_req(f);
    uv_fs_rename((uv_loop_t*)gleamc_uv_loop(), req, cf, ct, gleamc_fs_cb);
    free(cf); free(ct);
    return f;
}

GleamcFuture* Gleamc_uv_fs_symlink(GleamcString from, GleamcString to) {
    char* cf = gleamc_to_cstr(from);
    char* ct = gleamc_to_cstr(to);
    if (cf == NULL || ct == NULL) {
        free(cf); free(ct);
        return gleamc_future_err(fs_new(), 12);
    }
    GleamcFuture* f = fs_new();
    uv_fs_t* req = fs_new_req(f);
    /* arg1 = target path, arg2 = link path (mirrors the sync fs.symlink) */
    uv_fs_symlink((uv_loop_t*)gleamc_uv_loop(), req, cf, ct, 0, gleamc_fs_cb);
    free(cf); free(ct);
    return f;
}

GleamcFuture* Gleamc_uv_fs_link(GleamcString from, GleamcString to) {
    char* cf = gleamc_to_cstr(from);
    char* ct = gleamc_to_cstr(to);
    if (cf == NULL || ct == NULL) {
        free(cf); free(ct);
        return gleamc_future_err(fs_new(), 12);
    }
    GleamcFuture* f = fs_new();
    uv_fs_t* req = fs_new_req(f);
    uv_fs_link((uv_loop_t*)gleamc_uv_loop(), req, cf, ct, gleamc_fs_cb);
    free(cf); free(ct);
    return f;
}

GleamcFuture* Gleamc_uv_fs_chmod(GleamcString path, int64_t mode) {
    char* c = gleamc_to_cstr(path);
    if (c == NULL) return gleamc_future_err(fs_new(), 12);
    GleamcFuture* f = fs_new();
    uv_fs_t* req = fs_new_req(f);
    uv_fs_chmod((uv_loop_t*)gleamc_uv_loop(), req, c, (int)mode, gleamc_fs_cb);
    free(c);
    return f;
}

static void gleamc_fs_stat_cb(uv_fs_t* req) {
    GleamcFuture* f = gleamc_fs_fut_of(req);
    gleamc_fs_unbind(req);
    if (f == NULL) { uv_fs_req_cleanup(req); return; }
    ssize_t n = uv_fs_get_result(req);
    if (n < 0) {
        f->has_error = true;
        f->error_code = (int32_t)(-n);
    } else {
        const uv_stat_t* st = &req->statbuf;
        int64_t vals[10] = {
            (int64_t)st->st_size, (int64_t)st->st_mode, (int64_t)st->st_nlink,
            (int64_t)st->st_ino, (int64_t)st->st_uid, (int64_t)st->st_gid,
            (int64_t)st->st_dev, (int64_t)st->st_atim.tv_sec,
            (int64_t)st->st_mtim.tv_sec, (int64_t)st->st_ctim.tv_sec,
        };
        GleamcFileResult r = fs_info_from_ints(vals);
        f->value_p = r.data.data;
        f->value_i = (int64_t)r.data.len;
    }
    uv_fs_req_cleanup(req);
    gleamc_release(req);
    f->done = true;
}

GleamcFuture* Gleamc_uv_fs_stat(GleamcString path, int64_t follow_links) {
    char* c = gleamc_to_cstr(path);
    if (c == NULL) return gleamc_future_err(fs_new(), 12);
    GleamcFuture* f = fs_new();
    uv_fs_t* req = fs_new_req(f);
    if (follow_links) {
        uv_fs_stat((uv_loop_t*)gleamc_uv_loop(), req, c, gleamc_fs_stat_cb);
    } else {
        uv_fs_lstat((uv_loop_t*)gleamc_uv_loop(), req, c, gleamc_fs_stat_cb);
    }
    free(c);
    return f;
}

static void gleamc_fs_realpath_cb(uv_fs_t* req) {
    GleamcFuture* f = gleamc_fs_fut_of(req);
    gleamc_fs_unbind(req);
    if (f == NULL) { uv_fs_req_cleanup(req); return; }
    ssize_t n = uv_fs_get_result(req);
    if (n < 0) {
        f->has_error = true;
        f->error_code = (int32_t)(-n);
    } else {
        const char* p = (const char*)req->ptr;
        size_t len = p == NULL ? 0 : strlen(p);
        uint8_t* buf = (uint8_t*)gleamc_alloc(len > 0 ? len : 1);
        if (len > 0) memcpy(buf, p, len);
        f->value_p = buf;
        f->value_i = (int64_t)len;
    }
    uv_fs_req_cleanup(req);
    gleamc_release(req);
    f->done = true;
}

GleamcFuture* Gleamc_uv_fs_realpath(GleamcString path) {
    char* c = gleamc_to_cstr(path);
    if (c == NULL) return gleamc_future_err(fs_new(), 12);
    GleamcFuture* f = fs_new();
    uv_fs_t* req = fs_new_req(f);
    uv_fs_realpath((uv_loop_t*)gleamc_uv_loop(), req, c, gleamc_fs_realpath_cb);
    free(c);
    return f;
}

/* Directory entries joined by '/' (matching the sync `fs.read_directory`). */
static void gleamc_fs_readdir_cb(uv_fs_t* req) {
    GleamcFuture* f = gleamc_fs_fut_of(req);
    gleamc_fs_unbind(req);
    if (f == NULL) { uv_fs_req_cleanup(req); return; }
    ssize_t n = uv_fs_get_result(req);
    if (n < 0) {
        f->has_error = true;
        f->error_code = (int32_t)(-n);
    } else {
        /* Build in a scratch buffer, then copy into a refcounted block: the
         * awaited BitArray owns the block and releases it through the rc
         * kernel (`Gleamc_bit_array_release`), so it must come from
         * `gleamc_alloc`, not `malloc`. */
        size_t cap = 64, len = 0;
        uint8_t* scratch = (uint8_t*)malloc(cap);
        uv_dirent_t ent;
        int first = 1;
        while (uv_fs_scandir_next(req, &ent) == 0) {
            size_t l = strlen(ent.name);
            size_t need = len + l + 1;
            while (need > cap) { cap *= 2; scratch = realloc(scratch, cap); }
            if (!first) scratch[len++] = '/';
            memcpy(scratch + len, ent.name, l);
            len += l;
            first = 0;
        }
        uint8_t* out = (uint8_t*)gleamc_alloc(len > 0 ? len : 1);
        if (len > 0) memcpy(out, scratch, len);
        free(scratch);
        f->value_p = out;
        f->value_i = (int64_t)len;
    }
    uv_fs_req_cleanup(req);
    gleamc_release(req);
    f->done = true;
}

GleamcFuture* Gleamc_uv_fs_readdir(GleamcString path) {
    char* c = gleamc_to_cstr(path);
    if (c == NULL) return gleamc_future_err(fs_new(), 12);
    GleamcFuture* f = fs_new();
    uv_fs_t* req = fs_new_req(f);
    uv_fs_scandir((uv_loop_t*)gleamc_uv_loop(), req, c, 0, gleamc_fs_readdir_cb);
    free(c);
    return f;
}

GleamcFuture* Gleamc_uv_fs_cwd(void) {
    GleamcFuture* f = fs_new();
    char buf[4096];
    size_t len = sizeof(buf);
    if (uv_cwd(buf, &len) != 0) {
        return gleamc_future_err(f, 1);
    }
    uint8_t* out = (uint8_t*)gleamc_alloc(len > 0 ? len : 1);
    if (len > 0) memcpy(out, buf, len);
    f->value_p = out;
    f->value_i = (int64_t)len;
    f->done = true;
    f->uv_armed = false;
    return f;
}

int64_t Gleamc_uv_await_int(GleamcFuture* f) {
    gleamc_future_wait(f);
    return f == NULL ? 0 : f->value_i;
}

void Gleamc_uv_await_nil(GleamcFuture* f) {
    gleamc_future_wait(f);
}

GleamcBitArray Gleamc_uv_await_bytes(GleamcFuture* f) {
    gleamc_future_wait(f);
    if (f == NULL) return (GleamcBitArray){NULL, 0};
    return (GleamcBitArray){(uint8_t*)f->value_p, (size_t)f->value_i};
}

int64_t Gleamc_uv_error(GleamcFuture* f) {
    if (f == NULL) return 0;
    gleamc_future_wait(f);
    return f->has_error ? (int64_t)f->error_code : 0;
}

/* Byte-indexed string access for the tokenizer (O(1) per character). */
int64_t Gleamc_host_char_code_at(GleamcString s, int64_t off) {
    if (off < 0 || (size_t)off >= s.len) return -1;
    utf8proc_int32_t cp;
    utf8proc_ssize_t n = utf8proc_iterate(
        (const utf8proc_uint8_t*)s.data + off,
        (utf8proc_ssize_t)(s.len - (size_t)off), &cp);
    return n <= 0 ? -1 : (int64_t)cp;
}

int64_t Gleamc_host_char_byte_len(GleamcString s, int64_t off) {
    if (off < 0 || (size_t)off >= s.len) return 0;
    utf8proc_int32_t cp;
    utf8proc_ssize_t n = utf8proc_iterate(
        (const utf8proc_uint8_t*)s.data + off,
        (utf8proc_ssize_t)(s.len - (size_t)off), &cp);
    return n <= 0 ? 1 : (int64_t)n;
}

GleamcString Gleamc_host_byte_slice(GleamcString s, int64_t start, int64_t len) {
    if (start < 0) start = 0;
    if (start > (int64_t)s.len) start = (int64_t)s.len;
    int64_t end = start + len;
    if (end > (int64_t)s.len) end = (int64_t)s.len;
    size_t n = (size_t)(end - start);
    char* buf = (char*)gleamc_alloc(n + 1);
    if (n > 0) memcpy(buf, s.data + start, n);
    buf[n] = '\0';
    return (GleamcString){buf, n};
}
