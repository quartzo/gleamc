#include "gleam_runtime.h"

typedef struct List_tString_FfiSig List_tString_FfiSig;
typedef struct List_Int List_Int;
typedef struct List_ParamMode List_ParamMode;
typedef struct {
    List_ParamMode* _0;
    int64_t _1;
} GleamcTuple_List_ParamMode_i64;

typedef enum {
    TAG_ParamMode_Borrow_ParamMode,
    TAG_ParamMode_Owned_ParamMode
} ParamMode_Tag;
typedef struct {
    uint8_t tag;
} ParamMode;

typedef enum {
    TAG_ReturnMode_OwnedResult_ReturnMode,
    TAG_ReturnMode_BorrowedResult_ReturnMode
} ReturnMode_Tag;
typedef struct {
    uint8_t tag;
} ReturnMode;

typedef enum {
    TAG_FfiSig_FfiSig_FfiSig
} FfiSig_Tag;
typedef struct {
    uint8_t tag;
    union {
        struct {
        List_ParamMode* _0;
        ReturnMode _1;
        } FfiSig;
    } payload;
} FfiSig;

typedef struct {
    GleamcString _0;
    FfiSig _1;
} GleamcTuple_str_FfiSig;

typedef enum {
    TAG_Dict_String_FfiSig_Dict_Dict_String_FfiSig
} Dict_String_FfiSig_Tag;
typedef struct {
    uint8_t tag;
    union {
        struct {
        List_tString_FfiSig* _0;
        } Dict;
    } payload;
} Dict_String_FfiSig;

typedef enum {
    TAG_List_tString_FfiSig_ListCons_List_tString_FfiSig,
    TAG_List_tString_FfiSig_ListEmpty_List_tString_FfiSig
} List_tString_FfiSig_Tag;
struct List_tString_FfiSig {
    uint8_t tag;
    union {
        struct {
        GleamcTuple_str_FfiSig _0;
        List_tString_FfiSig* _1;
        } ListCons;
    } payload;
};

typedef enum {
    TAG_List_Int_ListCons_List_Int,
    TAG_List_Int_ListEmpty_List_Int
} List_Int_Tag;
struct List_Int {
    uint8_t tag;
    union {
        struct {
        int64_t _0;
        List_Int* _1;
        } ListCons;
    } payload;
};

typedef enum {
    TAG_List_ParamMode_ListCons_List_ParamMode,
    TAG_List_ParamMode_ListEmpty_List_ParamMode
} List_ParamMode_Tag;
struct List_ParamMode {
    uint8_t tag;
    union {
        struct {
        ParamMode _0;
        List_ParamMode* _1;
        } ListCons;
    } payload;
};

typedef enum {
    TAG_Order_Lt_Order,
    TAG_Order_Eq_Order,
    TAG_Order_Gt_Order
} Order_Tag;
typedef struct {
    uint8_t tag;
} Order;

typedef struct {
    Order _0;
    Order _1;
} GleamcTuple_Order_Order;

typedef struct {
    Order (*code)(void*);
    void* env;
    void (*env_drop)(void*);
} GleamFn_fn__Order;

void Gleamc_Rc_retain_FfiSig(FfiSig v);
void Gleamc_Rc_drop_FfiSig(FfiSig v);
void Gleamc_Rc_retain_tuple_str_FfiSig(GleamcTuple_str_FfiSig v);
void Gleamc_Rc_drop_tuple_str_FfiSig(GleamcTuple_str_FfiSig v);
void Gleamc_Rc_retain_List_tString_FfiSig(List_tString_FfiSig* v);
void Gleamc_Rc_drop_List_tString_FfiSig(List_tString_FfiSig* v);
void Gleamc_Rc_retain_tuple_List_ParamMode_i64(GleamcTuple_List_ParamMode_i64 v);
void Gleamc_Rc_drop_tuple_List_ParamMode_i64(GleamcTuple_List_ParamMode_i64 v);
void Gleamc_Rc_retain_List_ParamMode(List_ParamMode* v);
void Gleamc_Rc_drop_List_ParamMode(List_ParamMode* v);
void Gleamc_Rc_retain_List_Int(List_Int* v);
void Gleamc_Rc_drop_List_Int(List_Int* v);
void Gleamc_Rc_retain_Dict_String_FfiSig(Dict_String_FfiSig v);
void Gleamc_Rc_drop_Dict_String_FfiSig(Dict_String_FfiSig v);

static const struct { GleamcHdr hdr; char bytes[6]; } __gl_lit_723980658 = { { GLEAMC_RC_STATIC }, "panic" };
static const struct { GleamcHdr hdr; char bytes[11]; } __gl_lit_884453714 = { { GLEAMC_RC_STATIC }, "io.println" };
static const struct { GleamcHdr hdr; char bytes[9]; } __gl_lit_948470576 = { { GLEAMC_RC_STATIC }, "io.print" };
static const struct { GleamcHdr hdr; char bytes[14]; } __gl_lit_848383664 = { { GLEAMC_RC_STATIC }, "int.to_string" };
static const struct { GleamcHdr hdr; char bytes[16]; } __gl_lit_462172078 = { { GLEAMC_RC_STATIC }, "float.to_string" };
static const struct { GleamcHdr hdr; char bytes[15]; } __gl_lit_921175492 = { { GLEAMC_RC_STATIC }, "bool.to_string" };
static const struct { GleamcHdr hdr; char bytes[8]; } __gl_lit_888425143 = { { GLEAMC_RC_STATIC }, "int.min" };
static const struct { GleamcHdr hdr; char bytes[8]; } __gl_lit_888424889 = { { GLEAMC_RC_STATIC }, "int.max" };
static const struct { GleamcHdr hdr; char bytes[19]; } __gl_lit_771404131 = { { GLEAMC_RC_STATIC }, "int.absolute_value" };
static const struct { GleamcHdr hdr; char bytes[10]; } __gl_lit_577012292 = { { GLEAMC_RC_STATIC }, "float.min" };
static const struct { GleamcHdr hdr; char bytes[10]; } __gl_lit_577012038 = { { GLEAMC_RC_STATIC }, "float.max" };
static const struct { GleamcHdr hdr; char bytes[21]; } __gl_lit_677942627 = { { GLEAMC_RC_STATIC }, "float.absolute_value" };
static const struct { GleamcHdr hdr; char bytes[12]; } __gl_lit_358192822 = { { GLEAMC_RC_STATIC }, "float.floor" };
static const struct { GleamcHdr hdr; char bytes[14]; } __gl_lit_916399400 = { { GLEAMC_RC_STATIC }, "float.ceiling" };
static const struct { GleamcHdr hdr; char bytes[12]; } __gl_lit_372538172 = { { GLEAMC_RC_STATIC }, "float.round" };
static const struct { GleamcHdr hdr; char bytes[15]; } __gl_lit_15556311 = { { GLEAMC_RC_STATIC }, "float.truncate" };
static const struct { GleamcHdr hdr; char bytes[16]; } __gl_lit_194444432 = { { GLEAMC_RC_STATIC }, "float.raw_power" };
static const struct { GleamcHdr hdr; char bytes[22]; } __gl_lit_590922797 = { { GLEAMC_RC_STATIC }, "float.raw_square_root" };
static const struct { GleamcHdr hdr; char bytes[22]; } __gl_lit_802992126 = { { GLEAMC_RC_STATIC }, "float.raw_exponential" };
static const struct { GleamcHdr hdr; char bytes[20]; } __gl_lit_283068439 = { { GLEAMC_RC_STATIC }, "float.raw_logarithm" };
static const struct { GleamcHdr hdr; char bytes[16]; } __gl_lit_325809388 = { { GLEAMC_RC_STATIC }, "int.bitwise_and" };
static const struct { GleamcHdr hdr; char bytes[15]; } __gl_lit_555328024 = { { GLEAMC_RC_STATIC }, "int.bitwise_or" };
static const struct { GleamcHdr hdr; char bytes[25]; } __gl_lit_932664061 = { { GLEAMC_RC_STATIC }, "int.bitwise_exclusive_or" };
static const struct { GleamcHdr hdr; char bytes[16]; } __gl_lit_325823594 = { { GLEAMC_RC_STATIC }, "int.bitwise_not" };
static const struct { GleamcHdr hdr; char bytes[23]; } __gl_lit_390891949 = { { GLEAMC_RC_STATIC }, "int.bitwise_shift_left" };
static const struct { GleamcHdr hdr; char bytes[24]; } __gl_lit_906694316 = { { GLEAMC_RC_STATIC }, "int.bitwise_shift_right" };
static const struct { GleamcHdr hdr; char bytes[23]; } __gl_lit_844955336 = { { GLEAMC_RC_STATIC }, "int.raw_to_base_string" };
static const struct { GleamcHdr hdr; char bytes[13]; } __gl_lit_494849087 = { { GLEAMC_RC_STATIC }, "int.to_float" };
static const struct { GleamcHdr hdr; char bytes[21]; } __gl_lit_776327688 = { { GLEAMC_RC_STATIC }, "string.compare_bytes" };
static const struct { GleamcHdr hdr; char bytes[24]; } __gl_lit_883650838 = { { GLEAMC_RC_STATIC }, "string.raw_codepoint_at" };
static const struct { GleamcHdr hdr; char bytes[31]; } __gl_lit_265660841 = { { GLEAMC_RC_STATIC }, "string.raw_codepoint_to_string" };
static const struct { GleamcHdr hdr; char bytes[16]; } __gl_lit_317771550 = { { GLEAMC_RC_STATIC }, "string.contains" };
static const struct { GleamcHdr hdr; char bytes[19]; } __gl_lit_132115984 = { { GLEAMC_RC_STATIC }, "string.starts_with" };
static const struct { GleamcHdr hdr; char bytes[17]; } __gl_lit_729546171 = { { GLEAMC_RC_STATIC }, "string.ends_with" };
static const struct { GleamcHdr hdr; char bytes[12]; } __gl_lit_489028782 = { { GLEAMC_RC_STATIC }, "string.trim" };
static const struct { GleamcHdr hdr; char bytes[18]; } __gl_lit_309650162 = { { GLEAMC_RC_STATIC }, "string.trim_start" };
static const struct { GleamcHdr hdr; char bytes[16]; } __gl_lit_501646313 = { { GLEAMC_RC_STATIC }, "string.trim_end" };
static const struct { GleamcHdr hdr; char bytes[15]; } __gl_lit_143894201 = { { GLEAMC_RC_STATIC }, "string.replace" };
static const struct { GleamcHdr hdr; char bytes[17]; } __gl_lit_422038754 = { { GLEAMC_RC_STATIC }, "string.byte_size" };
static const struct { GleamcHdr hdr; char bytes[13]; } __gl_lit_136547922 = { { GLEAMC_RC_STATIC }, "string.slice" };
static const struct { GleamcHdr hdr; char bytes[14]; } __gl_lit_224016840 = { { GLEAMC_RC_STATIC }, "string.length" };
static const struct { GleamcHdr hdr; char bytes[14]; } __gl_lit_806642149 = { { GLEAMC_RC_STATIC }, "string.append" };
static const struct { GleamcHdr hdr; char bytes[17]; } __gl_lit_475690897 = { { GLEAMC_RC_STATIC }, "string.uppercase" };
static const struct { GleamcHdr hdr; char bytes[17]; } __gl_lit_220048371 = { { GLEAMC_RC_STATIC }, "string.lowercase" };
static const struct { GleamcHdr hdr; char bytes[15]; } __gl_lit_150777209 = { { GLEAMC_RC_STATIC }, "string.reverse" };
static const struct { GleamcHdr hdr; char bytes[22]; } __gl_lit_516192604 = { { GLEAMC_RC_STATIC }, "bit_array.from_string" };
static const struct { GleamcHdr hdr; char bytes[24]; } __gl_lit_805774608 = { { GLEAMC_RC_STATIC }, "bit_array.raw_to_string" };
static const struct { GleamcHdr hdr; char bytes[20]; } __gl_lit_566656839 = { { GLEAMC_RC_STATIC }, "bit_array.byte_size" };
static const struct { GleamcHdr hdr; char bytes[15]; } __gl_lit_845439464 = { { GLEAMC_RC_STATIC }, "bit_array.byte" };
static const struct { GleamcHdr hdr; char bytes[17]; } __gl_lit_633621156 = { { GLEAMC_RC_STATIC }, "bit_array.append" };
static const struct { GleamcHdr hdr; char bytes[19]; } __gl_lit_741216320 = { { GLEAMC_RC_STATIC }, "bit_array.bit_size" };
static const struct { GleamcHdr hdr; char bytes[19]; } __gl_lit_356778167 = { { GLEAMC_RC_STATIC }, "gleamc.key_compare" };
static const struct { GleamcHdr hdr; char bytes[12]; } __gl_lit_214384716 = { { GLEAMC_RC_STATIC }, "gleamc.show" };
static const struct { GleamcHdr hdr; char bytes[9]; } __gl_lit_933764938 = { { GLEAMC_RC_STATIC }, "io.debug" };
static const struct { GleamcHdr hdr; char bytes[18]; } __gl_lit_339068853 = { { GLEAMC_RC_STATIC }, "bit_array.is_utf8" };
static const struct { GleamcHdr hdr; char bytes[8]; } __gl_lit_129118482 = { { GLEAMC_RC_STATIC }, "fs.read" };
static const struct { GleamcHdr hdr; char bytes[9]; } __gl_lit_267316005 = { { GLEAMC_RC_STATIC }, "fs.write" };
static const struct { GleamcHdr hdr; char bytes[10]; } __gl_lit_958313249 = { { GLEAMC_RC_STATIC }, "fs.append" };
static const struct { GleamcHdr hdr; char bytes[10]; } __gl_lit_62530741 = { { GLEAMC_RC_STATIC }, "fs.delete" };
static const struct { GleamcHdr hdr; char bytes[20]; } __gl_lit_934029894 = { { GLEAMC_RC_STATIC }, "fs.create_directory" };
static const struct { GleamcHdr hdr; char bytes[15]; } __gl_lit_207361197 = { { GLEAMC_RC_STATIC }, "fs.create_file" };
static const struct { GleamcHdr hdr; char bytes[10]; } __gl_lit_124106082 = { { GLEAMC_RC_STATIC }, "fs.exists" };
static const struct { GleamcHdr hdr; char bytes[11]; } __gl_lit_53357054 = { { GLEAMC_RC_STATIC }, "fs.is_file" };
static const struct { GleamcHdr hdr; char bytes[16]; } __gl_lit_316285779 = { { GLEAMC_RC_STATIC }, "fs.is_directory" };
static const struct { GleamcHdr hdr; char bytes[13]; } __gl_lit_433928346 = { { GLEAMC_RC_STATIC }, "fs.file_size" };
static const struct { GleamcHdr hdr; char bytes[21]; } __gl_lit_843024696 = { { GLEAMC_RC_STATIC }, "fs.current_directory" };
static const struct { GleamcHdr hdr; char bytes[18]; } __gl_lit_44017804 = { { GLEAMC_RC_STATIC }, "fs.read_directory" };
static const struct { GleamcHdr hdr; char bytes[13]; } __gl_lit_433573771 = { { GLEAMC_RC_STATIC }, "fs.file_info" };
static const struct { GleamcHdr hdr; char bytes[13]; } __gl_lit_702972426 = { { GLEAMC_RC_STATIC }, "fs.link_info" };
static const struct { GleamcHdr hdr; char bytes[10]; } __gl_lit_610493530 = { { GLEAMC_RC_STATIC }, "fs.rename" };
static const struct { GleamcHdr hdr; char bytes[11]; } __gl_lit_219667599 = { { GLEAMC_RC_STATIC }, "fs.symlink" };
static const struct { GleamcHdr hdr; char bytes[8]; } __gl_lit_128907652 = { { GLEAMC_RC_STATIC }, "fs.link" };
static const struct { GleamcHdr hdr; char bytes[9]; } __gl_lit_263662941 = { { GLEAMC_RC_STATIC }, "fs.touch" };
static const struct { GleamcHdr hdr; char bytes[12]; } __gl_lit_331841931 = { { GLEAMC_RC_STATIC }, "fs.realpath" };
static const struct { GleamcHdr hdr; char bytes[9]; } __gl_lit_243242405 = { { GLEAMC_RC_STATIC }, "fs.chmod" };
static const struct { GleamcHdr hdr; char bytes[12]; } __gl_lit_66443176 = { { GLEAMC_RC_STATIC }, "fs.int64_at" };
static const struct { GleamcHdr hdr; char bytes[15]; } __gl_lit_877066990 = { { GLEAMC_RC_STATIC }, "fs.result_code" };
static const struct { GleamcHdr hdr; char bytes[15]; } __gl_lit_877636174 = { { GLEAMC_RC_STATIC }, "fs.result_size" };
static const struct { GleamcHdr hdr; char bytes[15]; } __gl_lit_877088205 = { { GLEAMC_RC_STATIC }, "fs.result_data" };
int Gleamc_Eq_tuple_str_FfiSig(GleamcTuple_str_FfiSig a, GleamcTuple_str_FfiSig b);
int Gleamc_Eq_tuple_List_ParamMode_i64(GleamcTuple_List_ParamMode_i64 a, GleamcTuple_List_ParamMode_i64 b);
int Gleamc_Eq_tuple_Order_Order(GleamcTuple_Order_Order a, GleamcTuple_Order_Order b);
int Gleamc_Eq_Order(Order a, Order b);
int Gleamc_Eq_List_ParamMode(List_ParamMode* a, List_ParamMode* b);
int Gleamc_Eq_List_Int(List_Int* a, List_Int* b);
int Gleamc_Eq_List_tString_FfiSig(List_tString_FfiSig* a, List_tString_FfiSig* b);
int Gleamc_Eq_Dict_String_FfiSig(Dict_String_FfiSig a, Dict_String_FfiSig b);
int Gleamc_Eq_FfiSig(FfiSig a, FfiSig b);
int Gleamc_Eq_ReturnMode(ReturnMode a, ReturnMode b);
int Gleamc_Eq_ParamMode(ParamMode a, ParamMode b);
int Gleamc_Cmp_str(GleamcString a, GleamcString b);

void Gleamc_Rc_retain_FfiSig(FfiSig v) {
    switch (v.tag) {
    case TAG_FfiSig_FfiSig_FfiSig:
        Gleamc_Rc_retain_List_ParamMode(v.payload.FfiSig._0);
        break;
    }
}

void Gleamc_Rc_drop_FfiSig(FfiSig v) {
    switch (v.tag) {
    case TAG_FfiSig_FfiSig_FfiSig:
        Gleamc_Rc_drop_List_ParamMode(v.payload.FfiSig._0);
        break;
    }
}

void Gleamc_Rc_retain_tuple_str_FfiSig(GleamcTuple_str_FfiSig v) {
    gleamc_string_retain(v._0);
    Gleamc_Rc_retain_FfiSig(v._1);
}

void Gleamc_Rc_drop_tuple_str_FfiSig(GleamcTuple_str_FfiSig v) {
    gleamc_string_release(v._0);
    Gleamc_Rc_drop_FfiSig(v._1);
}

void Gleamc_Rc_retain_List_tString_FfiSig(List_tString_FfiSig* v) {
    gleamc_retain(v);
}

void Gleamc_Rc_drop_List_tString_FfiSig(List_tString_FfiSig* v) {
    if (v == NULL) return;
    if (((GleamcHdr*)((uint8_t*)v - sizeof(GleamcHdr)))->refcount == 1) {
        switch (v->tag) {
        case TAG_List_tString_FfiSig_ListCons_List_tString_FfiSig:
            Gleamc_Rc_drop_tuple_str_FfiSig(v->payload.ListCons._0);
            Gleamc_Rc_drop_List_tString_FfiSig(v->payload.ListCons._1);
            break;

        }
    }
    gleamc_release(v);
}

void Gleamc_Rc_retain_tuple_List_ParamMode_i64(GleamcTuple_List_ParamMode_i64 v) {
    Gleamc_Rc_retain_List_ParamMode(v._0);
}

void Gleamc_Rc_drop_tuple_List_ParamMode_i64(GleamcTuple_List_ParamMode_i64 v) {
    Gleamc_Rc_drop_List_ParamMode(v._0);
}

void Gleamc_Rc_retain_List_ParamMode(List_ParamMode* v) {
    gleamc_retain(v);
}

void Gleamc_Rc_drop_List_ParamMode(List_ParamMode* v) {
    if (v == NULL) return;
    if (((GleamcHdr*)((uint8_t*)v - sizeof(GleamcHdr)))->refcount == 1) {
        switch (v->tag) {
        case TAG_List_ParamMode_ListCons_List_ParamMode:
            Gleamc_Rc_drop_List_ParamMode(v->payload.ListCons._1);
            break;

        }
    }
    gleamc_release(v);
}

void Gleamc_Rc_retain_List_Int(List_Int* v) {
    gleamc_retain(v);
}

void Gleamc_Rc_drop_List_Int(List_Int* v) {
    if (v == NULL) return;
    if (((GleamcHdr*)((uint8_t*)v - sizeof(GleamcHdr)))->refcount == 1) {
        switch (v->tag) {
        case TAG_List_Int_ListCons_List_Int:
            Gleamc_Rc_drop_List_Int(v->payload.ListCons._1);
            break;

        }
    }
    gleamc_release(v);
}

void Gleamc_Rc_retain_Dict_String_FfiSig(Dict_String_FfiSig v) {
    switch (v.tag) {
    case TAG_Dict_String_FfiSig_Dict_Dict_String_FfiSig:
        Gleamc_Rc_retain_List_tString_FfiSig(v.payload.Dict._0);
        break;
    }
}

void Gleamc_Rc_drop_Dict_String_FfiSig(Dict_String_FfiSig v) {
    switch (v.tag) {
    case TAG_Dict_String_FfiSig_Dict_Dict_String_FfiSig:
        Gleamc_Rc_drop_List_tString_FfiSig(v.payload.Dict._0);
        break;
    }
}
int Gleamc_Eq_tuple_str_FfiSig(GleamcTuple_str_FfiSig a, GleamcTuple_str_FfiSig b) {
    return gleamc_string_eq(a._0, b._0) && Gleamc_Eq_FfiSig(a._1, b._1);
}

int Gleamc_Eq_tuple_List_ParamMode_i64(GleamcTuple_List_ParamMode_i64 a, GleamcTuple_List_ParamMode_i64 b) {
    return Gleamc_Eq_List_ParamMode(a._0, b._0) && (a._1 == b._1);
}

int Gleamc_Eq_tuple_Order_Order(GleamcTuple_Order_Order a, GleamcTuple_Order_Order b) {
    return Gleamc_Eq_Order(a._0, b._0) && Gleamc_Eq_Order(a._1, b._1);
}

int Gleamc_Eq_Order(Order a, Order b) {
    if (a.tag != b.tag) return 0;
    switch (a.tag) {
        case TAG_Order_Eq_Order: return 1;
        case TAG_Order_Gt_Order: return 1;
        case TAG_Order_Lt_Order: return 1;
    }
    return 1;
}

