/* Skyrim Apple port: DXVK present tap for the visionOS compositor (Apple builds only).
 *
 * Off unless LB_PRESENT_TAP=1 is set and a callback is registered. When on, every D3D9 Present also copies the
 * back buffer into one of three tap-owned Vulkan images, inside DXVK's own command list, so it is ordered after
 * the frame. Then the callback runs on the presenting (game) thread with that image.
 *
 * Consumer contract:
 *  - The callback must not block. Hand the frame to the compositor thread.
 *  - Before reading the image, call skyrim_present_tap_wait(frame->state, frame->frame_id). It blocks until
 *    the GPU has finished the frame (DXVK's CPU-side frame fence).
 *  - Export the image's MTLTexture once per image with vkExportMetalObjectsEXT (VkExportMetalTextureInfoEXT,
 *    .image = frame->vk_image). Images only change when frame->state changes (back-buffer resize).
 *  - Never submit to vk_queue: DXVK owns it.
 *  - Call skyrim_present_tap_release(frame->state, frame->slot) once the compositor's read of the slot has
 *    completed on the GPU. Until then DXVK won't write that slot again. If all slots are held, DXVK
 *    skips the tap for that frame and never stalls the game.
 *  - skyrim_present_tap_ready() is the non-blocking form of _wait, for a compositor that must never miss its
 *    own deadline: take a frame only when it reports ready, otherwise re-present the previous one.
 *
 * Tap-only (exclusive) mode: while the runtime says the immersive layer is running
 * (skyrim_present_tap_set_exclusive(1)) AND a callback is registered AND LB_PRESENT_TAP=1, DXVK skips the WSI
 * swapchain entirely: no acquire, blit or present to the SDL window's CAMetalLayer, which may be hidden and
 * stall. It still records the tap copy and the frame fence. Pacing then comes from the runtime's present pacing,
 * not vsync. The environment variable alone never engages it, and exclusive starts off.
 * Clear it (set_exclusive(0)) before or together with clearing the callback when the immersive layer stops.
 */
#ifndef SKYRIM_PRESENT_TAP_H
#define SKYRIM_PRESENT_TAP_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct skyrim_present_tap_frame {
    void    *vk_device;   /* VkDevice */
    void    *vk_queue;    /* VkQueue DXVK presents on (read only: never submit to it) */
    uint64_t vk_image;    /* VkImage of the tap slot (a copy, not the back buffer itself) */
    uint32_t slot;        /* 0..2 */
    uint32_t width;
    uint32_t height;
    uint32_t vk_format;   /* VkFormat, normally VK_FORMAT_B8G8R8A8_UNORM */
    uint64_t frame_id;    /* pass to skyrim_present_tap_wait */
    void    *state;       /* opaque, holds one reference until skyrim_present_tap_release */
    /* The scene's depth for the same frame, when the runtime named a depth target (skyrim_present_tap_set_depth)
     * and it matched: VK_FORMAT_R32_SFLOAT, D3D depth 0 (near) to 1 (far). depth_vk_image is 0 otherwise. Same
     * slot, fence and release as the colour image. */
    uint64_t depth_vk_image;
    uint32_t depth_width;
    uint32_t depth_height;
    uint32_t depth_vk_format;
} skyrim_present_tap_frame;

typedef void (*skyrim_present_tap_fn)(void *user, const skyrim_present_tap_frame *frame);

/* Register (or clear, with NULL) the callback. Thread-safe. */
void skyrim_present_tap_set(skyrim_present_tap_fn fn, void *user);
/* Block until the GPU has finished the frame that filled the slot. */
void skyrim_present_tap_wait(void *state, uint64_t frame_id);
/* Give the slot back and drop the frame's reference. Call exactly once per callback. */
void skyrim_present_tap_release(void *state, uint32_t slot);
/* Non-blocking: 1 once the GPU has finished the frame that filled the slot, else 0. */
int skyrim_present_tap_ready(void *state, uint64_t frame_id);
/* The D3D9 surface (IDirect3DSurface9 *) holding the scene's depth for the next Present, or NULL. It must stay
 * alive until that Present returns; the runtime sets it right before each Present and clears it after. */
void skyrim_present_tap_set_depth(void *surface);
/* 1 while the immersive layer is running (tap-only presents), 0 otherwise. Thread-safe; takes effect at the
 * next Present. Off by default. */
void skyrim_present_tap_set_exclusive(int on);

#ifdef __cplusplus
}
#endif

#endif /* SKYRIM_PRESENT_TAP_H */
