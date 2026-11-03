/* Host OS details shared by the runtime, never guest Windows ABI values. */
#pragma once
#include <stdint.h>
#include <pthread.h>
#include <sys/stat.h>
#include <unistd.h>

static inline uint64_t rt_host_thread_id(void) {
#ifdef __APPLE__
    uint64_t tid;
    if (pthread_threadid_np(NULL, &tid) == 0) return tid;
    /* A real per-thread port name is still useful if the ID query fails. */
    return (uint64_t)pthread_mach_thread_np(pthread_self());
#else
    return (uint64_t)gettid();
#endif
}

static inline struct timespec rt_host_stat_mtime(const struct stat *st) {
#ifdef __APPLE__
    return st->st_mtimespec;
#else
    return st->st_mtim;
#endif
}
