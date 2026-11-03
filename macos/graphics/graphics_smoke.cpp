#include <SDL2/SDL.h>
#include <SDL2/SDL_vulkan.h>
#include <d3d9.h>
#include <wsi/native_wsi.h>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <stdexcept>

static void check(HRESULT hr, const char* what) {
  if (FAILED(hr)) {
    char detail[160];
    std::snprintf(detail, sizeof detail, "%s failed: 0x%08x", what, unsigned(hr));
    throw std::runtime_error(detail);
  }
}

int main() {
  try {
    // Bound the DXVK worker pool as well as the host build's compiler jobs.
    SDL_setenv("DXVK_CONFIG_FILE", SKYRIM_GRAPHICS_CONFIG_PATH, 1);
    if (SDL_Init(SDL_INIT_VIDEO) != 0) throw std::runtime_error(SDL_GetError());
    if (SDL_Vulkan_LoadLibrary(SKYRIM_MOLTENVK_LIBRARY_PATH) != 0)
      throw std::runtime_error(SDL_GetError());
    SDL_Window* window = SDL_CreateWindow("Skyrim graphics groundwork probe", SDL_WINDOWPOS_UNDEFINED,
        SDL_WINDOWPOS_UNDEFINED, 64, 64, SDL_WINDOW_VULKAN | SDL_WINDOW_HIDDEN);
    if (!window) throw std::runtime_error(SDL_GetError());
    IDirect3D9* d3d = Direct3DCreate9(D3D_SDK_VERSION);
    if (!d3d || !d3d->GetAdapterCount()) throw std::runtime_error("No D3D9 adapter");
    D3DADAPTER_IDENTIFIER9 adapter{};
    check(d3d->GetAdapterIdentifier(0, 0, &adapter), "GetAdapterIdentifier");
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
    check(device->Clear(0, nullptr, D3DCLEAR_TARGET, D3DCOLOR_XRGB(255, 0, 0), 1.0f, 0), "Clear");
    check(device->SetRenderState(D3DRS_CULLMODE, D3DCULL_NONE), "CULLMODE");
    check(device->SetRenderState(D3DRS_LIGHTING, FALSE), "LIGHTING");
    check(device->SetRenderState(D3DRS_ZENABLE, FALSE), "ZENABLE");
    check(device->SetFVF(D3DFVF_XYZRHW | D3DFVF_DIFFUSE), "SetFVF");
    struct Vertex { float x, y, z, rhw; DWORD color; };
    const Vertex triangle[] = {{8, 8, 0, 1, D3DCOLOR_XRGB(0, 255, 0)},
        {56, 8, 0, 1, D3DCOLOR_XRGB(0, 255, 0)}, {32, 56, 0, 1, D3DCOLOR_XRGB(0, 255, 0)}};
    check(device->BeginScene(), "BeginScene");
    check(device->DrawPrimitiveUP(D3DPT_TRIANGLELIST, 1, triangle, sizeof(Vertex)), "DrawPrimitiveUP");
    check(device->EndScene(), "EndScene");
    IDirect3DSurface9 *target = nullptr, *readback = nullptr;
    check(device->GetRenderTarget(0, &target), "GetRenderTarget");
    check(device->CreateOffscreenPlainSurface(64, 64, D3DFMT_A8R8G8B8, D3DPOOL_SYSTEMMEM,
        &readback, nullptr), "CreateOffscreenPlainSurface");
    check(device->GetRenderTargetData(target, readback), "GetRenderTargetData");
    D3DLOCKED_RECT locked{};
    check(readback->LockRect(&locked, nullptr, D3DLOCK_READONLY), "LockRect");
    auto pixel = [&](int x, int y) {
      uint32_t p;
      std::memcpy(&p, static_cast<const char*>(locked.pBits) + y * locked.Pitch + x * 4, 4);
      return p & 0x00ffffffu;
    };
    const uint32_t corner = pixel(1, 1), center = pixel(32, 24);
    unsigned red = 0, green = 0;
    uint64_t hash = 14695981039346656037ull;
    for (int y = 0; y < 64; ++y) for (int x = 0; x < 64; ++x) {
      uint32_t p = pixel(x, y);
      red += p == 0xff0000u;
      green += p == 0x00ff00u;
      for (int b = 0; b < 3; ++b) { hash ^= (p >> (b * 8)) & 255; hash *= 1099511628211ull; }
    }
    check(readback->UnlockRect(), "UnlockRect");
    const bool pass = corner == 0xff0000u && center == 0x00ff00u && red > 2000 && green > 1000;
    std::printf("{\"probe\":\"d3d9_clear_triangle_readback\",\"adapter\":\"%s\",\"width\":64,\"height\":64,\"corner_rgb\":\"%06x\",\"center_rgb\":\"%06x\",\"red_pixels\":%u,\"green_pixels\":%u,\"rgb_fnv1a64\":\"%016llx\",\"pass\":%s}\n",
        adapter.Description, corner, center, red, green, static_cast<unsigned long long>(hash), pass ? "true" : "false");
    readback->Release(); target->Release(); device->Release(); d3d->Release();
    SDL_DestroyWindow(window); SDL_Vulkan_UnloadLibrary(); SDL_Quit();
    return pass ? 0 : 2;
  } catch (const std::exception& e) {
    std::fprintf(stderr, "graphics_smoke: %s\n", e.what());
    SDL_Quit();
    return 1;
  }
}
