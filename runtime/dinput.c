/* DirectInput 8 shim: system keyboard and mouse devices backed by SDL.
 * Game controllers are listed only so the game finds its XInput pads: it
 * enumerates them here and keeps those IsXInputDevice (input.c) accepts. */
#include "hcom.h"
#include <SDL2/SDL.h>
#if defined(__APPLE__)
#define DI_APPLE 1  /* macOS, iOS, iPadOS and the iPad Simulator */
#else
#define DI_APPLE 0
#endif
const Uint8 *platform_keys(int *n);

void *g_hcom_slots[HCOM_MAX];

static const uint8_t GUID_SysMouse[16] = {0x60, 0x2B, 0x1D, 0x6F, 0xA0, 0xD5, 0xCF, 0x11,
                                          0xBF, 0xC7, 0x44, 0x45, 0x53, 0x54, 0x00, 0x00};
static const uint8_t GUID_SysKeyboard[16] = {0x61, 0x2B, 0x1D, 0x6F, 0xA0, 0xD5, 0xCF, 0x11,
                                             0xBF, 0xC7, 0x44, 0x45, 0x53, 0x54, 0x00, 0x00};

enum { DEV_KEYBOARD, DEV_MOUSE };
#if DI_APPLE
/* seen_*: the press counts (keys by DIK code; mouse buttons 0-7 in seen_state)
 * this device has already reported, by GetDeviceState and GetDeviceData. */
typedef struct { int kind; uint8_t prev[256]; uint32_t seq; uint32_t seen_state[256], seen_data[256]; } DIDev;
#else
typedef struct { int kind; uint8_t prev[256]; uint32_t seq; } DIDev;
#endif

static HComClass k_di8, k_didev;

#if DI_APPLE
/* Further keys a Mac or iPad hardware keyboard sends: keypad, F13-F15 and
 * the ISO key.
 * (Caps Lock never arrives as a key event from SDL on macOS.) */
static uint8_t dik_of_mac(SDL_Scancode s) {
    switch (s) {
    case SDL_SCANCODE_KP_0: return 0x52;
    case SDL_SCANCODE_KP_1: return 0x4F;
    case SDL_SCANCODE_KP_2: return 0x50;
    case SDL_SCANCODE_KP_3: return 0x51;
    case SDL_SCANCODE_KP_4: return 0x4B;
    case SDL_SCANCODE_KP_5: return 0x4C;
    case SDL_SCANCODE_KP_6: return 0x4D;
    case SDL_SCANCODE_KP_7: return 0x47;
    case SDL_SCANCODE_KP_8: return 0x48;
    case SDL_SCANCODE_KP_9: return 0x49;
    case SDL_SCANCODE_KP_PERIOD: return 0x53;
    case SDL_SCANCODE_KP_ENTER: return 0x9C;
    case SDL_SCANCODE_KP_PLUS: return 0x4E;
    case SDL_SCANCODE_KP_MINUS: return 0x4A;
    case SDL_SCANCODE_KP_MULTIPLY: return 0x37;
    case SDL_SCANCODE_KP_DIVIDE: return 0xB5;
    case SDL_SCANCODE_KP_EQUALS: return 0x8D;
    case SDL_SCANCODE_NUMLOCKCLEAR: return 0x45;
    case SDL_SCANCODE_NONUSBACKSLASH: return 0x56;
    case SDL_SCANCODE_F13: return 0x64;
    case SDL_SCANCODE_F14: return 0x65;
    case SDL_SCANCODE_F15: return 0x66;
    default: return 0;
    }
}
#endif

