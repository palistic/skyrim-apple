/* Calls actual statically recompiled Microsoft D3DX9 math exports. */
#include "rt.h"
#include "rt_table.h"
#include "module_metadata.h" /* privately generated PE metadata, never tracked */
#include <math.h>
#include <sys/mman.h>
#include <string.h>

extern void rt_module_add(const char *, uint32_t);
const FnEntry g_fn_table_exe[] = {{0, 0}};
const FnEntry g_fn_table_x3da[] = {{0, 0}};
const FnEntry g_fn_table_bink[] = {{0, 0}};
const unsigned g_fn_count_exe = 0, g_fn_count_x3da = 0, g_fn_count_bink = 0;
static unsigned checks;
#define CHECK(value) do { ++checks; if (!(value)) { fprintf(stderr,"FAIL %s:%d: %s\n",__FILE__,__LINE__,#value); return 1; } } while (0)
static uint32_t bits(float value) { uint32_t out; memcpy(&out,&value,4); return out; }

int main(int argc, char **argv) {
    CHECK(argc == 2);
    g_log_level = 0;
    MEM = mmap(NULL, 1ull << 32, PROT_READ | PROT_WRITE,
        MAP_PRIVATE | MAP_ANONYMOUS | MAP_NORESERVE, -1, 0);
    CHECK(MEM != MAP_FAILED);
    CHECK(mprotect(MEM, 0x10000, PROT_NONE) == 0);
    rt_init_shims();
    FILE *image = fopen(argv[1], "rb");
    CHECK(image != NULL);
    CHECK(fread(MEM + MODULE_BASE, 1, MODULE_IMAGE_BYTES, image) == MODULE_IMAGE_BYTES);
    CHECK(fclose(image) == 0);
    for (unsigned i = 0; i < sizeof(module_imports) / sizeof(module_imports[0]); ++i)
        M32(module_imports[i].address) = rt_import(module_imports[i].dll, module_imports[i].name);
    rt_module_add("d3dx9_42.dll", MODULE_BASE);
    CPU *cpu = rt_new_cpu();
    rt_thread_init(cpu);
    uint32_t stack = cpu->r[4];
    if (MODULE_ENTRY) {
        uint32_t attach[] = {MODULE_BASE, 1, 0};
        CHECK(rt_invoke(cpu, MODULE_ENTRY, 3, attach) != 0);
        CHECK(cpu->r[4] == stack);
    }
    uint32_t version[] = {32, 42};
    CHECK(rt_invoke(cpu, MODULE_CHECK_VERSION, 2, version) != 0);
    version[1] = 43;
    CHECK(rt_invoke(cpu, MODULE_CHECK_VERSION, 2, version) == 0);
    CHECK(cpu->r[4] == stack);

    uint32_t translation = gmalloc(64), scaling = gmalloc(64), result = gmalloc(64), inverse = gmalloc(64);
    uint32_t translate[] = {translation, bits(5), bits(6), bits(7)};
    CHECK(rt_invoke(cpu, MODULE_TRANSLATION, 4, translate) == translation);
    for (unsigned i = 0; i < 16; ++i) {
        float expected = (i % 5 == 0) ? 1 : i == 12 ? 5 : i == 13 ? 6 : i == 14 ? 7 : 0;
        CHECK(MF32(translation + i * 4) == expected);
    }
    uint32_t scale[] = {scaling, bits(2), bits(3), bits(4)};
    CHECK(rt_invoke(cpu, MODULE_SCALING, 4, scale) == scaling);
    for (unsigned i = 0; i < 16; ++i) {
        float expected = i == 0 ? 2 : i == 5 ? 3 : i == 10 ? 4 : i == 15 ? 1 : 0;
        CHECK(MF32(scaling + i * 4) == expected);
    }
    uint32_t multiply[] = {result, scaling, translation};
    CHECK(rt_invoke(cpu, MODULE_MULTIPLY, 3, multiply) == result);
    for (unsigned row = 0; row < 4; ++row) for (unsigned col = 0; col < 4; ++col) {
        float expected = 0;
        for (unsigned k = 0; k < 4; ++k)
            expected += MF32(scaling + (row * 4 + k) * 4) * MF32(translation + (k * 4 + col) * 4);
        CHECK(fabsf(MF32(result + (row * 4 + col) * 4) - expected) < 0.0001f);
    }
    uint32_t determinant = gmalloc(4), invert[] = {inverse, determinant, scaling};
    CHECK(rt_invoke(cpu, MODULE_INVERSE, 3, invert) == inverse);
    CHECK(fabsf(MF32(determinant) - 24) < 0.0001f);
    CHECK(fabsf(MF32(inverse) - 0.5f) < 0.0001f);
    CHECK(fabsf(MF32(inverse + 20) - 1.0f / 3.0f) < 0.0001f);
    CHECK(fabsf(MF32(inverse + 40) - 0.25f) < 0.0001f);
    uint32_t vector = gmalloc(12), normalized = gmalloc(12);
    MF32(vector) = 3; MF32(vector + 4) = 4; MF32(vector + 8) = 0;
    uint32_t normalize[] = {normalized, vector};
    CHECK(rt_invoke(cpu, MODULE_NORMALIZE, 2, normalize) == normalized);
    CHECK(fabsf(MF32(normalized) - 0.6f) < 0.0001f);
    CHECK(fabsf(MF32(normalized + 4) - 0.8f) < 0.0001f);
    CHECK(fabsf(MF32(normalized + 8)) < 0.0001f);
    CHECK(cpu->r[4] == stack);
    printf("{\"probe\":\"actual_recompiled_microsoft_d3dx9\",\"checks\":%u,"
           "\"determinant\":%.9g,\"normalized\":[%.9g,%.9g,%.9g],"
           "\"cpu_jit\":false,\"gameplay_tested\":false}\n",checks,MF32(determinant),
           MF32(normalized),MF32(normalized + 4),MF32(normalized + 8));
    return 0;
}
