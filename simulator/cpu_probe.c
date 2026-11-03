/* Expected results for the authored PE32 fixture, linked with the real runtime. */
#include "rt.h"
#include "fixture_addresses.h"
#include <mach/mach.h>
#include <sys/mman.h>
#include <string.h>

static unsigned passed, total;
static void check(const char *name, int condition) {
    total++;
    if (!condition) rt_fatal("simulator AOT fixture failed: %s", name);
    passed++;
}

static CPU fresh_cpu(void) {
    CPU c = {0};
    c.r[4] = 0x180000;
    c.fs_base = 0x25000;
    c.fpu_cw = 0x37f;
    c.mxcsr = 0x1f80;
    return c;
}

static CPU invoke(uint32_t fn) {
    CPU c = fresh_cpu();
    uint32_t stack = c.r[4];
    rt_invoke(&c, fn, 0, NULL);
    if (c.r[4] != stack) rt_fatal("Simulator fixture did not restore guest stack");
    return c;
}

int simulator_cpu_probe(unsigned *result_total) {
    MEM = mmap(NULL, 1ull << 32, PROT_READ | PROT_WRITE,
               MAP_PRIVATE | MAP_ANONYMOUS | MAP_NORESERVE, -1, 0);
    if (MEM == MAP_FAILED) rt_fatal("Simulator cannot reserve 4GiB guest data region");
    vm_address_t cursor = (vm_address_t)MEM;
    vm_address_t end = cursor + (1ull << 32);
    int full_mapped = 1, no_execute = 1;
    unsigned regions = 0;
    while (cursor < end) {
        vm_address_t address = cursor;
        vm_size_t region_size = 0;
        vm_region_basic_info_data_64_t info;
        mach_msg_type_number_t count = VM_REGION_BASIC_INFO_COUNT_64;
        mach_port_t object = MACH_PORT_NULL;
        kern_return_t status = vm_region_64(mach_task_self(), &address, &region_size,
            VM_REGION_BASIC_INFO_64, (vm_region_info_t)&info, &count, &object);
        if (object != MACH_PORT_NULL) mach_port_deallocate(mach_task_self(), object);
        if (status != KERN_SUCCESS || address > cursor || !region_size || address + region_size <= cursor) {
            full_mapped = 0;
            break;
        }
        no_execute &= !(info.protection & VM_PROT_EXECUTE);
        cursor = address + region_size < end ? address + region_size : end;
        ++regions;
    }
    check("full guest range is mapped", full_mapped && cursor == end);
    check("full guest data range is not executable", no_execute && cursor == end);
    fprintf(stderr, "Simulator guest VM: 4294967296 bytes across %u regions, none executable\n", regions);
    rt_init_shims();
    CPU *thread_cpu = rt_new_cpu();
    rt_thread_init(thread_cpu);
    check("real runtime guest thread has TEB", thread_cpu->fs_base != 0 && M32(thread_cpu->fs_base + 0x24) != 0);

    CPU c = invoke(FIX_ARITHMETIC_FLAGS);
    check("carry and zero flags", c.r[0] == 0 && c.r[1] == 1 && c.r[2] == 1);
    c = invoke(FIX_UNALIGNED_MEMORY);
    check("unaligned memory", M32(0x20003) == 0x11223344 && c.r[0] == 0x44332211);
    c = invoke(FIX_BRANCH_LOOP);
    check("backward branch", c.r[0] == 15 && c.r[1] == 0);
    uint32_t value = 35;
    c = fresh_cpu();
    check("cdecl arguments", rt_invoke(&c, FIX_CDECL_CALLEE, 1, &value) == 42 && c.r[4] == 0x180000);
    c = invoke(FIX_DIRECT_CALL);
    check("direct call", c.r[0] == 49);
    c = invoke(FIX_INDIRECT_CALL);
    check("indirect compiled dispatch", c.r[0] == 17);
    c = invoke(FIX_INDIRECT_CALL);
    check("cached compiled dispatch", c.r[0] == 17);
    float left[4] = {1.25f, -2.5f, 100.0f, 0.0f};
    float right[4] = {2.75f, 0.5f, -40.0f, 1.0f};
    float expected[4] = {4.0f, -2.0f, 60.0f, 1.0f};
    memcpy(MEM + 0x21000, left, sizeof left);
    memcpy(MEM + 0x21010, right, sizeof right);
    invoke(FIX_SSE_PACKED);
    check("SSE packed additions", !memcmp(MEM + 0x21020, expected, sizeof expected));
    MF64(0x22000) = 1.25;
    MF64(0x22008) = 2.5;
    c = invoke(FIX_X87_ADD);
    check("x87 arithmetic", MF64(0x22010) == 3.75 && c.top == 0);
    c = invoke(FIX_X87_ROUND);
    check("x87 rounding", M32(0x22020) == 2 && c.top == 0);
    M32(0x23000) = 5;
    c = invoke(FIX_ATOMIC_CMPXCHG);
    check("atomic success", M32(0x23000) == 9 && c.r[0] == 5 && c.r[1] == 1);
    M32(0x23000) = 6;
    c = invoke(FIX_ATOMIC_CMPXCHG);
    check("atomic failure", M32(0x23000) == 6 && c.r[0] == 6 && c.r[1] == 0);
    uint32_t words[4] = {0x12345678, 2, 3, 4};
    memcpy(MEM + 0x24000, words, sizeof words);
    invoke(FIX_REP_MOVSD);
    check("rep copy", !memcmp(MEM + 0x24010, words, sizeof words));
    memcpy(MEM + 0x24000, words, sizeof words);
    invoke(FIX_REP_OVERLAP);
    check("rep forward overlap", M32(0x24004) == words[0] && M32(0x24008) == words[0] && M32(0x2400c) == words[0] && M32(0x24010) == words[0]);
    M32(0x25024) = 0x12345678;
    c = invoke(FIX_FS_RELATIVE);
    check("Windows FS-relative memory", c.r[0] == 0x12345678);
    c = fresh_cpu();
    value = 39;
    check("stdcall arguments", rt_invoke(&c, FIX_STDCALL_CALLEE, 1, &value) == 42 && c.r[4] == 0x180000);
    *result_total = total;
    return (int)passed;
}
