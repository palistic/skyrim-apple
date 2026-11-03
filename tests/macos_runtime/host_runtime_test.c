/* Real Darwin host behavior used by the C runtime; contains no game data. */
#define _GNU_SOURCE
#include "rt.h"
#include "host_portability.h"
#include <assert.h>
#include <fcntl.h>
#include <stdarg.h>
#include <sys/mman.h>
#include <sys/time.h>
#include <time.h>

uint8_t *MEM;
int g_log_level = 1;
char g_save_dir[1024];

void rt_fatal(const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    vfprintf(stderr, fmt, ap);
    va_end(ap);
    abort();
}

static void *thread_id(void *out) {
    *(uint64_t *)out = rt_host_thread_id();
    return NULL;
}

static double monotonic(void) {
    struct timespec ts;
    assert(clock_gettime(CLOCK_MONOTONIC, &ts) == 0);
    return ts.tv_sec + ts.tv_nsec / 1e9;
}

int main(int argc, char **argv) {
    assert(argc == 2);
    snprintf(g_save_dir, sizeof g_save_dir, "%s", argv[1]);

    uint64_t main_id = rt_host_thread_id(), other_id = 0;
    assert(main_id != 0 && main_id == rt_host_thread_id());
    pthread_t thread;
    assert(pthread_create(&thread, NULL, thread_id, &other_id) == 0);
    assert(pthread_join(thread, NULL) == 0);
    assert(other_id != 0 && main_id != other_id);

    char name[1100];
    snprintf(name, sizeof name, "%s/mtime-test", g_save_dir);
    int fd = open(name, O_CREAT | O_RDWR | O_EXCL, 0600);
    assert(fd >= 0);
    struct timespec times[2] = {{123, 111}, {456, 987654321}};
    assert(futimens(fd, times) == 0);
    struct stat st;
    assert(fstat(fd, &st) == 0);
    struct timespec got = rt_host_stat_mtime(&st);
    assert(got.tv_sec == times[1].tv_sec && got.tv_nsec == times[1].tv_nsec);
    assert(close(fd) == 0 && unlink(name) == 0);

    MEM = mmap(NULL, 1ull << 32, PROT_READ | PROT_WRITE,
               MAP_PRIVATE | MAP_ANONYMOUS | MAP_NORESERVE, -1, 0);
    assert(MEM != MAP_FAILED);
    uint32_t region = gvalloc(0, 65536);
    assert(region != 0);
    memset(MEM + region, 0xA5, 65536);
    gvfree(region);
    uint32_t reused = gvalloc(0, 65536);
    assert(reused == region);
    for (uint32_t i = 0; i < 65536; i++) assert(MEM[reused + i] == 0);
    assert(munmap(MEM, 1ull << 32) == 0);

    extern void prof_start(void), prof_report(void), cpu_report(void);
    cpu_report();
    prof_start();
    volatile uint64_t work = 1;
    double until = monotonic() + 0.20;
    while (monotonic() < until)
        for (unsigned i = 0; i < 10000; i++) work = work * 6364136223846793005ull + 1;
    prof_report();
    cpu_report();
    struct itimerval off = {0};
    assert(setitimer(ITIMER_PROF, &off, NULL) == 0);
    printf("Darwin host checks passed; work=%llu\n", (unsigned long long)work);
    return 0;
}
