/* Input: XInput 1.3 shims backed by SDL game controllers, plus a virtual
 * pad fed by the keyboard (desktop) and the touch overlay (Android).
 * On Apple platforms the virtual pad is only for scripted test input (see
 * virtual_pad), and controller slots are locked: SDL events are pumped by
 * presenting threads while the game polls XInput from its own threads. */
#include "rt.h"
#include <SDL2/SDL.h>
#include <math.h>
#include <stdlib.h>
#if defined(__APPLE__)
#define INPUT_APPLE 1  /* macOS, iOS, iPadOS and the iPad Simulator */
#else
#define INPUT_APPLE 0
#endif

static SDL_GameController *g_pads[4];
static struct {
    uint16_t buttons;
    uint8_t lt, rt;
    int16_t lx, ly, rx, ry;
} g_virt;
static uint32_t g_packet;
static int g_nintendo;  /* swap A/B and X/Y on physical controllers */

void input_set_nintendo(int on) { g_nintendo = on; g_packet++; }

/* Skip Cutscenes: story cutscenes are levels of their own. While one is
 * playing or starting, pad 0 taps Start, which skips it, and A, which also
 * gets past the "press any key" screen of the level loading next. */
static int g_skip_cutscenes;
void input_set_skip_cutscenes(int on) { g_skip_cutscenes = on; }
/* The level being played: world (0x960894) +0x12C; level +0x64 flags, where
 * 0x20 intro, 0x40 cutscene/midtro and 0x80 outro mark cutscene levels. */
static int in_cutscene_level(void) {
#ifndef GAME_BATMAN
    return 0;  /* no cutscene skip for Marvel */
#endif
    uint32_t w = M32(0x960894), lv = w >= 0x10000 ? M32(w + 0x12C) : 0;
    if (lv < 0x10000) lv = M32(0xACA89C);  /* none yet: the one being started */
    return lv >= 0x10000 && (M8(lv + 0x64) & 0xE0);
}
static uint16_t skip_tap(void) {
    if (!g_skip_cutscenes || !in_cutscene_level()) return 0;
    uint32_t t = SDL_GetTicks() % 300;  /* Start at 0-60 ms, A at 150-210 ms */
    return t < 60 ? 0x10 : (t >= 150 && t < 210) ? 0x1000 : 0;
}

static const struct { SDL_Keycode key; uint16_t bit; } k_keymap[] = {
    {SDLK_UP, 0x1}, {SDLK_DOWN, 0x2}, {SDLK_LEFT, 0x4}, {SDLK_RIGHT, 0x8},
    {SDLK_RETURN, 0x10}, {SDLK_ESCAPE, 0x20}, {SDLK_SPACE, 0x1000}, {SDLK_LCTRL, 0x2000},
    {SDLK_LSHIFT, 0x4000}, {SDLK_TAB, 0x8000}, {SDLK_q, 0x100}, {SDLK_e, 0x200},
};

void input_set_virtual(uint16_t buttons, int16_t lx, int16_t ly, int16_t rx, int16_t ry, uint8_t lt, uint8_t rt) {
    g_virt.buttons = buttons;
    g_virt.lx = lx; g_virt.ly = ly; g_virt.rx = rx; g_virt.ry = ry;
    g_virt.lt = lt; g_virt.rt = rt;
    g_packet++;
}

#if INPUT_APPLE
/* Apple platforms: pad 0 is the first DualSense (through HIDAPI on macOS and
 * GameController.framework on iOS; see pad_allowed).
 * Without one the game sees no XInput pad and keeps its keyboard-and-mouse
 * interface (the menu cursor); an always-present pad would hold it in gamepad
 * mode, and physical keys would also press pad buttons (Space = A, LCtrl = B,
 * Esc = Back, ...). The virtual pad and its key mapping remain for scripted
 * test input (LB_KEYS, LB_KEYFIFO) and the LB_TOUCH overlay, as in the
 * upstream desktop test build. */
