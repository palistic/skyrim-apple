/* Full-reservation protection checks using the actual guest heap allocator.
 * Authored synthetic data only; no Windows image or generated game code.
 */
#include "rt.h"
#include <mach/mach.h>
#include <mach/mach_vm.h>
#include <stdarg.h>
#include <sys/mman.h>
#include <string.h>

uint8_t *MEM;
int g_log_level;
static unsigned checks, scans, regions;

void rt_fatal(const char *format, ...) {
    va_list args;
    va_start(args, format);
    vfprintf(stderr, format, args);
    va_end(args);
    fputc('\n', stderr);
    exit(2);
}

#define REQUIRE(condition) do { \
    ++checks; \
    if (!(condition)) rt_fatal("mapping check failed at line %d: %s", __LINE__, #condition); \
} while (0)

static void inspect_guest_reservation(void) {
    mach_vm_address_t cursor = (mach_vm_address_t)MEM;
    const mach_vm_address_t end = cursor + (1ull << 32);
    const mach_vm_address_t guarded_end = cursor + 0x10000;
    unsigned inspected = 0;
    while (cursor < end) {
        mach_vm_address_t address = cursor;
        mach_vm_size_t size = 0;
        vm_region_basic_info_data_64_t info;
        mach_msg_type_number_t count = VM_REGION_BASIC_INFO_COUNT_64;
        mach_port_t object = MACH_PORT_NULL;
        REQUIRE(mach_vm_region(mach_task_self(), &address, &size,
            VM_REGION_BASIC_INFO_64, (vm_region_info_t)&info, &count, &object) == KERN_SUCCESS);
        if (object != MACH_PORT_NULL) mach_port_deallocate(mach_task_self(), object);
        REQUIRE(address <= cursor && size > 0 && address + size > cursor);
        REQUIRE((info.protection & VM_PROT_EXECUTE) == 0);
        if (cursor < guarded_end) {
            REQUIRE(info.protection == VM_PROT_NONE);
            REQUIRE(address + size <= guarded_end);
        } else {
            REQUIRE((info.protection & (VM_PROT_READ | VM_PROT_WRITE)) ==
                (VM_PROT_READ | VM_PROT_WRITE));
        }
        cursor = address + size;
        ++inspected;
        REQUIRE(inspected < 65536);
    }
    REQUIRE(cursor >= end);
    regions += inspected;
    ++scans;
}

int main(void) {
    MEM = mmap(NULL, 1ull << 32, PROT_READ | PROT_WRITE,
        MAP_PRIVATE | MAP_ANONYMOUS | MAP_NORESERVE, -1, 0);
    REQUIRE(MEM != MAP_FAILED);
    REQUIRE(mprotect(MEM, 0x10000, PROT_NONE) == 0);
    inspect_guest_reservation();

    /* The low, middle and last pages remain data at their actual host mapping. */
    M32(0x10000) = 0x12345678;
    M32(0x7ffffffc) = 0xabcdef01;
    M32(0xfffffffc) = 0x87654321;
    REQUIRE(M32(0x10000) == 0x12345678);
    REQUIRE(M32(0x7ffffffc) == 0xabcdef01);
    REQUIRE(M32(0xfffffffc) == 0x87654321);

    uint32_t pointers[8];
    for (unsigned i = 0; i < 8; ++i) {
        pointers[i] = gvalloc(0, 65536);
        REQUIRE(pointers[i] != 0);
        memset(GPTR(pointers[i]), 0x80 + i, 65536);
    }
    inspect_guest_reservation();
    for (unsigned i = 0; i < 8; i += 2) gvfree(pointers[i]);
    inspect_guest_reservation();
    for (unsigned i = 0; i < 8; i += 2) {
        uint32_t reused = gvalloc(0, 65536);
        REQUIRE(reused == pointers[i]);
        REQUIRE(M32(reused) == 0 && M32(reused + 65532) == 0);
    }
    inspect_guest_reservation();
    REQUIRE(munmap(MEM, 1ull << 32) == 0);
    printf("{\"scope\":\"full-4GiB-guest-reservation\",\"checks\":%u,"
        "\"scans\":%u,\"regions_inspected\":%u,\"executable_guest_regions\":0,"
        "\"gameplay_tested\":false}\n", checks, scans, regions);
    return 0;
}
