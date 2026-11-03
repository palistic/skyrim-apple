/* Tests the real Windows runtime without loading any game image or assets. */
#include "rt.h"
#include <mach/mach.h>
#include <mach/mach_vm.h>
#include <errno.h>
#include <signal.h>
#include <stdint.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/resource.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>

static unsigned checks;
#define CHECK(c) do { ++checks; if (!(c)) { fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__, #c); return 1; } } while (0)

static uint32_t invoke(CPU *cpu, const char *name, int n, const uint32_t *args) {
    uint32_t target = rt_import_opt("kernel32.dll", name);
    if (!target) rt_fatal("smoke: missing genuine kernel32 import %s", name);
    return rt_invoke(cpu, target, n, args);
}

int main(void) {
    g_log_level = 0;
    MEM = mmap(NULL, 1ull << 32, PROT_READ | PROT_WRITE,
        MAP_PRIVATE | MAP_ANONYMOUS | MAP_NORESERVE, -1, 0);
    CHECK(MEM != MAP_FAILED);
    CHECK(mprotect(MEM, 0x10000, PROT_NONE) == 0);

    mach_vm_address_t address = (mach_vm_address_t)(MEM + 0x10000);
    mach_vm_size_t size = 0;
    vm_region_basic_info_data_64_t info;
    mach_msg_type_number_t count = VM_REGION_BASIC_INFO_COUNT_64;
    mach_port_t object = MACH_PORT_NULL;
    CHECK(mach_vm_region(mach_task_self(), &address, &size, VM_REGION_BASIC_INFO_64,
        (vm_region_info_t)&info, &count, &object) == KERN_SUCCESS);
    if (object != MACH_PORT_NULL) mach_port_deallocate(mach_task_self(), object);
    CHECK((info.protection & VM_PROT_EXECUTE) == 0);
    CHECK((info.protection & (VM_PROT_READ | VM_PROT_WRITE)) == (VM_PROT_READ | VM_PROT_WRITE));

    rt_init_shims();
    CPU *cpu = rt_new_cpu();
    CHECK(cpu != NULL);
    rt_thread_init(cpu);
    uint32_t stack = cpu->r[4];
    uint32_t add[] = {19, 23};
    CHECK(rt_invoke(cpu, 0x00401000u, 2, add) == 42);
    CHECK(cpu->r[4] == stack);

    /* Unknown code must abort. No interpreter or dynamic translator may rescue it. */
    int output[2];
    CHECK(pipe(output) == 0);
    pid_t child = fork();
    CHECK(child >= 0);
    if (child == 0) {
        struct rlimit limit = {0, 0};
        setrlimit(RLIMIT_CORE, &limit);
        close(output[0]);
        dup2(output[1], STDERR_FILENO);
        close(output[1]);
        rt_call(cpu, 0x0badc0deu);
        _exit(99);
    }
    close(output[1]);
    char fatal[2048] = {0};
    size_t got = 0;
    for (;;) {
        char chunk[512];
        ssize_t length = read(output[0], chunk, sizeof chunk);
        if (length < 0 && errno == EINTR) continue;
        if (length <= 0) break;
        size_t copy = (size_t)length;
        if (copy > sizeof fatal - 1 - got) copy = sizeof fatal - 1 - got;
        memcpy(fatal + got, chunk, copy);
        got += copy;
    }
    close(output[0]);
    int status = 0;
    CHECK(waitpid(child, &status, 0) == child);
    CHECK(got > 0 && strstr(fatal, "no recompiled code") != NULL);
    CHECK(WIFSIGNALED(status) && WTERMSIG(status) == SIGABRT);

    uint32_t block = gmalloc(256);
    CHECK(block != 0 && (block & 15) == 0);
    memset(GPTR(block), 0x47, 256);
    uint32_t grown = grealloc(block, 2048);
    CHECK(grown != 0 && M8(grown + 255) == 0x47);
    gfree(grown);
    uint32_t region = gvalloc(0, 65536);
    CHECK(region != 0);
    memset(GPTR(region), 0xa5, 65536);
    gvfree(region);
    uint32_t reused = gvalloc(0, 65536);
    CHECK(reused == region);
    CHECK(M32(reused) == 0 && M32(reused + 65532) == 0);
    gvfree(reused);

    char directory[] = "/tmp/skyrim-runtime-smoke-XXXXXX";
    CHECK(mkdtemp(directory) != NULL);
    snprintf(g_game_dir, sizeof g_game_dir, "%s", directory);
    snprintf(g_save_dir, sizeof g_save_dir, "%s/save", directory);
    CHECK(mkdir(g_save_dir, 0700) == 0);
    char filename[1200];
    snprintf(filename, sizeof filename, "%s/Case.DAT", directory);
    FILE *file = fopen(filename, "wb");
    CHECK(file != NULL);
    CHECK(fwrite("guest-data", 1, 10, file) == 10);
    CHECK(fclose(file) == 0);
    uint32_t name = gstrdup("C:\\Skyrim\\case.dat");
    uint32_t open_args[] = {name, 0x80000000u, 1, 0, 3, 0, 0};
    uint32_t handle = invoke(cpu, "CreateFileA", 7, open_args);
    CHECK(handle != 0xffffffffu && handle != 0);
    uint32_t buffer = gmalloc(64), bytes = gmalloc(4);
    uint32_t read_args[] = {handle, buffer, 10, bytes, 0};
    CHECK(invoke(cpu, "ReadFile", 5, read_args) != 0);
    CHECK(M32(bytes) == 10 && memcmp(GPTR(buffer), "guest-data", 10) == 0);
    uint32_t close_args[] = {handle};
    CHECK(invoke(cpu, "CloseHandle", 1, close_args) != 0);
    CHECK(cpu->r[4] == stack);

    uint32_t thread_output = gmalloc(8), thread_id = gmalloc(4);
    uint32_t thread_args[] = {0, 0, 0x00401100u, thread_output, 0, thread_id};
    uint32_t thread = invoke(cpu, "CreateThread", 6, thread_args);
    CHECK(thread != 0);
    uint32_t wait_args[] = {thread, 5000};
    CHECK(invoke(cpu, "WaitForSingleObject", 2, wait_args) == 0);
    CHECK(M32(thread_output) == M32(thread_id));
    CHECK(M32(thread_output + 4) == 0x51a7c0deu);
    uint32_t exit_code = gmalloc(4), exit_args[] = {thread, exit_code};
    CHECK(invoke(cpu, "GetExitCodeThread", 2, exit_args) != 0 && M32(exit_code) == 73);
    CHECK(cpu->r[4] == stack);

    unlink(filename);
    rmdir(g_save_dir);
    rmdir(directory);
    printf("{\"scope\":\"synthetic-full-runtime\",\"architecture\":\"arm64\",\"checks\":%u,"
        "\"guest_memory_executable\":false,\"unknown_code_aborts\":true,\"gameplay_tested\":false}\n", checks);
    /* The OS tears down the private 4GiB mapping after the process exits. */
    return 0;
}
