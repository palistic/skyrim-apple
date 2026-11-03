/* XAudio2 output-device recovery through the real shim and SDL's dummy output
 * device, which drains queued audio in real time:
 * - a suspended process (SIGSTOP 1 s, as vmmap or a debugger does) resumes
 *   with the same device playing and no stall counted;
 * - the same suspension made deterministic: holding the device lock for 1 s
 *   freezes both the engine's polling and the device's draining, and the
 *   device resumes draining 30 ms after the engine, as CoreAudio's IO thread
 *   did after vmmap. The dummy device alone resumes as fast as the engine, so
 *   the SIGSTOP case cannot always tell a suspension from a stall;
 * - a device that really stops draining (paused here) is closed, mixing
 *   continues on the timer, and a playing device is reopened with a bounded
 *   queue; a second stall soon after waits twice as long before reopening.
 * No game image or physical device; the fixture functions are hand-written.
 * AUDIO_RECOVERY_DRIVER=coreaudio runs the same checks on the host Mac's real
 * CoreAudio output (silent mix; system sound settings untouched). */
#include "rt.h"
#include <SDL2/SDL.h>
#include <signal.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

extern int xaudio2_create(uint32_t clsid, uint32_t *out);
void xaudio2_output_stats(uint32_t *dev, unsigned *stalls, unsigned *reopens, uint64_t *passes);

static unsigned checks;
#define CHECK(c) do { ++checks; if (!(c)) { fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__, #c); return 1; } } while (0)

static uint32_t method(CPU *cpu, uint32_t object, unsigned index, unsigned count, const uint32_t *arguments) {
    uint32_t values[8] = {object};
    if (count) memcpy(values + 1, arguments, count * sizeof(uint32_t));
    return rt_invoke(cpu, M32(M32(object) + 4 * index), (int)count + 1, values);
}
static void wait_ms(unsigned ms) {
    struct timespec t = {(time_t)(ms / 1000), (long)(ms % 1000) * 1000000L};
    while (nanosleep(&t, &t)) {}
}
/* A running XAudio2 2.6 engine with a 2-channel 48 kHz mastering voice. */
static int start_engine(void) {
    MEM = mmap(NULL, 1ull << 32, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS | MAP_NORESERVE, -1, 0);
    CHECK(MEM != MAP_FAILED && mprotect(MEM, 0x10000, PROT_NONE) == 0);
    rt_init_shims();
    CPU *cpu = rt_new_cpu();
    rt_thread_init(cpu);
    static const uint8_t guid[16] = {0x49, 0x9b, 0xda, 0x3e, 0x85, 0x20, 0x8b, 0x49, 0x9b, 0xb2, 0x39, 0xa6, 0x77, 0x84, 0x93, 0xde};
    uint32_t clsid = gmalloc(16), engine = 0;
    memcpy(GPTR(clsid), guid, sizeof guid);
    CHECK(xaudio2_create(clsid, &engine) != 0 && engine != 0);
    uint32_t master_out = gmalloc(4), master_args[] = {master_out, 2, 48000, 0, 0, 0};
    CHECK(method(cpu, engine, 10, 6, master_args) == 0 && M32(master_out) != 0);  /* CreateMasteringVoice */
    CHECK(method(cpu, engine, 11, 0, NULL) == 0);  /* StartEngine */
    return 0;
}
static int playing(uint32_t dev) { return dev && SDL_GetAudioDeviceStatus(dev) == SDL_AUDIO_PLAYING; }

/* Child: run the engine, report the device when ready and again on request. */
static int suspended_child(int ready_fd, int ask_fd) {
    if (start_engine()) return 1;
    wait_ms(300);
    uint32_t dev; unsigned stalls, reopens; uint64_t passes;
    xaudio2_output_stats(&dev, &stalls, &reopens, &passes);
    char line[96];
    int n = snprintf(line, sizeof line, "%u %u %u %llu %d\n", dev, stalls, reopens, (unsigned long long)passes, playing(dev));
    CHECK(write(ready_fd, line, (size_t)n) == n);
    char c;
    CHECK(read(ask_fd, &c, 1) == 1);
    xaudio2_output_stats(&dev, &stalls, &reopens, &passes);
    n = snprintf(line, sizeof line, "%u %u %u %llu %d\n", dev, stalls, reopens, (unsigned long long)passes, playing(dev));
    CHECK(write(ready_fd, line, (size_t)n) == n);
    return 0;
}
static int read_line(int fd, char *buf, size_t size) {
    size_t n = 0;
    while (n + 1 < size) {
        ssize_t r = read(fd, buf + n, 1);
        if (r <= 0) return -1;
        if (buf[n++] == '\n') break;
    }
    buf[n] = 0;
    return 0;
}