int Gleamc_Eq_List_ParamMode(List_ParamMode* a, List_ParamMode* b) {
    if (a == b) return 1;
    if (a == NULL || b == NULL) return 0;
    if (a->tag != b->tag) return 0;
    switch (a->tag) {
        case TAG_List_ParamMode_ListCons_List_ParamMode: return Gleamc_Eq_ParamMode(a->payload.ListCons._0, b->payload.ListCons._0) && Gleamc_Eq_List_ParamMode(a->payload.ListCons._1, b->payload.ListCons._1);
        case TAG_List_ParamMode_ListEmpty_List_ParamMode: return 1;
    }
    return 1;
}

int Gleamc_Eq_List_Int(List_Int* a, List_Int* b) {
    if (a == b) return 1;
    if (a == NULL || b == NULL) return 0;
    if (a->tag != b->tag) return 0;
    switch (a->tag) {
        case TAG_List_Int_ListCons_List_Int: return (a->payload.ListCons._0 == b->payload.ListCons._0) && Gleamc_Eq_List_Int(a->payload.ListCons._1, b->payload.ListCons._1);
        case TAG_List_Int_ListEmpty_List_Int: return 1;
    }
    return 1;
}

int Gleamc_Eq_List_tString_FfiSig(List_tString_FfiSig* a, List_tString_FfiSig* b) {
    if (a == b) return 1;
    if (a == NULL || b == NULL) return 0;
    if (a->tag != b->tag) return 0;
    switch (a->tag) {
        case TAG_List_tString_FfiSig_ListCons_List_tString_FfiSig: return Gleamc_Eq_tuple_str_FfiSig(a->payload.ListCons._0, b->payload.ListCons._0) && Gleamc_Eq_List_tString_FfiSig(a->payload.ListCons._1, b->payload.ListCons._1);
        case TAG_List_tString_FfiSig_ListEmpty_List_tString_FfiSig: return 1;
    }
    return 1;
}

int Gleamc_Eq_Dict_String_FfiSig(Dict_String_FfiSig a, Dict_String_FfiSig b) {
    if (a.tag != b.tag) return 0;
    switch (a.tag) {
        case TAG_Dict_String_FfiSig_Dict_Dict_String_FfiSig: return Gleamc_Eq_List_tString_FfiSig(a.payload.Dict._0, b.payload.Dict._0);
    }
    return 1;
}

int Gleamc_Eq_FfiSig(FfiSig a, FfiSig b) {
    if (a.tag != b.tag) return 0;
    switch (a.tag) {
        case TAG_FfiSig_FfiSig_FfiSig: return Gleamc_Eq_List_ParamMode(a.payload.FfiSig._0, b.payload.FfiSig._0) && Gleamc_Eq_ReturnMode(a.payload.FfiSig._1, b.payload.FfiSig._1);
    }
    return 1;
}

int Gleamc_Eq_ReturnMode(ReturnMode a, ReturnMode b) {
    if (a.tag != b.tag) return 0;
    switch (a.tag) {
        case TAG_ReturnMode_BorrowedResult_ReturnMode: return 1;
        case TAG_ReturnMode_OwnedResult_ReturnMode: return 1;
    }
    return 1;
}

int Gleamc_Eq_ParamMode(ParamMode a, ParamMode b) {
    if (a.tag != b.tag) return 0;
    switch (a.tag) {
        case TAG_ParamMode_Borrow_ParamMode: return 1;
        case TAG_ParamMode_Owned_ParamMode: return 1;
    }
    return 1;
}
int Gleamc_Cmp_str(GleamcString a, GleamcString b) { return (int)Gleamc_string_compare_bytes(a, b); }
int64_t Gleamc_order_to_int(Order);
Order Gleamc_order_compare(Order, Order);
Order Gleamc_order_negate(Order);
Order Gleamc_order_lazy_break_tie(Order, GleamFn_fn__Order);
Dict_String_FfiSig Gleamc_table();
int64_t Gleamc_list_sum(List_Int*);
Order Gleamc_order_break_tie(Order, Order);
ParamMode Gleamc_mode_at(List_ParamMode*, int64_t);
Dict_String_FfiSig Gleamc_dict_insert_String_FfiSig(Dict_String_FfiSig, GleamcString, FfiSig);
Dict_String_FfiSig Gleamc_dict_new_String_FfiSig();
List_tString_FfiSig* Gleamc_dict_entries_of_String_FfiSig(Dict_String_FfiSig);
List_tString_FfiSig* Gleamc_dict_insert_entries_String_FfiSig(List_tString_FfiSig*, GleamcString, FfiSig);
Order Gleamc_dict_key_order_String(GleamcString, GleamcString);
int64_t Gleamc_order_to_int(Order order) {
    int64_t res__0;
    bool tagis__9;
    int64_t unop__11;
    bool tagis__12;
    bool tagis__14;
entry:

    goto arm_test_b3;
arm_test_b3:
    tagis__9 = (order.tag == TAG_Order_Lt_Order);
    if (tagis__9) { goto ctor_ok_b10; } else { goto arm_test_b5; }
ctor_ok_b10:

    goto arm_body_b4;
arm_body_b4:
    unop__11 = (-1);
    res__0 = unop__11;
    goto case_end_b1;
arm_test_b5:
    tagis__12 = (order.tag == TAG_Order_Eq_Order);
    if (tagis__12) { goto ctor_ok_b13; } else { goto arm_test_b7; }
ctor_ok_b13:

    goto arm_body_b6;
arm_body_b6:
    res__0 = 0;
    goto case_end_b1;
arm_test_b7:
    tagis__14 = (order.tag == TAG_Order_Gt_Order);
    if (tagis__14) { goto ctor_ok_b15; } else { goto case_fail_b2; }
ctor_ok_b15:

    goto arm_body_b8;
arm_body_b8:
    res__0 = 1;
    goto case_end_b1;
case_fail_b2:

    abort();
case_end_b1:

    return res__0;
}

Order Gleamc_order_compare(Order a, Order b) {
    GleamcTuple_Order_Order tuple__0;
    Order res__1;
    Order tget__12;
    bool tagis__14;
    Order tget__16;
    bool tagis__17;
    Order ctor__19;
    Order tget__20;
    bool tagis__22;
    Order tget__24;
    Order ctor__25;
    Order tget__26;
    Order tget__28;
    bool tagis__29;
    Order ctor__31;
    Order tget__32;
    Order tget__34;
    Order ctor__35;
entry:
    tuple__0 = (GleamcTuple_Order_Order){ ._0 = a, ._1 = b };
    goto arm_test_b4;
arm_test_b4:
    tget__12 = tuple__0._0;
    tagis__14 = (tget__12.tag == TAG_Order_Eq_Order);
    if (tagis__14) { goto ctor_ok_b15; } else { goto arm_test_b6; }
ctor_ok_b15:

    goto tuple_next_b13;
tuple_next_b13:
    tget__16 = tuple__0._1;
    tagis__17 = (tget__16.tag == TAG_Order_Eq_Order);
    if (tagis__17) { goto ctor_ok_b18; } else { goto arm_test_b6; }
ctor_ok_b18:

    goto arm_body_b5;
arm_body_b5:
    ctor__19 = (Order){ .tag = TAG_Order_Eq_Order };
    res__1 = ctor__19;
    goto case_end_b2;
arm_test_b6:
    tget__20 = tuple__0._0;
    tagis__22 = (tget__20.tag == TAG_Order_Lt_Order);
    if (tagis__22) { goto ctor_ok_b23; } else { goto arm_test_b8; }
ctor_ok_b23:

    goto tuple_next_b21;
tuple_next_b21:
    tget__24 = tuple__0._1;
    goto arm_body_b7;
arm_body_b7:
    ctor__25 = (Order){ .tag = TAG_Order_Lt_Order };
    res__1 = ctor__25;
    goto case_end_b2;
arm_test_b8:
    tget__26 = tuple__0._0;
    goto tuple_next_b27;
tuple_next_b27:
    tget__28 = tuple__0._1;
    tagis__29 = (tget__28.tag == TAG_Order_Gt_Order);
    if (tagis__29) { goto ctor_ok_b30; } else { goto arm_test_b10; }
ctor_ok_b30:

    goto arm_body_b9;
arm_body_b9:
    ctor__31 = (Order){ .tag = TAG_Order_Lt_Order };
    res__1 = ctor__31;
    goto case_end_b2;
arm_test_b10:
    tget__32 = tuple__0._0;
    goto tuple_next_b33;
tuple_next_b33:
    tget__34 = tuple__0._1;
    goto arm_body_b11;
arm_body_b11:
    ctor__35 = (Order){ .tag = TAG_Order_Gt_Order };
    res__1 = ctor__35;
    goto case_end_b2;
case_fail_b3:

    abort();
case_end_b2:

    return res__1;
}

Order Gleamc_order_negate(Order order) {
    Order res__0;
    bool tagis__9;
    Order ctor__11;
    bool tagis__12;
    Order ctor__14;
    bool tagis__15;
    Order ctor__17;
entry:

    goto arm_test_b3;
arm_test_b3:
    tagis__9 = (order.tag == TAG_Order_Lt_Order);
    if (tagis__9) { goto ctor_ok_b10; } else { goto arm_test_b5; }
ctor_ok_b10:

    goto arm_body_b4;
arm_body_b4:
    ctor__11 = (Order){ .tag = TAG_Order_Gt_Order };
    res__0 = ctor__11;
    goto case_end_b1;
arm_test_b5:
    tagis__12 = (order.tag == TAG_Order_Eq_Order);
    if (tagis__12) { goto ctor_ok_b13; } else { goto arm_test_b7; }
ctor_ok_b13:

    goto arm_body_b6;
arm_body_b6:
    ctor__14 = (Order){ .tag = TAG_Order_Eq_Order };
    res__0 = ctor__14;
    goto case_end_b1;
arm_test_b7:
    tagis__15 = (order.tag == TAG_Order_Gt_Order);
    if (tagis__15) { goto ctor_ok_b16; } else { goto case_fail_b2; }
ctor_ok_b16:

    goto arm_body_b8;
arm_body_b8:
    ctor__17 = (Order){ .tag = TAG_Order_Lt_Order };
    res__0 = ctor__17;
    goto case_end_b1;
case_fail_b2:

    abort();
case_end_b1:

    return res__0;
}

Order Gleamc_order_lazy_break_tie(Order a, GleamFn_fn__Order comparison) {
    Order res__0;
    bool tagis__9;
    Order ctor__11;
    bool tagis__12;
    Order ctor__14;
    bool tagis__15;
    Order callind__17;
entry:

    goto arm_test_b3;
arm_test_b3:
    tagis__9 = (a.tag == TAG_Order_Lt_Order);
    if (tagis__9) { goto ctor_ok_b10; } else { goto arm_test_b5; }
ctor_ok_b10:

    goto arm_body_b4;
arm_body_b4:
    ctor__11 = (Order){ .tag = TAG_Order_Lt_Order };
    res__0 = ctor__11;
    goto case_end_b1;
arm_test_b5:
    tagis__12 = (a.tag == TAG_Order_Gt_Order);
    if (tagis__12) { goto ctor_ok_b13; } else { goto arm_test_b7; }
ctor_ok_b13:

    goto arm_body_b6;
arm_body_b6:
    ctor__14 = (Order){ .tag = TAG_Order_Gt_Order };
    res__0 = ctor__14;
    goto case_end_b1;
arm_test_b7:
    tagis__15 = (a.tag == TAG_Order_Eq_Order);
    if (tagis__15) { goto ctor_ok_b16; } else { goto case_fail_b2; }
ctor_ok_b16:

    goto arm_body_b8;
arm_body_b8:
    callind__17 = comparison.code(comparison.env);
    res__0 = callind__17;
    goto case_end_b1;
case_fail_b2:

    abort();
case_end_b1:

    return res__0;
}

