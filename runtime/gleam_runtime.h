/* gleamc C runtime — minimal refcounted memory kernel.
 *
 * Adapted from Vesper (src/vesper/runtime/vesper_runtime.[ch]): the
 * refcount header, the inline retain/release macro pair (free on the
 * cold path) and the String type. The prefix changes `vesper_` to
 * `gleamc_`.
 *
 * Linked into every generated program:
 *   clang -O0 -I runtime out.c runtime/gleam_runtime.c -o app
 */
#ifndef GLEAMC_RUNTIME_H
#define GLEAMC_RUNTIME_H

#include <stdint.h>
#include <stddef.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* ------------------------------------------------------------------ */
/* Memory kernel (Vesper doc 13 §1): every allocation is refcounted.   */
/* ------------------------------------------------------------------ */

typedef struct {
    size_t refcount;
} GleamcHdr;

/* Immortal block: String literals live in .rodata with the header marked
 * by this sentinel. String retain/release recognise it and become a no-op. */
#define GLEAMC_RC_STATIC ((size_t)-1)

/* Allocates `size` payload bytes; the header refcount starts at 1. */
void* gleamc_alloc(size_t size);

/* Drop to zero: frees the block (cold path). */
void gleamc_release_slow(GleamcHdr* h);

/* Inline retain/release: the +1/-1 at the generated site becomes header
 * arithmetic; only the drop to zero calls into the kernel. NULL-safe. */
#define gleamc_retain(p)                                                \
    do {                                                                \
        void* _gp = (p);                                                \
        if (_gp != NULL)                                                \
            ((GleamcHdr*)((uint8_t*)_gp - sizeof(GleamcHdr)))           \
                ->refcount++;                                           \
    } while (0)

#define gleamc_release(p)                                               \
    do {                                                                \
        void* _gr = (p);                                                \
        if (_gr != NULL) {                                              \
            GleamcHdr* _gh = (GleamcHdr*)                               \
                ((uint8_t*)_gr - sizeof(GleamcHdr));                    \
            if (_gh->refcount != GLEAMC_RC_STATIC                       \
                    && --_gh->refcount == 0)                            \
                gleamc_release_slow(_gh);                               \
        }                                                               \
    } while (0)

size_t gleamc_live_blocks(void);   /* live blocks (tests) */

/* ------------------------------------------------------------------ */
/* String — UTF-8 text (bytes + length)                                */
/* ------------------------------------------------------------------ */

typedef struct {
    const char* data;
    size_t len;
} GleamcString;

/* Dynamic literal: copies `len` bytes into a refcounted block. */
GleamcString gleamc_string_lit(const char* data, size_t len);

/* Concatenation and equality (UTF-8 bytes). */
GleamcString gleamc_string_concat(GleamcString a, GleamcString b);
bool gleamc_string_eq(GleamcString a, GleamcString b);

#define gleamc_string_retain(s)                                         \
    do {                                                                \
        GleamcString _gs = (s);                                         \
        if (_gs.data != NULL) {                                         \
            GleamcHdr* _gh = (GleamcHdr*)                               \
                ((uint8_t*)_gs.data - sizeof(GleamcHdr));               \
            if (_gh->refcount != GLEAMC_RC_STATIC) _gh->refcount++;     \
        }                                                               \
    } while (0)

#define gleamc_string_release(s)                                        \
    do {                                                                \
        GleamcString _gs = (s);                                         \
        if (_gs.data != NULL) {                                         \
            GleamcHdr* _gh = (GleamcHdr*)                               \
                ((uint8_t*)_gs.data - sizeof(GleamcHdr));               \
            if (_gh->refcount != GLEAMC_RC_STATIC                       \
                    && --_gh->refcount == 0)                            \
                gleamc_release_slow(_gh);                               \
        }                                                               \
    } while (0)

/* ------------------------------------------------------------------ */
/* std::io — print (to_string is inserted by the compiler)             */
/* ------------------------------------------------------------------ */

/* Nil is represented as `int` in generated code, so print returns 0. */
int Gleamc_io_print(GleamcString s);
int Gleamc_io_println(GleamcString s);

/* std::string */
int64_t Gleamc_string_length(GleamcString s);
GleamcString Gleamc_string_append(GleamcString a, GleamcString b);
GleamcString Gleamc_string_uppercase(GleamcString s);
GleamcString Gleamc_string_lowercase(GleamcString s);
GleamcString Gleamc_string_reverse(GleamcString s);

/* std::string (predicates / transforms) */
bool Gleamc_string_contains(GleamcString haystack, GleamcString needle);
bool Gleamc_string_starts_with(GleamcString value, GleamcString prefix);
bool Gleamc_string_ends_with(GleamcString value, GleamcString suffix);
GleamcString Gleamc_string_trim(GleamcString value);
GleamcString Gleamc_string_trim_start(GleamcString value);
GleamcString Gleamc_string_trim_end(GleamcString value);
GleamcString Gleamc_string_slice(GleamcString value, int64_t from, int64_t to);
GleamcString Gleamc_string_replace(
    GleamcString value,
    GleamcString pattern,
    GleamcString substitute
);

/* std::int */
int64_t Gleamc_int_min(int64_t a, int64_t b);
int64_t Gleamc_int_max(int64_t a, int64_t b);
int64_t Gleamc_int_absolute_value(int64_t a);

/* std::float */
double Gleamc_float_min(double a, double b);
double Gleamc_float_max(double a, double b);
double Gleamc_float_absolute_value(double a);
double Gleamc_float_floor(double a);
double Gleamc_float_ceiling(double a);
int64_t Gleamc_float_round(double a);
int64_t Gleamc_float_truncate(double a);

/* std::int / std::float / std::bool to_string */
GleamcString Gleamc_int_to_string(int64_t v);
GleamcString Gleamc_float_to_string(double v);
GleamcString Gleamc_bool_to_string(bool v);

#endif /* GLEAMC_RUNTIME_H */
