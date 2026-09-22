/* gleamc kernel implementation (see gleam_runtime.h). */
#include "gleam_runtime.h"

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

GleamcString Gleamc_string_uppercase(GleamcString s) {
    char* buf = (char*)gleamc_alloc(s.len + 1);
    for (size_t i = 0; i < s.len; i++) buf[i] = ascii_upper(s.data[i]);
    buf[s.len] = '\0';
    return (GleamcString){buf, s.len};
}

GleamcString Gleamc_string_lowercase(GleamcString s) {
    char* buf = (char*)gleamc_alloc(s.len + 1);
    for (size_t i = 0; i < s.len; i++) buf[i] = ascii_lower(s.data[i]);
    buf[s.len] = '\0';
    return (GleamcString){buf, s.len};
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

static GleamcString from_cstr(const char* text) {
    return gleamc_string_lit(text, strlen(text));
}

GleamcString Gleamc_int_to_string(int64_t v) {
    char buf[32];
    snprintf(buf, sizeof buf, "%lld", (long long)v);
    return from_cstr(buf);
}

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