Dict_String_FfiSig Gleamc_table() {
    Dict_String_FfiSig call__0;
    GleamcString str__1;
    ParamMode ctor__2;
    List_ParamMode* ctor__3;
    List_ParamMode* ctor__4;
    ReturnMode ctor__5;
    FfiSig ctor__6;
    Dict_String_FfiSig call__7;
    GleamcString str__8;
    ParamMode ctor__9;
    List_ParamMode* ctor__10;
    List_ParamMode* ctor__11;
    ReturnMode ctor__12;
    FfiSig ctor__13;
    Dict_String_FfiSig call__14;
    GleamcString str__15;
    ParamMode ctor__16;
    List_ParamMode* ctor__17;
    List_ParamMode* ctor__18;
    ReturnMode ctor__19;
    FfiSig ctor__20;
    Dict_String_FfiSig call__21;
    GleamcString str__22;
    ParamMode ctor__23;
    List_ParamMode* ctor__24;
    List_ParamMode* ctor__25;
    ReturnMode ctor__26;
    FfiSig ctor__27;
    Dict_String_FfiSig call__28;
    GleamcString str__29;
    ParamMode ctor__30;
    List_ParamMode* ctor__31;
    List_ParamMode* ctor__32;
    ReturnMode ctor__33;
    FfiSig ctor__34;
    Dict_String_FfiSig call__35;
    GleamcString str__36;
    ParamMode ctor__37;
    List_ParamMode* ctor__38;
    List_ParamMode* ctor__39;
    ReturnMode ctor__40;
    FfiSig ctor__41;
    Dict_String_FfiSig call__42;
    GleamcString str__43;
    ParamMode ctor__44;
    ParamMode ctor__45;
    List_ParamMode* ctor__46;
    List_ParamMode* ctor__47;
    List_ParamMode* ctor__48;
    ReturnMode ctor__49;
    FfiSig ctor__50;
    Dict_String_FfiSig call__51;
    GleamcString str__52;
    ParamMode ctor__53;
    ParamMode ctor__54;
    List_ParamMode* ctor__55;
    List_ParamMode* ctor__56;
    List_ParamMode* ctor__57;
    ReturnMode ctor__58;
    FfiSig ctor__59;
    Dict_String_FfiSig call__60;
    GleamcString str__61;
    ParamMode ctor__62;
    List_ParamMode* ctor__63;
    List_ParamMode* ctor__64;
    ReturnMode ctor__65;
    FfiSig ctor__66;
    Dict_String_FfiSig call__67;
    GleamcString str__68;
    ParamMode ctor__69;
    ParamMode ctor__70;
    List_ParamMode* ctor__71;
    List_ParamMode* ctor__72;
    List_ParamMode* ctor__73;
    ReturnMode ctor__74;
    FfiSig ctor__75;
    Dict_String_FfiSig call__76;
    GleamcString str__77;
    ParamMode ctor__78;
    ParamMode ctor__79;
    List_ParamMode* ctor__80;
    List_ParamMode* ctor__81;
    List_ParamMode* ctor__82;
    ReturnMode ctor__83;
    FfiSig ctor__84;
    Dict_String_FfiSig call__85;
    GleamcString str__86;
    ParamMode ctor__87;
    List_ParamMode* ctor__88;
    List_ParamMode* ctor__89;
    ReturnMode ctor__90;
    FfiSig ctor__91;
    Dict_String_FfiSig call__92;
    GleamcString str__93;
    ParamMode ctor__94;
    List_ParamMode* ctor__95;
    List_ParamMode* ctor__96;
    ReturnMode ctor__97;
    FfiSig ctor__98;
    Dict_String_FfiSig call__99;
    GleamcString str__100;
    ParamMode ctor__101;
    List_ParamMode* ctor__102;
    List_ParamMode* ctor__103;
    ReturnMode ctor__104;
    FfiSig ctor__105;
    Dict_String_FfiSig call__106;
    GleamcString str__107;
    ParamMode ctor__108;
    List_ParamMode* ctor__109;
    List_ParamMode* ctor__110;
    ReturnMode ctor__111;
    FfiSig ctor__112;
    Dict_String_FfiSig call__113;
    GleamcString str__114;
    ParamMode ctor__115;
    List_ParamMode* ctor__116;
    List_ParamMode* ctor__117;
    ReturnMode ctor__118;
    FfiSig ctor__119;
    Dict_String_FfiSig call__120;
    GleamcString str__121;
    ParamMode ctor__122;
    ParamMode ctor__123;
    List_ParamMode* ctor__124;
    List_ParamMode* ctor__125;
    List_ParamMode* ctor__126;
    ReturnMode ctor__127;
    FfiSig ctor__128;
    Dict_String_FfiSig call__129;
    GleamcString str__130;
    ParamMode ctor__131;
    List_ParamMode* ctor__132;
    List_ParamMode* ctor__133;
    ReturnMode ctor__134;
    FfiSig ctor__135;
    Dict_String_FfiSig call__136;
    GleamcString str__137;
    ParamMode ctor__138;
    List_ParamMode* ctor__139;
    List_ParamMode* ctor__140;
    ReturnMode ctor__141;
    FfiSig ctor__142;
    Dict_String_FfiSig call__143;
    GleamcString str__144;
    ParamMode ctor__145;
    List_ParamMode* ctor__146;
    List_ParamMode* ctor__147;
    ReturnMode ctor__148;
    FfiSig ctor__149;
    Dict_String_FfiSig call__150;
    GleamcString str__151;
    ParamMode ctor__152;
    ParamMode ctor__153;
    List_ParamMode* ctor__154;
    List_ParamMode* ctor__155;
    List_ParamMode* ctor__156;
    ReturnMode ctor__157;
    FfiSig ctor__158;
    Dict_String_FfiSig call__159;
    GleamcString str__160;
    ParamMode ctor__161;
    ParamMode ctor__162;
    List_ParamMode* ctor__163;
    List_ParamMode* ctor__164;
    List_ParamMode* ctor__165;
    ReturnMode ctor__166;
    FfiSig ctor__167;
    Dict_String_FfiSig call__168;
    GleamcString str__169;
    ParamMode ctor__170;
    ParamMode ctor__171;
    List_ParamMode* ctor__172;
    List_ParamMode* ctor__173;
    List_ParamMode* ctor__174;
    ReturnMode ctor__175;
    FfiSig ctor__176;
    Dict_String_FfiSig call__177;
    GleamcString str__178;
    ParamMode ctor__179;
    List_ParamMode* ctor__180;
    List_ParamMode* ctor__181;
    ReturnMode ctor__182;
    FfiSig ctor__183;
    Dict_String_FfiSig call__184;
    GleamcString str__185;
    ParamMode ctor__186;
    ParamMode ctor__187;
    List_ParamMode* ctor__188;
    List_ParamMode* ctor__189;
    List_ParamMode* ctor__190;
    ReturnMode ctor__191;
    FfiSig ctor__192;
    Dict_String_FfiSig call__193;
    GleamcString str__194;
    ParamMode ctor__195;
    ParamMode ctor__196;
    List_ParamMode* ctor__197;
    List_ParamMode* ctor__198;
    List_ParamMode* ctor__199;
    ReturnMode ctor__200;
    FfiSig ctor__201;
    Dict_String_FfiSig call__202;
    GleamcString str__203;
    ParamMode ctor__204;
    ParamMode ctor__205;
    List_ParamMode* ctor__206;
    List_ParamMode* ctor__207;
    List_ParamMode* ctor__208;
    ReturnMode ctor__209;
    FfiSig ctor__210;
    Dict_String_FfiSig call__211;
    GleamcString str__212;
    ParamMode ctor__213;
    List_ParamMode* ctor__214;
    List_ParamMode* ctor__215;
    ReturnMode ctor__216;
    FfiSig ctor__217;
    Dict_String_FfiSig call__218;
    GleamcString str__219;
    ParamMode ctor__220;
    ParamMode ctor__221;
    List_ParamMode* ctor__222;
    List_ParamMode* ctor__223;
    List_ParamMode* ctor__224;
    ReturnMode ctor__225;
    FfiSig ctor__226;
    Dict_String_FfiSig call__227;
    GleamcString str__228;
    ParamMode ctor__229;
    ParamMode ctor__230;
    List_ParamMode* ctor__231;
    List_ParamMode* ctor__232;
    List_ParamMode* ctor__233;
    ReturnMode ctor__234;
    FfiSig ctor__235;
    Dict_String_FfiSig call__236;
    GleamcString str__237;
    ParamMode ctor__238;
    List_ParamMode* ctor__239;
    List_ParamMode* ctor__240;
    ReturnMode ctor__241;
    FfiSig ctor__242;
    Dict_String_FfiSig call__243;
    GleamcString str__244;
    ParamMode ctor__245;
    ParamMode ctor__246;
    List_ParamMode* ctor__247;
    List_ParamMode* ctor__248;
    List_ParamMode* ctor__249;
    ReturnMode ctor__250;
    FfiSig ctor__251;
    Dict_String_FfiSig call__252;
    GleamcString str__253;
    ParamMode ctor__254;
    ParamMode ctor__255;
    List_ParamMode* ctor__256;
    List_ParamMode* ctor__257;
    List_ParamMode* ctor__258;
    ReturnMode ctor__259;
    FfiSig ctor__260;
    Dict_String_FfiSig call__261;
    GleamcString str__262;
    ParamMode ctor__263;
    ParamMode ctor__264;
    List_ParamMode* ctor__265;
    List_ParamMode* ctor__266;
    List_ParamMode* ctor__267;
    ReturnMode ctor__268;
    FfiSig ctor__269;
    Dict_String_FfiSig call__270;
    GleamcString str__271;
    ParamMode ctor__272;
    List_ParamMode* ctor__273;
    List_ParamMode* ctor__274;
    ReturnMode ctor__275;
    FfiSig ctor__276;
    Dict_String_FfiSig call__277;
    GleamcString str__278;
    ParamMode ctor__279;
    List_ParamMode* ctor__280;
    List_ParamMode* ctor__281;
    ReturnMode ctor__282;
    FfiSig ctor__283;
    Dict_String_FfiSig call__284;
    GleamcString str__285;
    ParamMode ctor__286;
    List_ParamMode* ctor__287;
    List_ParamMode* ctor__288;
    ReturnMode ctor__289;
    FfiSig ctor__290;
    Dict_String_FfiSig call__291;
    GleamcString str__292;
    ParamMode ctor__293;
    ParamMode ctor__294;
    ParamMode ctor__295;
    List_ParamMode* ctor__296;
    List_ParamMode* ctor__297;
    List_ParamMode* ctor__298;
    List_ParamMode* ctor__299;
    ReturnMode ctor__300;
    FfiSig ctor__301;
    Dict_String_FfiSig call__302;
    GleamcString str__303;
    ParamMode ctor__304;
    List_ParamMode* ctor__305;
    List_ParamMode* ctor__306;
    ReturnMode ctor__307;
    FfiSig ctor__308;
    Dict_String_FfiSig call__309;
    GleamcString str__310;
    ParamMode ctor__311;
    ParamMode ctor__312;
    ParamMode ctor__313;
    List_ParamMode* ctor__314;
    List_ParamMode* ctor__315;
    List_ParamMode* ctor__316;
    List_ParamMode* ctor__317;
    ReturnMode ctor__318;
    FfiSig ctor__319;
    Dict_String_FfiSig call__320;
    GleamcString str__321;
    ParamMode ctor__322;
    List_ParamMode* ctor__323;
    List_ParamMode* ctor__324;
    ReturnMode ctor__325;
    FfiSig ctor__326;
    Dict_String_FfiSig call__327;
    GleamcString str__328;
    ParamMode ctor__329;
    ParamMode ctor__330;
    List_ParamMode* ctor__331;
    List_ParamMode* ctor__332;
    List_ParamMode* ctor__333;
    ReturnMode ctor__334;
    FfiSig ctor__335;
    Dict_String_FfiSig call__336;
    GleamcString str__337;
    ParamMode ctor__338;
    List_ParamMode* ctor__339;
    List_ParamMode* ctor__340;
    ReturnMode ctor__341;
    FfiSig ctor__342;
    Dict_String_FfiSig call__343;
    GleamcString str__344;
    ParamMode ctor__345;
    List_ParamMode* ctor__346;
    List_ParamMode* ctor__347;
    ReturnMode ctor__348;
    FfiSig ctor__349;
    Dict_String_FfiSig call__350;
    GleamcString str__351;
    ParamMode ctor__352;
    List_ParamMode* ctor__353;
    List_ParamMode* ctor__354;
    ReturnMode ctor__355;
    FfiSig ctor__356;
    Dict_String_FfiSig call__357;
    GleamcString str__358;
    ParamMode ctor__359;
    List_ParamMode* ctor__360;
    List_ParamMode* ctor__361;
    ReturnMode ctor__362;
    FfiSig ctor__363;
    Dict_String_FfiSig call__364;
    GleamcString str__365;
    ParamMode ctor__366;
    List_ParamMode* ctor__367;
    List_ParamMode* ctor__368;
    ReturnMode ctor__369;
    FfiSig ctor__370;
    Dict_String_FfiSig call__371;
    GleamcString str__372;
    ParamMode ctor__373;
    List_ParamMode* ctor__374;
    List_ParamMode* ctor__375;
    ReturnMode ctor__376;
    FfiSig ctor__377;
    Dict_String_FfiSig call__378;
    GleamcString str__379;
    ParamMode ctor__380;
    ParamMode ctor__381;
    List_ParamMode* ctor__382;
    List_ParamMode* ctor__383;
    List_ParamMode* ctor__384;
    ReturnMode ctor__385;
    FfiSig ctor__386;
    Dict_String_FfiSig call__387;
    GleamcString str__388;
    ParamMode ctor__389;
    ParamMode ctor__390;
    List_ParamMode* ctor__391;
    List_ParamMode* ctor__392;
    List_ParamMode* ctor__393;
    ReturnMode ctor__394;
    FfiSig ctor__395;
    Dict_String_FfiSig call__396;
    GleamcString str__397;
    ParamMode ctor__398;
    List_ParamMode* ctor__399;
    List_ParamMode* ctor__400;
    ReturnMode ctor__401;
    FfiSig ctor__402;
    Dict_String_FfiSig call__403;
    GleamcString str__404;
    ParamMode ctor__405;
    ParamMode ctor__406;
    List_ParamMode* ctor__407;
    List_ParamMode* ctor__408;
    List_ParamMode* ctor__409;
    ReturnMode ctor__410;
    FfiSig ctor__411;
    Dict_String_FfiSig call__412;
    GleamcString str__413;
    ParamMode ctor__414;
    List_ParamMode* ctor__415;
    List_ParamMode* ctor__416;
    ReturnMode ctor__417;
    FfiSig ctor__418;
    Dict_String_FfiSig call__419;
    GleamcString str__420;
    ParamMode ctor__421;
    List_ParamMode* ctor__422;
    List_ParamMode* ctor__423;
    ReturnMode ctor__424;
    FfiSig ctor__425;
    Dict_String_FfiSig call__426;
    GleamcString str__427;
    ParamMode ctor__428;
    List_ParamMode* ctor__429;
    List_ParamMode* ctor__430;
    ReturnMode ctor__431;
    FfiSig ctor__432;
    Dict_String_FfiSig call__433;
    GleamcString str__434;
    ParamMode ctor__435;
    List_ParamMode* ctor__436;
    List_ParamMode* ctor__437;
    ReturnMode ctor__438;
    FfiSig ctor__439;
    Dict_String_FfiSig call__440;
    GleamcString str__441;
    ParamMode ctor__442;
    ParamMode ctor__443;
    List_ParamMode* ctor__444;
    List_ParamMode* ctor__445;
    List_ParamMode* ctor__446;
    ReturnMode ctor__447;
    FfiSig ctor__448;
    Dict_String_FfiSig call__449;
    GleamcString str__450;
    ParamMode ctor__451;
    ParamMode ctor__452;
    List_ParamMode* ctor__453;
    List_ParamMode* ctor__454;
    List_ParamMode* ctor__455;
    ReturnMode ctor__456;
    FfiSig ctor__457;
    Dict_String_FfiSig call__458;
    GleamcString str__459;
    ParamMode ctor__460;
    List_ParamMode* ctor__461;
    List_ParamMode* ctor__462;
    ReturnMode ctor__463;
    FfiSig ctor__464;
    Dict_String_FfiSig call__465;
    GleamcString str__466;
    ParamMode ctor__467;
    List_ParamMode* ctor__468;
    List_ParamMode* ctor__469;
    ReturnMode ctor__470;
    FfiSig ctor__471;
    Dict_String_FfiSig call__472;
    GleamcString str__473;
    ParamMode ctor__474;
    List_ParamMode* ctor__475;
    List_ParamMode* ctor__476;
    ReturnMode ctor__477;
    FfiSig ctor__478;
    Dict_String_FfiSig call__479;
    GleamcString str__480;
    ParamMode ctor__481;
    List_ParamMode* ctor__482;
    List_ParamMode* ctor__483;
    ReturnMode ctor__484;
    FfiSig ctor__485;
    Dict_String_FfiSig call__486;
    GleamcString str__487;
    ParamMode ctor__488;
    List_ParamMode* ctor__489;
    List_ParamMode* ctor__490;
    ReturnMode ctor__491;
    FfiSig ctor__492;
    Dict_String_FfiSig call__493;
    GleamcString str__494;
    ParamMode ctor__495;
    List_ParamMode* ctor__496;
    List_ParamMode* ctor__497;
    ReturnMode ctor__498;
    FfiSig ctor__499;
    Dict_String_FfiSig call__500;
    GleamcString str__501;
    ParamMode ctor__502;
    List_ParamMode* ctor__503;
    List_ParamMode* ctor__504;
    ReturnMode ctor__505;
    FfiSig ctor__506;
    Dict_String_FfiSig call__507;
    GleamcString str__508;
    List_ParamMode* ctor__509;
    ReturnMode ctor__510;
    FfiSig ctor__511;
    Dict_String_FfiSig call__512;
    GleamcString str__513;
    ParamMode ctor__514;
    List_ParamMode* ctor__515;
    List_ParamMode* ctor__516;
    ReturnMode ctor__517;
    FfiSig ctor__518;
    Dict_String_FfiSig call__519;
    GleamcString str__520;
    ParamMode ctor__521;
    List_ParamMode* ctor__522;
    List_ParamMode* ctor__523;
    ReturnMode ctor__524;
    FfiSig ctor__525;
    Dict_String_FfiSig call__526;
    GleamcString str__527;
    ParamMode ctor__528;
    List_ParamMode* ctor__529;
    List_ParamMode* ctor__530;
    ReturnMode ctor__531;
    FfiSig ctor__532;
    Dict_String_FfiSig call__533;
    GleamcString str__534;
    ParamMode ctor__535;
    ParamMode ctor__536;
    List_ParamMode* ctor__537;
    List_ParamMode* ctor__538;
    List_ParamMode* ctor__539;
    ReturnMode ctor__540;
    FfiSig ctor__541;
    Dict_String_FfiSig call__542;
    GleamcString str__543;
    ParamMode ctor__544;
    ParamMode ctor__545;
    List_ParamMode* ctor__546;
    List_ParamMode* ctor__547;
    List_ParamMode* ctor__548;
    ReturnMode ctor__549;
    FfiSig ctor__550;
    Dict_String_FfiSig call__551;
    GleamcString str__552;
    ParamMode ctor__553;
    ParamMode ctor__554;
    List_ParamMode* ctor__555;
    List_ParamMode* ctor__556;
    List_ParamMode* ctor__557;
    ReturnMode ctor__558;
    FfiSig ctor__559;
    Dict_String_FfiSig call__560;
    GleamcString str__561;
    ParamMode ctor__562;
    List_ParamMode* ctor__563;
    List_ParamMode* ctor__564;
    ReturnMode ctor__565;
    FfiSig ctor__566;
    Dict_String_FfiSig call__567;
    GleamcString str__568;
    ParamMode ctor__569;
    List_ParamMode* ctor__570;
    List_ParamMode* ctor__571;
    ReturnMode ctor__572;
    FfiSig ctor__573;
    Dict_String_FfiSig call__574;
    GleamcString str__575;
    ParamMode ctor__576;
    ParamMode ctor__577;
    List_ParamMode* ctor__578;
    List_ParamMode* ctor__579;
    List_ParamMode* ctor__580;
    ReturnMode ctor__581;
    FfiSig ctor__582;
    Dict_String_FfiSig call__583;
    GleamcString str__584;
    ParamMode ctor__585;
    ParamMode ctor__586;
    List_ParamMode* ctor__587;
    List_ParamMode* ctor__588;
    List_ParamMode* ctor__589;
    ReturnMode ctor__590;
    FfiSig ctor__591;
    Dict_String_FfiSig call__592;
    GleamcString str__593;
    ParamMode ctor__594;
    List_ParamMode* ctor__595;
    List_ParamMode* ctor__596;
    ReturnMode ctor__597;
    FfiSig ctor__598;
    Dict_String_FfiSig call__599;
    GleamcString str__600;
    ParamMode ctor__601;
    List_ParamMode* ctor__602;
    List_ParamMode* ctor__603;
    ReturnMode ctor__604;
    FfiSig ctor__605;
    Dict_String_FfiSig call__606;
    GleamcString str__607;
    ParamMode ctor__608;
    List_ParamMode* ctor__609;
    List_ParamMode* ctor__610;
    ReturnMode ctor__611;
    FfiSig ctor__612;
    Dict_String_FfiSig call__613;
entry:
    call__0 = Gleamc_dict_new_String_FfiSig();
    str__1 = (GleamcString){ __gl_lit_723980658.bytes, 5 };
    ctor__2 = (ParamMode){ .tag = TAG_ParamMode_Borrow_ParamMode };
    ctor__3 = ({ List_ParamMode* _node = (List_ParamMode*)gleamc_alloc(sizeof(List_ParamMode)); _node->tag = TAG_List_ParamMode_ListEmpty_List_ParamMode; _node; });
    ctor__4 = ({ List_ParamMode* _node = (List_ParamMode*)gleamc_alloc(sizeof(List_ParamMode)); _node->tag = TAG_List_ParamMode_ListCons_List_ParamMode;
        _node->payload.ListCons._0 = ctor__2;
        _node->payload.ListCons._1 = ctor__3;
     _node; });
    ctor__5 = (ReturnMode){ .tag = TAG_ReturnMode_OwnedResult_ReturnMode };
    ctor__6 = (FfiSig){ .tag = TAG_FfiSig_FfiSig_FfiSig, .payload.FfiSig = { ._0 = ctor__4, ._1 = ctor__5 } };
    call__7 = Gleamc_dict_insert_String_FfiSig(call__0, str__1, ctor__6);
    str__8 = (GleamcString){ __gl_lit_884453714.bytes, 10 };
    ctor__9 = (ParamMode){ .tag = TAG_ParamMode_Borrow_ParamMode };
    ctor__10 = ({ List_ParamMode* _node = (List_ParamMode*)gleamc_alloc(sizeof(List_ParamMode)); _node->tag = TAG_List_ParamMode_ListEmpty_List_ParamMode; _node; });
    ctor__11 = ({ List_ParamMode* _node = (List_ParamMode*)gleamc_alloc(sizeof(List_ParamMode)); _node->tag = TAG_List_ParamMode_ListCons_List_ParamMode;
        _node->payload.ListCons._0 = ctor__9;
        _node->payload.ListCons._1 = ctor__10;
     _node; });
    ctor__12 = (ReturnMode){ .tag = TAG_ReturnMode_OwnedResult_ReturnMode };
    ctor__13 = (FfiSig){ .tag = TAG_FfiSig_FfiSig_FfiSig, .payload.FfiSig = { ._0 = ctor__11, ._1 = ctor__12 } };
    call__14 = Gleamc_dict_insert_String_FfiSig(call__7, str__8, ctor__13);
    str__15 = (GleamcString){ __gl_lit_948470576.bytes, 8 };
    ctor__16 = (ParamMode){ .tag = TAG_ParamMode_Borrow_ParamMode };
    ctor__17 = ({ List_ParamMode* _node = (List_ParamMode*)gleamc_alloc(sizeof(List_ParamMode)); _node->tag = TAG_List_ParamMode_ListEmpty_List_ParamMode; _node; });
    ctor__18 = ({ List_ParamMode* _node = (List_ParamMode*)gleamc_alloc(sizeof(List_ParamMode)); _node->tag = TAG_List_ParamMode_ListCons_List_ParamMode;
        _node->payload.ListCons._0 = ctor__16;
        _node->payload.ListCons._1 = ctor__17;
     _node; });
    ctor__19 = (ReturnMode){ .tag = TAG_ReturnMode_OwnedResult_ReturnMode };
    ctor__20 = (FfiSig){ .tag = TAG_FfiSig_FfiSig_FfiSig, .payload.FfiSig = { ._0 = ctor__18, ._1 = ctor__19 } };
    call__21 = Gleamc_dict_insert_String_FfiSig(call__14, str__15, ctor__20);
    str__22 = (GleamcString){ __gl_lit_848383664.bytes, 13 };
    ctor__23 = (ParamMode){ .tag = TAG_ParamMode_Borrow_ParamMode };
    ctor__24 = ({ List_ParamMode* _node = (List_ParamMode*)gleamc_alloc(sizeof(List_ParamMode)); _node->tag = TAG_List_ParamMode_ListEmpty_List_ParamMode; _node; });
    ctor__25 = ({ List_ParamMode* _node = (List_ParamMode*)gleamc_alloc(sizeof(List_ParamMode)); _node->tag = TAG_List_ParamMode_ListCons_List_ParamMode;
        _node->payload.ListCons._0 = ctor__23;
        _node->payload.ListCons._1 = ctor__24;
     _node; });
    ctor__26 = (ReturnMode){ .tag = TAG_ReturnMode_OwnedResult_ReturnMode };
    ctor__27 = (FfiSig){ .tag = TAG_FfiSig_FfiSig_FfiSig, .payload.FfiSig = { ._0 = ctor__25, ._1 = ctor__26 } };
    call__28 = Gleamc_dict_insert_String_FfiSig(call__21, str__22, ctor__27);
    str__29 = (GleamcString){ __gl_lit_462172078.bytes, 15 };
    ctor__30 = (ParamMode){ .tag = TAG_ParamMode_Borrow_ParamMode };
    ctor__31 = ({ List_ParamMode* _node = (List_ParamMode*)gleamc_alloc(sizeof(List_ParamMode)); _node->tag = TAG_List_ParamMode_ListEmpty_List_ParamMode; _node; });
    ctor__32 = ({ List_ParamMode* _node = (List_ParamMode*)gleamc_alloc(sizeof(List_ParamMode)); _node->tag = TAG_List_ParamMode_ListCons_List_ParamMode;
        _node->payload.ListCons._0 = ctor__30;
        _node->payload.ListCons._1 = ctor__31;
     _node; });
    ctor__33 = (ReturnMode){ .tag = TAG_ReturnMode_OwnedResult_ReturnMode };
    ctor__34 = (FfiSig){ .tag = TAG_FfiSig_FfiSig_FfiSig, .payload.FfiSig = { ._0 = ctor__32, ._1 = ctor__33 } };
    call__35 = Gleamc_dict_insert_String_FfiSig(call__28, str__29, ctor__34);
    str__36 = (GleamcString){ __gl_lit_921175492.bytes, 14 };
    ctor__37 = (ParamMode){ .tag = TAG_ParamMode_Borrow_ParamMode };
    ctor__38 = ({ List_ParamMode* _node = (List_ParamMode*)gleamc_alloc(sizeof(List_ParamMode)); _node->tag = TAG_List_ParamMode_ListEmpty_List_ParamMode; _node; });
    ctor__39 = ({ List_ParamMode* _node = (List_ParamMode*)gleamc_alloc(sizeof(List_ParamMode)); _node->tag = TAG_List_ParamMode_ListCons_List_ParamMode;
        _node->payload.ListCons._0 = ctor__37;
        _node->payload.ListCons._1 = ctor__38;
     _node; });
    ctor__40 = (ReturnMode){ .tag = TAG_ReturnMode_OwnedResult_ReturnMode };
    ctor__41 = (FfiSig){ .tag = TAG_FfiSig_FfiSig_FfiSig, .payload.FfiSig = { ._0 = ctor__39, ._1 = ctor__40 } };
    call__42 = Gleamc_dict_insert_String_FfiSig(call__35, str__36, ctor__41);
    str__43 = (GleamcString){ __gl_lit_888425143.bytes, 7 };
    ctor__44 = (ParamMode){ .tag = TAG_ParamMode_Borrow_ParamMode };
    ctor__45 = (ParamMode){ .tag = TAG_ParamMode_Borrow_ParamMode };
    ctor__46 = ({ List_ParamMode* _node = (List_ParamMode*)gleamc_alloc(sizeof(List_ParamMode)); _node->tag = TAG_List_ParamMode_ListEmpty_List_ParamMode; _node; });
    ctor__47 = ({ List_ParamMode* _node = (List_ParamMode*)gleamc_alloc(sizeof(List_ParamMode)); _node->tag = TAG_List_ParamMode_ListCons_List_ParamMode;
        _node->payload.ListCons._0 = ctor__45;
        _node->payload.ListCons._1 = ctor__46;
     _node; });
    ctor__48 = ({ List_ParamMode* _node = (List_ParamMode*)gleamc_alloc(sizeof(List_ParamMode)); _node->tag = TAG_List_ParamMode_ListCons_List_ParamMode;
        _node->payload.ListCons._0 = ctor__44;
        _node->payload.ListCons._1 = ctor__47;
     _node; });
    ctor__49 = (ReturnMode){ .tag = TAG_ReturnMode_OwnedResult_ReturnMode };
    ctor__50 = (FfiSig){ .tag = TAG_FfiSig_FfiSig_FfiSig, .payload.FfiSig = { ._0 = ctor__48, ._1 = ctor__49 } };
    call__51 = Gleamc_dict_insert_String_FfiSig(call__42, str__43, ctor__50);
    str__52 = (GleamcString){ __gl_lit_888424889.bytes, 7 };
    ctor__53 = (ParamMode){ .tag = TAG_ParamMode_Borrow_ParamMode };
    ctor__54 = (ParamMode){ .tag = TAG_ParamMode_Borrow_ParamMode };
    ctor__55 = ({ List_ParamMode* _node = (List_ParamMode*)gleamc_alloc(sizeof(List_ParamMode)); _node->tag = TAG_List_ParamMode_ListEmpty_List_ParamMode; _node; });
    ctor__56 = ({ List_ParamMode* _node = (List_ParamMode*)gleamc_alloc(sizeof(List_ParamMode)); _node->tag = TAG_List_ParamMode_ListCons_List_ParamMode;
        _node->payload.ListCons._0 = ctor__54;
        _node->payload.ListCons._1 = ctor__55;
     _node; });
    ctor__57 = ({ List_ParamMode* _node = (List_ParamMode*)gleamc_alloc(sizeof(List_ParamMode)); _node->tag = TAG_List_ParamMode_ListCons_List_ParamMode;
        _node->payload.ListCons._0 = ctor__53;
        _node->payload.ListCons._1 = ctor__56;
     _node; });
    ctor__58 = (ReturnMode){ .tag = TAG_ReturnMode_OwnedResult_ReturnMode };
    ctor__59 = (FfiSig){ .tag = TAG_FfiSig_FfiSig_FfiSig, .payload.FfiSig = { ._0 = ctor__57, ._1 = ctor__58 } };
    call__60 = Gleamc_dict_insert_String_FfiSig(call__51, str__52, ctor__59);
    str__61 = (GleamcString){ __gl_lit_771404131.bytes, 18 };
    ctor__62 = (ParamMode){ .tag = TAG_ParamMode_Borrow_ParamMode };
    ctor__63 = ({ List_ParamMode* _node = (List_ParamMode*)gleamc_alloc(sizeof(List_ParamMode)); _node->tag = TAG_List_ParamMode_ListEmpty_List_ParamMode; _node; });
    ctor__64 = ({ List_ParamMode* _node = (List_ParamMode*)gleamc_alloc(sizeof(List_ParamMode)); _node->tag = TAG_List_ParamMode_ListCons_List_ParamMode;
        _node->payload.ListCons._0 = ctor__62;
        _node->payload.ListCons._1 = ctor__63;
     _node; });
    ctor__65 = (ReturnMode){ .tag = TAG_ReturnMode_OwnedResult_ReturnMode };
    ctor__66 = (FfiSig){ .tag = TAG_FfiSig_FfiSig_FfiSig, .payload.FfiSig = { ._0 = ctor__64, ._1 = ctor__65 } };
    call__67 = Gleamc_dict_insert_String_FfiSig(call__60, str__61, ctor__66);
    str__68 = (GleamcString){ __gl_lit_577012292.bytes, 9 };
    ctor__69 = (ParamMode){ .tag = TAG_ParamMode_Borrow_ParamMode };
    ctor__70 = (ParamMode){ .tag = TAG_ParamMode_Borrow_ParamMode };
    ctor__71 = ({ List_ParamMode* _node = (List_ParamMode*)gleamc_alloc(sizeof(List_ParamMode)); _node->tag = TAG_List_ParamMode_ListEmpty_List_ParamMode; _node; });
    ctor__72 = ({ List_ParamMode* _node = (List_ParamMode*)gleamc_alloc(sizeof(List_ParamMode)); _node->tag = TAG_List_ParamMode_ListCons_List_ParamMode;
        _node->payload.ListCons._0 = ctor__70;
        _node->payload.ListCons._1 = ctor__71;
     _node; });
    ctor__73 = ({ List_ParamMode* _node = (List_ParamMode*)gleamc_alloc(sizeof(List_ParamMode)); _node->tag = TAG_List_ParamMode_ListCons_List_ParamMode;
        _node->payload.ListCons._0 = ctor__69;
        _node->payload.ListCons._1 = ctor__72;
     _node; });
    ctor__74 = (ReturnMode){ .tag = TAG_ReturnMode_OwnedResult_ReturnMode };
    ctor__75 = (FfiSig){ .tag = TAG_FfiSig_FfiSig_FfiSig, .payload.FfiSig = { ._0 = ctor__73, ._1 = ctor__74 } };
    call__76 = Gleamc_dict_insert_String_FfiSig(call__67, str__68, ctor__75);
    str__77 = (GleamcString){ __gl_lit_577012038.bytes, 9 };
    ctor__78 = (ParamMode){ .tag = TAG_ParamMode_Borrow_ParamMode };
    ctor__79 = (ParamMode){ .tag = TAG_ParamMode_Borrow_ParamMode };
    ctor__80 = ({ List_ParamMode* _node = (List_ParamMode*)gleamc_alloc(sizeof(List_ParamMode)); _node->tag = TAG_List_ParamMode_ListEmpty_List_ParamMode; _node; });
    ctor__81 = ({ List_ParamMode* _node = (List_ParamMode*)gleamc_alloc(sizeof(List_ParamMode)); _node->tag = TAG_List_ParamMode_ListCons_List_ParamMode;
        _node->payload.ListCons._0 = ctor__79;
        _node->payload.ListCons._1 = ctor__80;
     _node; });
    ctor__82 = ({ List_ParamMode* _node = (List_ParamMode*)gleamc_alloc(sizeof(List_ParamMode)); _node->tag = TAG_List_ParamMode_ListCons_List_ParamMode;
        _node->payload.ListCons._0 = ctor__78;
        _node->payload.ListCons._1 = ctor__81;
     _node; });
    ctor__83 = (ReturnMode){ .tag = TAG_ReturnMode_OwnedResult_ReturnMode };
    ctor__84 = (FfiSig){ .tag = TAG_FfiSig_FfiSig_FfiSig, .payload.FfiSig = { ._0 = ctor__82, ._1 = ctor__83 } };
    call__85 = Gleamc_dict_insert_String_FfiSig(call__76, str__77, ctor__84);
    str__86 = (GleamcString){ __gl_lit_677942627.bytes, 20 };
    ctor__87 = (ParamMode){ .tag = TAG_ParamMode_Borrow_ParamMode };
    ctor__88 = ({ List_ParamMode* _node = (List_ParamMode*)gleamc_alloc(sizeof(List_ParamMode)); _node->tag = TAG_List_ParamMode_ListEmpty_List_ParamMode; _node; });
    ctor__89 = ({ List_ParamMode* _node = (List_ParamMode*)gleamc_alloc(sizeof(List_ParamMode)); _node->tag = TAG_List_ParamMode_ListCons_List_ParamMode;
        _node->payload.ListCons._0 = ctor__87;
        _node->payload.ListCons._1 = ctor__88;
     _node; });
    ctor__90 = (ReturnMode){ .tag = TAG_ReturnMode_OwnedResult_ReturnMode };
    ctor__91 = (FfiSig){ .tag = TAG_FfiSig_FfiSig_FfiSig, .payload.FfiSig = { ._0 = ctor__89, ._1 = ctor__90 } };
    call__92 = Gleamc_dict_insert_String_FfiSig(call__85, str__86, ctor__91);
    str__93 = (GleamcString){ __gl_lit_358192822.bytes, 11 };
    ctor__94 = (ParamMode){ .tag = TAG_ParamMode_Borrow_ParamMode };
    ctor__95 = ({ List_ParamMode* _node = (List_ParamMode*)gleamc_alloc(sizeof(List_ParamMode)); _node->tag = TAG_List_ParamMode_ListEmpty_List_ParamMode; _node; });
    ctor__96 = ({ List_ParamMode* _node = (List_ParamMode*)gleamc_alloc(sizeof(List_ParamMode)); _node->tag = TAG_List_ParamMode_ListCons_List_ParamMode;
        _node->payload.ListCons._0 = ctor__94;
        _node->payload.ListCons._1 = ctor__95;
     _node; });
    ctor__97 = (ReturnMode){ .tag = TAG_ReturnMode_OwnedResult_ReturnMode };
    ctor__98 = (FfiSig){ .tag = TAG_FfiSig_FfiSig_FfiSig, .payload.FfiSig = { ._0 = ctor__96, ._1 = ctor__97 } };
    call__99 = Gleamc_dict_insert_String_FfiSig(call__92, str__93, ctor__98);
    str__100 = (GleamcString){ __gl_lit_916399400.bytes, 13 };
    ctor__101 = (ParamMode){ .tag = TAG_ParamMode_Borrow_ParamMode };
    ctor__102 = ({ List_ParamMode* _node = (List_ParamMode*)gleamc_alloc(sizeof(List_ParamMode)); _node->tag = TAG_List_ParamMode_ListEmpty_List_ParamMode; _node; });
    ctor__103 = ({ List_ParamMode* _node = (List_ParamMode*)gleamc_alloc(sizeof(List_ParamMode)); _node->tag = TAG_List_ParamMode_ListCons_List_ParamMode;
        _node->payload.ListCons._0 = ctor__101;
        _node->payload.ListCons._1 = ctor__102;
     _node; });
    ctor__104 = (ReturnMode){ .tag = TAG_ReturnMode_OwnedResult_ReturnMode };
    ctor__105 = (FfiSig){ .tag = TAG_FfiSig_FfiSig_FfiSig, .payload.FfiSig = { ._0 = ctor__103, ._1 = ctor__104 } };
    call__106 = Gleamc_dict_insert_String_FfiSig(call__99, str__100, ctor__105);
    str__107 = (GleamcString){ __gl_lit_372538172.bytes, 11 };
    ctor__108 = (ParamMode){ .tag = TAG_ParamMode_Borrow_ParamMode };
    ctor__109 = ({ List_ParamMode* _node = (List_ParamMode*)gleamc_alloc(sizeof(List_ParamMode)); _node->tag = TAG_List_ParamMode_ListEmpty_List_ParamMode; _node; });
    ctor__110 = ({ List_ParamMode* _node = (List_ParamMode*)gleamc_alloc(sizeof(List_ParamMode)); _node->tag = TAG_List_ParamMode_ListCons_List_ParamMode;
        _node->payload.ListCons._0 = ctor__108;
        _node->payload.ListCons._1 = ctor__109;
     _node; });
    ctor__111 = (ReturnMode){ .tag = TAG_ReturnMode_OwnedResult_ReturnMode };
    ctor__112 = (FfiSig){ .tag = TAG_FfiSig_FfiSig_FfiSig, .payload.FfiSig = { ._0 = ctor__110, ._1 = ctor__111 } };
    call__113 = Gleamc_dict_insert_String_FfiSig(call__106, str__107, ctor__112);
    str__114 = (GleamcString){ __gl_lit_15556311.bytes, 14 };
    ctor__115 = (ParamMode){ .tag = TAG_ParamMode_Borrow_ParamMode };
    ctor__116 = ({ List_ParamMode* _node = (List_ParamMode*)gleamc_alloc(sizeof(List_ParamMode)); _node->tag = TAG_List_ParamMode_ListEmpty_List_ParamMode; _node; });
    ctor__117 = ({ List_ParamMode* _node = (List_ParamMode*)gleamc_alloc(sizeof(List_ParamMode)); _node->tag = TAG_List_ParamMode_ListCons_List_ParamMode;
        _node->payload.ListCons._0 = ctor__115;
        _node->payload.ListCons._1 = ctor__116;
     _node; });
    ctor__118 = (ReturnMode){ .tag = TAG_ReturnMode_OwnedResult_ReturnMode };
    ctor__119 = (FfiSig){ .tag = TAG_FfiSig_FfiSig_FfiSig, .payload.FfiSig = { ._0 = ctor__117, ._1 = ctor__118 } };
    call__120 = Gleamc_dict_insert_String_FfiSig(call__113, str__114, ctor__119);
    str__121 = (GleamcString){ __gl_lit_194444432.bytes, 15 };
    ctor__122 = (ParamMode){ .tag = TAG_ParamMode_Borrow_ParamMode };
    ctor__123 = (ParamMode){ .tag = TAG_ParamMode_Borrow_ParamMode };
    ctor__124 = ({ List_ParamMode* _node = (List_ParamMode*)gleamc_alloc(sizeof(List_ParamMode)); _node->tag = TAG_List_ParamMode_ListEmpty_List_ParamMode; _node; });
    ctor__125 = ({ List_ParamMode* _node = (List_ParamMode*)gleamc_alloc(sizeof(List_ParamMode)); _node->tag = TAG_List_ParamMode_ListCons_List_ParamMode;
        _node->payload.ListCons._0 = ctor__123;
        _node->payload.ListCons._1 = ctor__124;
     _node; });
    ctor__126 = ({ List_ParamMode* _node = (List_ParamMode*)gleamc_alloc(sizeof(List_ParamMode)); _node->tag = TAG_List_ParamMode_ListCons_List_ParamMode;
        _node->payload.ListCons._0 = ctor__122;
        _node->payload.ListCons._1 = ctor__125;
     _node; });
    ctor__127 = (ReturnMode){ .tag = TAG_ReturnMode_OwnedResult_ReturnMode };
    ctor__128 = (FfiSig){ .tag = TAG_FfiSig_FfiSig_FfiSig, .payload.FfiSig = { ._0 = ctor__126, ._1 = ctor__127 } };
    call__129 = Gleamc_dict_insert_String_FfiSig(call__120, str__121, ctor__128);
    str__130 = (GleamcString){ __gl_lit_590922797.bytes, 21 };
    ctor__131 = (ParamMode){ .tag = TAG_ParamMode_Borrow_ParamMode };
    ctor__132 = ({ List_ParamMode* _node = (List_ParamMode*)gleamc_alloc(sizeof(List_ParamMode)); _node->tag = TAG_List_ParamMode_ListEmpty_List_ParamMode; _node; });
    ctor__133 = ({ List_ParamMode* _node = (List_ParamMode*)gleamc_alloc(sizeof(List_ParamMode)); _node->tag = TAG_List_ParamMode_ListCons_List_ParamMode;
        _node->payload.ListCons._0 = ctor__131;
        _node->payload.ListCons._1 = ctor__132;
     _node; });
    ctor__134 = (ReturnMode){ .tag = TAG_ReturnMode_OwnedResult_ReturnMode };
    ctor__135 = (FfiSig){ .tag = TAG_FfiSig_FfiSig_FfiSig, .payload.FfiSig = { ._0 = ctor__133, ._1 = ctor__134 } };
    call__136 = Gleamc_dict_insert_String_FfiSig(call__129, str__130, ctor__135);
    str__137 = (GleamcString){ __gl_lit_802992126.bytes, 21 };
    ctor__138 = (ParamMode){ .tag = TAG_ParamMode_Borrow_ParamMode };
    ctor__139 = ({ List_ParamMode* _node = (List_ParamMode*)gleamc_alloc(sizeof(List_ParamMode)); _node->tag = TAG_List_ParamMode_ListEmpty_List_ParamMode; _node; });
    ctor__140 = ({ List_ParamMode* _node = (List_ParamMode*)gleamc_alloc(sizeof(List_ParamMode)); _node->tag = TAG_List_ParamMode_ListCons_List_ParamMode;
        _node->payload.ListCons._0 = ctor__138;
        _node->payload.ListCons._1 = ctor__139;
     _node; });
    ctor__141 = (ReturnMode){ .tag = TAG_ReturnMode_OwnedResult_ReturnMode };
    ctor__142 = (FfiSig){ .tag = TAG_FfiSig_FfiSig_FfiSig, .payload.FfiSig = { ._0 = ctor__140, ._1 = ctor__141 } };
    call__143 = Gleamc_dict_insert_String_FfiSig(call__136, str__137, ctor__142);
    str__144 = (GleamcString){ __gl_lit_283068439.bytes, 19 };
    ctor__145 = (ParamMode){ .tag = TAG_ParamMode_Borrow_ParamMode };
    ctor__146 = ({ List_ParamMode* _node = (List_ParamMode*)gleamc_alloc(sizeof(List_ParamMode)); _node->tag = TAG_List_ParamMode_ListEmpty_List_ParamMode; _node; });
    ctor__147 = ({ List_ParamMode* _node = (List_ParamMode*)gleamc_alloc(sizeof(List_ParamMode)); _node->tag = TAG_List_ParamMode_ListCons_List_ParamMode;
        _node->payload.ListCons._0 = ctor__145;
        _node->payload.ListCons._1 = ctor__146;
     _node; });
    ctor__148 = (ReturnMode){ .tag = TAG_ReturnMode_OwnedResult_ReturnMode };
    ctor__149 = (FfiSig){ .tag = TAG_FfiSig_FfiSig_FfiSig, .payload.FfiSig = { ._0 = ctor__147, ._1 = ctor__148 } };
    call__150 = Gleamc_dict_insert_String_FfiSig(call__143, str__144, ctor__149);
    str__151 = (GleamcString){ __gl_lit_325809388.bytes, 15 };
    ctor__152 = (ParamMode){ .tag = TAG_ParamMode_Borrow_ParamMode };
    ctor__153 = (ParamMode){ .tag = TAG_ParamMode_Borrow_ParamMode };
    ctor__154 = ({ List_ParamMode* _node = (List_ParamMode*)gleamc_alloc(sizeof(List_ParamMode)); _node->tag = TAG_List_ParamMode_ListEmpty_List_ParamMode; _node; });
    ctor__155 = ({ List_ParamMode* _node = (List_ParamMode*)gleamc_alloc(sizeof(List_ParamMode)); _node->tag = TAG_List_ParamMode_ListCons_List_ParamMode;
        _node->payload.ListCons._0 = ctor__153;
        _node->payload.ListCons._1 = ctor__154;
     _node; });
    ctor__156 = ({ List_ParamMode* _node = (List_ParamMode*)gleamc_alloc(sizeof(List_ParamMode)); _node->tag = TAG_List_ParamMode_ListCons_List_ParamMode;
        _node->payload.ListCons._0 = ctor__152;
        _node->payload.ListCons._1 = ctor__155;
     _node; });
    ctor__157 = (ReturnMode){ .tag = TAG_ReturnMode_OwnedResult_ReturnMode };
    ctor__158 = (FfiSig){ .tag = TAG_FfiSig_FfiSig_FfiSig, .payload.FfiSig = { ._0 = ctor__156, ._1 = ctor__157 } };
    call__159 = Gleamc_dict_insert_String_FfiSig(call__150, str__151, ctor__158);
    str__160 = (GleamcString){ __gl_lit_555328024.bytes, 14 };
    ctor__161 = (ParamMode){ .tag = TAG_ParamMode_Borrow_ParamMode };
    ctor__162 = (ParamMode){ .tag = TAG_ParamMode_Borrow_ParamMode };
    ctor__163 = ({ List_ParamMode* _node = (List_ParamMode*)gleamc_alloc(sizeof(List_ParamMode)); _node->tag = TAG_List_ParamMode_ListEmpty_List_ParamMode; _node; });
    ctor__164 = ({ List_ParamMode* _node = (List_ParamMode*)gleamc_alloc(sizeof(List_ParamMode)); _node->tag = TAG_List_ParamMode_ListCons_List_ParamMode;
        _node->payload.ListCons._0 = ctor__162;
        _node->payload.ListCons._1 = ctor__163;
     _node; });
    ctor__165 = ({ List_ParamMode* _node = (List_ParamMode*)gleamc_alloc(sizeof(List_ParamMode)); _node->tag = TAG_List_ParamMode_ListCons_List_ParamMode;
        _node->payload.ListCons._0 = ctor__161;
        _node->payload.ListCons._1 = ctor__164;
     _node; });
    ctor__166 = (ReturnMode){ .tag = TAG_ReturnMode_OwnedResult_ReturnMode };
    ctor__167 = (FfiSig){ .tag = TAG_FfiSig_FfiSig_FfiSig, .payload.FfiSig = { ._0 = ctor__165, ._1 = ctor__166 } };
    call__168 = Gleamc_dict_insert_String_FfiSig(call__159, str__160, ctor__167);
    str__169 = (GleamcString){ __gl_lit_932664061.bytes, 24 };
    ctor__170 = (ParamMode){ .tag = TAG_ParamMode_Borrow_ParamMode };
    ctor__171 = (ParamMode){ .tag = TAG_ParamMode_Borrow_ParamMode };
    ctor__172 = ({ List_ParamMode* _node = (List_ParamMode*)gleamc_alloc(sizeof(List_ParamMode)); _node->tag = TAG_List_ParamMode_ListEmpty_List_ParamMode; _node; });
    ctor__173 = ({ List_ParamMode* _node = (List_ParamMode*)gleamc_alloc(sizeof(List_ParamMode)); _node->tag = TAG_List_ParamMode_ListCons_List_ParamMode;
        _node->payload.ListCons._0 = ctor__171;
        _node->payload.ListCons._1 = ctor__172;
     _node; });
    ctor__174 = ({ List_ParamMode* _node = (List_ParamMode*)gleamc_alloc(sizeof(List_ParamMode)); _node->tag = TAG_List_ParamMode_ListCons_List_ParamMode;
        _node->payload.ListCons._0 = ctor__170;
        _node->payload.ListCons._1 = ctor__173;
     _node; });
    ctor__175 = (ReturnMode){ .tag = TAG_ReturnMode_OwnedResult_ReturnMode };
    ctor__176 = (FfiSig){ .tag = TAG_FfiSig_FfiSig_FfiSig, .payload.FfiSig = { ._0 = ctor__174, ._1 = ctor__175 } };
    call__177 = Gleamc_dict_insert_String_FfiSig(call__168, str__169, ctor__176);
    str__178 = (GleamcString){ __gl_lit_325823594.bytes, 15 };
    ctor__179 = (ParamMode){ .tag = TAG_ParamMode_Borrow_ParamMode };
    ctor__180 = ({ List_ParamMode* _node = (List_ParamMode*)gleamc_alloc(sizeof(List_ParamMode)); _node->tag = TAG_List_ParamMode_ListEmpty_List_ParamMode; _node; });
    ctor__181 = ({ List_ParamMode* _node = (List_ParamMode*)gleamc_alloc(sizeof(List_ParamMode)); _node->tag = TAG_List_ParamMode_ListCons_List_ParamMode;
        _node->payload.ListCons._0 = ctor__179;
        _node->payload.ListCons._1 = ctor__180;
     _node; });
    ctor__182 = (ReturnMode){ .tag = TAG_ReturnMode_OwnedResult_ReturnMode };
    ctor__183 = (FfiSig){ .tag = TAG_FfiSig_FfiSig_FfiSig, .payload.FfiSig = { ._0 = ctor__181, ._1 = ctor__182 } };
    call__184 = Gleamc_dict_insert_String_FfiSig(call__177, str__178, ctor__183);
    str__185 = (GleamcString){ __gl_lit_390891949.bytes, 22 };
    ctor__186 = (ParamMode){ .tag = TAG_ParamMode_Borrow_ParamMode };
    ctor__187 = (ParamMode){ .tag = TAG_ParamMode_Borrow_ParamMode };
    ctor__188 = ({ List_ParamMode* _node = (List_ParamMode*)gleamc_alloc(sizeof(List_ParamMode)); _node->tag = TAG_List_ParamMode_ListEmpty_List_ParamMode; _node; });
    ctor__189 = ({ List_ParamMode* _node = (List_ParamMode*)gleamc_alloc(sizeof(List_ParamMode)); _node->tag = TAG_List_ParamMode_ListCons_List_ParamMode;
        _node->payload.ListCons._0 = ctor__187;
        _node->payload.ListCons._1 = ctor__188;
     _node; });
    ctor__190 = ({ List_ParamMode* _node = (List_ParamMode*)gleamc_alloc(sizeof(List_ParamMode)); _node->tag = TAG_List_ParamMode_ListCons_List_ParamMode;
        _node->payload.ListCons._0 = ctor__186;
        _node->payload.ListCons._1 = ctor__189;
     _node; });
    ctor__191 = (ReturnMode){ .tag = TAG_ReturnMode_OwnedResult_ReturnMode };
    ctor__192 = (FfiSig){ .tag = TAG_FfiSig_FfiSig_FfiSig, .payload.FfiSig = { ._0 = ctor__190, ._1 = ctor__191 } };
    call__193 = Gleamc_dict_insert_String_FfiSig(call__184, str__185, ctor__192);
    str__194 = (GleamcString){ __gl_lit_906694316.bytes, 23 };
    ctor__195 = (ParamMode){ .tag = TAG_ParamMode_Borrow_ParamMode };
    ctor__196 = (ParamMode){ .tag = TAG_ParamMode_Borrow_ParamMode };
    ctor__197 = ({ List_ParamMode* _node = (List_ParamMode*)gleamc_alloc(sizeof(List_ParamMode)); _node->tag = TAG_List_ParamMode_ListEmpty_List_ParamMode; _node; });
    ctor__198 = ({ List_ParamMode* _node = (List_ParamMode*)gleamc_alloc(sizeof(List_ParamMode)); _node->tag = TAG_List_ParamMode_ListCons_List_ParamMode;
        _node->payload.ListCons._0 = ctor__196;
        _node->payload.ListCons._1 = ctor__197;
     _node; });
    ctor__199 = ({ List_ParamMode* _node = (List_ParamMode*)gleamc_alloc(sizeof(List_ParamMode)); _node->tag = TAG_List_ParamMode_ListCons_List_ParamMode;
        _node->payload.ListCons._0 = ctor__195;
        _node->payload.ListCons._1 = ctor__198;
     _node; });
    ctor__200 = (ReturnMode){ .tag = TAG_ReturnMode_OwnedResult_ReturnMode };
    ctor__201 = (FfiSig){ .tag = TAG_FfiSig_FfiSig_FfiSig, .payload.FfiSig = { ._0 = ctor__199, ._1 = ctor__200 } };
    call__202 = Gleamc_dict_insert_String_FfiSig(call__193, str__194, ctor__201);
    str__203 = (GleamcString){ __gl_lit_844955336.bytes, 22 };
    ctor__204 = (ParamMode){ .tag = TAG_ParamMode_Borrow_ParamMode };
    ctor__205 = (ParamMode){ .tag = TAG_ParamMode_Borrow_ParamMode };
    ctor__206 = ({ List_ParamMode* _node = (List_ParamMode*)gleamc_alloc(sizeof(List_ParamMode)); _node->tag = TAG_List_ParamMode_ListEmpty_List_ParamMode; _node; });
    ctor__207 = ({ List_ParamMode* _node = (List_ParamMode*)gleamc_alloc(sizeof(List_ParamMode)); _node->tag = TAG_List_ParamMode_ListCons_List_ParamMode;
        _node->payload.ListCons._0 = ctor__205;
        _node->payload.ListCons._1 = ctor__206;
     _node; });
    ctor__208 = ({ List_ParamMode* _node = (List_ParamMode*)gleamc_alloc(sizeof(List_ParamMode)); _node->tag = TAG_List_ParamMode_ListCons_List_ParamMode;
        _node->payload.ListCons._0 = ctor__204;
        _node->payload.ListCons._1 = ctor__207;
     _node; });
    ctor__209 = (ReturnMode){ .tag = TAG_ReturnMode_OwnedResult_ReturnMode };
    ctor__210 = (FfiSig){ .tag = TAG_FfiSig_FfiSig_FfiSig, .payload.FfiSig = { ._0 = ctor__208, ._1 = ctor__209 } };
    call__211 = Gleamc_dict_insert_String_FfiSig(call__202, str__203, ctor__210);
    str__212 = (GleamcString){ __gl_lit_494849087.bytes, 12 };
    ctor__213 = (ParamMode){ .tag = TAG_ParamMode_Borrow_ParamMode };
    ctor__214 = ({ List_ParamMode* _node = (List_ParamMode*)gleamc_alloc(sizeof(List_ParamMode)); _node->tag = TAG_List_ParamMode_ListEmpty_List_ParamMode; _node; });
    ctor__215 = ({ List_ParamMode* _node = (List_ParamMode*)gleamc_alloc(sizeof(List_ParamMode)); _node->tag = TAG_List_ParamMode_ListCons_List_ParamMode;
        _node->payload.ListCons._0 = ctor__213;
        _node->payload.ListCons._1 = ctor__214;
     _node; });
    ctor__216 = (ReturnMode){ .tag = TAG_ReturnMode_OwnedResult_ReturnMode };
    ctor__217 = (FfiSig){ .tag = TAG_FfiSig_FfiSig_FfiSig, .payload.FfiSig = { ._0 = ctor__215, ._1 = ctor__216 } };
    call__218 = Gleamc_dict_insert_String_FfiSig(call__211, str__212, ctor__217);
    str__219 = (GleamcString){ __gl_lit_776327688.bytes, 20 };
    ctor__220 = (ParamMode){ .tag = TAG_ParamMode_Borrow_ParamMode };
    ctor__221 = (ParamMode){ .tag = TAG_ParamMode_Borrow_ParamMode };
    ctor__222 = ({ List_ParamMode* _node = (List_ParamMode*)gleamc_alloc(sizeof(List_ParamMode)); _node->tag = TAG_List_ParamMode_ListEmpty_List_ParamMode; _node; });
    ctor__223 = ({ List_ParamMode* _node = (List_ParamMode*)gleamc_alloc(sizeof(List_ParamMode)); _node->tag = TAG_List_ParamMode_ListCons_List_ParamMode;
        _node->payload.ListCons._0 = ctor__221;
        _node->payload.ListCons._1 = ctor__222;
     _node; });
    ctor__224 = ({ List_ParamMode* _node = (List_ParamMode*)gleamc_alloc(sizeof(List_ParamMode)); _node->tag = TAG_List_ParamMode_ListCons_List_ParamMode;
        _node->payload.ListCons._0 = ctor__220;
        _node->payload.ListCons._1 = ctor__223;
     _node; });
    ctor__225 = (ReturnMode){ .tag = TAG_ReturnMode_OwnedResult_ReturnMode };
    ctor__226 = (FfiSig){ .tag = TAG_FfiSig_FfiSig_FfiSig, .payload.FfiSig = { ._0 = ctor__224, ._1 = ctor__225 } };
    call__227 = Gleamc_dict_insert_String_FfiSig(call__218, str__219, ctor__226);
    str__228 = (GleamcString){ __gl_lit_883650838.bytes, 23 };
    ctor__229 = (ParamMode){ .tag = TAG_ParamMode_Borrow_ParamMode };
    ctor__230 = (ParamMode){ .tag = TAG_ParamMode_Borrow_ParamMode };
    ctor__231 = ({ List_ParamMode* _node = (List_ParamMode*)gleamc_alloc(sizeof(List_ParamMode)); _node->tag = TAG_List_ParamMode_ListEmpty_List_ParamMode; _node; });
    ctor__232 = ({ List_ParamMode* _node = (List_ParamMode*)gleamc_alloc(sizeof(List_ParamMode)); _node->tag = TAG_List_ParamMode_ListCons_List_ParamMode;
        _node->payload.ListCons._0 = ctor__230;
        _node->payload.ListCons._1 = ctor__231;
     _node; });
    ctor__233 = ({ List_ParamMode* _node = (List_ParamMode*)gleamc_alloc(sizeof(List_ParamMode)); _node->tag = TAG_List_ParamMode_ListCons_List_ParamMode;
        _node->payload.ListCons._0 = ctor__229;
        _node->payload.ListCons._1 = ctor__232;
     _node; });
    ctor__234 = (ReturnMode){ .tag = TAG_ReturnMode_OwnedResult_ReturnMode };
    ctor__235 = (FfiSig){ .tag = TAG_FfiSig_FfiSig_FfiSig, .payload.FfiSig = { ._0 = ctor__233, ._1 = ctor__234 } };
    call__236 = Gleamc_dict_insert_String_FfiSig(call__227, str__228, ctor__235);
    str__237 = (GleamcString){ __gl_lit_265660841.bytes, 30 };
    ctor__238 = (ParamMode){ .tag = TAG_ParamMode_Borrow_ParamMode };
    ctor__239 = ({ List_ParamMode* _node = (List_ParamMode*)gleamc_alloc(sizeof(List_ParamMode)); _node->tag = TAG_List_ParamMode_ListEmpty_List_ParamMode; _node; });
    ctor__240 = ({ List_ParamMode* _node = (List_ParamMode*)gleamc_alloc(sizeof(List_ParamMode)); _node->tag = TAG_List_ParamMode_ListCons_List_ParamMode;
        _node->payload.ListCons._0 = ctor__238;
        _node->payload.ListCons._1 = ctor__239;
     _node; });
    ctor__241 = (ReturnMode){ .tag = TAG_ReturnMode_OwnedResult_ReturnMode };
    ctor__242 = (FfiSig){ .tag = TAG_FfiSig_FfiSig_FfiSig, .payload.FfiSig = { ._0 = ctor__240, ._1 = ctor__241 } };
    call__243 = Gleamc_dict_insert_String_FfiSig(call__236, str__237, ctor__242);
    str__244 = (GleamcString){ __gl_lit_317771550.bytes, 15 };
    ctor__245 = (ParamMode){ .tag = TAG_ParamMode_Borrow_ParamMode };
    ctor__246 = (ParamMode){ .tag = TAG_ParamMode_Borrow_ParamMode };
    ctor__247 = ({ List_ParamMode* _node = (List_ParamMode*)gleamc_alloc(sizeof(List_ParamMode)); _node->tag = TAG_List_ParamMode_ListEmpty_List_ParamMode; _node; });
    ctor__248 = ({ List_ParamMode* _node = (List_ParamMode*)gleamc_alloc(sizeof(List_ParamMode)); _node->tag = TAG_List_ParamMode_ListCons_List_ParamMode;
        _node->payload.ListCons._0 = ctor__246;
        _node->payload.ListCons._1 = ctor__247;
     _node; });
    ctor__249 = ({ List_ParamMode* _node = (List_ParamMode*)gleamc_alloc(sizeof(List_ParamMode)); _node->tag = TAG_List_ParamMode_ListCons_List_ParamMode;
        _node->payload.ListCons._0 = ctor__245;
        _node->payload.ListCons._1 = ctor__248;
     _node; });
    ctor__250 = (ReturnMode){ .tag = TAG_ReturnMode_OwnedResult_ReturnMode };
    ctor__251 = (FfiSig){ .tag = TAG_FfiSig_FfiSig_FfiSig, .payload.FfiSig = { ._0 = ctor__249, ._1 = ctor__250 } };
    call__252 = Gleamc_dict_insert_String_FfiSig(call__243, str__244, ctor__251);
    str__253 = (GleamcString){ __gl_lit_132115984.bytes, 18 };
    ctor__254 = (ParamMode){ .tag = TAG_ParamMode_Borrow_ParamMode };
    ctor__255 = (ParamMode){ .tag = TAG_ParamMode_Borrow_ParamMode };
    ctor__256 = ({ List_ParamMode* _node = (List_ParamMode*)gleamc_alloc(sizeof(List_ParamMode)); _node->tag = TAG_List_ParamMode_ListEmpty_List_ParamMode; _node; });
    ctor__257 = ({ List_ParamMode* _node = (List_ParamMode*)gleamc_alloc(sizeof(List_ParamMode)); _node->tag = TAG_List_ParamMode_ListCons_List_ParamMode;
        _node->payload.ListCons._0 = ctor__255;
        _node->payload.ListCons._1 = ctor__256;
     _node; });
    ctor__258 = ({ List_ParamMode* _node = (List_ParamMode*)gleamc_alloc(sizeof(List_ParamMode)); _node->tag = TAG_List_ParamMode_ListCons_List_ParamMode;
        _node->payload.ListCons._0 = ctor__254;
        _node->payload.ListCons._1 = ctor__257;
     _node; });
    ctor__259 = (ReturnMode){ .tag = TAG_ReturnMode_OwnedResult_ReturnMode };
    ctor__260 = (FfiSig){ .tag = TAG_FfiSig_FfiSig_FfiSig, .payload.FfiSig = { ._0 = ctor__258, ._1 = ctor__259 } };
    call__261 = Gleamc_dict_insert_String_FfiSig(call__252, str__253, ctor__260);
    str__262 = (GleamcString){ __gl_lit_729546171.bytes, 16 };
    ctor__263 = (ParamMode){ .tag = TAG_ParamMode_Borrow_ParamMode };
    ctor__264 = (ParamMode){ .tag = TAG_ParamMode_Borrow_ParamMode };
    ctor__265 = ({ List_ParamMode* _node = (List_ParamMode*)gleamc_alloc(sizeof(List_ParamMode)); _node->tag = TAG_List_ParamMode_ListEmpty_List_ParamMode; _node; });
    ctor__266 = ({ List_ParamMode* _node = (List_ParamMode*)gleamc_alloc(sizeof(List_ParamMode)); _node->tag = TAG_List_ParamMode_ListCons_List_ParamMode;
        _node->payload.ListCons._0 = ctor__264;
        _node->payload.ListCons._1 = ctor__265;
     _node; });
    ctor__267 = ({ List_ParamMode* _node = (List_ParamMode*)gleamc_alloc(sizeof(List_ParamMode)); _node->tag = TAG_List_ParamMode_ListCons_List_ParamMode;
        _node->payload.ListCons._0 = ctor__263;
        _node->payload.ListCons._1 = ctor__266;
     _node; });
    ctor__268 = (ReturnMode){ .tag = TAG_ReturnMode_OwnedResult_ReturnMode };
    ctor__269 = (FfiSig){ .tag = TAG_FfiSig_FfiSig_FfiSig, .payload.FfiSig = { ._0 = ctor__267, ._1 = ctor__268 } };
    call__270 = Gleamc_dict_insert_String_FfiSig(call__261, str__262, ctor__269);
    str__271 = (GleamcString){ __gl_lit_489028782.bytes, 11 };
    ctor__272 = (ParamMode){ .tag = TAG_ParamMode_Borrow_ParamMode };
    ctor__273 = ({ List_ParamMode* _node = (List_ParamMode*)gleamc_alloc(sizeof(List_ParamMode)); _node->tag = TAG_List_ParamMode_ListEmpty_List_ParamMode; _node; });
    ctor__274 = ({ List_ParamMode* _node = (List_ParamMode*)gleamc_alloc(sizeof(List_ParamMode)); _node->tag = TAG_List_ParamMode_ListCons_List_ParamMode;
        _node->payload.ListCons._0 = ctor__272;
        _node->payload.ListCons._1 = ctor__273;
     _node; });
    ctor__275 = (ReturnMode){ .tag = TAG_ReturnMode_OwnedResult_ReturnMode };
    ctor__276 = (FfiSig){ .tag = TAG_FfiSig_FfiSig_FfiSig, .payload.FfiSig = { ._0 = ctor__274, ._1 = ctor__275 } };
    call__277 = Gleamc_dict_insert_String_FfiSig(call__270, str__271, ctor__276);
    str__278 = (GleamcString){ __gl_lit_309650162.bytes, 17 };
    ctor__279 = (ParamMode){ .tag = TAG_ParamMode_Borrow_ParamMode };
    ctor__280 = ({ List_ParamMode* _node = (List_ParamMode*)gleamc_alloc(sizeof(List_ParamMode)); _node->tag = TAG_List_ParamMode_ListEmpty_List_ParamMode; _node; });
    ctor__281 = ({ List_ParamMode* _node = (List_ParamMode*)gleamc_alloc(sizeof(List_ParamMode)); _node->tag = TAG_List_ParamMode_ListCons_List_ParamMode;
        _node->payload.ListCons._0 = ctor__279;
        _node->payload.ListCons._1 = ctor__280;
     _node; });
    ctor__282 = (ReturnMode){ .tag = TAG_ReturnMode_OwnedResult_ReturnMode };
    ctor__283 = (FfiSig){ .tag = TAG_FfiSig_FfiSig_FfiSig, .payload.FfiSig = { ._0 = ctor__281, ._1 = ctor__282 } };
    call__284 = Gleamc_dict_insert_String_FfiSig(call__277, str__278, ctor__283);
    str__285 = (GleamcString){ __gl_lit_501646313.bytes, 15 };
    ctor__286 = (ParamMode){ .tag = TAG_ParamMode_Borrow_ParamMode };
    ctor__287 = ({ List_ParamMode* _node = (List_ParamMode*)gleamc_alloc(sizeof(List_ParamMode)); _node->tag = TAG_List_ParamMode_ListEmpty_List_ParamMode; _node; });
    ctor__288 = ({ List_ParamMode* _node = (List_ParamMode*)gleamc_alloc(sizeof(List_ParamMode)); _node->tag = TAG_List_ParamMode_ListCons_List_ParamMode;
        _node->payload.ListCons._0 = ctor__286;
        _node->payload.ListCons._1 = ctor__287;
     _node; });
    ctor__289 = (ReturnMode){ .tag = TAG_ReturnMode_OwnedResult_ReturnMode };
    ctor__290 = (FfiSig){ .tag = TAG_FfiSig_FfiSig_FfiSig, .payload.FfiSig = { ._0 = ctor__288, ._1 = ctor__289 } };
    call__291 = Gleamc_dict_insert_String_FfiSig(call__284, str__285, ctor__290);
    str__292 = (GleamcString){ __gl_lit_143894201.bytes, 14 };
    ctor__293 = (ParamMode){ .tag = TAG_ParamMode_Borrow_ParamMode };
    ctor__294 = (ParamMode){ .tag = TAG_ParamMode_Borrow_ParamMode };
    ctor__295 = (ParamMode){ .tag = TAG_ParamMode_Borrow_ParamMode };
    ctor__296 = ({ List_ParamMode* _node = (List_ParamMode*)gleamc_alloc(sizeof(List_ParamMode)); _node->tag = TAG_List_ParamMode_ListEmpty_List_ParamMode; _node; });
    ctor__297 = ({ List_ParamMode* _node = (List_ParamMode*)gleamc_alloc(sizeof(List_ParamMode)); _node->tag = TAG_List_ParamMode_ListCons_List_ParamMode;
        _node->payload.ListCons._0 = ctor__295;
        _node->payload.ListCons._1 = ctor__296;
     _node; });
    ctor__298 = ({ List_ParamMode* _node = (List_ParamMode*)gleamc_alloc(sizeof(List_ParamMode)); _node->tag = TAG_List_ParamMode_ListCons_List_ParamMode;
        _node->payload.ListCons._0 = ctor__294;
        _node->payload.ListCons._1 = ctor__297;
     _node; });
    ctor__299 = ({ List_ParamMode* _node = (List_ParamMode*)gleamc_alloc(sizeof(List_ParamMode)); _node->tag = TAG_List_ParamMode_ListCons_List_ParamMode;
        _node->payload.ListCons._0 = ctor__293;
        _node->payload.ListCons._1 = ctor__298;
     _node; });
    ctor__300 = (ReturnMode){ .tag = TAG_ReturnMode_OwnedResult_ReturnMode };
    ctor__301 = (FfiSig){ .tag = TAG_FfiSig_FfiSig_FfiSig, .payload.FfiSig = { ._0 = ctor__299, ._1 = ctor__300 } };
    call__302 = Gleamc_dict_insert_String_FfiSig(call__291, str__292, ctor__301);
    str__303 = (GleamcString){ __gl_lit_422038754.bytes, 16 };
    ctor__304 = (ParamMode){ .tag = TAG_ParamMode_Borrow_ParamMode };
    ctor__305 = ({ List_ParamMode* _node = (List_ParamMode*)gleamc_alloc(sizeof(List_ParamMode)); _node->tag = TAG_List_ParamMode_ListEmpty_List_ParamMode; _node; });
    ctor__306 = ({ List_ParamMode* _node = (List_ParamMode*)gleamc_alloc(sizeof(List_ParamMode)); _node->tag = TAG_List_ParamMode_ListCons_List_ParamMode;
        _node->payload.ListCons._0 = ctor__304;
        _node->payload.ListCons._1 = ctor__305;
     _node; });
    ctor__307 = (ReturnMode){ .tag = TAG_ReturnMode_OwnedResult_ReturnMode };
    ctor__308 = (FfiSig){ .tag = TAG_FfiSig_FfiSig_FfiSig, .payload.FfiSig = { ._0 = ctor__306, ._1 = ctor__307 } };
    call__309 = Gleamc_dict_insert_String_FfiSig(call__302, str__303, ctor__308);
    str__310 = (GleamcString){ __gl_lit_136547922.bytes, 12 };
    ctor__311 = (ParamMode){ .tag = TAG_ParamMode_Borrow_ParamMode };
    ctor__312 = (ParamMode){ .tag = TAG_ParamMode_Borrow_ParamMode };
    ctor__313 = (ParamMode){ .tag = TAG_ParamMode_Borrow_ParamMode };
    ctor__314 = ({ List_ParamMode* _node = (List_ParamMode*)gleamc_alloc(sizeof(List_ParamMode)); _node->tag = TAG_List_ParamMode_ListEmpty_List_ParamMode; _node; });
    ctor__315 = ({ List_ParamMode* _node = (List_ParamMode*)gleamc_alloc(sizeof(List_ParamMode)); _node->tag = TAG_List_ParamMode_ListCons_List_ParamMode;
        _node->payload.ListCons._0 = ctor__313;
        _node->payload.ListCons._1 = ctor__314;
     _node; });
    ctor__316 = ({ List_ParamMode* _node = (List_ParamMode*)gleamc_alloc(sizeof(List_ParamMode)); _node->tag = TAG_List_ParamMode_ListCons_List_ParamMode;
        _node->payload.ListCons._0 = ctor__312;
        _node->payload.ListCons._1 = ctor__315;
     _node; });
    ctor__317 = ({ List_ParamMode* _node = (List_ParamMode*)gleamc_alloc(sizeof(List_ParamMode)); _node->tag = TAG_List_ParamMode_ListCons_List_ParamMode;
        _node->payload.ListCons._0 = ctor__311;
        _node->payload.ListCons._1 = ctor__316;
     _node; });
    ctor__318 = (ReturnMode){ .tag = TAG_ReturnMode_OwnedResult_ReturnMode };
    ctor__319 = (FfiSig){ .tag = TAG_FfiSig_FfiSig_FfiSig, .payload.FfiSig = { ._0 = ctor__317, ._1 = ctor__318 } };
    call__320 = Gleamc_dict_insert_String_FfiSig(call__309, str__310, ctor__319);
    str__321 = (GleamcString){ __gl_lit_224016840.bytes, 13 };
    ctor__322 = (ParamMode){ .tag = TAG_ParamMode_Borrow_ParamMode };
    ctor__323 = ({ List_ParamMode* _node = (List_ParamMode*)gleamc_alloc(sizeof(List_ParamMode)); _node->tag = TAG_List_ParamMode_ListEmpty_List_ParamMode; _node; });
    ctor__324 = ({ List_ParamMode* _node = (List_ParamMode*)gleamc_alloc(sizeof(List_ParamMode)); _node->tag = TAG_List_ParamMode_ListCons_List_ParamMode;
        _node->payload.ListCons._0 = ctor__322;
        _node->payload.ListCons._1 = ctor__323;
     _node; });
    ctor__325 = (ReturnMode){ .tag = TAG_ReturnMode_OwnedResult_ReturnMode };
    ctor__326 = (FfiSig){ .tag = TAG_FfiSig_FfiSig_FfiSig, .payload.FfiSig = { ._0 = ctor__324, ._1 = ctor__325 } };
    call__327 = Gleamc_dict_insert_String_FfiSig(call__320, str__321, ctor__326);
    str__328 = (GleamcString){ __gl_lit_806642149.bytes, 13 };
    ctor__329 = (ParamMode){ .tag = TAG_ParamMode_Borrow_ParamMode };
    ctor__330 = (ParamMode){ .tag = TAG_ParamMode_Borrow_ParamMode };
    ctor__331 = ({ List_ParamMode* _node = (List_ParamMode*)gleamc_alloc(sizeof(List_ParamMode)); _node->tag = TAG_List_ParamMode_ListEmpty_List_ParamMode; _node; });
    ctor__332 = ({ List_ParamMode* _node = (List_ParamMode*)gleamc_alloc(sizeof(List_ParamMode)); _node->tag = TAG_List_ParamMode_ListCons_List_ParamMode;
        _node->payload.ListCons._0 = ctor__330;
        _node->payload.ListCons._1 = ctor__331;
     _node; });
    ctor__333 = ({ List_ParamMode* _node = (List_ParamMode*)gleamc_alloc(sizeof(List_ParamMode)); _node->tag = TAG_List_ParamMode_ListCons_List_ParamMode;
        _node->payload.ListCons._0 = ctor__329;
        _node->payload.ListCons._1 = ctor__332;
     _node; });
    ctor__334 = (ReturnMode){ .tag = TAG_ReturnMode_OwnedResult_ReturnMode };
    ctor__335 = (FfiSig){ .tag = TAG_FfiSig_FfiSig_FfiSig, .payload.FfiSig = { ._0 = ctor__333, ._1 = ctor__334 } };
    call__336 = Gleamc_dict_insert_String_FfiSig(call__327, str__328, ctor__335);
    str__337 = (GleamcString){ __gl_lit_475690897.bytes, 16 };
    ctor__338 = (ParamMode){ .tag = TAG_ParamMode_Owned_ParamMode };
    ctor__339 = ({ List_ParamMode* _node = (List_ParamMode*)gleamc_alloc(sizeof(List_ParamMode)); _node->tag = TAG_List_ParamMode_ListEmpty_List_ParamMode; _node; });
    ctor__340 = ({ List_ParamMode* _node = (List_ParamMode*)gleamc_alloc(sizeof(List_ParamMode)); _node->tag = TAG_List_ParamMode_ListCons_List_ParamMode;
        _node->payload.ListCons._0 = ctor__338;
        _node->payload.ListCons._1 = ctor__339;
     _node; });
    ctor__341 = (ReturnMode){ .tag = TAG_ReturnMode_OwnedResult_ReturnMode };
    ctor__342 = (FfiSig){ .tag = TAG_FfiSig_FfiSig_FfiSig, .payload.FfiSig = { ._0 = ctor__340, ._1 = ctor__341 } };
    call__343 = Gleamc_dict_insert_String_FfiSig(call__336, str__337, ctor__342);
    str__344 = (GleamcString){ __gl_lit_220048371.bytes, 16 };
    ctor__345 = (ParamMode){ .tag = TAG_ParamMode_Owned_ParamMode };
    ctor__346 = ({ List_ParamMode* _node = (List_ParamMode*)gleamc_alloc(sizeof(List_ParamMode)); _node->tag = TAG_List_ParamMode_ListEmpty_List_ParamMode; _node; });
    ctor__347 = ({ List_ParamMode* _node = (List_ParamMode*)gleamc_alloc(sizeof(List_ParamMode)); _node->tag = TAG_List_ParamMode_ListCons_List_ParamMode;
        _node->payload.ListCons._0 = ctor__345;
        _node->payload.ListCons._1 = ctor__346;
     _node; });
    ctor__348 = (ReturnMode){ .tag = TAG_ReturnMode_OwnedResult_ReturnMode };
    ctor__349 = (FfiSig){ .tag = TAG_FfiSig_FfiSig_FfiSig, .payload.FfiSig = { ._0 = ctor__347, ._1 = ctor__348 } };
    call__350 = Gleamc_dict_insert_String_FfiSig(call__343, str__344, ctor__349);
    str__351 = (GleamcString){ __gl_lit_150777209.bytes, 14 };
    ctor__352 = (ParamMode){ .tag = TAG_ParamMode_Borrow_ParamMode };
    ctor__353 = ({ List_ParamMode* _node = (List_ParamMode*)gleamc_alloc(sizeof(List_ParamMode)); _node->tag = TAG_List_ParamMode_ListEmpty_List_ParamMode; _node; });
    ctor__354 = ({ List_ParamMode* _node = (List_ParamMode*)gleamc_alloc(sizeof(List_ParamMode)); _node->tag = TAG_List_ParamMode_ListCons_List_ParamMode;
        _node->payload.ListCons._0 = ctor__352;
        _node->payload.ListCons._1 = ctor__353;
     _node; });
    ctor__355 = (ReturnMode){ .tag = TAG_ReturnMode_OwnedResult_ReturnMode };
    ctor__356 = (FfiSig){ .tag = TAG_FfiSig_FfiSig_FfiSig, .payload.FfiSig = { ._0 = ctor__354, ._1 = ctor__355 } };
    call__357 = Gleamc_dict_insert_String_FfiSig(call__350, str__351, ctor__356);
    str__358 = (GleamcString){ __gl_lit_516192604.bytes, 21 };
    ctor__359 = (ParamMode){ .tag = TAG_ParamMode_Borrow_ParamMode };
    ctor__360 = ({ List_ParamMode* _node = (List_ParamMode*)gleamc_alloc(sizeof(List_ParamMode)); _node->tag = TAG_List_ParamMode_ListEmpty_List_ParamMode; _node; });
    ctor__361 = ({ List_ParamMode* _node = (List_ParamMode*)gleamc_alloc(sizeof(List_ParamMode)); _node->tag = TAG_List_ParamMode_ListCons_List_ParamMode;
        _node->payload.ListCons._0 = ctor__359;
        _node->payload.ListCons._1 = ctor__360;
     _node; });
    ctor__362 = (ReturnMode){ .tag = TAG_ReturnMode_OwnedResult_ReturnMode };
    ctor__363 = (FfiSig){ .tag = TAG_FfiSig_FfiSig_FfiSig, .payload.FfiSig = { ._0 = ctor__361, ._1 = ctor__362 } };
    call__364 = Gleamc_dict_insert_String_FfiSig(call__357, str__358, ctor__363);
    str__365 = (GleamcString){ __gl_lit_805774608.bytes, 23 };
    ctor__366 = (ParamMode){ .tag = TAG_ParamMode_Borrow_ParamMode };
    ctor__367 = ({ List_ParamMode* _node = (List_ParamMode*)gleamc_alloc(sizeof(List_ParamMode)); _node->tag = TAG_List_ParamMode_ListEmpty_List_ParamMode; _node; });
    ctor__368 = ({ List_ParamMode* _node = (List_ParamMode*)gleamc_alloc(sizeof(List_ParamMode)); _node->tag = TAG_List_ParamMode_ListCons_List_ParamMode;
        _node->payload.ListCons._0 = ctor__366;
        _node->payload.ListCons._1 = ctor__367;
     _node; });
    ctor__369 = (ReturnMode){ .tag = TAG_ReturnMode_OwnedResult_ReturnMode };
    ctor__370 = (FfiSig){ .tag = TAG_FfiSig_FfiSig_FfiSig, .payload.FfiSig = { ._0 = ctor__368, ._1 = ctor__369 } };
    call__371 = Gleamc_dict_insert_String_FfiSig(call__364, str__365, ctor__370);
    str__372 = (GleamcString){ __gl_lit_566656839.bytes, 19 };
    ctor__373 = (ParamMode){ .tag = TAG_ParamMode_Borrow_ParamMode };
    ctor__374 = ({ List_ParamMode* _node = (List_ParamMode*)gleamc_alloc(sizeof(List_ParamMode)); _node->tag = TAG_List_ParamMode_ListEmpty_List_ParamMode; _node; });
    ctor__375 = ({ List_ParamMode* _node = (List_ParamMode*)gleamc_alloc(sizeof(List_ParamMode)); _node->tag = TAG_List_ParamMode_ListCons_List_ParamMode;
        _node->payload.ListCons._0 = ctor__373;
        _node->payload.ListCons._1 = ctor__374;
     _node; });
    ctor__376 = (ReturnMode){ .tag = TAG_ReturnMode_OwnedResult_ReturnMode };
    ctor__377 = (FfiSig){ .tag = TAG_FfiSig_FfiSig_FfiSig, .payload.FfiSig = { ._0 = ctor__375, ._1 = ctor__376 } };
    call__378 = Gleamc_dict_insert_String_FfiSig(call__371, str__372, ctor__377);
    str__379 = (GleamcString){ __gl_lit_845439464.bytes, 14 };
    ctor__380 = (ParamMode){ .tag = TAG_ParamMode_Borrow_ParamMode };
    ctor__381 = (ParamMode){ .tag = TAG_ParamMode_Borrow_ParamMode };
    ctor__382 = ({ List_ParamMode* _node = (List_ParamMode*)gleamc_alloc(sizeof(List_ParamMode)); _node->tag = TAG_List_ParamMode_ListEmpty_List_ParamMode; _node; });
    ctor__383 = ({ List_ParamMode* _node = (List_ParamMode*)gleamc_alloc(sizeof(List_ParamMode)); _node->tag = TAG_List_ParamMode_ListCons_List_ParamMode;
        _node->payload.ListCons._0 = ctor__381;
        _node->payload.ListCons._1 = ctor__382;
     _node; });
    ctor__384 = ({ List_ParamMode* _node = (List_ParamMode*)gleamc_alloc(sizeof(List_ParamMode)); _node->tag = TAG_List_ParamMode_ListCons_List_ParamMode;
        _node->payload.ListCons._0 = ctor__380;
        _node->payload.ListCons._1 = ctor__383;
     _node; });
    ctor__385 = (ReturnMode){ .tag = TAG_ReturnMode_OwnedResult_ReturnMode };
    ctor__386 = (FfiSig){ .tag = TAG_FfiSig_FfiSig_FfiSig, .payload.FfiSig = { ._0 = ctor__384, ._1 = ctor__385 } };
    call__387 = Gleamc_dict_insert_String_FfiSig(call__378, str__379, ctor__386);
    str__388 = (GleamcString){ __gl_lit_633621156.bytes, 16 };
    ctor__389 = (ParamMode){ .tag = TAG_ParamMode_Borrow_ParamMode };
    ctor__390 = (ParamMode){ .tag = TAG_ParamMode_Borrow_ParamMode };
    ctor__391 = ({ List_ParamMode* _node = (List_ParamMode*)gleamc_alloc(sizeof(List_ParamMode)); _node->tag = TAG_List_ParamMode_ListEmpty_List_ParamMode; _node; });
    ctor__392 = ({ List_ParamMode* _node = (List_ParamMode*)gleamc_alloc(sizeof(List_ParamMode)); _node->tag = TAG_List_ParamMode_ListCons_List_ParamMode;
        _node->payload.ListCons._0 = ctor__390;
        _node->payload.ListCons._1 = ctor__391;
     _node; });
    ctor__393 = ({ List_ParamMode* _node = (List_ParamMode*)gleamc_alloc(sizeof(List_ParamMode)); _node->tag = TAG_List_ParamMode_ListCons_List_ParamMode;
        _node->payload.ListCons._0 = ctor__389;
        _node->payload.ListCons._1 = ctor__392;
     _node; });
    ctor__394 = (ReturnMode){ .tag = TAG_ReturnMode_OwnedResult_ReturnMode };
    ctor__395 = (FfiSig){ .tag = TAG_FfiSig_FfiSig_FfiSig, .payload.FfiSig = { ._0 = ctor__393, ._1 = ctor__394 } };
    call__396 = Gleamc_dict_insert_String_FfiSig(call__387, str__388, ctor__395);
    str__397 = (GleamcString){ __gl_lit_741216320.bytes, 18 };
    ctor__398 = (ParamMode){ .tag = TAG_ParamMode_Borrow_ParamMode };
    ctor__399 = ({ List_ParamMode* _node = (List_ParamMode*)gleamc_alloc(sizeof(List_ParamMode)); _node->tag = TAG_List_ParamMode_ListEmpty_List_ParamMode; _node; });
    ctor__400 = ({ List_ParamMode* _node = (List_ParamMode*)gleamc_alloc(sizeof(List_ParamMode)); _node->tag = TAG_List_ParamMode_ListCons_List_ParamMode;
        _node->payload.ListCons._0 = ctor__398;
        _node->payload.ListCons._1 = ctor__399;
     _node; });
    ctor__401 = (ReturnMode){ .tag = TAG_ReturnMode_OwnedResult_ReturnMode };
    ctor__402 = (FfiSig){ .tag = TAG_FfiSig_FfiSig_FfiSig, .payload.FfiSig = { ._0 = ctor__400, ._1 = ctor__401 } };
    call__403 = Gleamc_dict_insert_String_FfiSig(call__396, str__397, ctor__402);
    str__404 = (GleamcString){ __gl_lit_356778167.bytes, 18 };
    ctor__405 = (ParamMode){ .tag = TAG_ParamMode_Borrow_ParamMode };
    ctor__406 = (ParamMode){ .tag = TAG_ParamMode_Borrow_ParamMode };
    ctor__407 = ({ List_ParamMode* _node = (List_ParamMode*)gleamc_alloc(sizeof(List_ParamMode)); _node->tag = TAG_List_ParamMode_ListEmpty_List_ParamMode; _node; });
    ctor__408 = ({ List_ParamMode* _node = (List_ParamMode*)gleamc_alloc(sizeof(List_ParamMode)); _node->tag = TAG_List_ParamMode_ListCons_List_ParamMode;
        _node->payload.ListCons._0 = ctor__406;
        _node->payload.ListCons._1 = ctor__407;
     _node; });
    ctor__409 = ({ List_ParamMode* _node = (List_ParamMode*)gleamc_alloc(sizeof(List_ParamMode)); _node->tag = TAG_List_ParamMode_ListCons_List_ParamMode;
        _node->payload.ListCons._0 = ctor__405;
        _node->payload.ListCons._1 = ctor__408;
     _node; });
    ctor__410 = (ReturnMode){ .tag = TAG_ReturnMode_OwnedResult_ReturnMode };
    ctor__411 = (FfiSig){ .tag = TAG_FfiSig_FfiSig_FfiSig, .payload.FfiSig = { ._0 = ctor__409, ._1 = ctor__410 } };
    call__412 = Gleamc_dict_insert_String_FfiSig(call__403, str__404, ctor__411);
    str__413 = (GleamcString){ __gl_lit_214384716.bytes, 11 };
    ctor__414 = (ParamMode){ .tag = TAG_ParamMode_Borrow_ParamMode };
    ctor__415 = ({ List_ParamMode* _node = (List_ParamMode*)gleamc_alloc(sizeof(List_ParamMode)); _node->tag = TAG_List_ParamMode_ListEmpty_List_ParamMode; _node; });
    ctor__416 = ({ List_ParamMode* _node = (List_ParamMode*)gleamc_alloc(sizeof(List_ParamMode)); _node->tag = TAG_List_ParamMode_ListCons_List_ParamMode;
        _node->payload.ListCons._0 = ctor__414;
        _node->payload.ListCons._1 = ctor__415;
     _node; });
    ctor__417 = (ReturnMode){ .tag = TAG_ReturnMode_OwnedResult_ReturnMode };
    ctor__418 = (FfiSig){ .tag = TAG_FfiSig_FfiSig_FfiSig, .payload.FfiSig = { ._0 = ctor__416, ._1 = ctor__417 } };
    call__419 = Gleamc_dict_insert_String_FfiSig(call__412, str__413, ctor__418);
    str__420 = (GleamcString){ __gl_lit_933764938.bytes, 8 };
    ctor__421 = (ParamMode){ .tag = TAG_ParamMode_Borrow_ParamMode };
    ctor__422 = ({ List_ParamMode* _node = (List_ParamMode*)gleamc_alloc(sizeof(List_ParamMode)); _node->tag = TAG_List_ParamMode_ListEmpty_List_ParamMode; _node; });
    ctor__423 = ({ List_ParamMode* _node = (List_ParamMode*)gleamc_alloc(sizeof(List_ParamMode)); _node->tag = TAG_List_ParamMode_ListCons_List_ParamMode;
        _node->payload.ListCons._0 = ctor__421;
        _node->payload.ListCons._1 = ctor__422;
     _node; });
    ctor__424 = (ReturnMode){ .tag = TAG_ReturnMode_OwnedResult_ReturnMode };
    ctor__425 = (FfiSig){ .tag = TAG_FfiSig_FfiSig_FfiSig, .payload.FfiSig = { ._0 = ctor__423, ._1 = ctor__424 } };
    call__426 = Gleamc_dict_insert_String_FfiSig(call__419, str__420, ctor__425);
    str__427 = (GleamcString){ __gl_lit_339068853.bytes, 17 };
    ctor__428 = (ParamMode){ .tag = TAG_ParamMode_Borrow_ParamMode };
    ctor__429 = ({ List_ParamMode* _node = (List_ParamMode*)gleamc_alloc(sizeof(List_ParamMode)); _node->tag = TAG_List_ParamMode_ListEmpty_List_ParamMode; _node; });
    ctor__430 = ({ List_ParamMode* _node = (List_ParamMode*)gleamc_alloc(sizeof(List_ParamMode)); _node->tag = TAG_List_ParamMode_ListCons_List_ParamMode;
        _node->payload.ListCons._0 = ctor__428;
        _node->payload.ListCons._1 = ctor__429;
     _node; });
    ctor__431 = (ReturnMode){ .tag = TAG_ReturnMode_OwnedResult_ReturnMode };
    ctor__432 = (FfiSig){ .tag = TAG_FfiSig_FfiSig_FfiSig, .payload.FfiSig = { ._0 = ctor__430, ._1 = ctor__431 } };
    call__433 = Gleamc_dict_insert_String_FfiSig(call__426, str__427, ctor__432);
    str__434 = (GleamcString){ __gl_lit_129118482.bytes, 7 };
    ctor__435 = (ParamMode){ .tag = TAG_ParamMode_Borrow_ParamMode };
    ctor__436 = ({ List_ParamMode* _node = (List_ParamMode*)gleamc_alloc(sizeof(List_ParamMode)); _node->tag = TAG_List_ParamMode_ListEmpty_List_ParamMode; _node; });
    ctor__437 = ({ List_ParamMode* _node = (List_ParamMode*)gleamc_alloc(sizeof(List_ParamMode)); _node->tag = TAG_List_ParamMode_ListCons_List_ParamMode;
        _node->payload.ListCons._0 = ctor__435;
        _node->payload.ListCons._1 = ctor__436;
     _node; });
    ctor__438 = (ReturnMode){ .tag = TAG_ReturnMode_OwnedResult_ReturnMode };
    ctor__439 = (FfiSig){ .tag = TAG_FfiSig_FfiSig_FfiSig, .payload.FfiSig = { ._0 = ctor__437, ._1 = ctor__438 } };
    call__440 = Gleamc_dict_insert_String_FfiSig(call__433, str__434, ctor__439);
    str__441 = (GleamcString){ __gl_lit_267316005.bytes, 8 };
    ctor__442 = (ParamMode){ .tag = TAG_ParamMode_Borrow_ParamMode };
    ctor__443 = (ParamMode){ .tag = TAG_ParamMode_Borrow_ParamMode };
    ctor__444 = ({ List_ParamMode* _node = (List_ParamMode*)gleamc_alloc(sizeof(List_ParamMode)); _node->tag = TAG_List_ParamMode_ListEmpty_List_ParamMode; _node; });
    ctor__445 = ({ List_ParamMode* _node = (List_ParamMode*)gleamc_alloc(sizeof(List_ParamMode)); _node->tag = TAG_List_ParamMode_ListCons_List_ParamMode;
        _node->payload.ListCons._0 = ctor__443;
        _node->payload.ListCons._1 = ctor__444;
     _node; });
    ctor__446 = ({ List_ParamMode* _node = (List_ParamMode*)gleamc_alloc(sizeof(List_ParamMode)); _node->tag = TAG_List_ParamMode_ListCons_List_ParamMode;
        _node->payload.ListCons._0 = ctor__442;
        _node->payload.ListCons._1 = ctor__445;
     _node; });
    ctor__447 = (ReturnMode){ .tag = TAG_ReturnMode_OwnedResult_ReturnMode };
    ctor__448 = (FfiSig){ .tag = TAG_FfiSig_FfiSig_FfiSig, .payload.FfiSig = { ._0 = ctor__446, ._1 = ctor__447 } };
    call__449 = Gleamc_dict_insert_String_FfiSig(call__440, str__441, ctor__448);
    str__450 = (GleamcString){ __gl_lit_958313249.bytes, 9 };
    ctor__451 = (ParamMode){ .tag = TAG_ParamMode_Borrow_ParamMode };
    ctor__452 = (ParamMode){ .tag = TAG_ParamMode_Borrow_ParamMode };
    ctor__453 = ({ List_ParamMode* _node = (List_ParamMode*)gleamc_alloc(sizeof(List_ParamMode)); _node->tag = TAG_List_ParamMode_ListEmpty_List_ParamMode; _node; });
    ctor__454 = ({ List_ParamMode* _node = (List_ParamMode*)gleamc_alloc(sizeof(List_ParamMode)); _node->tag = TAG_List_ParamMode_ListCons_List_ParamMode;
        _node->payload.ListCons._0 = ctor__452;
        _node->payload.ListCons._1 = ctor__453;
     _node; });
    ctor__455 = ({ List_ParamMode* _node = (List_ParamMode*)gleamc_alloc(sizeof(List_ParamMode)); _node->tag = TAG_List_ParamMode_ListCons_List_ParamMode;
        _node->payload.ListCons._0 = ctor__451;
        _node->payload.ListCons._1 = ctor__454;
     _node; });
    ctor__456 = (ReturnMode){ .tag = TAG_ReturnMode_OwnedResult_ReturnMode };
    ctor__457 = (FfiSig){ .tag = TAG_FfiSig_FfiSig_FfiSig, .payload.FfiSig = { ._0 = ctor__455, ._1 = ctor__456 } };
    call__458 = Gleamc_dict_insert_String_FfiSig(call__449, str__450, ctor__457);
    str__459 = (GleamcString){ __gl_lit_62530741.bytes, 9 };
    ctor__460 = (ParamMode){ .tag = TAG_ParamMode_Borrow_ParamMode };
    ctor__461 = ({ List_ParamMode* _node = (List_ParamMode*)gleamc_alloc(sizeof(List_ParamMode)); _node->tag = TAG_List_ParamMode_ListEmpty_List_ParamMode; _node; });
    ctor__462 = ({ List_ParamMode* _node = (List_ParamMode*)gleamc_alloc(sizeof(List_ParamMode)); _node->tag = TAG_List_ParamMode_ListCons_List_ParamMode;
        _node->payload.ListCons._0 = ctor__460;
        _node->payload.ListCons._1 = ctor__461;
     _node; });
    ctor__463 = (ReturnMode){ .tag = TAG_ReturnMode_OwnedResult_ReturnMode };
    ctor__464 = (FfiSig){ .tag = TAG_FfiSig_FfiSig_FfiSig, .payload.FfiSig = { ._0 = ctor__462, ._1 = ctor__463 } };
    call__465 = Gleamc_dict_insert_String_FfiSig(call__458, str__459, ctor__464);
    str__466 = (GleamcString){ __gl_lit_934029894.bytes, 19 };
    ctor__467 = (ParamMode){ .tag = TAG_ParamMode_Borrow_ParamMode };
    ctor__468 = ({ List_ParamMode* _node = (List_ParamMode*)gleamc_alloc(sizeof(List_ParamMode)); _node->tag = TAG_List_ParamMode_ListEmpty_List_ParamMode; _node; });
    ctor__469 = ({ List_ParamMode* _node = (List_ParamMode*)gleamc_alloc(sizeof(List_ParamMode)); _node->tag = TAG_List_ParamMode_ListCons_List_ParamMode;
        _node->payload.ListCons._0 = ctor__467;
        _node->payload.ListCons._1 = ctor__468;
     _node; });
    ctor__470 = (ReturnMode){ .tag = TAG_ReturnMode_OwnedResult_ReturnMode };
    ctor__471 = (FfiSig){ .tag = TAG_FfiSig_FfiSig_FfiSig, .payload.FfiSig = { ._0 = ctor__469, ._1 = ctor__470 } };
    call__472 = Gleamc_dict_insert_String_FfiSig(call__465, str__466, ctor__471);
    str__473 = (GleamcString){ __gl_lit_207361197.bytes, 14 };
    ctor__474 = (ParamMode){ .tag = TAG_ParamMode_Borrow_ParamMode };
    ctor__475 = ({ List_ParamMode* _node = (List_ParamMode*)gleamc_alloc(sizeof(List_ParamMode)); _node->tag = TAG_List_ParamMode_ListEmpty_List_ParamMode; _node; });
    ctor__476 = ({ List_ParamMode* _node = (List_ParamMode*)gleamc_alloc(sizeof(List_ParamMode)); _node->tag = TAG_List_ParamMode_ListCons_List_ParamMode;
        _node->payload.ListCons._0 = ctor__474;
        _node->payload.ListCons._1 = ctor__475;
     _node; });
    ctor__477 = (ReturnMode){ .tag = TAG_ReturnMode_OwnedResult_ReturnMode };
    ctor__478 = (FfiSig){ .tag = TAG_FfiSig_FfiSig_FfiSig, .payload.FfiSig = { ._0 = ctor__476, ._1 = ctor__477 } };
    call__479 = Gleamc_dict_insert_String_FfiSig(call__472, str__473, ctor__478);
    str__480 = (GleamcString){ __gl_lit_124106082.bytes, 9 };
    ctor__481 = (ParamMode){ .tag = TAG_ParamMode_Borrow_ParamMode };
    ctor__482 = ({ List_ParamMode* _node = (List_ParamMode*)gleamc_alloc(sizeof(List_ParamMode)); _node->tag = TAG_List_ParamMode_ListEmpty_List_ParamMode; _node; });
    ctor__483 = ({ List_ParamMode* _node = (List_ParamMode*)gleamc_alloc(sizeof(List_ParamMode)); _node->tag = TAG_List_ParamMode_ListCons_List_ParamMode;
        _node->payload.ListCons._0 = ctor__481;
        _node->payload.ListCons._1 = ctor__482;
     _node; });
    ctor__484 = (ReturnMode){ .tag = TAG_ReturnMode_OwnedResult_ReturnMode };
    ctor__485 = (FfiSig){ .tag = TAG_FfiSig_FfiSig_FfiSig, .payload.FfiSig = { ._0 = ctor__483, ._1 = ctor__484 } };
    call__486 = Gleamc_dict_insert_String_FfiSig(call__479, str__480, ctor__485);
    str__487 = (GleamcString){ __gl_lit_53357054.bytes, 10 };
    ctor__488 = (ParamMode){ .tag = TAG_ParamMode_Borrow_ParamMode };
    ctor__489 = ({ List_ParamMode* _node = (List_ParamMode*)gleamc_alloc(sizeof(List_ParamMode)); _node->tag = TAG_List_ParamMode_ListEmpty_List_ParamMode; _node; });
    ctor__490 = ({ List_ParamMode* _node = (List_ParamMode*)gleamc_alloc(sizeof(List_ParamMode)); _node->tag = TAG_List_ParamMode_ListCons_List_ParamMode;
        _node->payload.ListCons._0 = ctor__488;
        _node->payload.ListCons._1 = ctor__489;
     _node; });
    ctor__491 = (ReturnMode){ .tag = TAG_ReturnMode_OwnedResult_ReturnMode };
    ctor__492 = (FfiSig){ .tag = TAG_FfiSig_FfiSig_FfiSig, .payload.FfiSig = { ._0 = ctor__490, ._1 = ctor__491 } };
    call__493 = Gleamc_dict_insert_String_FfiSig(call__486, str__487, ctor__492);
    str__494 = (GleamcString){ __gl_lit_316285779.bytes, 15 };
    ctor__495 = (ParamMode){ .tag = TAG_ParamMode_Borrow_ParamMode };
    ctor__496 = ({ List_ParamMode* _node = (List_ParamMode*)gleamc_alloc(sizeof(List_ParamMode)); _node->tag = TAG_List_ParamMode_ListEmpty_List_ParamMode; _node; });
    ctor__497 = ({ List_ParamMode* _node = (List_ParamMode*)gleamc_alloc(sizeof(List_ParamMode)); _node->tag = TAG_List_ParamMode_ListCons_List_ParamMode;
        _node->payload.ListCons._0 = ctor__495;
        _node->payload.ListCons._1 = ctor__496;
     _node; });
    ctor__498 = (ReturnMode){ .tag = TAG_ReturnMode_OwnedResult_ReturnMode };
    ctor__499 = (FfiSig){ .tag = TAG_FfiSig_FfiSig_FfiSig, .payload.FfiSig = { ._0 = ctor__497, ._1 = ctor__498 } };
    call__500 = Gleamc_dict_insert_String_FfiSig(call__493, str__494, ctor__499);
    str__501 = (GleamcString){ __gl_lit_433928346.bytes, 12 };
    ctor__502 = (ParamMode){ .tag = TAG_ParamMode_Borrow_ParamMode };
    ctor__503 = ({ List_ParamMode* _node = (List_ParamMode*)gleamc_alloc(sizeof(List_ParamMode)); _node->tag = TAG_List_ParamMode_ListEmpty_List_ParamMode; _node; });
    ctor__504 = ({ List_ParamMode* _node = (List_ParamMode*)gleamc_alloc(sizeof(List_ParamMode)); _node->tag = TAG_List_ParamMode_ListCons_List_ParamMode;
        _node->payload.ListCons._0 = ctor__502;
        _node->payload.ListCons._1 = ctor__503;
     _node; });
    ctor__505 = (ReturnMode){ .tag = TAG_ReturnMode_OwnedResult_ReturnMode };
    ctor__506 = (FfiSig){ .tag = TAG_FfiSig_FfiSig_FfiSig, .payload.FfiSig = { ._0 = ctor__504, ._1 = ctor__505 } };
    call__507 = Gleamc_dict_insert_String_FfiSig(call__500, str__501, ctor__506);
    str__508 = (GleamcString){ __gl_lit_843024696.bytes, 20 };
    ctor__509 = ({ List_ParamMode* _node = (List_ParamMode*)gleamc_alloc(sizeof(List_ParamMode)); _node->tag = TAG_List_ParamMode_ListEmpty_List_ParamMode; _node; });
    ctor__510 = (ReturnMode){ .tag = TAG_ReturnMode_OwnedResult_ReturnMode };
    ctor__511 = (FfiSig){ .tag = TAG_FfiSig_FfiSig_FfiSig, .payload.FfiSig = { ._0 = ctor__509, ._1 = ctor__510 } };
    call__512 = Gleamc_dict_insert_String_FfiSig(call__507, str__508, ctor__511);
    str__513 = (GleamcString){ __gl_lit_44017804.bytes, 17 };
    ctor__514 = (ParamMode){ .tag = TAG_ParamMode_Borrow_ParamMode };
    ctor__515 = ({ List_ParamMode* _node = (List_ParamMode*)gleamc_alloc(sizeof(List_ParamMode)); _node->tag = TAG_List_ParamMode_ListEmpty_List_ParamMode; _node; });
    ctor__516 = ({ List_ParamMode* _node = (List_ParamMode*)gleamc_alloc(sizeof(List_ParamMode)); _node->tag = TAG_List_ParamMode_ListCons_List_ParamMode;
        _node->payload.ListCons._0 = ctor__514;
        _node->payload.ListCons._1 = ctor__515;
     _node; });
    ctor__517 = (ReturnMode){ .tag = TAG_ReturnMode_OwnedResult_ReturnMode };
    ctor__518 = (FfiSig){ .tag = TAG_FfiSig_FfiSig_FfiSig, .payload.FfiSig = { ._0 = ctor__516, ._1 = ctor__517 } };
    call__519 = Gleamc_dict_insert_String_FfiSig(call__512, str__513, ctor__518);
    str__520 = (GleamcString){ __gl_lit_433573771.bytes, 12 };
    ctor__521 = (ParamMode){ .tag = TAG_ParamMode_Borrow_ParamMode };
    ctor__522 = ({ List_ParamMode* _node = (List_ParamMode*)gleamc_alloc(sizeof(List_ParamMode)); _node->tag = TAG_List_ParamMode_ListEmpty_List_ParamMode; _node; });
    ctor__523 = ({ List_ParamMode* _node = (List_ParamMode*)gleamc_alloc(sizeof(List_ParamMode)); _node->tag = TAG_List_ParamMode_ListCons_List_ParamMode;
        _node->payload.ListCons._0 = ctor__521;
        _node->payload.ListCons._1 = ctor__522;
     _node; });
    ctor__524 = (ReturnMode){ .tag = TAG_ReturnMode_OwnedResult_ReturnMode };
    ctor__525 = (FfiSig){ .tag = TAG_FfiSig_FfiSig_FfiSig, .payload.FfiSig = { ._0 = ctor__523, ._1 = ctor__524 } };
    call__526 = Gleamc_dict_insert_String_FfiSig(call__519, str__520, ctor__525);
    str__527 = (GleamcString){ __gl_lit_702972426.bytes, 12 };
    ctor__528 = (ParamMode){ .tag = TAG_ParamMode_Borrow_ParamMode };
    ctor__529 = ({ List_ParamMode* _node = (List_ParamMode*)gleamc_alloc(sizeof(List_ParamMode)); _node->tag = TAG_List_ParamMode_ListEmpty_List_ParamMode; _node; });
    ctor__530 = ({ List_ParamMode* _node = (List_ParamMode*)gleamc_alloc(sizeof(List_ParamMode)); _node->tag = TAG_List_ParamMode_ListCons_List_ParamMode;
        _node->payload.ListCons._0 = ctor__528;
        _node->payload.ListCons._1 = ctor__529;
     _node; });
    ctor__531 = (ReturnMode){ .tag = TAG_ReturnMode_OwnedResult_ReturnMode };
    ctor__532 = (FfiSig){ .tag = TAG_FfiSig_FfiSig_FfiSig, .payload.FfiSig = { ._0 = ctor__530, ._1 = ctor__531 } };
    call__533 = Gleamc_dict_insert_String_FfiSig(call__526, str__527, ctor__532);
    str__534 = (GleamcString){ __gl_lit_610493530.bytes, 9 };
    ctor__535 = (ParamMode){ .tag = TAG_ParamMode_Borrow_ParamMode };
    ctor__536 = (ParamMode){ .tag = TAG_ParamMode_Borrow_ParamMode };
    ctor__537 = ({ List_ParamMode* _node = (List_ParamMode*)gleamc_alloc(sizeof(List_ParamMode)); _node->tag = TAG_List_ParamMode_ListEmpty_List_ParamMode; _node; });
    ctor__538 = ({ List_ParamMode* _node = (List_ParamMode*)gleamc_alloc(sizeof(List_ParamMode)); _node->tag = TAG_List_ParamMode_ListCons_List_ParamMode;
        _node->payload.ListCons._0 = ctor__536;
        _node->payload.ListCons._1 = ctor__537;
     _node; });
    ctor__539 = ({ List_ParamMode* _node = (List_ParamMode*)gleamc_alloc(sizeof(List_ParamMode)); _node->tag = TAG_List_ParamMode_ListCons_List_ParamMode;
        _node->payload.ListCons._0 = ctor__535;
        _node->payload.ListCons._1 = ctor__538;
     _node; });
    ctor__540 = (ReturnMode){ .tag = TAG_ReturnMode_OwnedResult_ReturnMode };
    ctor__541 = (FfiSig){ .tag = TAG_FfiSig_FfiSig_FfiSig, .payload.FfiSig = { ._0 = ctor__539, ._1 = ctor__540 } };
    call__542 = Gleamc_dict_insert_String_FfiSig(call__533, str__534, ctor__541);
    str__543 = (GleamcString){ __gl_lit_219667599.bytes, 10 };
    ctor__544 = (ParamMode){ .tag = TAG_ParamMode_Borrow_ParamMode };
    ctor__545 = (ParamMode){ .tag = TAG_ParamMode_Borrow_ParamMode };
    ctor__546 = ({ List_ParamMode* _node = (List_ParamMode*)gleamc_alloc(sizeof(List_ParamMode)); _node->tag = TAG_List_ParamMode_ListEmpty_List_ParamMode; _node; });
    ctor__547 = ({ List_ParamMode* _node = (List_ParamMode*)gleamc_alloc(sizeof(List_ParamMode)); _node->tag = TAG_List_ParamMode_ListCons_List_ParamMode;
        _node->payload.ListCons._0 = ctor__545;
        _node->payload.ListCons._1 = ctor__546;
     _node; });
    ctor__548 = ({ List_ParamMode* _node = (List_ParamMode*)gleamc_alloc(sizeof(List_ParamMode)); _node->tag = TAG_List_ParamMode_ListCons_List_ParamMode;
        _node->payload.ListCons._0 = ctor__544;
        _node->payload.ListCons._1 = ctor__547;
     _node; });
    ctor__549 = (ReturnMode){ .tag = TAG_ReturnMode_OwnedResult_ReturnMode };
    ctor__550 = (FfiSig){ .tag = TAG_FfiSig_FfiSig_FfiSig, .payload.FfiSig = { ._0 = ctor__548, ._1 = ctor__549 } };
    call__551 = Gleamc_dict_insert_String_FfiSig(call__542, str__543, ctor__550);
    str__552 = (GleamcString){ __gl_lit_128907652.bytes, 7 };
    ctor__553 = (ParamMode){ .tag = TAG_ParamMode_Borrow_ParamMode };
    ctor__554 = (ParamMode){ .tag = TAG_ParamMode_Borrow_ParamMode };
    ctor__555 = ({ List_ParamMode* _node = (List_ParamMode*)gleamc_alloc(sizeof(List_ParamMode)); _node->tag = TAG_List_ParamMode_ListEmpty_List_ParamMode; _node; });
    ctor__556 = ({ List_ParamMode* _node = (List_ParamMode*)gleamc_alloc(sizeof(List_ParamMode)); _node->tag = TAG_List_ParamMode_ListCons_List_ParamMode;
        _node->payload.ListCons._0 = ctor__554;
        _node->payload.ListCons._1 = ctor__555;
     _node; });
    ctor__557 = ({ List_ParamMode* _node = (List_ParamMode*)gleamc_alloc(sizeof(List_ParamMode)); _node->tag = TAG_List_ParamMode_ListCons_List_ParamMode;
        _node->payload.ListCons._0 = ctor__553;
        _node->payload.ListCons._1 = ctor__556;
     _node; });
    ctor__558 = (ReturnMode){ .tag = TAG_ReturnMode_OwnedResult_ReturnMode };
    ctor__559 = (FfiSig){ .tag = TAG_FfiSig_FfiSig_FfiSig, .payload.FfiSig = { ._0 = ctor__557, ._1 = ctor__558 } };
    call__560 = Gleamc_dict_insert_String_FfiSig(call__551, str__552, ctor__559);
    str__561 = (GleamcString){ __gl_lit_263662941.bytes, 8 };
    ctor__562 = (ParamMode){ .tag = TAG_ParamMode_Borrow_ParamMode };
    ctor__563 = ({ List_ParamMode* _node = (List_ParamMode*)gleamc_alloc(sizeof(List_ParamMode)); _node->tag = TAG_List_ParamMode_ListEmpty_List_ParamMode; _node; });
    ctor__564 = ({ List_ParamMode* _node = (List_ParamMode*)gleamc_alloc(sizeof(List_ParamMode)); _node->tag = TAG_List_ParamMode_ListCons_List_ParamMode;
        _node->payload.ListCons._0 = ctor__562;
        _node->payload.ListCons._1 = ctor__563;
     _node; });
    ctor__565 = (ReturnMode){ .tag = TAG_ReturnMode_OwnedResult_ReturnMode };
    ctor__566 = (FfiSig){ .tag = TAG_FfiSig_FfiSig_FfiSig, .payload.FfiSig = { ._0 = ctor__564, ._1 = ctor__565 } };
    call__567 = Gleamc_dict_insert_String_FfiSig(call__560, str__561, ctor__566);
    str__568 = (GleamcString){ __gl_lit_331841931.bytes, 11 };
    ctor__569 = (ParamMode){ .tag = TAG_ParamMode_Borrow_ParamMode };
    ctor__570 = ({ List_ParamMode* _node = (List_ParamMode*)gleamc_alloc(sizeof(List_ParamMode)); _node->tag = TAG_List_ParamMode_ListEmpty_List_ParamMode; _node; });
    ctor__571 = ({ List_ParamMode* _node = (List_ParamMode*)gleamc_alloc(sizeof(List_ParamMode)); _node->tag = TAG_List_ParamMode_ListCons_List_ParamMode;
        _node->payload.ListCons._0 = ctor__569;
        _node->payload.ListCons._1 = ctor__570;
     _node; });
    ctor__572 = (ReturnMode){ .tag = TAG_ReturnMode_OwnedResult_ReturnMode };
    ctor__573 = (FfiSig){ .tag = TAG_FfiSig_FfiSig_FfiSig, .payload.FfiSig = { ._0 = ctor__571, ._1 = ctor__572 } };
    call__574 = Gleamc_dict_insert_String_FfiSig(call__567, str__568, ctor__573);
    str__575 = (GleamcString){ __gl_lit_243242405.bytes, 8 };
    ctor__576 = (ParamMode){ .tag = TAG_ParamMode_Borrow_ParamMode };
    ctor__577 = (ParamMode){ .tag = TAG_ParamMode_Borrow_ParamMode };
    ctor__578 = ({ List_ParamMode* _node = (List_ParamMode*)gleamc_alloc(sizeof(List_ParamMode)); _node->tag = TAG_List_ParamMode_ListEmpty_List_ParamMode; _node; });
    ctor__579 = ({ List_ParamMode* _node = (List_ParamMode*)gleamc_alloc(sizeof(List_ParamMode)); _node->tag = TAG_List_ParamMode_ListCons_List_ParamMode;
        _node->payload.ListCons._0 = ctor__577;
        _node->payload.ListCons._1 = ctor__578;
     _node; });
    ctor__580 = ({ List_ParamMode* _node = (List_ParamMode*)gleamc_alloc(sizeof(List_ParamMode)); _node->tag = TAG_List_ParamMode_ListCons_List_ParamMode;
        _node->payload.ListCons._0 = ctor__576;
        _node->payload.ListCons._1 = ctor__579;
     _node; });
    ctor__581 = (ReturnMode){ .tag = TAG_ReturnMode_OwnedResult_ReturnMode };
    ctor__582 = (FfiSig){ .tag = TAG_FfiSig_FfiSig_FfiSig, .payload.FfiSig = { ._0 = ctor__580, ._1 = ctor__581 } };
    call__583 = Gleamc_dict_insert_String_FfiSig(call__574, str__575, ctor__582);
    str__584 = (GleamcString){ __gl_lit_66443176.bytes, 11 };
    ctor__585 = (ParamMode){ .tag = TAG_ParamMode_Borrow_ParamMode };
    ctor__586 = (ParamMode){ .tag = TAG_ParamMode_Borrow_ParamMode };
    ctor__587 = ({ List_ParamMode* _node = (List_ParamMode*)gleamc_alloc(sizeof(List_ParamMode)); _node->tag = TAG_List_ParamMode_ListEmpty_List_ParamMode; _node; });
    ctor__588 = ({ List_ParamMode* _node = (List_ParamMode*)gleamc_alloc(sizeof(List_ParamMode)); _node->tag = TAG_List_ParamMode_ListCons_List_ParamMode;
        _node->payload.ListCons._0 = ctor__586;
        _node->payload.ListCons._1 = ctor__587;
     _node; });
    ctor__589 = ({ List_ParamMode* _node = (List_ParamMode*)gleamc_alloc(sizeof(List_ParamMode)); _node->tag = TAG_List_ParamMode_ListCons_List_ParamMode;
        _node->payload.ListCons._0 = ctor__585;
        _node->payload.ListCons._1 = ctor__588;
     _node; });
    ctor__590 = (ReturnMode){ .tag = TAG_ReturnMode_OwnedResult_ReturnMode };
    ctor__591 = (FfiSig){ .tag = TAG_FfiSig_FfiSig_FfiSig, .payload.FfiSig = { ._0 = ctor__589, ._1 = ctor__590 } };
    call__592 = Gleamc_dict_insert_String_FfiSig(call__583, str__584, ctor__591);
    str__593 = (GleamcString){ __gl_lit_877066990.bytes, 14 };
    ctor__594 = (ParamMode){ .tag = TAG_ParamMode_Borrow_ParamMode };
    ctor__595 = ({ List_ParamMode* _node = (List_ParamMode*)gleamc_alloc(sizeof(List_ParamMode)); _node->tag = TAG_List_ParamMode_ListEmpty_List_ParamMode; _node; });
    ctor__596 = ({ List_ParamMode* _node = (List_ParamMode*)gleamc_alloc(sizeof(List_ParamMode)); _node->tag = TAG_List_ParamMode_ListCons_List_ParamMode;
        _node->payload.ListCons._0 = ctor__594;
        _node->payload.ListCons._1 = ctor__595;
     _node; });
    ctor__597 = (ReturnMode){ .tag = TAG_ReturnMode_OwnedResult_ReturnMode };
    ctor__598 = (FfiSig){ .tag = TAG_FfiSig_FfiSig_FfiSig, .payload.FfiSig = { ._0 = ctor__596, ._1 = ctor__597 } };
    call__599 = Gleamc_dict_insert_String_FfiSig(call__592, str__593, ctor__598);
    str__600 = (GleamcString){ __gl_lit_877636174.bytes, 14 };
    ctor__601 = (ParamMode){ .tag = TAG_ParamMode_Borrow_ParamMode };
    ctor__602 = ({ List_ParamMode* _node = (List_ParamMode*)gleamc_alloc(sizeof(List_ParamMode)); _node->tag = TAG_List_ParamMode_ListEmpty_List_ParamMode; _node; });
    ctor__603 = ({ List_ParamMode* _node = (List_ParamMode*)gleamc_alloc(sizeof(List_ParamMode)); _node->tag = TAG_List_ParamMode_ListCons_List_ParamMode;
        _node->payload.ListCons._0 = ctor__601;
        _node->payload.ListCons._1 = ctor__602;
     _node; });
    ctor__604 = (ReturnMode){ .tag = TAG_ReturnMode_OwnedResult_ReturnMode };
    ctor__605 = (FfiSig){ .tag = TAG_FfiSig_FfiSig_FfiSig, .payload.FfiSig = { ._0 = ctor__603, ._1 = ctor__604 } };
    call__606 = Gleamc_dict_insert_String_FfiSig(call__599, str__600, ctor__605);
    str__607 = (GleamcString){ __gl_lit_877088205.bytes, 14 };
    ctor__608 = (ParamMode){ .tag = TAG_ParamMode_Borrow_ParamMode };
    ctor__609 = ({ List_ParamMode* _node = (List_ParamMode*)gleamc_alloc(sizeof(List_ParamMode)); _node->tag = TAG_List_ParamMode_ListEmpty_List_ParamMode; _node; });
    ctor__610 = ({ List_ParamMode* _node = (List_ParamMode*)gleamc_alloc(sizeof(List_ParamMode)); _node->tag = TAG_List_ParamMode_ListCons_List_ParamMode;
        _node->payload.ListCons._0 = ctor__608;
        _node->payload.ListCons._1 = ctor__609;
     _node; });
    ctor__611 = (ReturnMode){ .tag = TAG_ReturnMode_OwnedResult_ReturnMode };
    ctor__612 = (FfiSig){ .tag = TAG_FfiSig_FfiSig_FfiSig, .payload.FfiSig = { ._0 = ctor__610, ._1 = ctor__611 } };
    call__613 = Gleamc_dict_insert_String_FfiSig(call__606, str__607, ctor__612);
    Gleamc_Rc_drop_Dict_String_FfiSig(call__0);
    Gleamc_Rc_drop_Dict_String_FfiSig(call__7);
    Gleamc_Rc_drop_Dict_String_FfiSig(call__14);
    Gleamc_Rc_drop_Dict_String_FfiSig(call__21);
    Gleamc_Rc_drop_Dict_String_FfiSig(call__28);
    Gleamc_Rc_drop_Dict_String_FfiSig(call__35);
    Gleamc_Rc_drop_Dict_String_FfiSig(call__42);
    Gleamc_Rc_drop_Dict_String_FfiSig(call__51);
    Gleamc_Rc_drop_Dict_String_FfiSig(call__60);
    Gleamc_Rc_drop_Dict_String_FfiSig(call__67);
    Gleamc_Rc_drop_Dict_String_FfiSig(call__76);
    Gleamc_Rc_drop_Dict_String_FfiSig(call__85);
    Gleamc_Rc_drop_Dict_String_FfiSig(call__92);
    Gleamc_Rc_drop_Dict_String_FfiSig(call__99);
    Gleamc_Rc_drop_Dict_String_FfiSig(call__106);
    Gleamc_Rc_drop_Dict_String_FfiSig(call__113);
    Gleamc_Rc_drop_Dict_String_FfiSig(call__120);
    Gleamc_Rc_drop_Dict_String_FfiSig(call__129);
    Gleamc_Rc_drop_Dict_String_FfiSig(call__136);
    Gleamc_Rc_drop_Dict_String_FfiSig(call__143);
    Gleamc_Rc_drop_Dict_String_FfiSig(call__150);
    Gleamc_Rc_drop_Dict_String_FfiSig(call__159);
    Gleamc_Rc_drop_Dict_String_FfiSig(call__168);
    Gleamc_Rc_drop_Dict_String_FfiSig(call__177);
    Gleamc_Rc_drop_Dict_String_FfiSig(call__184);
    Gleamc_Rc_drop_Dict_String_FfiSig(call__193);
    Gleamc_Rc_drop_Dict_String_FfiSig(call__202);
    Gleamc_Rc_drop_Dict_String_FfiSig(call__211);
    Gleamc_Rc_drop_Dict_String_FfiSig(call__218);
    Gleamc_Rc_drop_Dict_String_FfiSig(call__227);
    Gleamc_Rc_drop_Dict_String_FfiSig(call__236);
    Gleamc_Rc_drop_Dict_String_FfiSig(call__243);
    Gleamc_Rc_drop_Dict_String_FfiSig(call__252);
    Gleamc_Rc_drop_Dict_String_FfiSig(call__261);
    Gleamc_Rc_drop_Dict_String_FfiSig(call__270);
    Gleamc_Rc_drop_Dict_String_FfiSig(call__277);
    Gleamc_Rc_drop_Dict_String_FfiSig(call__284);
    Gleamc_Rc_drop_Dict_String_FfiSig(call__291);
    Gleamc_Rc_drop_Dict_String_FfiSig(call__302);
    Gleamc_Rc_drop_Dict_String_FfiSig(call__309);
    Gleamc_Rc_drop_Dict_String_FfiSig(call__320);
    Gleamc_Rc_drop_Dict_String_FfiSig(call__327);
    Gleamc_Rc_drop_Dict_String_FfiSig(call__336);
    Gleamc_Rc_drop_Dict_String_FfiSig(call__343);
    Gleamc_Rc_drop_Dict_String_FfiSig(call__350);
    Gleamc_Rc_drop_Dict_String_FfiSig(call__357);
    Gleamc_Rc_drop_Dict_String_FfiSig(call__364);
    Gleamc_Rc_drop_Dict_String_FfiSig(call__371);
    Gleamc_Rc_drop_Dict_String_FfiSig(call__378);
    Gleamc_Rc_drop_Dict_String_FfiSig(call__387);
    Gleamc_Rc_drop_Dict_String_FfiSig(call__396);
    Gleamc_Rc_drop_Dict_String_FfiSig(call__403);
    Gleamc_Rc_drop_Dict_String_FfiSig(call__412);
    Gleamc_Rc_drop_Dict_String_FfiSig(call__419);
    Gleamc_Rc_drop_Dict_String_FfiSig(call__426);
    Gleamc_Rc_drop_Dict_String_FfiSig(call__433);
    Gleamc_Rc_drop_Dict_String_FfiSig(call__440);
    Gleamc_Rc_drop_Dict_String_FfiSig(call__449);
    Gleamc_Rc_drop_Dict_String_FfiSig(call__458);
    Gleamc_Rc_drop_Dict_String_FfiSig(call__465);
    Gleamc_Rc_drop_Dict_String_FfiSig(call__472);
    Gleamc_Rc_drop_Dict_String_FfiSig(call__479);
    Gleamc_Rc_drop_Dict_String_FfiSig(call__486);
    Gleamc_Rc_drop_Dict_String_FfiSig(call__493);
    Gleamc_Rc_drop_Dict_String_FfiSig(call__500);
    Gleamc_Rc_drop_Dict_String_FfiSig(call__507);
    Gleamc_Rc_drop_Dict_String_FfiSig(call__512);
    Gleamc_Rc_drop_Dict_String_FfiSig(call__519);
    Gleamc_Rc_drop_Dict_String_FfiSig(call__526);
    Gleamc_Rc_drop_Dict_String_FfiSig(call__533);
    Gleamc_Rc_drop_Dict_String_FfiSig(call__542);
    Gleamc_Rc_drop_Dict_String_FfiSig(call__551);
    Gleamc_Rc_drop_Dict_String_FfiSig(call__560);
    Gleamc_Rc_drop_Dict_String_FfiSig(call__567);
    Gleamc_Rc_drop_Dict_String_FfiSig(call__574);
    Gleamc_Rc_drop_Dict_String_FfiSig(call__583);
    Gleamc_Rc_drop_Dict_String_FfiSig(call__592);
    Gleamc_Rc_drop_Dict_String_FfiSig(call__599);
    Gleamc_Rc_drop_Dict_String_FfiSig(call__606);
    return call__613;
}