/* SDL scancode -> DIK code */
static uint8_t dik_of(SDL_Scancode s) {
    if (s >= SDL_SCANCODE_A && s <= SDL_SCANCODE_Z) {
        static const uint8_t az[26] = {0x1E, 0x30, 0x2E, 0x20, 0x12, 0x21, 0x22, 0x23, 0x17, 0x24, 0x25, 0x26, 0x32,
                                       0x31, 0x18, 0x19, 0x10, 0x13, 0x1F, 0x14, 0x16, 0x2F, 0x11, 0x2D, 0x15, 0x2C};
        return az[s - SDL_SCANCODE_A];
    }
    if (s >= SDL_SCANCODE_1 && s <= SDL_SCANCODE_9) return (uint8_t)(0x02 + (s - SDL_SCANCODE_1));
    if (s >= SDL_SCANCODE_F1 && s <= SDL_SCANCODE_F10) return (uint8_t)(0x3B + (s - SDL_SCANCODE_F1));
    switch (s) {
    case SDL_SCANCODE_0: return 0x0B;
    case SDL_SCANCODE_RETURN: return 0x1C;
    case SDL_SCANCODE_ESCAPE: return 0x01;
    case SDL_SCANCODE_BACKSPACE: return 0x0E;
    case SDL_SCANCODE_TAB: return 0x0F;
    case SDL_SCANCODE_SPACE: return 0x39;
    case SDL_SCANCODE_MINUS: return 0x0C;
    case SDL_SCANCODE_EQUALS: return 0x0D;
    case SDL_SCANCODE_LEFTBRACKET: return 0x1A;
    case SDL_SCANCODE_RIGHTBRACKET: return 0x1B;
    case SDL_SCANCODE_SEMICOLON: return 0x27;
    case SDL_SCANCODE_APOSTROPHE: return 0x28;
    case SDL_SCANCODE_GRAVE: return 0x29;
    case SDL_SCANCODE_BACKSLASH: return 0x2B;
    case SDL_SCANCODE_COMMA: return 0x33;
    case SDL_SCANCODE_PERIOD: return 0x34;
    case SDL_SCANCODE_SLASH: return 0x35;
    case SDL_SCANCODE_LCTRL: return 0x1D;
    case SDL_SCANCODE_RCTRL: return 0x9D;
    case SDL_SCANCODE_LSHIFT: return 0x2A;
    case SDL_SCANCODE_RSHIFT: return 0x36;
    case SDL_SCANCODE_LALT: return 0x38;
    case SDL_SCANCODE_RALT: return 0xB8;
    case SDL_SCANCODE_UP: return 0xC8;
    case SDL_SCANCODE_DOWN: return 0xD0;
    case SDL_SCANCODE_LEFT: return 0xCB;
    case SDL_SCANCODE_RIGHT: return 0xCD;
    case SDL_SCANCODE_F11: return 0x57;
    case SDL_SCANCODE_F12: return 0x58;
    case SDL_SCANCODE_PAGEUP: return 0xC9;
    case SDL_SCANCODE_PAGEDOWN: return 0xD1;
    case SDL_SCANCODE_HOME: return 0xC7;
    case SDL_SCANCODE_END: return 0xCF;
    case SDL_SCANCODE_INSERT: return 0xD2;
    case SDL_SCANCODE_DELETE: return 0xD3;
#if DI_APPLE
    default: return dik_of_mac(s);
#else
    default: return 0;
#endif
    }
}

uint32_t dinput_dik_of(int sdl_scancode) { return dik_of((SDL_Scancode)sdl_scancode); }

#if DI_APPLE
/* Apple platforms: the mouse and keyboard as DirectInput reports them, tracked
 * from the SDL events the platform layer pumps (dinput_handle_event; on macOS
 * that is the main thread, on iOS whichever thread presents, while the game
 * reads devices from its own threads). Touches are never mouse input: SDL's
 * touch-to-mouse events are off and SDL_TOUCH_MOUSEID events are ignored.
 * - Relative motion and the wheel (WHEEL_DELTA, 120 per notch) accumulate until
 *   GetDeviceState reads them, like DirectInput's relative axes.
 * - Buttons use DIMOUSESTATE order: 0 left, 1 right, 2 middle, 3-4 side.
 * - Each press is counted; a device reports a key or button as down at least
 *   once per press even if it was released before the game polled (trackpad
 *   taps, quick taps at low frame rates), whatever the pump's cadence.
 * - Buffered (GetDeviceData) mouse records are kept too, independently of the
 *   immediate state, as DirectInput does.
 * Until the platform layer delivers events, the mouse falls back to SDL's own
 * relative state. */
