/* Hand-written test functions, never a substitute for generated Skyrim code. */
#include "rt.h"
#include "rt_table.h"

static void synthetic_add(CPU *c) {
    uint32_t a = ARG(0), b = ARG(1);
    RET(a + b, 2);
}

static void synthetic_thread(CPU *c) {
    uint32_t output = ARG(0);
    M32(output) = M32(c->fs_base + 0x24);
    M32(output + 4) = 0x51a7c0deu;
    RET(73, 1);
}

const FnEntry g_fn_table_exe[] = {
    {0x00401000u, synthetic_add},
    {0x00401100u, synthetic_thread},
};
const unsigned g_fn_count_exe = 2;
const FnEntry g_fn_table_d3dx9[] = {{0, 0}};
const FnEntry g_fn_table_bink[] = {{0, 0}};
const FnEntry g_fn_table_x3da[] = {{0, 0}};
const unsigned g_fn_count_d3dx9 = 0;
const unsigned g_fn_count_bink = 0;
const unsigned g_fn_count_x3da = 0;