int64_t Gleamc_list_sum(List_Int* list) {
    int64_t res__0;
    bool tagis__7;
    int64_t field__9;
    List_Int* field__11;
    int64_t call__12;
    int64_t binop__13;
    bool tagis__14;
entry:

    goto arm_test_b3;
arm_test_b3:
    tagis__7 = (list->tag == TAG_List_Int_ListCons_List_Int);
    if (tagis__7) { goto ctor_ok_b8; } else { goto arm_test_b5; }
ctor_ok_b8:
    field__9 = list->payload.ListCons._0;
    goto ctor_next_b10;
ctor_next_b10:
    field__11 = list->payload.ListCons._1;
    Gleamc_Rc_retain_List_Int(field__11);
    goto arm_body_b4;
arm_body_b4:
    call__12 = Gleamc_list_sum(field__11);
    binop__13 = (field__9 + call__12);
    res__0 = binop__13;
    Gleamc_Rc_drop_List_Int(field__11);
    goto case_end_b1;
arm_test_b5:
    tagis__14 = (list->tag == TAG_List_Int_ListEmpty_List_Int);
    if (tagis__14) { goto ctor_ok_b15; } else { goto case_fail_b2; }
ctor_ok_b15:

    goto arm_body_b6;
arm_body_b6:
    res__0 = 0;
    goto case_end_b1;
case_fail_b2:

    abort();
case_end_b1:

    return res__0;
}