int main(void) {
    const char *driver = getenv("AUDIO_RECOVERY_DRIVER");
    setenv("SDL_AUDIODRIVER", driver && *driver ? driver : "dummy", 1);
    g_log_level = 0;

    /* 1. Suspension. Fork before any thread exists; the child runs the engine. */
    int up[2], down[2];
    CHECK(pipe(up) == 0 && pipe(down) == 0);
    pid_t child = fork();
    CHECK(child >= 0);
    if (child == 0) {
        close(up[0]); close(down[1]);
        _exit(suspended_child(up[1], down[0]));
    }
    close(up[1]); close(down[0]);
    char line[96];
    unsigned dev0 = 0, stalls0 = 9, reopens0 = 9, play0 = 0, dev1 = 0, stalls1 = 9, reopens1 = 9, play1 = 0;
    unsigned long long passes0 = 0, passes1 = 0;
    CHECK(read_line(up[0], line, sizeof line) == 0);
    CHECK(sscanf(line, "%u %u %u %llu %u", &dev0, &stalls0, &reopens0, &passes0, &play0) == 5);
    CHECK(dev0 && play0 && stalls0 == 0 && passes0 > 0);
    CHECK(kill(child, SIGSTOP) == 0);
    wait_ms(1000);
    CHECK(kill(child, SIGCONT) == 0);
    wait_ms(800);
    CHECK(write(down[1], "r", 1) == 1);
    CHECK(read_line(up[0], line, sizeof line) == 0);
    CHECK(sscanf(line, "%u %u %u %llu %u", &dev1, &stalls1, &reopens1, &passes1, &play1) == 5);
    int status = 0;
    CHECK(waitpid(child, &status, 0) == child && WIFEXITED(status) && WEXITSTATUS(status) == 0);
    CHECK(stalls1 == 0 && reopens1 == 0);   /* the suspension is not a device stall */
    CHECK(dev1 && play1);                   /* still playing (SDL reuses device ids) */
    CHECK(passes1 > passes0 + 50);          /* mixing went on after the resume */

    if (start_engine()) return 1;
    wait_ms(300);
    uint32_t dev; unsigned stalls, reopens; uint64_t passes, passes_stalled;
    xaudio2_output_stats(&dev, &stalls, &reopens, &passes);
    CHECK(playing(dev) && stalls == 0);

    /* 2. Suspension with a late device resume, three times. A full queue means
     * the engine is waiting for it to drain when the lock is taken. */
    const Uint32 full = 4u * 480u * 2u * sizeof(float);
    for (int round = 0; round < 3; round++) {
        uint64_t before;
        xaudio2_output_stats(NULL, NULL, NULL, &before);
        int locked = 0;
        for (int i = 0; i < 200 && !locked; i++) {
            SDL_LockAudioDevice(dev);
            if (SDL_GetQueuedAudioSize(dev) > full) locked = 1;
            else { SDL_UnlockAudioDevice(dev); wait_ms(1); }
        }
        CHECK(locked);
        SDL_PauseAudioDevice(dev, 1);  /* lock held: both threads stop */
        wait_ms(1000);
        SDL_UnlockAudioDevice(dev);
        wait_ms(30);
        SDL_PauseAudioDevice(dev, 0);  /* the device drains again 30 ms later */
        wait_ms(400);
        uint32_t now_dev;
        xaudio2_output_stats(&now_dev, &stalls, &reopens, &passes);
        CHECK(stalls == 0 && reopens == 0 && now_dev == dev && playing(dev));
        CHECK(passes >= before + 25);  /* mixing resumed (about 39 passes expected) */
    }

    /* 3. A device that stops draining: closed, mixed on the timer, reopened. */
    SDL_PauseAudioDevice(dev, 1);  /* the device stops consuming its queue */
    for (int i = 0; i < 100 && stalls == 0; i++) { wait_ms(10); xaudio2_output_stats(&dev, &stalls, &reopens, &passes); }
    CHECK(stalls == 1 && dev == 0 && reopens == 0);
    passes_stalled = passes;
    /* no device: mixing continues on the timer (10 passes take about 100 ms of
     * the 500 ms before the reopen) */
    for (int i = 0; i < 40 && passes < passes_stalled + 10; i++) { wait_ms(5); xaudio2_output_stats(&dev, &stalls, &reopens, &passes); }
    CHECK(passes >= passes_stalled + 10 && dev == 0 && reopens == 0);
    for (int i = 0; i < 200 && reopens == 0; i++) { wait_ms(10); xaudio2_output_stats(&dev, &stalls, &reopens, &passes); }
    CHECK(reopens == 1 && stalls == 1 && playing(dev));
    wait_ms(500);
    xaudio2_output_stats(&dev, &stalls, &reopens, &passes);
    CHECK(stalls == 1 && reopens == 1 && playing(dev));  /* the reopened device keeps draining */
    /* bounded queue: at most four 10 ms passes waiting plus the one being added */
    CHECK(SDL_GetQueuedAudioSize(dev) <= 5u * 480u * 2u * sizeof(float));

    /* 4. A second stall within 10 s of the reopen waits twice as long (1 s). */
    SDL_PauseAudioDevice(dev, 1);
    for (int i = 0; i < 100 && stalls == 1; i++) { wait_ms(10); xaudio2_output_stats(&dev, &stalls, &reopens, &passes); }
    CHECK(stalls == 2 && dev == 0 && reopens == 1);
    struct timespec t0, t1;
    clock_gettime(CLOCK_MONOTONIC, &t0);
    for (int i = 0; i < 400 && reopens == 1; i++) { wait_ms(10); xaudio2_output_stats(&dev, &stalls, &reopens, &passes); }
    clock_gettime(CLOCK_MONOTONIC, &t1);
    long waited_ms = (long)(t1.tv_sec - t0.tv_sec) * 1000 + (t1.tv_nsec - t0.tv_nsec) / 1000000;
    CHECK(reopens == 2 && playing(dev));
    CHECK(waited_ms >= 850 && waited_ms <= 2500);  /* doubled from 500 ms, not reset or capped */

    printf("{\"scope\":\"xaudio2-output-device-recovery\",\"checks\":%u,\"suspension_stalls\":0,"
           "\"stall_reopened\":true,\"audio_output\":\"SDL-%s\",\"gameplay_tested\":false}\n",
           checks, SDL_GetCurrentAudioDriver() ? SDL_GetCurrentAudioDriver() : "none");
    return 0;
}