#define DI_MOUSE_QUEUE 1024
typedef struct { uint32_t ofs, data, time, seq; } DIMouseRec;
static pthread_mutex_t g_di_lock = PTHREAD_MUTEX_INITIALIZER;
static int g_di_fed;  /* dinput_handle_event has been called */
static struct {
    int32_t dx, dy, dz;
    uint8_t held;
    uint32_t presses[8];
    DIMouseRec q[DI_MOUSE_QUEUE];
    uint32_t head, tail, seq;
} g_mouse;
static uint32_t g_key_presses[256];

static int di_button_of(Uint8 sdl_button) {
    switch (sdl_button) {
    case SDL_BUTTON_LEFT: return 0;
    case SDL_BUTTON_RIGHT: return 1;
    case SDL_BUTTON_MIDDLE: return 2;
    case SDL_BUTTON_X1: return 3;
    case SDL_BUTTON_X2: return 4;
    default: return -1;
    }
}

/* Caller holds g_di_lock. Keeps the newest records if the game never drains them. */
static void mouse_record(uint32_t ofs, uint32_t data) {
    if (g_mouse.tail - g_mouse.head >= DI_MOUSE_QUEUE) g_mouse.head++;
    DIMouseRec *r = &g_mouse.q[g_mouse.tail++ % DI_MOUSE_QUEUE];
    r->ofs = ofs;
    r->data = data;
    r->time = SDL_GetTicks();
    r->seq = ++g_mouse.seq;
}

/* Called by the platform layer for every SDL event it pumps, on any thread. */
void dinput_handle_event(const SDL_Event *e) {
    pthread_mutex_lock(&g_di_lock);
    g_di_fed = 1;
    switch (e->type) {
    case SDL_MOUSEMOTION:
        if (e->motion.which == SDL_TOUCH_MOUSEID) break;
        g_mouse.dx += e->motion.xrel;
        g_mouse.dy += e->motion.yrel;
        if (e->motion.xrel) mouse_record(0, (uint32_t)e->motion.xrel);  /* DIMOFS_X */
        if (e->motion.yrel) mouse_record(4, (uint32_t)e->motion.yrel);  /* DIMOFS_Y */
        break;
    case SDL_MOUSEWHEEL: {
        if (e->wheel.which == SDL_TOUCH_MOUSEID) break;
        /* y follows the system's scroll direction (natural scrolling) setting */
        int32_t z = e->wheel.y * 120;
        g_mouse.dz += z;
        if (z) mouse_record(8, (uint32_t)z);  /* DIMOFS_Z */
        break;
    }
    case SDL_MOUSEBUTTONDOWN:
    case SDL_MOUSEBUTTONUP: {
        if (e->button.which == SDL_TOUCH_MOUSEID) break;
        int b = di_button_of(e->button.button);
        if (b < 0) break;
        uint8_t bit = (uint8_t)(1u << b);
        int down = e->type == SDL_MOUSEBUTTONDOWN;
        if (down) { g_mouse.held |= bit; g_mouse.presses[b]++; }
        else g_mouse.held &= (uint8_t)~bit;
        mouse_record(12u + (uint32_t)b, down ? 0x80 : 0);  /* DIMOFS_BUTTONn */
        break;
    }
    case SDL_KEYDOWN:
        if (!e->key.repeat) {
            uint8_t k = dik_of(e->key.keysym.scancode);
            if (k) g_key_presses[k]++;
        }
        break;
    case SDL_WINDOWEVENT:
        /* a release outside the window (after Cmd-Tab) may never arrive */
        if (e->window.event == SDL_WINDOWEVENT_FOCUS_LOST) {
            for (uint32_t b = 0; b < 8; b++)
                if (g_mouse.held & (1u << b)) mouse_record(12u + b, 0);
            g_mouse.held = 0;
            g_mouse.dx = g_mouse.dy = g_mouse.dz = 0;
        }
        break;
    }
    pthread_mutex_unlock(&g_di_lock);
}