Order Gleamc_order_break_tie(Order a, Order b) {
    Order res__0;
    bool tagis__9;
    Order ctor__11;
    bool tagis__12;
    Order ctor__14;
    bool tagis__15;
entry:

    goto arm_test_b3;
arm_test_b3:
    tagis__9 = (a.tag == TAG_Order_Lt_Order);
    if (tagis__9) { goto ctor_ok_b10; } else { goto arm_test_b5; }
ctor_ok_b10:

    goto arm_body_b4;
arm_body_b4:
    ctor__11 = (Order){ .tag = TAG_Order_Lt_Order };
    res__0 = ctor__11;
    goto case_end_b1;
arm_test_b5:
    tagis__12 = (a.tag == TAG_Order_Gt_Order);
    if (tagis__12) { goto ctor_ok_b13; } else { goto arm_test_b7; }
ctor_ok_b13:

    goto arm_body_b6;
arm_body_b6:
    ctor__14 = (Order){ .tag = TAG_Order_Gt_Order };
    res__0 = ctor__14;
    goto case_end_b1;
arm_test_b7:
    tagis__15 = (a.tag == TAG_Order_Eq_Order);
    if (tagis__15) { goto ctor_ok_b16; } else { goto case_fail_b2; }
ctor_ok_b16:

    goto arm_body_b8;
arm_body_b8:
    res__0 = b;
    goto case_end_b1;
case_fail_b2:

    abort();
case_end_b1:

    return res__0;
}

