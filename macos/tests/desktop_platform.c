/* macOS desktop platform behaviour the game depends on, through the real
 * shims: DirectInput 8 keyboard/mouse, XInput controllers, and the host stack
 * of threads that run guest code. No game image, window or physical device:
 * this test is the main-thread event pump (as the platform layer is on macOS),
 * events are synthetic, controllers are SDL virtual joysticks (generic, or a
 * DualSense by its USB IDs; system HID, IOKit and GameController backends are
 * off), and guest code is the hand-written fixture below. */
#include "rt.h"
#include "rt_table.h"
#include <SDL2/SDL.h>
#include <pthread.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

static unsigned checks;
#define CHECK(c) do { ++checks; if (!(c)) { fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__, #c); return 1; } } while (0)

void dinput_handle_event(const SDL_Event *e);
uint32_t dinput_dik_of(int sdl_scancode);
void input_handle_event(const SDL_Event *e);
void input_open_attached(void);

/* Hand-written guest functions, never a substitute for generated game code:
 * each stores its host thread's stack size in KiB. */
static uint32_t host_stack_kib(void) { return (uint32_t)(pthread_get_stacksize_np(pthread_self()) >> 10); }
static void synthetic_thread_stack(CPU *c) {  /* LPTHREAD_START_ROUTINE(param) */
    M32(ARG(0)) = host_stack_kib();
    RET(0, 1);
}
static void synthetic_timer_stack(CPU *c) {   /* TIMECALLBACK(id, msg, user, dw1, dw2) */
    __atomic_store_n((uint32_t *)GPTR(ARG(2)), host_stack_kib(), __ATOMIC_RELEASE);
    RET(0, 5);
}
const FnEntry g_fn_table_exe[] = {
    {0x00401000u, synthetic_thread_stack},
    {0x00401100u, synthetic_timer_stack},
};
const unsigned g_fn_count_exe = 2;
const FnEntry g_fn_table_d3dx9[] = {{0, 0}};
const FnEntry g_fn_table_bink[] = {{0, 0}};
const FnEntry g_fn_table_x3da[] = {{0, 0}};
const unsigned g_fn_count_d3dx9 = 0;
const unsigned g_fn_count_bink = 0;
const unsigned g_fn_count_x3da = 0;

static CPU *cpu;

static uint32_t shim_on(CPU *c, const char *dll, const char *name, int n, const uint32_t *args) {
    uint32_t target = rt_import_opt(dll, name);
    if (!target) rt_fatal("desktop_platform: no shim %s!%s", dll, name);
    return rt_invoke(c, target, n, args);
}
static uint32_t shim(const char *dll, const char *name, int n, const uint32_t *args) {
    return shim_on(cpu, dll, name, n, args);
}
/* COM call: slot in the object's vtable, `this` first. */
static uint32_t method(uint32_t obj, int slot, int n, const uint32_t *args) {
    uint32_t all[8] = {obj};
    memcpy(all + 1, args, 4 * (size_t)n);
    return rt_invoke(cpu, M32(M32(obj) + 4 * (uint32_t)slot), n + 1, all);
}
enum { DI_CREATE_DEVICE = 3, DEV_GET_STATE = 9, DEV_GET_DATA = 10 };

/* The platform layer's main-thread pump, reduced to the input consumers. */
static void pump(void) {
    SDL_Event e;
    while (SDL_PollEvent(&e)) {
        input_handle_event(&e);
        dinput_handle_event(&e);
    }
}
static void deliver(const SDL_Event *e) {
    input_handle_event(e);
    dinput_handle_event(e);
}
static void motion(int x, int y) {
    SDL_Event e = {0};
    e.type = SDL_MOUSEMOTION;
    e.motion.xrel = x;
    e.motion.yrel = y;
    deliver(&e);
}
static void button(Uint8 b, int down) {
    SDL_Event e = {0};
    e.type = down ? SDL_MOUSEBUTTONDOWN : SDL_MOUSEBUTTONUP;
    e.button.button = b;
    deliver(&e);
}
static void wheel(int y) {
    SDL_Event e = {0};
    e.type = SDL_MOUSEWHEEL;
    e.wheel.y = y;
    deliver(&e);
}
static void key(SDL_Scancode sc, SDL_Keycode sym, int down, int repeat) {
    SDL_Event e = {0};
    e.type = down ? SDL_KEYDOWN : SDL_KEYUP;
    e.key.keysym.scancode = sc;
    e.key.keysym.sym = sym;
    e.key.repeat = (Uint8)repeat;
    deliver(&e);
}
static uint32_t pad_state_on(CPU *c, uint32_t index, uint32_t out) {
    uint32_t args[] = {index, out};
    return shim_on(c, "XINPUT1_3.dll", "XInputGetState", 2, args);
}
static uint32_t pad_state(uint32_t index, uint32_t out) { return pad_state_on(cpu, index, out); }
/* A virtual controller; with DualSense USB IDs SDL types it as a PS5 pad. */
static int attach_pad(int dualsense) {
    SDL_VirtualJoystickDesc desc;
    SDL_zero(desc);
    desc.version = SDL_VIRTUAL_JOYSTICK_DESC_VERSION;
    desc.type = SDL_JOYSTICK_TYPE_GAMECONTROLLER;
    desc.naxes = SDL_CONTROLLER_AXIS_MAX;
    desc.nbuttons = SDL_CONTROLLER_BUTTON_MAX;
    if (dualsense) {
        desc.vendor_id = 0x054C;
        desc.product_id = 0x0CE6;
    }
    desc.name = "desktop_platform virtual pad";
    return SDL_JoystickAttachVirtualEx(&desc);
}