static int virtual_pad(void) {
    static int v = -1;
    if (v < 0) {
        const char *k = getenv("LB_KEYS"), *f = getenv("LB_KEYFIFO"), *t = getenv("LB_TOUCH");
        v = (k && *k) || (f && *f) || (t && atoi(t));
        /* LB_VPAD=0: scripted keys act as a physical keyboard only (no pad
         * stick/buttons), e.g. typing in the console where A = stick left
         * would move the text cursor. */
        const char *vp = getenv("LB_VPAD");
        if (vp && *vp == '0') v = 0;
    }
    return v;
}
/* Guards g_pads: opened and closed by the event pump, read by XInput calls. */
static pthread_mutex_t g_pad_lock = PTHREAD_MUTEX_INITIALIZER;
/* Caller holds g_pad_lock. */
static int connected(uint32_t i) { return i < 4 && (g_pads[i] || (i == 0 && virtual_pad())); }

/* The launcher's input gate is a DualSense or a physical keyboard and mouse,
 * so only a DualSense becomes a pad. Others (the Simulator's own "Gamepad",
 * generic or virtual controllers) would put the game into gamepad mode without
 * passing that gate; LB_ANY_PAD=1 admits them for development. */
static int pad_allowed(int device_index) {
    SDL_GameControllerType type = SDL_GameControllerTypeForIndex(device_index);
    const char *any = getenv("LB_ANY_PAD");
    if (type == SDL_CONTROLLER_TYPE_PS5 || (any && *any == '1')) return 1;
    const char *name = SDL_GameControllerNameForIndex(device_index);
    LOG("input: ignoring controller %s (type %d; DualSense only, LB_ANY_PAD=1 allows)",
        name ? name : "?", (int)type);
    return 0;
}

/* Opens a controller once (input_open_attached opens those attached at
 * launch, and SDL then reports them again as added) into the first free slot. */
static void pad_open(int device_index) {
    if (!SDL_IsGameController(device_index) || !pad_allowed(device_index)) return;
    SDL_JoystickID id = SDL_JoystickGetDeviceInstanceID(device_index);
    pthread_mutex_lock(&g_pad_lock);
    int slot = -1;
    for (int i = 0; i < 4; i++) {
        if (g_pads[i] && SDL_JoystickInstanceID(SDL_GameControllerGetJoystick(g_pads[i])) == id) {
            pthread_mutex_unlock(&g_pad_lock);
            return;
        }
        if (!g_pads[i] && slot < 0) slot = i;
    }
    SDL_GameController *p = slot < 0 ? NULL : SDL_GameControllerOpen(device_index);
    if (p) {
        g_pads[slot] = p;
        g_packet++;
    }
    pthread_mutex_unlock(&g_pad_lock);
    if (p) LOG("input: XInput pad %d is %s (type %d)", slot, SDL_GameControllerName(p) ? SDL_GameControllerName(p) : "a controller",
               (int)SDL_GameControllerGetType(p));
    else if (slot >= 0) LOG("input: cannot open controller %d: %s", device_index, SDL_GetError());
}
/* Closes the gap a removed pad leaves, so the first controller is always pad 0. */
static void pad_close(SDL_JoystickID id) {
    pthread_mutex_lock(&g_pad_lock);
    for (int i = 0; i < 4; i++) {
        if (!g_pads[i] || SDL_JoystickInstanceID(SDL_GameControllerGetJoystick(g_pads[i])) != id) continue;
        SDL_GameControllerClose(g_pads[i]);
        for (int j = i; j < 3; j++) g_pads[j] = g_pads[j + 1];
        g_pads[3] = NULL;
        g_packet++;
        LOG("input: XInput pad %d disconnected", i);
        break;
    }
    pthread_mutex_unlock(&g_pad_lock);
}
/* Call once on the main thread after SDL_Init: controllers attached before
 * launch are pads from the game's first XInput poll. Logs the input mode, so a
 * run shows whether the game can see a pad without inferring it from frames. */
void input_open_attached(void) {
    LOG("input: virtual pad %s; %d controller(s) attached at launch",
        virtual_pad() ? "on (LB_KEYS/LB_KEYFIFO/LB_TOUCH)" : "off", SDL_NumJoysticks());
    for (int i = 0; i < SDL_NumJoysticks(); i++) pad_open(i);
}
#endif