/* Keys pressed since this device last reported them read as down, once. */
static void key_presses_merge(uint32_t seen[256], uint8_t *state, uint32_t n, int consume) {
    pthread_mutex_lock(&g_di_lock);
    for (uint32_t k = 0; k < 256 && k < n; k++)
        if (seen[k] != g_key_presses[k]) {
            state[k] = 0x80;
            if (consume) seen[k] = g_key_presses[k];
        }
    pthread_mutex_unlock(&g_di_lock);
}

/* DIMOUSESTATE(2): lX, lY, lZ, then 4 (or 8) buttons. */
static void mouse_state(DIDev *d, uint32_t p, uint32_t n) {
    int32_t x, y, z = 0;
    uint8_t b = 0;
    pthread_mutex_lock(&g_di_lock);
    if (g_di_fed) {
        x = g_mouse.dx; y = g_mouse.dy; z = g_mouse.dz;
        g_mouse.dx = g_mouse.dy = g_mouse.dz = 0;
        b = g_mouse.held;
        for (int i = 0; i < 8; i++)
            if (d->seen_state[i] != g_mouse.presses[i]) { b |= (uint8_t)(1u << i); d->seen_state[i] = g_mouse.presses[i]; }
    } else {
        Uint32 s = SDL_GetRelativeMouseState(&x, &y);
        if (s & SDL_BUTTON_LMASK) b |= 1;
        if (s & SDL_BUTTON_RMASK) b |= 2;
        if (s & SDL_BUTTON_MMASK) b |= 4;
        if (s & SDL_BUTTON_X1MASK) b |= 8;
        if (s & SDL_BUTTON_X2MASK) b |= 16;
    }
    pthread_mutex_unlock(&g_di_lock);
    if (n >= 4) M32(p) = (uint32_t)x;
    if (n >= 8) M32(p + 4) = (uint32_t)y;
    if (n >= 12) M32(p + 8) = (uint32_t)z;
    for (uint32_t i = 0; i < 8 && 12 + i < n; i++)
        M8(p + 12 + i) = (b & (1u << i)) ? 0x80 : 0;
}
#endif