ParamMode Gleamc_mode_at(List_ParamMode* modes, int64_t index) {
    GleamcTuple_List_ParamMode_i64 tuple__0;
    ParamMode res__1;
    List_ParamMode* tget__10;
    bool tagis__12;
    int64_t tget__14;
    ParamMode ctor__15;
    List_ParamMode* tget__16;
    bool tagis__18;
    ParamMode field__20;
    List_ParamMode* field__22;
    int64_t tget__23;
    bool test__24;
    List_ParamMode* tget__25;
    bool tagis__27;
    ParamMode field__29;
    List_ParamMode* field__31;
    int64_t tget__32;
    int64_t binop__33;
    ParamMode call__34;
entry:
    tuple__0 = (GleamcTuple_List_ParamMode_i64){ ._0 = modes, ._1 = index };
    goto arm_test_b4;
arm_test_b4:
    tget__10 = tuple__0._0;
    Gleamc_Rc_retain_List_ParamMode(tget__10);
    tagis__12 = (tget__10->tag == TAG_List_ParamMode_ListEmpty_List_ParamMode);
    Gleamc_Rc_drop_List_ParamMode(tget__10);
    if (tagis__12) { goto ctor_ok_b13; } else { goto arm_test_b6; }
ctor_ok_b13:

    goto tuple_next_b11;
tuple_next_b11:
    tget__14 = tuple__0._1;
    Gleamc_Rc_drop_tuple_List_ParamMode_i64(tuple__0);
    goto arm_body_b5;
arm_body_b5:
    ctor__15 = (ParamMode){ .tag = TAG_ParamMode_Owned_ParamMode };
    res__1 = ctor__15;
    goto case_end_b2;
arm_test_b6:
    tget__16 = tuple__0._0;
    Gleamc_Rc_retain_List_ParamMode(tget__16);
    tagis__18 = (tget__16->tag == TAG_List_ParamMode_ListCons_List_ParamMode);
    if (tagis__18) { goto ctor_ok_b19; } else { goto arm_test_b8; }
ctor_ok_b19:
    field__20 = tget__16->payload.ListCons._0;
    goto ctor_next_b21;
ctor_next_b21:
    field__22 = tget__16->payload.ListCons._1;
    Gleamc_Rc_retain_List_ParamMode(field__22);
    Gleamc_Rc_drop_List_ParamMode(tget__16);
    Gleamc_Rc_drop_List_ParamMode(field__22);
    goto tuple_next_b17;
tuple_next_b17:
    tget__23 = tuple__0._1;
    test__24 = (tget__23 == 0);
    if (test__24) { goto arm_body_b7; } else { goto arm_test_b8; }
arm_body_b7:
    res__1 = field__20;
    Gleamc_Rc_drop_tuple_List_ParamMode_i64(tuple__0);
    goto case_end_b2;
arm_test_b8:
    tget__25 = tuple__0._0;
    Gleamc_Rc_retain_List_ParamMode(tget__25);
    tagis__27 = (tget__25->tag == TAG_List_ParamMode_ListCons_List_ParamMode);
    if (tagis__27) { goto ctor_ok_b28; } else { goto case_fail_b3; }
ctor_ok_b28:
    field__29 = tget__25->payload.ListCons._0;
    goto ctor_next_b30;
ctor_next_b30:
    field__31 = tget__25->payload.ListCons._1;
    Gleamc_Rc_retain_List_ParamMode(field__31);
    Gleamc_Rc_drop_List_ParamMode(tget__25);
    goto tuple_next_b26;
tuple_next_b26:
    tget__32 = tuple__0._1;
    Gleamc_Rc_drop_tuple_List_ParamMode_i64(tuple__0);
    goto arm_body_b9;
arm_body_b9:
    binop__33 = (tget__32 - 1);
    call__34 = Gleamc_mode_at(field__31, binop__33);
    res__1 = call__34;
    goto case_end_b2;
case_fail_b3:
    Gleamc_Rc_drop_tuple_List_ParamMode_i64(tuple__0);
    Gleamc_Rc_drop_List_ParamMode(tget__25);
    abort();
case_end_b2:

    return res__1;
}