void input_handle_event(const SDL_Event *e) {
    switch (e->type) {
    case SDL_CONTROLLERDEVICEADDED:
#if INPUT_APPLE
        pad_open(e->cdevice.which);
#else
        for (int i = 0; i < 4; i++)
            if (!g_pads[i]) { g_pads[i] = SDL_GameControllerOpen(e->cdevice.which); break; }
#endif
        break;
    case SDL_CONTROLLERDEVICEREMOVED:
#if INPUT_APPLE
        pad_close(e->cdevice.which);
#else
        for (int i = 0; i < 4; i++)
            if (g_pads[i] && SDL_JoystickInstanceID(SDL_GameControllerGetJoystick(g_pads[i])) == e->cdevice.which) {
                SDL_GameControllerClose(g_pads[i]);
                g_pads[i] = NULL;
            }
#endif
        break;
    case SDL_KEYDOWN:
    case SDL_KEYUP:
#if INPUT_APPLE
        if (!virtual_pad()) break;  /* physical keys reach the game via DirectInput */
#endif
        for (unsigned i = 0; i < sizeof k_keymap / sizeof k_keymap[0]; i++)
            if (k_keymap[i].key == e->key.keysym.sym) {
                if (e->type == SDL_KEYDOWN) g_virt.buttons |= k_keymap[i].bit;
                else g_virt.buttons &= (uint16_t)~k_keymap[i].bit;
                g_packet++;
            }
        {
            /* WASD = left stick; tracked from events so scripted keys work too */
            static int held[4];
            static const SDL_Keycode wasd[4] = {SDLK_w, SDLK_a, SDLK_s, SDLK_d};
            for (int i = 0; i < 4; i++)
                if (e->key.keysym.sym == wasd[i]) held[i] = e->type == SDL_KEYDOWN;
            g_virt.lx = (int16_t)((held[3] ? 32767 : 0) - (held[1] ? 32767 : 0));
            g_virt.ly = (int16_t)((held[0] ? 32767 : 0) - (held[2] ? 32767 : 0));
            /* J and L = right stick left and right, so a scripted route (LB_KEYS) can turn */
            static int look[2];
            if (e->key.keysym.sym == SDLK_j) look[0] = e->type == SDL_KEYDOWN;
            if (e->key.keysym.sym == SDLK_l) look[1] = e->type == SDL_KEYDOWN;
            g_virt.rx = (int16_t)((look[1] ? 32767 : 0) - (look[0] ? 32767 : 0));
            g_packet++;
        }
        break;
    }
}

/* Head steering on a pad (runtime/platform_sdl.c head_steer): a right-stick deflection, -1..1, used while the
 * real right stick is centred. While a pad is connected the game is in gamepad mode and ignores mouse look. */
static volatile float g_head_rx, g_head_ry;
static volatile int g_real_right_stick;  /* the real right stick was off centre at the last poll */
void input_head_stick(float x, float y) { g_head_rx = x; g_head_ry = y; }
int input_right_stick_moved(void) { return g_real_right_stick; }
int input_pad_connected(void) {
#if INPUT_APPLE
    pthread_mutex_lock(&g_pad_lock);
    int c = connected(0);
    pthread_mutex_unlock(&g_pad_lock);
    return c;
#else
    return g_pads[0] != NULL;
#endif
}

