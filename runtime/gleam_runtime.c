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
 * when the limit is reached it calls this to name the function that went
 * deepest and abort. */
void gleamc_depth_die(const char* fn) {
    fprintf(stderr, "gleamc: call depth limit reached in %s\n",
            fn != NULL ? fn : "?");
    fflush(stderr);
    abort();
}

static void _gleamc_report_leaks(void) {
    const char* flag = getenv("GLEAMC_MEM_REPORT");
    if (flag != NULL) {
        fprintf(stderr, "gleamc: live blocks = %zu\n", _gleamc_live);
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

void gleamc_release_slow(GleamcHdr* h) {
    if (h->refcount == GLEAMC_RC_STATIC) return;
    _gleamc_live--;
    free(h);
}

size_t gleamc_live_blocks(void) { return _gleamc_live; }

GleamcString gleamc_string_lit(const char* data, size_t len) {
    char* buf = (char*)gleamc_alloc(len + 1);
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
    GleamcFuture* f = gleamc_alloc(sizeof(GleamcFuture));
    f->deadline = (int64_t)gleamc_now_ms() + ms;
    f->done = false;
    f->has_error = false;
    f->error_code = 0;
    f->value_i = 0;
    f->value_p = NULL;
    f->uv_armed = false;
    return f;
}

/* Scheduler task list (spawn). */
#define GLEAMC_TASKS_MAX 64
static struct {
    bool (*step)(void*);
    void* frame;
    GleamcFuture** fut_slot;
    bool done;
} gleamc_tasks[GLEAMC_TASKS_MAX];
static int gleamc_tasks_n = 0;

void gleamc_task_spawn(bool (*step)(void*), void* frame,
                       GleamcFuture** fut_slot) {
    /* The spawn site allocates the frame with rc=1 and TRANSFERS ownership
     * to the scheduler (no extra retain); drain releases it. */
    if (gleamc_tasks_n >= GLEAMC_TASKS_MAX) {
        fprintf(stderr, "gleamc: task overflow (%d) — frame discarded\n",
                GLEAMC_TASKS_MAX);
        gleamc_release(frame);
        return;
    }
    gleamc_tasks[gleamc_tasks_n].step = step;
    gleamc_tasks[gleamc_tasks_n].frame = frame;
    gleamc_tasks[gleamc_tasks_n].fut_slot = fut_slot;
    gleamc_tasks[gleamc_tasks_n].done = false;
    gleamc_tasks_n++;
}

int32_t gleamc_tasks_drain(void) {
    while (gleamc_tasks_n > 0) {
        int progressed = 0;
        for (int i = 0; i < gleamc_tasks_n; i++) {
            if (gleamc_tasks[i].done) continue;
            if (gleamc_tasks[i].step(gleamc_tasks[i].frame)) {
                gleamc_release(gleamc_tasks[i].frame);
                gleamc_tasks[i] = gleamc_tasks[gleamc_tasks_n - 1];
                gleamc_tasks_n--;
                i--;
                progressed = 1;
                continue;
            }
            GleamcFuture* fut = *gleamc_tasks[i].fut_slot;
            if (fut != NULL && !fut->done && fut->deadline > 0) {
                int64_t now = (int64_t)gleamc_now_ms();
                if (fut->deadline > now)
                    gleamc_sleep_ms(fut->deadline - now);
                fut->done = true;
                progressed = 1;
            }
            if (fut != NULL && fut->uv_armed) progressed = 1;
        }
        if (!progressed && gleamc_tasks_n > 0) {
            break;  /* no progress and no resolved future: avoid spinning */
        }
    }
    return 0;
}

bool gleamc_sched_run(bool (*step)(void* frame), void* frame,
                      GleamcFuture** fut_slot) {
    void* loop = gleamc_uv_loop();
    for (;;) {
        if (step(frame)) {
            /* Drain pending libuv close callbacks so handles (timers, ...) are
             * released before the machine returns. */
            uv_run((uv_loop_t*)loop, UV_RUN_NOWAIT);
            return true;
        }
        GleamcFuture* fut = *fut_slot;
        while (fut != NULL && !fut->done) {
            /* Only scheduler-deadline futures sleep; libuv-armed ones are
             * woken by their callback. */
            if (!fut->uv_armed && fut->deadline > 0) {
                int64_t now = (int64_t)gleamc_now_ms();
                if (fut->deadline > now)
                    gleamc_sleep_ms(fut->deadline - now);
                fut->done = true;
                break;
            }
            uv_run((uv_loop_t*)loop, UV_RUN_ONCE);
        }
    }
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
    GleamcFuture* f = gleamc_alloc(sizeof(GleamcFuture));
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
    GleamcFuture* f = gleamc_alloc(sizeof(GleamcFuture));
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
    GleamcFuture* f = gleamc_alloc(sizeof(GleamcFuture));
    f->done = false; f->has_error = false;
    f->error_code = 0; f->value_i = 0; f->value_p = NULL;
    f->uv_armed = true;
    uv_fs_t* req = (uv_fs_t*)gleamc_alloc(uv_req_size(UV_FS));
    gleamc_fs_bind(req, f);
    uv_fs_open((uv_loop_t*)loop, req, path, flags, mode, gleamc_fs_cb);
    return f;
}

GleamcFuture* gleamc_uv_fs_read(void* loop, void* fd, int64_t n) {
    GleamcFuture* f = gleamc_alloc(sizeof(GleamcFuture));
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
    GleamcFuture* f = gleamc_alloc(sizeof(GleamcFuture));
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
    GleamcFuture* f = gleamc_alloc(sizeof(GleamcFuture));
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
        return gleamc_future_err(gleamc_alloc(sizeof(GleamcFuture)), 12);
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
    GleamcFuture* f = gleamc_alloc(sizeof(GleamcFuture));
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
        return gleamc_future_err(gleamc_alloc(sizeof(GleamcFuture)), 12);
    GleamcFuture* f = gleamc_alloc(sizeof(GleamcFuture));
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
    GleamcFuture* f = gleamc_alloc(sizeof(GleamcFuture));
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