Dict_String_FfiSig Gleamc_dict_insert_String_FfiSig(Dict_String_FfiSig dict, GleamcString key, FfiSig value) {
    List_tString_FfiSig* call__0;
    List_tString_FfiSig* call__1;
    Dict_String_FfiSig ctor__2;
entry:
    call__0 = Gleamc_dict_entries_of_String_FfiSig(dict);
    call__1 = Gleamc_dict_insert_entries_String_FfiSig(call__0, key, value);
    ctor__2 = (Dict_String_FfiSig){ .tag = TAG_Dict_String_FfiSig_Dict_Dict_String_FfiSig, .payload.Dict = { ._0 = call__1 } };
    return ctor__2;
}

Dict_String_FfiSig Gleamc_dict_new_String_FfiSig() {
    List_tString_FfiSig* ctor__0;
    Dict_String_FfiSig ctor__1;
entry:
    ctor__0 = ({ List_tString_FfiSig* _node = (List_tString_FfiSig*)gleamc_alloc(sizeof(List_tString_FfiSig)); _node->tag = TAG_List_tString_FfiSig_ListEmpty_List_tString_FfiSig; _node; });
    ctor__1 = (Dict_String_FfiSig){ .tag = TAG_Dict_String_FfiSig_Dict_Dict_String_FfiSig, .payload.Dict = { ._0 = ctor__0 } };
    return ctor__1;
}