static void fill_state(int idx, uint32_t g) {
    uint16_t b = 0;
    uint8_t lt = 0, rt = 0;
    int16_t lx = 0, ly = 0, rx = 0, ry = 0;
    SDL_GameController *p = g_pads[idx];
    if (p) {
        static const struct { SDL_GameControllerButton b; uint16_t bit; } map[] = {
            {SDL_CONTROLLER_BUTTON_DPAD_UP, 0x1}, {SDL_CONTROLLER_BUTTON_DPAD_DOWN, 0x2},
            {SDL_CONTROLLER_BUTTON_DPAD_LEFT, 0x4}, {SDL_CONTROLLER_BUTTON_DPAD_RIGHT, 0x8},
            {SDL_CONTROLLER_BUTTON_START, 0x10}, {SDL_CONTROLLER_BUTTON_BACK, 0x20},
            {SDL_CONTROLLER_BUTTON_LEFTSTICK, 0x40}, {SDL_CONTROLLER_BUTTON_RIGHTSTICK, 0x80},
            {SDL_CONTROLLER_BUTTON_LEFTSHOULDER, 0x100}, {SDL_CONTROLLER_BUTTON_RIGHTSHOULDER, 0x200},
            {SDL_CONTROLLER_BUTTON_A, 0x1000}, {SDL_CONTROLLER_BUTTON_B, 0x2000},
            {SDL_CONTROLLER_BUTTON_X, 0x4000}, {SDL_CONTROLLER_BUTTON_Y, 0x8000},
        };
        for (unsigned i = 0; i < sizeof map / sizeof map[0]; i++)
            if (SDL_GameControllerGetButton(p, map[i].b)) b |= map[i].bit;
        if (g_nintendo)
            b = (uint16_t)((b & 0x0FFF) | ((b & 0x1000) << 1) | ((b & 0x2000) >> 1) |
                           ((b & 0x4000) << 1) | ((b & 0x8000) >> 1));
        lt = (uint8_t)(SDL_GameControllerGetAxis(p, SDL_CONTROLLER_AXIS_TRIGGERLEFT) >> 7);
        rt = (uint8_t)(SDL_GameControllerGetAxis(p, SDL_CONTROLLER_AXIS_TRIGGERRIGHT) >> 7);
        lx = SDL_GameControllerGetAxis(p, SDL_CONTROLLER_AXIS_LEFTX);
        ly = (int16_t)~SDL_GameControllerGetAxis(p, SDL_CONTROLLER_AXIS_LEFTY);
        rx = SDL_GameControllerGetAxis(p, SDL_CONTROLLER_AXIS_RIGHTX);
        ry = (int16_t)~SDL_GameControllerGetAxis(p, SDL_CONTROLLER_AXIS_RIGHTY);
    }
    if (idx == 0) {
        b |= g_virt.buttons | skip_tap();
        if (g_virt.lt) lt = g_virt.lt;
        if (g_virt.rt) rt = g_virt.rt;
        if (g_virt.lx || g_virt.ly) { lx = g_virt.lx; ly = g_virt.ly; }
        if (g_virt.rx || g_virt.ry) { rx = g_virt.rx; ry = g_virt.ry; }
        g_real_right_stick = abs(rx) > 8000 || abs(ry) > 8000;
        if (!g_real_right_stick && (g_head_rx != 0 || g_head_ry != 0)) {
            rx = (int16_t)(fmaxf(-1.0f, fminf(1.0f, g_head_rx)) * 32767.0f);
            ry = (int16_t)(fmaxf(-1.0f, fminf(1.0f, g_head_ry)) * 32767.0f);
        }
    }
    { /* a new packet number whenever the reported state changes */
        static uint16_t last_b[4];
        if (b != last_b[idx & 3]) { last_b[idx & 3] = b; g_packet++; }
    }
    M32(g) = g_packet;
    M16(g + 4) = b;
    M8(g + 6) = lt;
    M8(g + 7) = rt;
    M16(g + 8) = (uint16_t)lx;
    M16(g + 10) = (uint16_t)ly;
    M16(g + 12) = (uint16_t)rx;
    M16(g + 14) = (uint16_t)ry;
}

#if !INPUT_APPLE
static int connected(uint32_t i) { return i == 0 || (i < 4 && g_pads[i]); }
#endif

