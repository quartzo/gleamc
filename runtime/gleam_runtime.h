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
/* BitArray — raw bytes (bit arrays with 8-bit segments)               */
/* ------------------------------------------------------------------ */

typedef struct {
    uint8_t* data;
    size_t len;
} GleamcBitArray;

GleamcBitArray Gleamc_bit_array_new(size_t len);
GleamcBitArray Gleamc_bit_array_from_bytes(const int64_t* values, size_t count);
GleamcBitArray Gleamc_bit_array_from_string(GleamcString s);
GleamcString Gleamc_bit_array_raw_to_string(GleamcBitArray a);
int64_t Gleamc_bit_array_byte_size(GleamcBitArray a);
int64_t Gleamc_bit_array_byte(GleamcBitArray a, size_t index);
GleamcBitArray Gleamc_bit_array_append(GleamcBitArray a, GleamcBitArray b);
bool Gleamc_bit_array_eq(GleamcBitArray a, GleamcBitArray b);
void Gleamc_bit_array_retain(GleamcBitArray a);
void Gleamc_bit_array_release(GleamcBitArray a);
bool Gleamc_bit_array_is_utf8(GleamcBitArray a);

/* ------------------------------------------------------------------ */
/* File I/O results: a fixed struct the runtime knowns how to build.   */
/*                                                                     */
/* `code` is 0 on success or a positive errno on failure. A Gleam      */
/* wrapper (std/simplifile.gleam) turns it into a concrete Result with */
/* the FileError type.                                                 */
/* ------------------------------------------------------------------ */

typedef struct {
    int64_t code;        /* 0 = ok, else positive errno               */
    GleamcBitArray data; /* owned bytes when a read succeeds          */
    int64_t size;        /* byte size or boolean (0/1) when relevant  */
} GleamcFileResult;

GleamcFileResult Gleamc_fs_read(GleamcString path);
GleamcFileResult Gleamc_fs_write(GleamcString path, GleamcBitArray data);
GleamcFileResult Gleamc_fs_append(GleamcString path, GleamcBitArray data);
GleamcFileResult Gleamc_fs_delete(GleamcString path);
GleamcFileResult Gleamc_fs_create_directory(GleamcString path);
GleamcFileResult Gleamc_fs_create_file(GleamcString path);
GleamcFileResult Gleamc_fs_rename(GleamcString path, GleamcString new_path);
GleamcFileResult Gleamc_fs_symlink(GleamcString target, GleamcString path);
GleamcFileResult Gleamc_fs_link(GleamcString target, GleamcString path);
GleamcFileResult Gleamc_fs_touch(GleamcString path);
GleamcFileResult Gleamc_fs_realpath(GleamcString path);
GleamcFileResult Gleamc_fs_chmod(GleamcString path, int64_t mode);
GleamcFileResult Gleamc_fs_exists(GleamcString path);
GleamcFileResult Gleamc_fs_is_file(GleamcString path);
GleamcFileResult Gleamc_fs_is_directory(GleamcString path);
GleamcFileResult Gleamc_fs_file_size(GleamcString path);
GleamcFileResult Gleamc_fs_current_directory(void);
GleamcFileResult Gleamc_fs_read_directory(GleamcString path);
GleamcFileResult Gleamc_fs_file_info(GleamcString path);
GleamcFileResult Gleamc_fs_link_info(GleamcString path);

/* Reads a little-endian int64 field from a packed info blob. */
int64_t Gleamc_fs_int64_at(GleamcBitArray blob, int64_t index);

/* Accessors for the fixed result struct. */
int64_t Gleamc_fs_result_code(GleamcFileResult result);
GleamcBitArray Gleamc_fs_result_data(GleamcFileResult result);
int64_t Gleamc_fs_result_size(GleamcFileResult result);

/* ------------------------------------------------------------------ */
/* std::io — print (to_string is inserted by the compiler)             */
/* ------------------------------------------------------------------ */

/* Nil is represented as `int` in generated code, so print returns 0. */
int Gleamc_io_print(GleamcString s);
int Gleamc_io_println(GleamcString s);

/* std::string */
int64_t Gleamc_string_length(GleamcString s);
GleamcString Gleamc_string_append(GleamcString a, GleamcString b);

/* `uppercase`/`lowercase` take ownership of `s` (FFI mode `Owned`, see
 * `src/gleamc/ffi_modes.gleam`): they reuse the buffer in place when uniquely
 * owned, otherwise return a fresh copy and release `s`. */
GleamcString Gleamc_string_uppercase(GleamcString s);
GleamcString Gleamc_string_lowercase(GleamcString s);
GleamcString Gleamc_string_reverse(GleamcString s);

/* Debug/inspect helpers: concatenate two strings, consuming both. */
GleamcString Gleamc_show_concat(GleamcString a, GleamcString b);
/* Renders a string with surrounding quotes and escapes (inspect form). */
GleamcString Gleamc_string_show(GleamcString value);
/* Writes an inspect string to stderr with a trailing newline (io.debug). */
int Gleamc_io_debug(GleamcString value);

