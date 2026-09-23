#include "gleam_runtime.h"

typedef struct List_Int List_Int;
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

void Gleamc_Rc_retain_List_Int(List_Int* v);
void Gleamc_Rc_drop_List_Int(List_Int* v);

int Gleamc_Eq_tuple_Order_Order(GleamcTuple_Order_Order a, GleamcTuple_Order_Order b);
int Gleamc_Eq_Order(Order a, Order b);
int Gleamc_Eq_List_Int(List_Int* a, List_Int* b);

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
int64_t Gleamc_order_to_int(Order);
Order Gleamc_order_compare(Order, Order);
Order Gleamc_order_negate(Order);
Order Gleamc_order_lazy_break_tie(Order, GleamFn_fn__Order);
int64_t Gleamc_list_sum(List_Int*);
Order Gleamc_order_break_tie(Order, Order);
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