/* ---------------- IDirectInputDevice8A ---------------- */
SHIM(dev_QueryInterface) { if (ARG(2)) M32(ARG(2)) = ARG(0); hcom_addref(ARG(0)); RET(0, 3); }
SHIM(dev_AddRef) { RET(hcom_addref(ARG(0)), 1); }
SHIM(dev_Release) {
    uint32_t left;
    void *h = hcom_host(ARG(0));
    if (hcom_release(ARG(0), &left)) free(h);
    RET(left, 1);
}
SHIM(dev_GetCapabilities) {
    DIDev *d = hcom_host(ARG(0));
    uint32_t p = ARG(1);
    uint32_t sz = M32(p);
    memset(MEM + p + 4, 0, sz - 4);
    M32(p + 4) = 0x5; /* DIDC_ATTACHED | DIDC_EMULATED */
    M32(p + 8) = d->kind == DEV_KEYBOARD ? 0x13 : 0x12;
    M32(p + 16) = d->kind == DEV_KEYBOARD ? 128 : 3;
    RET(0, 2);
}
SHIM(dev_EnumObjects) { RET(0, 4); }
SHIM(dev_GetProperty) { RET(E_NOTIMPL_, 3); }
SHIM(dev_SetProperty) { RET(0, 3); }
SHIM(dev_Acquire) { RET(0, 1); }
SHIM(dev_Unacquire) { RET(0, 1); }
SHIM(dev_GetDeviceState) {
    DIDev *d = hcom_host(ARG(0));
    uint32_t n = ARG(1), p = ARG(2);
    memset(MEM + p, 0, n);
    if (d->kind == DEV_KEYBOARD) {
        int nk;
        const Uint8 *ks = platform_keys(&nk);
        for (int i = 0; i < nk; i++)
            if (ks[i]) {
                uint8_t k = dik_of((SDL_Scancode)i);
                if (k && k < n) M8(p + k) = 0x80;
            }
#if DI_APPLE
        key_presses_merge(d->seen_state, MEM + p, n, 1);
#endif
    } else {
#if DI_APPLE
        mouse_state(d, p, n);
#else
        int x, y;
        Uint32 b = SDL_GetRelativeMouseState(&x, &y);
        M32(p) = (uint32_t)x;
        M32(p + 4) = (uint32_t)y;
        M32(p + 8) = 0;
        for (int i = 0; i < 3 && 12 + (uint32_t)i < n; i++)
            M8(p + 12 + i) = (b & SDL_BUTTON(i + 1)) ? 0x80 : 0;
#endif
    }
    RET(0, 3);
}
/* Buffered input: key transitions since the last call, as DIDEVICEOBJECTDATA. */
#if DI_APPLE
static void dik_state(DIDev *d, uint8_t out[256], int consume) {
#else
static void dik_state(uint8_t out[256]) {
#endif
    int nk;
    const Uint8 *ks = platform_keys(&nk);
    memset(out, 0, 256);
    for (int i = 0; i < nk; i++)
        if (ks[i]) {
            uint8_t k = dik_of((SDL_Scancode)i);
            if (k) out[k] = 0x80;
        }
#if DI_APPLE
    key_presses_merge(d->seen_data, out, 256, consume);
#endif
}
SHIM(dev_GetDeviceData) {
    DIDev *d = hcom_host(ARG(0));
    uint32_t sz = ARG(1), buf = ARG(2), pn = ARG(3), flags = ARG(4);
    uint32_t cap = pn ? M32(pn) : 0, n = 0;
    if (d->kind == DEV_KEYBOARD) {
        uint8_t cur[256];
#if DI_APPLE
        dik_state(d, cur, !(flags & 1));  /* DIGDD_PEEK does not consume presses */
#else
        dik_state(cur);
#endif
        for (int k = 0; k < 256 && n < cap; k++) {
            if (cur[k] == d->prev[k]) continue;
            if (buf) {
                uint32_t e = buf + n * sz;
                memset(MEM + e, 0, sz);
                M32(e) = (uint32_t)k;
                M32(e + 4) = cur[k];
                M32(e + 8) = SDL_GetTicks();
                M32(e + 12) = ++d->seq;
            }
            if (!(flags & 1)) d->prev[k] = cur[k]; /* DIGDD_PEEK leaves the buffer */
            n++;
        }
    }
#if DI_APPLE
    else {
        /* buf NULL with *pn INFINITE flushes everything, as in DirectInput */
        pthread_mutex_lock(&g_di_lock);
        uint32_t avail = g_mouse.tail - g_mouse.head;
        for (; n < avail && n < cap; n++) {
            if (!buf) continue;
            const DIMouseRec *r = &g_mouse.q[(g_mouse.head + n) % DI_MOUSE_QUEUE];
            uint32_t e = buf + n * sz;
            memset(MEM + e, 0, sz);
            if (sz >= 4) M32(e) = r->ofs;
            if (sz >= 8) M32(e + 4) = r->data;
            if (sz >= 12) M32(e + 8) = r->time;
            if (sz >= 16) M32(e + 12) = r->seq;
        }
        if (!(flags & 1)) g_mouse.head += n;  /* DIGDD_PEEK leaves the buffer */
        pthread_mutex_unlock(&g_di_lock);
    }
#endif
    if (pn) M32(pn) = n;
    RET(0, 5);
}
SHIM(dev_SetDataFormat) { RET(0, 2); }
SHIM(dev_SetEventNotification) { RET(0, 2); }
SHIM(dev_SetCooperativeLevel) { RET(0, 3); }
SHIM(dev_GetObjectInfo) { RET(E_NOTIMPL_, 4); }
SHIM(dev_GetDeviceInfo) { RET(E_NOTIMPL_, 2); }
SHIM(dev_RunControlPanel) { RET(0, 3); }
SHIM(dev_Initialize) { RET(0, 4); }
SHIM(dev_CreateEffect) { RET(E_NOTIMPL_, 5); }
SHIM(dev_EnumEffects) { RET(0, 4); }
SHIM(dev_GetEffectInfo) { RET(E_NOTIMPL_, 3); }
SHIM(dev_GetForceFeedbackState) { RET(E_NOTIMPL_, 2); }
SHIM(dev_SendForceFeedbackCommand) { RET(E_NOTIMPL_, 2); }
SHIM(dev_EnumCreatedEffectObjects) { RET(0, 4); }
SHIM(dev_Escape) { RET(E_NOTIMPL_, 2); }
SHIM(dev_Poll) { RET(1, 1); } /* DI_NOEFFECT */
SHIM(dev_SendDeviceData) { RET(E_NOTIMPL_, 5); }
SHIM(dev_EnumEffectsInFile) { RET(E_NOTIMPL_, 5); }
SHIM(dev_WriteEffectToFile) { RET(E_NOTIMPL_, 5); }
SHIM(dev_BuildActionMap) { RET(E_NOTIMPL_, 4); }
SHIM(dev_SetActionMap) { RET(E_NOTIMPL_, 4); }
SHIM(dev_GetImageInfo) { RET(E_NOTIMPL_, 2); }

static const ShimFn k_dev_fns[] = {
    shim_dev_QueryInterface, shim_dev_AddRef, shim_dev_Release, shim_dev_GetCapabilities, shim_dev_EnumObjects,
    shim_dev_GetProperty, shim_dev_SetProperty, shim_dev_Acquire, shim_dev_Unacquire, shim_dev_GetDeviceState,
    shim_dev_GetDeviceData, shim_dev_SetDataFormat, shim_dev_SetEventNotification, shim_dev_SetCooperativeLevel,
    shim_dev_GetObjectInfo, shim_dev_GetDeviceInfo, shim_dev_RunControlPanel, shim_dev_Initialize,
    shim_dev_CreateEffect, shim_dev_EnumEffects, shim_dev_GetEffectInfo, shim_dev_GetForceFeedbackState,
    shim_dev_SendForceFeedbackCommand, shim_dev_EnumCreatedEffectObjects, shim_dev_Escape, shim_dev_Poll,
    shim_dev_SendDeviceData, shim_dev_EnumEffectsInFile, shim_dev_WriteEffectToFile, shim_dev_BuildActionMap,
    shim_dev_SetActionMap, shim_dev_GetImageInfo,
};

/* ---------------- IDirectInput8A ---------------- */
SHIM(di_QueryInterface) { if (ARG(2)) M32(ARG(2)) = ARG(0); hcom_addref(ARG(0)); RET(0, 3); }
SHIM(di_AddRef) { RET(hcom_addref(ARG(0)), 1); }
SHIM(di_Release) { uint32_t left; hcom_release(ARG(0), &left); RET(left, 1); }
SHIM(di_CreateDevice) {
    uint32_t guid = ARG(1);
    int kind;
    if (guid_eq(guid, GUID_SysKeyboard)) kind = DEV_KEYBOARD;
    else if (guid_eq(guid, GUID_SysMouse)) kind = DEV_MOUSE;
    else { M32(ARG(2)) = 0; RET(0x80040154u, 4); } /* DIERR_DEVICENOTREG */
    DIDev *d = calloc(1, sizeof *d);
    d->kind = kind;
#if DI_APPLE
    /* a new device reports presses from now on, not earlier ones */
    pthread_mutex_lock(&g_di_lock);
    for (int i = 0; i < 256; i++) d->seen_state[i] = d->seen_data[i] = g_key_presses[i];
    if (kind == DEV_MOUSE)
        for (int i = 0; i < 8; i++) d->seen_state[i] = g_mouse.presses[i];
    pthread_mutex_unlock(&g_di_lock);
#endif
    M32(ARG(2)) = hcom_new(&k_didev, d);
    LOG("DirectInput: created %s", kind == DEV_KEYBOARD ? "keyboard" : "mouse");
    RET(0, 4);
}
/* Enumerates the system keyboard and mouse; pads go through XInput. */
static int enum_one(CPU *c, uint32_t cb, uint32_t ref, const uint8_t guid[16], uint32_t type, const char *name) {
    uint32_t d = gmalloc(0x244);
    memset(MEM + d, 0, 0x244);
    M32(d) = 0x244;
    static const uint8_t xinput_product[16] = {0x5E, 0x04, 0x8E, 0x02, 0, 0, 0, 0, 0, 0, 'P', 'I', 'D', 'V', 'I', 'D'};
    memcpy(MEM + d + 4, guid, 16);
    memcpy(MEM + d + 0x14, (type & 0xFF) == 0x15 ? xinput_product : guid, 16);
    M32(d + 0x24) = type;
    snprintf((char *)MEM + d + 0x28, 260, "%s", name);
    snprintf((char *)MEM + d + 0x12C, 260, "%s", name);
    uint32_t args[2] = {d, ref};
    uint32_t r = rt_invoke(c, cb, 2, args);
    gfree(d);
    return r != 0; /* DIENUM_CONTINUE */
}
SHIM(di_EnumDevices) {
    /* (this, dwDevType, lpCallback, pvRef, dwFlags) */
    uint32_t cls = ARG(1), cb = ARG(2), ref = ARG(3);
    int go = 1;
    if (cls == 0 || cls == 3 || cls == 0x13) go = enum_one(c, cb, ref, GUID_SysKeyboard, 0x413, "Keyboard");
    if (go && (cls == 0 || cls == 2 || cls == 0x12)) go = enum_one(c, cb, ref, GUID_SysMouse, 0x112, "Mouse");
    if (cls == 0 || cls == 4 || (cls >= 0x14 && cls <= 0x18)) {
        extern int input_pad_count(void);
        int n = input_pad_count();
        for (int i = 0; go && i < n; i++) {
            /* guidProduct = "Controller (XBOX 360 For Windows)": VID 045E PID 028E */
            uint8_t inst[16] = {0x10 + i, 0x4C, 0xB0, 0x1B, 0, 0, 0, 0, 'L', 'B', 'P', 'A', 'D', 0, 0, 0};
            go = enum_one(c, cb, ref, inst, 0x10215, "Controller (XBOX 360 For Windows)");
        }
        LOG("DirectInput: listed %d XInput pad(s)", n);
    }
    RET(0, 5);
}
SHIM(di_GetDeviceStatus) { RET(guid_eq(ARG(1), GUID_SysKeyboard) || guid_eq(ARG(1), GUID_SysMouse) ? 0 : 1, 2); }
SHIM(di_RunControlPanel) { RET(0, 3); }
SHIM(di_Initialize) { RET(0, 3); }
SHIM(di_FindDevice) { RET(E_FAIL_, 4); }
SHIM(di_EnumDevicesBySemantics) { RET(0, 6); }
SHIM(di_ConfigureDevices) { RET(E_NOTIMPL_, 5); }

static const ShimFn k_di_fns[] = {
    shim_di_QueryInterface, shim_di_AddRef, shim_di_Release, shim_di_CreateDevice, shim_di_EnumDevices,
    shim_di_GetDeviceStatus, shim_di_RunControlPanel, shim_di_Initialize, shim_di_FindDevice,
    shim_di_EnumDevicesBySemantics, shim_di_ConfigureDevices,
};

SHIM(DirectInput8Create) {
    /* (hinst, version, riid, ppvOut, punkOuter) */
    static int init;
    if (!init) {
        hcom_class_init(&k_di8, "IDirectInput8A", k_di_fns, sizeof k_di_fns / sizeof k_di_fns[0]);
        hcom_class_init(&k_didev, "IDirectInputDevice8A", k_dev_fns, sizeof k_dev_fns / sizeof k_dev_fns[0]);
        init = 1;
    }
    M32(ARG(3)) = hcom_new(&k_di8, NULL);
    RET(0, 5);
}

static const ShimDef defs[] = {
    {"DINPUT8.dll", "DirectInput8Create", shim_DirectInput8Create},
    {NULL, NULL, NULL}
};

void dinput_init(void) { rt_register_shims(defs); }
