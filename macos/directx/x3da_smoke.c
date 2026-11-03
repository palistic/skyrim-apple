/* Calls the actual statically recompiled Microsoft X3DAudio DLL, not a mock. */
#include "rt.h"
#include "rt_table.h"
#include "module_metadata.h" /* privately generated PE metadata, never tracked */
#include <math.h>
#include <sys/mman.h>
#include <string.h>

extern void rt_module_add(const char *, uint32_t);
const FnEntry g_fn_table_exe[] = {{0, 0}};
const FnEntry g_fn_table_d3dx9[] = {{0, 0}};
const FnEntry g_fn_table_bink[] = {{0, 0}};
const unsigned g_fn_count_exe = 0, g_fn_count_d3dx9 = 0, g_fn_count_bink = 0;
static unsigned checks;
#define CHECK(value) do { ++checks; if (!(value)) { fprintf(stderr,"FAIL %s:%d: %s\n",__FILE__,__LINE__,#value); return 1; } } while (0)

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
    rt_module_add("X3DAudio1_7.dll", MODULE_BASE);
    CPU *cpu = rt_new_cpu();
    rt_thread_init(cpu);
    uint32_t stack = cpu->r[4];
    if (MODULE_ENTRY) {
        uint32_t attach[] = {MODULE_BASE, 1, 0};
        CHECK(rt_invoke(cpu, MODULE_ENTRY, 3, attach) != 0);
        CHECK(cpu->r[4] == stack);
    }
    uint32_t handle = gmalloc(28), repeated = gmalloc(20);
    memset(GPTR(handle), 0xa5, 28);
    float speed = 343.5f;
    uint32_t speed_bits;
    memcpy(&speed_bits, &speed, 4);
    uint32_t initialize[] = {3, speed_bits, handle + 4}; /* stereo, meters/second */
    rt_invoke(cpu, MODULE_INITIALIZE, 3, initialize);
    CHECK(cpu->r[4] == stack);
    CHECK(M32(handle) == 0xa5a5a5a5u && M32(handle + 24) == 0xa5a5a5a5u);
    initialize[2] = repeated;
    rt_invoke(cpu, MODULE_INITIALIZE, 3, initialize);
    CHECK(memcmp(GPTR(handle + 4), GPTR(repeated), 20) == 0);

    /* Win32 layouts: pointers are guest uint32_t, not host-size pointers. */
    uint32_t listener = gmalloc(52), emitter = gmalloc(100), dsp = gmalloc(48), matrix = gmalloc(8);
    memset(GPTR(listener), 0, 52);
    memset(GPTR(emitter), 0, 100);
    memset(GPTR(dsp), 0, 48);
    MF32(listener + 8) = 1;       /* OrientFront.z */
    MF32(listener + 16) = 1;      /* OrientTop.y */
    MF32(emitter + 12) = 1;       /* OrientFront.z */
    MF32(emitter + 20) = 1;       /* OrientTop.y */
    MF32(emitter + 36) = 1;       /* Position.z, one meter ahead */
    M32(emitter + 60) = 1;        /* ChannelCount */
    MF32(emitter + 92) = 1;       /* CurveDistanceScaler */
    MF32(emitter + 96) = 1;       /* DopplerScaler */
    M32(dsp) = matrix;
    M32(dsp + 8) = 1;             /* one source channel */
    M32(dsp + 12) = 2;            /* two destination channels */
    uint32_t calculate[] = {handle + 4, listener, emitter, 0x21, dsp}; /* MATRIX | DOPPLER */
    rt_invoke(cpu, MODULE_CALCULATE, 5, calculate);
    CHECK(cpu->r[4] == stack);
    float center_left = MF32(matrix), center_right = MF32(matrix + 4);
    CHECK(isfinite(center_left) && isfinite(center_right));
    CHECK(center_left > 0 && fabsf(center_left - center_right) < 0.0001f);
    CHECK(fabsf(MF32(dsp + 28) - 1) < 0.0001f);
    CHECK(fabsf(MF32(dsp + 36) - 1) < 0.0001f);

    MF32(emitter + 28) = 1;       /* Position.x, one meter to the right */
    MF32(emitter + 36) = 0;
    rt_invoke(cpu, MODULE_CALCULATE, 5, calculate);
    float right_left = MF32(matrix), right_right = MF32(matrix + 4);
    CHECK(right_right > right_left);
    MF32(emitter + 28) = -1;
    rt_invoke(cpu, MODULE_CALCULATE, 5, calculate);
    float left_left = MF32(matrix), left_right = MF32(matrix + 4);
    CHECK(left_left > left_right);
    CHECK(fabsf(right_right - left_left) < 0.0001f && fabsf(right_left - left_right) < 0.0001f);
    CHECK(cpu->r[4] == stack);
    printf("{\"probe\":\"actual_recompiled_microsoft_x3daudio\",\"checks\":%u,"
           "\"center\":[%.9g,%.9g],\"right\":[%.9g,%.9g],\"left\":[%.9g,%.9g],"
           "\"cpu_jit\":false,\"gameplay_tested\":false}\n",
           checks,center_left,center_right,right_left,right_right,left_left,left_right);
    return 0;
}
