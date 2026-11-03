/* Independent expected results for the authored synthetic x86 fixture.
 * This links actual generated code, runtime/dispatch.c and runtime/fpu.c.
 * It is never linked into the game target.
 */
#include "rt.h"
#include "rt_table.h"
#include "fixture_addresses.h"
#include <stdarg.h>
#include <sys/mman.h>

uint8_t *MEM;
int g_log_level;
extern const FnEntry g_fn_table_fixture[];
extern const unsigned g_fn_count_fixture;
const FnModule g_modules[] = {{"authored-synthetic-fixture", g_fn_table_fixture, 0}};
const unsigned g_nmodules = 1;
unsigned rt_module_count(unsigned index) { return index == 0 ? g_fn_count_fixture : 0; }

void rt_fatal(const char *fmt, ...) {
    va_list args;
    va_start(args, fmt);
    vfprintf(stderr, fmt, args);
    va_end(args);
    fputc('\n', stderr);
    exit(86);
}

/* Unused watchdog dependencies deliberately fail if a fixture ever calls them. */
int platform_frame_count(void) { rt_fatal("unexpected graphics watchdog call in CPU fixture"); }
void prof_report(void) { rt_fatal("unexpected profiler call in CPU fixture"); }
void cpu_report(void) { rt_fatal("unexpected CPU profiler call in CPU fixture"); }

static unsigned passed, total;
static void check(const char *name, int condition) {
    total++;
    if (!condition) rt_fatal("fixture failed: %s", name);
    passed++;
}

static CPU cpu(void) {
    CPU c = {0};
    c.r[4] = 0x180000;
    c.fs_base = 0x25000;
    c.fpu_cw = 0x37F;
    c.mxcsr = 0x1F80;
    return c;
}

static CPU invoke(uint32_t fn) {
    CPU c = cpu();
    uint32_t sp = c.r[4];
    rt_invoke(&c, fn, 0, NULL);
    if (c.r[4] != sp) rt_fatal("host invocation failed to restore guest stack");
    return c;
}

int main(int argc, char **argv) {
    const size_t space = 1ull << 32;
    MEM = mmap(NULL, space, PROT_READ | PROT_WRITE,
               MAP_PRIVATE | MAP_ANONYMOUS | MAP_NORESERVE, -1, 0);
    if (MEM == MAP_FAILED) rt_fatal("cannot reserve synthetic guest memory");
    if (argc == 2 && !strcmp(argv[1], "--unknown")) {
        invoke(FIX_UNKNOWN_CALL);
        rt_fatal("unknown call unexpectedly returned");
    }
    if (argc == 2 && !strcmp(argv[1], "--trap")) {
        invoke(FIX_UNIMPLEMENTED_TRAP);
        rt_fatal("unimplemented instruction unexpectedly returned");
    }

    CPU c = invoke(FIX_ARITHMETIC_FLAGS);
    check("add wrap and carry/zero flags", c.r[0] == 0 && c.r[1] == 1 && c.r[2] == 1);
    c = invoke(FIX_UNALIGNED_MEMORY);
    check("unaligned guest load/store and bswap", M32(0x20003) == 0x11223344 && c.r[0] == 0x44332211);
    c = invoke(FIX_BRANCH_LOOP);
    check("conditional backward branch", c.r[0] == 15 && c.r[1] == 0);

    uint32_t value = 35;
    c = cpu();
    check("host to cdecl guest arguments", rt_invoke(&c, FIX_CDECL_CALLEE, 1, &value) == 42 && c.r[4] == 0x180000);
    c = invoke(FIX_DIRECT_CALL);
    check("direct guest call and stack cleanup", c.r[0] == 49);
    c = invoke(FIX_INDIRECT_CALL);
    check("indirect guest call via compiled dispatch", c.r[0] == 17);
    c = invoke(FIX_INDIRECT_CALL);
    check("repeated indirect call through inline cache", c.r[0] == 17);

    float left[4] = {1.25f, -2.5f, 100.0f, 0.0f};
    float right[4] = {2.75f, 0.5f, -40.0f, 1.0f};
    float expected[4] = {4.0f, -2.0f, 60.0f, 1.0f};
    memcpy(MEM + 0x21000, left, sizeof left);
    memcpy(MEM + 0x21010, right, sizeof right);
    invoke(FIX_SSE_PACKED);
    check("SSE four packed single additions", !memcmp(MEM + 0x21020, expected, sizeof expected));

    MF64(0x22000) = 1.25;
    MF64(0x22008) = 2.5;
    c = invoke(FIX_X87_ADD);
    check("x87 add and stack balance", MF64(0x22010) == 3.75 && c.top == 0);
    c = invoke(FIX_X87_ROUND);
    check("x87 nearest-even integer conversion", M32(0x22020) == 2 && c.top == 0);

    M32(0x23000) = 5;
    c = invoke(FIX_ATOMIC_CMPXCHG);
    check("atomic cmpxchg success", M32(0x23000) == 9 && c.r[0] == 5 && c.r[1] == 1);
    M32(0x23000) = 6;
    c = invoke(FIX_ATOMIC_CMPXCHG);
    check("atomic cmpxchg failure", M32(0x23000) == 6 && c.r[0] == 6 && c.r[1] == 0);

    uint32_t words[4] = {0x12345678, 2, 3, 4};
    memcpy(MEM + 0x24000, words, sizeof words);
    invoke(FIX_REP_MOVSD);
    check("rep movsd regular copy", !memcmp(MEM + 0x24010, words, sizeof words));
    memcpy(MEM + 0x24000, words, sizeof words);
    invoke(FIX_REP_OVERLAP);
    check("rep movsd forward overlapping semantics", M32(0x24004) == words[0] && M32(0x24008) == words[0] &&
          M32(0x2400C) == words[0] && M32(0x24010) == words[0]);

    M32(0x25024) = 0x12345678;
    c = invoke(FIX_FS_RELATIVE);
    check("FS-relative Windows TEB load", c.r[0] == 0x12345678);
    c = cpu();
    value = 39;
    check("stdcall guest pops argument", rt_invoke(&c, FIX_STDCALL_CALLEE, 1, &value) == 42 && c.r[4] == 0x180000);

    munmap(MEM, space);
    printf("{\"passed\":%u,\"total\":%u}\n", passed, total);
    return passed == total ? 0 : 1;
}
