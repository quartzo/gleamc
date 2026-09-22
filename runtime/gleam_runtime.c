/* gleamc kernel implementation (see gleam_runtime.h). */
#include "gleam_runtime.h"

static size_t codepoint_offset(GleamcString s, int64_t index);

#include <math.h>

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

int64_t Gleamc_string_length(GleamcString s) {
    /* counts UTF-8 codepoints (ASCII == graphemes) */
    int64_t n = 0;
    for (size_t i = 0; i < s.len; i++) {
        if (((unsigned char)s.data[i] & 0xC0) != 0x80) n++;
    }
    return n;
}

GleamcString Gleamc_string_append(GleamcString a, GleamcString b) {
    return gleamc_string_concat(a, b);
}

static char ascii_upper(char c) {
    return (c >= 'a' && c <= 'z') ? (char)(c - 32) : c;
}

static char ascii_lower(char c) {
    return (c >= 'A' && c <= 'Z') ? (char)(c + 32) : c;
}

/* True when `s` is an RC block this call uniquely owns, so it may be mutated
 * in place. Shared blocks (refcount > 1) and immortal literals
 * (GLEAMC_RC_STATIC) are excluded. */
static bool string_can_mutate(GleamcString s) {
    if (s.data == NULL) return false;
    GleamcHdr* h = (GleamcHdr*)((uint8_t*)s.data - sizeof(GleamcHdr));
    return h->refcount == 1;
}

/* `uppercase`/`lowercase` preserve length, so a uniquely owned string can be
 * rewritten in place. The FFI declares the argument `Owned`; when the caller
 * still needs it the ownership pass retains first, the refcount becomes > 1
 * and this falls back to allocating a copy (releasing the transferred ref). */
GleamcString Gleamc_string_uppercase(GleamcString s) {
    if (string_can_mutate(s)) {
        char* buf = (char*)s.data;
        for (size_t i = 0; i < s.len; i++) buf[i] = ascii_upper(buf[i]);
        return s;
    }
    char* buf = (char*)gleamc_alloc(s.len + 1);
    for (size_t i = 0; i < s.len; i++) buf[i] = ascii_upper(s.data[i]);
    buf[s.len] = '\0';
    GleamcString result = {buf, s.len};
    gleamc_string_release(s);
    return result;
}

GleamcString Gleamc_string_lowercase(GleamcString s) {
    if (string_can_mutate(s)) {
        char* buf = (char*)s.data;
        for (size_t i = 0; i < s.len; i++) buf[i] = ascii_lower(buf[i]);
        return s;
    }
    char* buf = (char*)gleamc_alloc(s.len + 1);
    for (size_t i = 0; i < s.len; i++) buf[i] = ascii_lower(s.data[i]);
    buf[s.len] = '\0';
    GleamcString result = {buf, s.len};
    gleamc_string_release(s);
    return result;
}

GleamcString Gleamc_string_reverse(GleamcString s) {
    /* reverses codepoints, not combining sequences (ASCII == graphemes) */
    char* buf = (char*)gleamc_alloc(s.len + 1);
    size_t out = 0;
    size_t i = s.len;
    while (i > 0) {
        size_t j = i - 1;
        while (j > 0 && ((unsigned char)s.data[j] & 0xC0) == 0x80) j--;
        memcpy(buf + out, s.data + j, i - j);
        out += i - j;
        i = j;
    }
    buf[out] = '\0';
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
    size_t start = codepoint_offset(value, idx);
    size_t finish = codepoint_offset(value, end);
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
