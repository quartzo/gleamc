/* gleamc kernel implementation (see gleam_runtime.h). */
#define _POSIX_C_SOURCE 200809L /* nanosleep / fileno / fstat (scheduler+libuv) */
#include "gleam_runtime.h"

static size_t codepoint_offset(GleamcString s, int64_t index);

#include <math.h>
#include <pthread.h>
#include <uv.h>
#include <fcntl.h>
#include <string.h>

#include <unicode/ustring.h>
#include <utf8proc.h>

static size_t _gleamc_live = 0;

static void _gleamc_report_leaks(void) {
    const char* flag = getenv("GLEAMC_MEM_REPORT");
    if (flag != NULL) {
        fprintf(stderr, "gleamc: live blocks = %zu\n", _gleamc_live);
    }
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
    return (uint8_t*)h + sizeof(GleamcHdr);
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
    char* buf = (char*)gleamc_alloc(len + 1);
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
    uint8_t* data = (uint8_t*)gleamc_alloc(len + 1);
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
        if (step(frame)) return true;
        GleamcFuture* fut = *fut_slot;
        while (fut != NULL && !fut->done) {
            if (fut->deadline > 0) {
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