/* Abort the program with a message (panic / todo / let assert). */
void Gleamc_panic(GleamcString message);

/* std::string (predicates / transforms) */
bool Gleamc_string_contains(GleamcString haystack, GleamcString needle);
bool Gleamc_string_starts_with(GleamcString value, GleamcString prefix);
bool Gleamc_string_ends_with(GleamcString value, GleamcString suffix);
GleamcString Gleamc_string_trim(GleamcString value);
GleamcString Gleamc_string_trim_start(GleamcString value);
GleamcString Gleamc_string_trim_end(GleamcString value);
GleamcString Gleamc_string_slice(GleamcString value, int64_t idx, int64_t len);
int64_t Gleamc_string_byte_size(GleamcString value);
int64_t Gleamc_string_compare_bytes(GleamcString a, GleamcString b);
int64_t Gleamc_string_raw_codepoint_at(GleamcString value, size_t index);
GleamcString Gleamc_string_raw_codepoint_to_string(int64_t codepoint);
GleamcString Gleamc_string_replace(
    GleamcString value,
    GleamcString pattern,
    GleamcString substitute
);

/* std::int */
int64_t Gleamc_int_min(int64_t a, int64_t b);
int64_t Gleamc_int_max(int64_t a, int64_t b);
int64_t Gleamc_int_absolute_value(int64_t a);
GleamcString Gleamc_int_raw_to_base_string(int64_t value, int64_t base);
double Gleamc_int_to_float(int64_t value);

/* std::float */
double Gleamc_float_min(double a, double b);
double Gleamc_float_max(double a, double b);
double Gleamc_float_absolute_value(double a);
double Gleamc_float_floor(double a);
double Gleamc_float_ceiling(double a);
int64_t Gleamc_float_round(double a);
int64_t Gleamc_float_truncate(double a);
double Gleamc_float_raw_power(double base, double exponent);
double Gleamc_float_raw_square_root(double value);
double Gleamc_float_raw_exponential(double value);
double Gleamc_float_raw_logarithm(double value);

int64_t Gleamc_int_bitwise_and(int64_t a, int64_t b);
int64_t Gleamc_int_bitwise_or(int64_t a, int64_t b);
int64_t Gleamc_int_bitwise_exclusive_or(int64_t a, int64_t b);
int64_t Gleamc_int_bitwise_not(int64_t a);
int64_t Gleamc_int_bitwise_shift_left(int64_t a, int64_t b);
int64_t Gleamc_int_bitwise_shift_right(int64_t a, int64_t b);

/* std::int / std::float / std::bool to_string */
GleamcString Gleamc_int_to_string(int64_t v);
GleamcString Gleamc_float_to_string(double v);
GleamcString Gleamc_bool_to_string(bool v);

/* ------------------------------------------------------------------ */
/* Futures + scheduler + libuv (ported from Vesper docs 09/11/14)      */
/*                                                                     */
/* A future is a refcounted heap cell. `step` is a state machine:      */
/* true = completed (the frame holds the result); false = suspended    */
/* with *fut_slot pointing at the pending future. The scheduler sleeps */
/* until the deadline or runs a libuv round until the future finishes. */
/* libuv is required; there is no synchronous fallback.                */
/* ------------------------------------------------------------------ */

typedef struct GleamcFuture {
    GleamcHdr hdr;
    int64_t deadline;   /* monotonic ms; ready when done             */
    bool done;
    bool has_error;     /* I/O: error code in error_code             */
    int32_t error_code;
    int64_t value_i;    /* wake value (scalars / handles / length)   */
    void* value_p;      /* wake value by reference (structs / bytes) */
    bool uv_armed;      /* handle registered on the libuv loop       */
} GleamcFuture;

uint64_t gleamc_now_ms(void);
void gleamc_sleep_ms(int64_t ms);
GleamcFuture* Gleamc_std_time_timer(int64_t ms);
bool gleamc_sched_run(bool (*step)(void* frame), void* frame,
                      GleamcFuture** fut_slot);

void gleamc_sched_poll(void);
void* gleamc_uv_loop(void);
void* gleamc_uv_timer_init(void* loop);
GleamcFuture* gleamc_uv_timer_start(void* timer, int64_t ms);
GleamcFuture* gleamc_uv_fs_open(void* loop, const char* path,
                                int32_t flags, int32_t mode);
GleamcFuture* gleamc_uv_fs_read(void* loop, void* fd, int64_t n);
GleamcFuture* gleamc_uv_fs_fstat(void* loop, void* fd);
GleamcFuture* gleamc_uv_fs_close(void* loop, void* fd);

void gleamc_task_spawn(bool (*step)(void*), void* frame,
                       GleamcFuture** fut_slot);
int32_t gleamc_tasks_drain(void);

#endif /* GLEAMC_RUNTIME_H */