List_tString_FfiSig* Gleamc_dict_entries_of_String_FfiSig(Dict_String_FfiSig dict) {
    List_tString_FfiSig* res__0;
    bool tagis__5;
    List_tString_FfiSig* field__7;
entry:

    goto arm_test_b3;
arm_test_b3:
    tagis__5 = (dict.tag == TAG_Dict_String_FfiSig_Dict_Dict_String_FfiSig);
    if (tagis__5) { goto ctor_ok_b6; } else { goto case_fail_b2; }
ctor_ok_b6:
    field__7 = dict.payload.Dict._0;
    Gleamc_Rc_retain_List_tString_FfiSig(field__7);
    goto arm_body_b4;
arm_body_b4:
    res__0 = field__7;
    goto case_end_b1;
case_fail_b2:

    abort();
case_end_b1:

    return res__0;
}

List_tString_FfiSig* Gleamc_dict_insert_entries_String_FfiSig(List_tString_FfiSig* entries, GleamcString key, FfiSig value) {
    List_tString_FfiSig* res__0;
    bool tagis__7;
    GleamcTuple_str_FfiSig tuple__9;
    List_tString_FfiSig* ctor__10;
    List_tString_FfiSig* ctor__11;
    bool tagis__12;
    GleamcTuple_str_FfiSig field__14;
    List_tString_FfiSig* field__16;
    GleamcString tget__17;
    FfiSig tget__18;
    Order call__19;
    List_tString_FfiSig* res__20;
    bool tagis__29;
    GleamcTuple_str_FfiSig tuple__31;
    List_tString_FfiSig* ctor__32;
    bool tagis__33;
    GleamcTuple_str_FfiSig tuple__35;
    List_tString_FfiSig* ctor__36;
    bool tagis__37;
    List_tString_FfiSig* call__39;
    List_tString_FfiSig* ctor__40;
entry:

    goto arm_test_b3;
arm_test_b3:
    tagis__7 = (entries->tag == TAG_List_tString_FfiSig_ListEmpty_List_tString_FfiSig);
    if (tagis__7) { goto ctor_ok_b8; } else { goto arm_test_b5; }
ctor_ok_b8:
    Gleamc_Rc_drop_List_tString_FfiSig(entries);
    goto arm_body_b4;
arm_body_b4:
    tuple__9 = (GleamcTuple_str_FfiSig){ ._0 = key, ._1 = value };
    ctor__10 = ({ List_tString_FfiSig* _node = (List_tString_FfiSig*)gleamc_alloc(sizeof(List_tString_FfiSig)); _node->tag = TAG_List_tString_FfiSig_ListEmpty_List_tString_FfiSig; _node; });
    ctor__11 = ({ List_tString_FfiSig* _node = (List_tString_FfiSig*)gleamc_alloc(sizeof(List_tString_FfiSig)); _node->tag = TAG_List_tString_FfiSig_ListCons_List_tString_FfiSig;
        _node->payload.ListCons._0 = tuple__9;
        _node->payload.ListCons._1 = ctor__10;
     _node; });
    res__0 = ctor__11;
    goto case_end_b1;
arm_test_b5:
    tagis__12 = (entries->tag == TAG_List_tString_FfiSig_ListCons_List_tString_FfiSig);
    if (tagis__12) { goto ctor_ok_b13; } else { goto case_fail_b2; }
ctor_ok_b13:
    field__14 = entries->payload.ListCons._0;
    Gleamc_Rc_retain_tuple_str_FfiSig(field__14);
    goto ctor_next_b15;
ctor_next_b15:
    field__16 = entries->payload.ListCons._1;
    Gleamc_Rc_retain_List_tString_FfiSig(field__16);
    goto arm_body_b6;
arm_body_b6:
    tget__17 = field__14._0;
    gleamc_string_retain(tget__17);
    tget__18 = field__14._1;
    Gleamc_Rc_retain_FfiSig(tget__18);
    call__19 = Gleamc_dict_key_order_String(key, tget__17);
    gleamc_string_release(tget__17);
    Gleamc_Rc_drop_FfiSig(tget__18);
    goto arm_test_b23;
arm_test_b23:
    tagis__29 = (call__19.tag == TAG_Order_Lt_Order);
    if (tagis__29) { goto ctor_ok_b30; } else { goto arm_test_b25; }
ctor_ok_b30:
    Gleamc_Rc_drop_tuple_str_FfiSig(field__14);
    Gleamc_Rc_drop_List_tString_FfiSig(field__16);
    goto arm_body_b24;
arm_body_b24:
    tuple__31 = (GleamcTuple_str_FfiSig){ ._0 = key, ._1 = value };
    ctor__32 = ({ List_tString_FfiSig* _node = (List_tString_FfiSig*)gleamc_alloc(sizeof(List_tString_FfiSig)); _node->tag = TAG_List_tString_FfiSig_ListCons_List_tString_FfiSig;
        _node->payload.ListCons._0 = tuple__31;
        _node->payload.ListCons._1 = entries;
     _node; });
    res__20 = ctor__32;
    goto case_end_b21;
arm_test_b25:
    tagis__33 = (call__19.tag == TAG_Order_Eq_Order);
    Gleamc_Rc_drop_List_tString_FfiSig(entries);
    if (tagis__33) { goto ctor_ok_b34; } else { goto arm_test_b27; }
ctor_ok_b34:
    Gleamc_Rc_drop_tuple_str_FfiSig(field__14);
    goto arm_body_b26;
arm_body_b26:
    tuple__35 = (GleamcTuple_str_FfiSig){ ._0 = key, ._1 = value };
    ctor__36 = ({ List_tString_FfiSig* _node = (List_tString_FfiSig*)gleamc_alloc(sizeof(List_tString_FfiSig)); _node->tag = TAG_List_tString_FfiSig_ListCons_List_tString_FfiSig;
        _node->payload.ListCons._0 = tuple__35;
        _node->payload.ListCons._1 = field__16;
     _node; });
    res__20 = ctor__36;
    goto case_end_b21;
arm_test_b27:
    tagis__37 = (call__19.tag == TAG_Order_Gt_Order);
    if (tagis__37) { goto ctor_ok_b38; } else { goto case_fail_b22; }
ctor_ok_b38:

    goto arm_body_b28;
arm_body_b28:
    call__39 = Gleamc_dict_insert_entries_String_FfiSig(field__16, key, value);
    ctor__40 = ({ List_tString_FfiSig* _node = (List_tString_FfiSig*)gleamc_alloc(sizeof(List_tString_FfiSig)); _node->tag = TAG_List_tString_FfiSig_ListCons_List_tString_FfiSig;
        _node->payload.ListCons._0 = field__14;
        _node->payload.ListCons._1 = call__39;
     _node; });
    res__20 = ctor__40;
    goto case_end_b21;
case_fail_b22:
    gleamc_string_release(key);
    Gleamc_Rc_drop_FfiSig(value);
    Gleamc_Rc_drop_tuple_str_FfiSig(field__14);
    Gleamc_Rc_drop_List_tString_FfiSig(field__16);
    abort();
case_end_b21:
    res__0 = res__20;
    goto case_end_b1;
case_fail_b2:
    Gleamc_Rc_drop_List_tString_FfiSig(entries);
    gleamc_string_release(key);
    Gleamc_Rc_drop_FfiSig(value);
    abort();
case_end_b1:

    return res__0;
}

Order Gleamc_dict_key_order_String(GleamcString a, GleamcString b) {
    int64_t call__0;
    bool binop__1;
    Order res__2;
    Order ctor__9;
    bool binop__10;
    Order res__11;
    Order ctor__18;
    Order ctor__19;
entry:
    call__0 = Gleamc_Cmp_str(a, b);
    binop__1 = (call__0 < 0);
    goto arm_test_b5;
arm_test_b5:

    if (binop__1) { goto arm_body_b6; } else { goto arm_test_b7; }
arm_body_b6:
    ctor__9 = (Order){ .tag = TAG_Order_Lt_Order };
    res__2 = ctor__9;
    goto case_end_b3;
arm_test_b7:

    if (binop__1) { goto case_fail_b4; } else { goto arm_body_b8; }
arm_body_b8:
    binop__10 = (call__0 > 0);
    goto arm_test_b14;
arm_test_b14:

    if (binop__10) { goto arm_body_b15; } else { goto arm_test_b16; }
arm_body_b15:
    ctor__18 = (Order){ .tag = TAG_Order_Gt_Order };
    res__11 = ctor__18;
    goto case_end_b12;
arm_test_b16:

    if (binop__10) { goto case_fail_b13; } else { goto arm_body_b17; }
arm_body_b17:
    ctor__19 = (Order){ .tag = TAG_Order_Eq_Order };
    res__11 = ctor__19;
    goto case_end_b12;
case_fail_b13:

    abort();
case_end_b12:
    res__2 = res__11;
    goto case_end_b3;
case_fail_b4:

    abort();
case_end_b3:

    return res__2;
}