/* A game thread polling XInput while the main thread hot-plugs controllers. */
static int g_stop;
static unsigned g_polls;
static void *xinput_poller(void *arg) {
    (void)arg;
    CPU *c = rt_new_cpu();
    rt_thread_init(c);
    uint32_t out = gmalloc(16);
    while (!__atomic_load_n(&g_stop, __ATOMIC_ACQUIRE)) {
        for (uint32_t i = 0; i < 4; i++) pad_state_on(c, i, out);
        uint32_t vib = gmalloc(4), args[] = {0, vib};
        M32(vib) = 0;
        shim_on(c, "XINPUT1_3.dll", "XInputSetState", 2, args);
        gfree(vib);
        __atomic_add_fetch(&g_polls, 1, __ATOMIC_RELAXED);
    }
    return NULL;
}

int main(void) {
    g_log_level = 0;
    unsetenv("LB_KEYS");
    unsetenv("LB_KEYFIFO");
    unsetenv("LB_TOUCH");
    unsetenv("LB_ANY_PAD");
    MEM = mmap(NULL, 1ull << 32, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS | MAP_NORESERVE, -1, 0);
    CHECK(MEM != MAP_FAILED);
    rt_init_shims();
    cpu = rt_new_cpu();
    rt_thread_init(cpu);
    uint32_t stack = cpu->r[4];
    SDL_SetHint(SDL_HINT_JOYSTICK_HIDAPI, "0");
    SDL_SetHint(SDL_HINT_JOYSTICK_IOKIT, "0");
    SDL_SetHint(SDL_HINT_JOYSTICK_MFI, "0");
    CHECK(SDL_Init(SDL_INIT_EVENTS | SDL_INIT_GAMECONTROLLER) == 0);
    CHECK(SDL_NumJoysticks() == 0);

    /* No controller: no XInput pad, so the game keeps keyboard-and-mouse mode. */
    uint32_t xs = gmalloc(16), caps = gmalloc(20);
    CHECK(pad_state(0, xs) == 1167);  /* ERROR_DEVICE_NOT_CONNECTED */
    uint32_t cap_args[] = {0, 0, caps};
    CHECK(shim("XINPUT1_3.dll", "XInputGetCapabilities", 3, cap_args) == 1167);

    /* DirectInput 8 system mouse and keyboard */
    static const uint8_t mouse_guid[16] = {0x60, 0x2B, 0x1D, 0x6F, 0xA0, 0xD5, 0xCF, 0x11,
                                           0xBF, 0xC7, 0x44, 0x45, 0x53, 0x54, 0x00, 0x00};
    static const uint8_t keyboard_guid[16] = {0x61, 0x2B, 0x1D, 0x6F, 0xA0, 0xD5, 0xCF, 0x11,
                                              0xBF, 0xC7, 0x44, 0x45, 0x53, 0x54, 0x00, 0x00};
    uint32_t guids = gmalloc(32), out = gmalloc(4);
    memcpy(GPTR(guids), mouse_guid, 16);
    memcpy(GPTR(guids + 16), keyboard_guid, 16);
    uint32_t create_args[] = {0x400000, 0x800, guids, out, 0};
    CHECK(shim("DINPUT8.dll", "DirectInput8Create", 5, create_args) == 0);
    uint32_t di = M32(out);
    uint32_t mouse_args[] = {guids, out, 0};
    CHECK(method(di, DI_CREATE_DEVICE, 3, mouse_args) == 0);
    uint32_t mouse = M32(out);
    uint32_t keyboard_args[] = {guids + 16, out, 0};
    CHECK(method(di, DI_CREATE_DEVICE, 3, keyboard_args) == 0);
    uint32_t keyboard = M32(out);
    CHECK(mouse && keyboard && mouse != keyboard);

    /* Before any event is delivered the mouse falls back to SDL's own state. */
    uint32_t ms = gmalloc(20), state_args[] = {20, ms};
    CHECK(method(mouse, DEV_GET_STATE, 2, state_args) == 0);
    CHECK(M32(ms) == 0 && M32(ms + 4) == 0 && M8(ms + 12) == 0);

    /* Motion accumulates; a right click released before the poll, a wheel
     * notch and a held left button. DIMOUSESTATE2 is 20 bytes. */
    motion(7, -3);
    motion(2, 0);
    button(SDL_BUTTON_RIGHT, 1);
    button(SDL_BUTTON_RIGHT, 0);
    wheel(1);
    button(SDL_BUTTON_LEFT, 1);
    CHECK(method(mouse, DEV_GET_STATE, 2, state_args) == 0);
    CHECK((int32_t)M32(ms) == 9 && (int32_t)M32(ms + 4) == -3 && (int32_t)M32(ms + 8) == 120);
    CHECK(M8(ms + 12) == 0x80 && M8(ms + 13) == 0x80 && M8(ms + 14) == 0);  /* left, right, middle */
    /* the next poll: motion was consumed, the tap has been reported, left is held */
    CHECK(method(mouse, DEV_GET_STATE, 2, state_args) == 0);
    CHECK(M32(ms) == 0 && M32(ms + 4) == 0 && M32(ms + 8) == 0);
    CHECK(M8(ms + 12) == 0x80 && M8(ms + 13) == 0);
    button(SDL_BUTTON_LEFT, 0);
    button(SDL_BUTTON_MIDDLE, 1);
    CHECK(method(mouse, DEV_GET_STATE, 2, state_args) == 0);
    CHECK(M8(ms + 12) == 0 && M8(ms + 13) == 0 && M8(ms + 14) == 0x80);
    /* a device created later does not replay earlier presses */
    CHECK(method(di, DI_CREATE_DEVICE, 3, mouse_args) == 0);
    uint32_t mouse2 = M32(out), state2_args[] = {20, ms};
    CHECK(method(mouse2, DEV_GET_STATE, 2, state2_args) == 0);
    CHECK(M8(ms + 12) == 0 && M8(ms + 13) == 0 && M8(ms + 14) == 0x80);

    /* Buffered mouse data (DIDEVICEOBJECTDATA, 20 bytes), in event order */
    uint32_t recs = gmalloc(20 * 64), count = gmalloc(4);
    M32(count) = 64;
    uint32_t data_args[] = {20, recs, count, 0};
    CHECK(method(mouse, DEV_GET_DATA, 4, data_args) == 0);
    static const uint32_t want[][2] = {{0, 7}, {4, (uint32_t)-3}, {0, 2}, {13, 0x80}, {13, 0},
                                       {8, 120}, {12, 0x80}, {12, 0}, {14, 0x80}};
    CHECK(M32(count) == sizeof want / sizeof want[0]);
    for (uint32_t i = 0; i < M32(count); i++) {
        CHECK(M32(recs + 20 * i) == want[i][0] && M32(recs + 20 * i + 4) == want[i][1]);
        if (i) CHECK(M32(recs + 20 * i + 12) == M32(recs + 20 * (i - 1) + 12) + 1);
    }
    M32(count) = 64;
    CHECK(method(mouse, DEV_GET_DATA, 4, data_args) == 0 && M32(count) == 0);
    motion(1, 0);
    M32(count) = 64;
    uint32_t peek_args[] = {20, recs, count, 1};  /* DIGDD_PEEK */
    CHECK(method(mouse, DEV_GET_DATA, 4, peek_args) == 0 && M32(count) == 1);
    M32(count) = 0xFFFFFFFFu;  /* flush: no buffer, INFINITE */
    uint32_t flush_args[] = {20, 0, count, 0};
    CHECK(method(mouse, DEV_GET_DATA, 4, flush_args) == 0 && M32(count) == 1);
    M32(count) = 64;
    CHECK(method(mouse, DEV_GET_DATA, 4, data_args) == 0 && M32(count) == 0);
    /* focus loss releases held buttons (their releases may never arrive) */
    button(SDL_BUTTON_RIGHT, 1);
    SDL_Event focus = {0};
    focus.type = SDL_WINDOWEVENT;
    focus.window.event = SDL_WINDOWEVENT_FOCUS_LOST;
    deliver(&focus);
    CHECK(method(mouse, DEV_GET_STATE, 2, state_args) == 0);
    CHECK(M8(ms + 13) == 0x80 && M8(ms + 14) == 0);  /* the press itself is still reported once */
    CHECK(method(mouse, DEV_GET_STATE, 2, state_args) == 0);
    CHECK(M8(ms + 13) == 0 && M8(ms + 14) == 0);
    M32(count) = 64;
    CHECK(method(mouse, DEV_GET_DATA, 4, data_args) == 0);
    /* right pressed, then focus loss releases right and the still-held middle */
    CHECK(M32(count) == 3 && M32(recs) == 13 && M32(recs + 4) == 0x80);
    CHECK(M32(recs + 20) == 13 && M32(recs + 24) == 0 && M32(recs + 40) == 14 && M32(recs + 44) == 0);

    /* Keyboard: a tap released before the poll is seen once by state reads and
     * as a down/up pair by buffered reads; auto-repeat is not a new press. */
    uint32_t ks = gmalloc(256), key_args[] = {256, ks};
    key(SDL_SCANCODE_A, SDLK_a, 1, 0);
    key(SDL_SCANCODE_A, SDLK_a, 0, 0);
    key(SDL_SCANCODE_B, SDLK_b, 1, 1);
    CHECK(method(keyboard, DEV_GET_STATE, 2, key_args) == 0);
    CHECK(M8(ks + 0x1E) == 0x80 && M8(ks + 0x30) == 0);
    CHECK(method(keyboard, DEV_GET_STATE, 2, key_args) == 0 && M8(ks + 0x1E) == 0);
    M32(count) = 64;
    CHECK(method(keyboard, DEV_GET_DATA, 4, data_args) == 0);
    CHECK(M32(count) == 1 && M32(recs) == 0x1E && M32(recs + 4) == 0x80);
    M32(count) = 64;
    CHECK(method(keyboard, DEV_GET_DATA, 4, data_args) == 0);
    CHECK(M32(count) == 1 && M32(recs) == 0x1E && M32(recs + 4) == 0);
    M32(count) = 64;
    CHECK(method(keyboard, DEV_GET_DATA, 4, data_args) == 0 && M32(count) == 0);
    key(SDL_SCANCODE_C, SDLK_c, 1, 0);
    key(SDL_SCANCODE_C, SDLK_c, 0, 0);
    M32(count) = 64;
    uint32_t key_peek[] = {20, recs, count, 1};
    CHECK(method(keyboard, DEV_GET_DATA, 4, key_peek) == 0 && M32(count) == 1 && M32(recs) == 0x2E);
    M32(count) = 64;
    CHECK(method(keyboard, DEV_GET_DATA, 4, data_args) == 0 && M32(count) == 1 && M32(recs + 4) == 0x80);
    M32(count) = 64;
    CHECK(method(keyboard, DEV_GET_DATA, 4, data_args) == 0 && M32(count) == 1 && M32(recs + 4) == 0);
    CHECK(dinput_dik_of(SDL_SCANCODE_KP_8) == 0x48 && dinput_dik_of(SDL_SCANCODE_KP_ENTER) == 0x9C);
    CHECK(dinput_dik_of(SDL_SCANCODE_GRAVE) == 0x29 && dinput_dik_of(SDL_SCANCODE_LALT) == 0x38);
    /* physical keys do not create or press a virtual XInput pad */
    key(SDL_SCANCODE_SPACE, SDLK_SPACE, 1, 0);
    CHECK(pad_state(0, xs) == 1167);

    /* Only a DualSense is a pad (the launcher's input gate): a generic
     * controller is ignored unless LB_ANY_PAD=1 admits it for development. */
    int generic = attach_pad(0);
    CHECK(generic >= 0);
    CHECK(SDL_GameControllerTypeForIndex(generic) != SDL_CONTROLLER_TYPE_PS5);
    input_open_attached();
    pump();
    CHECK(pad_state(0, xs) == 1167);
    setenv("LB_ANY_PAD", "1", 1);
    input_open_attached();
    CHECK(pad_state(0, xs) == 0);
    unsetenv("LB_ANY_PAD");
    CHECK(SDL_JoystickDetachVirtual(generic) == 0);
    pump();
    CHECK(pad_state(0, xs) == 1167);

    /* Controllers: one attached before launch is pad 0 once, even after SDL
     * reports it as added; a second is pad 1; removing the first closes the
     * gap, so the remaining controller becomes pad 0. */
    int first = attach_pad(1);
    CHECK(first >= 0);
    CHECK(SDL_GameControllerTypeForIndex(first) == SDL_CONTROLLER_TYPE_PS5);
    input_open_attached();
    pump();
    CHECK(pad_state(0, xs) == 0);
    CHECK(pad_state(1, xs) == 1167);
    CHECK((M16(xs + 4) & 0x1000) == 0);  /* the Space key held above is not pad A */
    SDL_Joystick *joy = SDL_JoystickFromInstanceID(SDL_JoystickGetDeviceInstanceID(first));
    CHECK(joy != NULL);
    SDL_JoystickSetVirtualButton(joy, SDL_CONTROLLER_BUTTON_A, SDL_PRESSED);
    SDL_JoystickSetVirtualAxis(joy, SDL_CONTROLLER_AXIS_TRIGGERLEFT, 32767);
    SDL_JoystickSetVirtualAxis(joy, SDL_CONTROLLER_AXIS_LEFTY, -32768);
    pump();
    CHECK(pad_state(0, xs) == 0);
    CHECK((M16(xs + 4) & 0x1000) && M8(xs + 6) == 255 && (int16_t)M16(xs + 10) == 32767);
    CHECK(shim("XINPUT1_3.dll", "XInputGetCapabilities", 3, cap_args) == 0 && M8(caps) == 1);
    uint32_t vibration = gmalloc(4), vib_args[] = {0, vibration};
    M16(vibration) = 0x8000;
    M16(vibration + 2) = 0x4000;
    CHECK(shim("XINPUT1_3.dll", "XInputSetState", 2, vib_args) == 0);
    int second = attach_pad(1);
    CHECK(second >= 0);
    pump();
    CHECK(pad_state(1, xs) == 0 && M16(xs + 4) == 0);
    CHECK(SDL_JoystickDetachVirtual(first) == 0);
    pump();
    CHECK(pad_state(0, xs) == 0 && M16(xs + 4) == 0);  /* the second controller, nothing pressed */
    CHECK(pad_state(1, xs) == 1167);
    CHECK(SDL_JoystickDetachVirtual(0) == 0);
    pump();
    CHECK(pad_state(0, xs) == 1167);

    /* A game thread polls XInput while this (main) thread hot-plugs pads. */
    pthread_t poller;
    CHECK(pthread_create(&poller, NULL, xinput_poller, NULL) == 0);
    for (int i = 0; i < 200; i++) {
        CHECK(attach_pad(1) >= 0);
        pump();
        CHECK(SDL_JoystickDetachVirtual(0) == 0);
        pump();
    }
    __atomic_store_n(&g_stop, 1, __ATOMIC_RELEASE);
    CHECK(pthread_join(poller, NULL) == 0);
    CHECK(g_polls > 0 && pad_state(0, xs) == 1167);
    CHECK(cpu->r[4] == stack);

    /* Guest threads and timer callbacks run on host stacks as large as the
     * main thread's (macOS would give secondary threads only 512 KiB). */
    uint32_t kib = gmalloc(8), tid = gmalloc(4);
    uint32_t thread_args[] = {0, 0, 0x00401000u, kib, 0, tid};
    uint32_t thread = shim("kernel32.dll", "CreateThread", 6, thread_args);
    CHECK(thread != 0);
    uint32_t wait_args[] = {thread, 5000};
    CHECK(shim("kernel32.dll", "WaitForSingleObject", 2, wait_args) == 0);
    CHECK(M32(kib) >= 8192);
    uint32_t timer_args[] = {1, 1, 0x00401100u, kib + 4, 0};  /* one-shot */
    CHECK(shim("WINMM.dll", "timeSetEvent", 5, timer_args) != 0);
    for (int i = 0; i < 2000 && !__atomic_load_n((uint32_t *)GPTR(kib + 4), __ATOMIC_ACQUIRE); i++) usleep(1000);
    CHECK(M32(kib + 4) >= 8192);
    CHECK(cpu->r[4] == stack);

    SDL_Quit();
    printf("{\"scope\":\"macos-desktop-platform\",\"checks\":%u,\"devices\":\"synthetic\","
           "\"hotplug_polls\":%u,\"guest_thread_stack_kib\":%u,\"gameplay_tested\":false}\n",
           checks, g_polls, M32(kib));
    return 0;
}
