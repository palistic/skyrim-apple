// D3D9 hardware shadow-map compare through DXVK and MoltenVK on this GPU.
//
// An 8x8 D24S8 depth texture holds 0.25 in columns 0-3 and 1.0 in columns
// 4-7. A ps_2_0 shader samples it (texld/texldp r0, t0, s0) across a 64x64
// target, eight pixels per texel, and the red channel is read back:
//   rows  0-15  texld,  LINEAR, ref 0.5        2x2 PCF: a ramp over x 28-35
//   rows 16-31  texldp, LINEAR, ref 0.5, q 2   the same ramp (Dref / q)
//   rows 32-47  texld,  POINT,  ref 0.5        a single 0 -> 255 step at x 32
//   rows 48-63  texld,  POINT,  ref 1.25       ref clamped to 1: right side lit
// Comparing a linearly filtered depth instead of filtering the comparison
// results gives a hard 0/255 step in rows 0-31 and fails.
#include <SDL2/SDL.h>
#include <SDL2/SDL_vulkan.h>
#include <d3d9.h>
#include <wsi/native_wsi.h>
#include <algorithm>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <stdexcept>

static void check(HRESULT hr, const char* what) {
  if (FAILED(hr)) {
    char detail[160];
    std::snprintf(detail, sizeof detail, "%s failed: 0x%08x", what, unsigned(hr));
    throw std::runtime_error(detail);
  }
}

// ps_2_0 / dcl t0 / dcl_2d s0 / texld r0, t0, s0 / mov oC0, r0
static const DWORD kTexld[] = {
  0xFFFF0200,
  0x0200001F, 0x80000000, 0xB00F0000,
  0x0200001F, 0x90000000, 0xA00F0800,
  0x03000042, 0x800F0000, 0xB0E40000, 0xA0E40800,
  0x02000001, 0x800F0800, 0x80E40000,
  0x0000FFFF };

// Same with texldp (D3DSI_TEXLD_PROJECT).
static const DWORD kTexldp[] = {
  0xFFFF0200,
  0x0200001F, 0x80000000, 0xB00F0000,
  0x0200001F, 0x90000000, 0xA00F0800,
  0x03010042, 0x800F0000, 0xB0E40000, 0xA0E40800,
  0x02000001, 0x800F0800, 0x80E40000,
  0x0000FFFF };

struct Vertex { float x, y, z, rhw, u, v, r, q; };