#if INPUT_APPLE
SHIM(XInputGetState) {
    uint32_t i = ARG(0), out = ARG(1);
    pthread_mutex_lock(&g_pad_lock);
    int ok = connected(i);
    if (ok) fill_state((int)i, out);
    pthread_mutex_unlock(&g_pad_lock);
    RET(ok ? 0 : 1167, 2);
}
SHIM(XInputSetState) {
    uint32_t i = ARG(0), v = ARG(1);
    pthread_mutex_lock(&g_pad_lock);
    int ok = connected(i);
    if (ok && g_pads[i]) SDL_GameControllerRumble(g_pads[i], M16(v), M16(v + 2), 200);
    pthread_mutex_unlock(&g_pad_lock);
    RET(ok ? 0 : 1167, 2);
}
SHIM(XInputGetCapabilities) {
    uint32_t i = ARG(0);
    pthread_mutex_lock(&g_pad_lock);
    int ok = connected(i);
    pthread_mutex_unlock(&g_pad_lock);
    if (!ok) RET(1167, 3);
    uint32_t g = ARG(2);
    memset(MEM + g, 0, 20);
    M8(g) = 1;       /* XINPUT_DEVTYPE_GAMEPAD */
    M8(g + 1) = 1;   /* XINPUT_DEVSUBTYPE_GAMEPAD */
    M16(g + 4) = 0xF3FF;
    M8(g + 6) = 0xFF; M8(g + 7) = 0xFF;
    M16(g + 8) = 0xFFC0; M16(g + 10) = 0xFFC0; M16(g + 12) = 0xFFC0; M16(g + 14) = 0xFFC0;
    M16(g + 16) = 0xFF; M16(g + 18) = 0xFF;
    RET(0, 3);
}
#else
SHIM(XInputGetState) {
    uint32_t i = ARG(0);
    if (!connected(i)) RET(1167, 2);
    fill_state((int)i, ARG(1));
    RET(0, 2);
}
SHIM(XInputSetState) {
    uint32_t i = ARG(0);
    if (!connected(i)) RET(1167, 2);
    if (i < 4 && g_pads[i])
        SDL_GameControllerRumble(g_pads[i], M16(ARG(1)), M16(ARG(1) + 2), 200);
    RET(0, 2);
}
SHIM(XInputGetCapabilities) {
    uint32_t i = ARG(0);
    if (!connected(i)) RET(1167, 3);
    uint32_t g = ARG(2);
    memset(MEM + g, 0, 20);
    M8(g) = 1;       /* XINPUT_DEVTYPE_GAMEPAD */
    M8(g + 1) = 1;   /* XINPUT_DEVSUBTYPE_GAMEPAD */
    M16(g + 4) = 0xF3FF;
    M8(g + 6) = 0xFF; M8(g + 7) = 0xFF;
    M16(g + 8) = 0xFFC0; M16(g + 10) = 0xFFC0; M16(g + 12) = 0xFFC0; M16(g + 14) = 0xFFC0;
    M16(g + 16) = 0xFF; M16(g + 18) = 0xFF;
    RET(0, 3);
}

#endif

/* Pads the game is told about. Android and desktop Linux: pad 0 (touch
 * overlay, keyboard, first SDL controller) always, plus any further SDL
 * controllers. Apple: the real controllers, or the virtual pad alone. */
int input_pad_count(void) {
#if INPUT_APPLE
    int n = 0;
    pthread_mutex_lock(&g_pad_lock);
    while (n < 4 && g_pads[n]) n++;
    pthread_mutex_unlock(&g_pad_lock);
    return n ? n : virtual_pad();
#else
    int n = 1;
    while (n < 4 && g_pads[n]) n++;
    return n;
#endif
}

/* Replaces the game's IsXInputDevice (0x51E280, cdecl, GUID *guidProduct),
 * which asks WMI for "IG_" device ids. Our pads use the 360 pad's product id. */
#ifdef GAME_BATMAN
void f_51E280(CPU *c) {
    RETC(M32(ARG(0)) == 0x028E045Eu);
}
#endif

static const ShimDef defs[] = {
    {"XINPUT1_3.dll", "#2", shim_XInputGetState},
    {"XINPUT1_3.dll", "#3", shim_XInputSetState},
    {"XINPUT1_3.dll", "#4", shim_XInputGetCapabilities},
    {"XINPUT1_3.dll", "XInputGetState", shim_XInputGetState},
    {"XINPUT1_3.dll", "XInputSetState", shim_XInputSetState},
    {"XINPUT1_3.dll", "XInputGetCapabilities", shim_XInputGetCapabilities},
    {NULL, NULL, NULL}
};

void input_init(void) { rt_register_shims(defs); }