int main() {
  try {
    SDL_setenv("DXVK_CONFIG_FILE", SKYRIM_GRAPHICS_CONFIG_PATH, 1);
    if (SDL_Init(SDL_INIT_VIDEO) != 0) throw std::runtime_error(SDL_GetError());
    if (SDL_Vulkan_LoadLibrary(SKYRIM_MOLTENVK_LIBRARY_PATH) != 0)
      throw std::runtime_error(SDL_GetError());
    SDL_Window* window = SDL_CreateWindow("Skyrim depth compare probe", SDL_WINDOWPOS_UNDEFINED,
        SDL_WINDOWPOS_UNDEFINED, 64, 64, SDL_WINDOW_VULKAN | SDL_WINDOW_HIDDEN);
    if (!window) throw std::runtime_error(SDL_GetError());
    IDirect3D9* d3d = Direct3DCreate9(D3D_SDK_VERSION);
    if (!d3d || !d3d->GetAdapterCount()) throw std::runtime_error("No D3D9 adapter");
    D3DADAPTER_IDENTIFIER9 adapter{};
    check(d3d->GetAdapterIdentifier(0, 0, &adapter), "GetAdapterIdentifier");
    check(d3d->CheckDeviceFormat(0, D3DDEVTYPE_HAL, D3DFMT_X8R8G8B8, D3DUSAGE_DEPTHSTENCIL,
        D3DRTYPE_TEXTURE, D3DFMT_D24S8), "CheckDeviceFormat(D24S8 texture)");
    D3DPRESENT_PARAMETERS pp{};
    pp.BackBufferWidth = pp.BackBufferHeight = 64;
    pp.BackBufferFormat = D3DFMT_A8R8G8B8;
    pp.BackBufferCount = 1;
    pp.SwapEffect = D3DSWAPEFFECT_DISCARD;
    pp.hDeviceWindow = dxvk::wsi::toHwnd(window);
    pp.Windowed = TRUE;
    pp.PresentationInterval = D3DPRESENT_INTERVAL_IMMEDIATE;
    IDirect3DDevice9* device = nullptr;
    check(d3d->CreateDevice(0, D3DDEVTYPE_HAL, pp.hDeviceWindow,
        D3DCREATE_HARDWARE_VERTEXPROCESSING, &pp, &device), "CreateDevice");

    // Shadow map: clear to 1.0, then 0.25 in the left half.
    IDirect3DTexture9* shadow = nullptr;
    IDirect3DSurface9 *shadowSurface = nullptr, *smallTarget = nullptr, *backbuffer = nullptr;
    check(device->CreateTexture(8, 8, 1, D3DUSAGE_DEPTHSTENCIL, D3DFMT_D24S8, D3DPOOL_DEFAULT,
        &shadow, nullptr), "CreateTexture(D24S8)");
    check(shadow->GetSurfaceLevel(0, &shadowSurface), "GetSurfaceLevel");
    check(device->CreateRenderTarget(8, 8, D3DFMT_A8R8G8B8, D3DMULTISAMPLE_NONE, 0, FALSE,
        &smallTarget, nullptr), "CreateRenderTarget");
    check(device->GetRenderTarget(0, &backbuffer), "GetRenderTarget");
    check(device->SetRenderTarget(0, smallTarget), "SetRenderTarget(8x8)");
    check(device->SetDepthStencilSurface(shadowSurface), "SetDepthStencilSurface");
    check(device->Clear(0, nullptr, D3DCLEAR_ZBUFFER | D3DCLEAR_STENCIL, 0, 1.0f, 0), "Clear(1.0)");
    const D3DRECT left = { 0, 0, 4, 8 };
    check(device->Clear(1, &left, D3DCLEAR_ZBUFFER, 0, 0.25f, 0), "Clear(0.25)");
    check(device->SetDepthStencilSurface(nullptr), "SetDepthStencilSurface(null)");
    check(device->SetRenderTarget(0, backbuffer), "SetRenderTarget(backbuffer)");

    IDirect3DPixelShader9 *texld = nullptr, *texldp = nullptr;
    check(device->CreatePixelShader(kTexld, &texld), "CreatePixelShader(texld)");
    check(device->CreatePixelShader(kTexldp, &texldp), "CreatePixelShader(texldp)");
    check(device->Clear(0, nullptr, D3DCLEAR_TARGET, D3DCOLOR_XRGB(0, 0, 255), 1.0f, 0), "Clear");
    check(device->SetRenderState(D3DRS_CULLMODE, D3DCULL_NONE), "CULLMODE");
    check(device->SetRenderState(D3DRS_LIGHTING, FALSE), "LIGHTING");
    check(device->SetRenderState(D3DRS_ZENABLE, FALSE), "ZENABLE");
    check(device->SetFVF(D3DFVF_XYZRHW | D3DFVF_TEX1 | D3DFVF_TEXCOORDSIZE4(0)), "SetFVF");
    check(device->SetTexture(0, shadow), "SetTexture");
    check(device->SetSamplerState(0, D3DSAMP_ADDRESSU, D3DTADDRESS_CLAMP), "ADDRESSU");
    check(device->SetSamplerState(0, D3DSAMP_ADDRESSV, D3DTADDRESS_CLAMP), "ADDRESSV");
    check(device->SetSamplerState(0, D3DSAMP_MIPFILTER, D3DTEXF_NONE), "MIPFILTER");

    auto band = [&](float y0, IDirect3DPixelShader9* ps, D3DTEXTUREFILTERTYPE filter, float ref, float q) {
      check(device->SetPixelShader(ps), "SetPixelShader");
      check(device->SetSamplerState(0, D3DSAMP_MAGFILTER, filter), "MAGFILTER");
      check(device->SetSamplerState(0, D3DSAMP_MINFILTER, filter), "MINFILTER");
      // Pixel x samples u = (x + 0.5) / 64: texel centres at x = 3.5 + 8i.
      const float x0 = -0.5f, x1 = 63.5f, top = y0 - 0.5f, bottom = y0 + 15.5f;
      const Vertex quad[] = {
        { x0, top,    0.0f, 1.0f, 0.0f, 0.5f * q, ref * q, q },
        { x1, top,    0.0f, 1.0f, q,    0.5f * q, ref * q, q },
        { x0, bottom, 0.0f, 1.0f, 0.0f, 0.5f * q, ref * q, q },
        { x1, bottom, 0.0f, 1.0f, q,    0.5f * q, ref * q, q } };
      check(device->DrawPrimitiveUP(D3DPT_TRIANGLESTRIP, 2, quad, sizeof(Vertex)), "DrawPrimitiveUP");
    };

    check(device->BeginScene(), "BeginScene");
    band( 0.0f, texld,  D3DTEXF_LINEAR, 0.5f,  1.0f);
    band(16.0f, texldp, D3DTEXF_LINEAR, 0.5f,  2.0f);
    band(32.0f, texld,  D3DTEXF_POINT,  0.5f,  1.0f);
    band(48.0f, texld,  D3DTEXF_POINT,  1.25f, 1.0f);
    check(device->EndScene(), "EndScene");

    IDirect3DSurface9* readback = nullptr;
    check(device->CreateOffscreenPlainSurface(64, 64, D3DFMT_A8R8G8B8, D3DPOOL_SYSTEMMEM,
        &readback, nullptr), "CreateOffscreenPlainSurface");
    check(device->GetRenderTargetData(backbuffer, readback), "GetRenderTargetData");
    D3DLOCKED_RECT locked{};
    check(readback->LockRect(&locked, nullptr, D3DLOCK_READONLY), "LockRect");
    int pcf[64], proj[64], point[64], clamp[64];
    for (int x = 0; x < 64; ++x) {
      auto red = [&](int y) {
        uint32_t p;
        std::memcpy(&p, static_cast<const char*>(locked.pBits) + y * locked.Pitch + x * 4, 4);
        return int((p >> 16) & 255u);
      };
      pcf[x] = red(8); proj[x] = red(24); point[x] = red(40); clamp[x] = red(56);
    }
    check(readback->UnlockRect(), "UnlockRect");

    // Rows 0-15: a monotonic ramp across the texel boundary, not a step.
    bool pcfOk = pcf[0] <= 8 && pcf[25] <= 8 && pcf[38] >= 247 && pcf[63] >= 247;
    int blended = 0;
    for (int x = 1; x < 64; ++x) pcfOk = pcfOk && pcf[x] + 2 >= pcf[x - 1];
    for (int x = 26; x <= 37; ++x) blended += pcf[x] > 8 && pcf[x] < 247;
    pcfOk = pcfOk && blended >= 6 && std::abs(pcf[31] - 112) <= 40 && std::abs(pcf[32] - 143) <= 40;
    // Rows 16-31: projected lookup equals the unprojected one.
    int projDiff = 0;
    for (int x = 0; x < 64; ++x) projDiff = std::max(projDiff, std::abs(proj[x] - pcf[x]));
    // Rows 32-47: binary, one 0 -> 255 transition near x = 32.
    bool pointOk = true;
    int transition = -1;
    for (int x = 0; x < 64; ++x) {
      pointOk = pointOk && (point[x] <= 8 || point[x] >= 247);
      if (x && point[x - 1] <= 8 && point[x] >= 247) transition = transition < 0 ? x : 99;
    }
    pointOk = pointOk && transition >= 30 && transition <= 34;
    // Rows 48-63: ref 1.25 is clamped to 1.0, so 1.0 texels pass, 0.25 texels fail.
    const bool clampOk = clamp[16] <= 8 && clamp[48] >= 247;
    const bool pass = pcfOk && projDiff <= 4 && pointOk && clampOk;

    std::printf("{\"probe\":\"d3d9_depth_compare\",\"adapter\":\"%s\",\"pcf_row_x24_x40\":[", adapter.Description);
    for (int x = 24; x <= 40; ++x) std::printf("%s%d", x > 24 ? "," : "", pcf[x]);
    std::printf("],\"pcf_ok\":%s,\"pcf_blended_pixels\":%d,\"proj_max_diff\":%d,\"point_transition_x\":%d,"
        "\"point_ok\":%s,\"dref_clamp_ok\":%s,\"pass\":%s}\n",
        pcfOk ? "true" : "false", blended, projDiff, transition, pointOk ? "true" : "false",
        clampOk ? "true" : "false", pass ? "true" : "false");

    readback->Release(); texldp->Release(); texld->Release(); backbuffer->Release();
    smallTarget->Release(); shadowSurface->Release(); shadow->Release();
    device->Release(); d3d->Release();
    SDL_DestroyWindow(window); SDL_Vulkan_UnloadLibrary(); SDL_Quit();
    return pass ? 0 : 2;
  } catch (const std::exception& e) {
    std::fprintf(stderr, "depth_compare_smoke: %s\n", e.what());
    SDL_Quit();
    return 1;
  }
}
