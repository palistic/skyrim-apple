// D3D9 DrawIndexedPrimitive base vertices through DXVK and MoltenVK on this
// GPU, drawn natively or emulated as on the iOS Simulator, whose Metal device
// cannot draw with a base vertex (DXVK_FORCE_BASE_VERTEX_FOLD=1 forces the
// Simulator path here: fold the base into the stream offsets, or rebase the
// indices when a negative base would move a stream before its buffer start).
//
// Streams of one vs_3_0 declaration:
//   0  per vertex, stride 24 at D3D9 offset 48: float4 position, D3DCOLOR red
//   1  per vertex, stride 12 at offset 36: float2 (0, green)
//   2  stride 0 at offset 4: float3 (0, 0, blue), a constant attribute
//   3  stride 0 zero translation; in the instanced phase per-instance
//      translations, stride 16 at offset 16
// Quad q owns vertices 4q..4q+3, placed inside 8x8 cell q of a 64x64 target
// with a red and green unique to q, so a draw that fetches the wrong
// vertices, streams or instances lands in the wrong cell or colour. The bytes
// before each stream offset are sentinels (magenta geometry in cell 1).
//
// The draws cover positive bases, a negative base that folds, negative bases
// that do not (16-bit and 32-bit indices, managed and dynamic index buffers,
// one stream or both), repeated draws of one index range with different
// bases, non-indexed draws right after folded and rebased draws (binding
// restoration), and instanced draws with a folded and a rebased base.
//
// Without arguments it renders once and checks every cell against the
// expected colours. --compare runs itself natively and with the fold forced
// and also requires the two images to match pixel for pixel.
#include <SDL2/SDL.h>
#include <SDL2/SDL_vulkan.h>
#include <d3d9.h>
#include <wsi/native_wsi.h>
#include <mach-o/dyld.h>
#include <spawn.h>
#include <sys/wait.h>
#include <unistd.h>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <stdexcept>
#include <string>
#include <vector>

extern char** environ;

static void check(HRESULT hr, const char* what) {
  if (FAILED(hr)) {
    char detail[160];
    std::snprintf(detail, sizeof detail, "%s failed: 0x%08x", what, unsigned(hr));
    throw std::runtime_error(detail);
  }
}

// vs_3_0
//   dcl_position v0 / dcl_color v1 / dcl_texcoord0 v2 / dcl_texcoord1 v3 / dcl_texcoord2 v4
//   dcl_position o0 / dcl_color o1
//   add r0, v0, v4 / mov o0, r0 / add r1, v1, v2 / add o1, r1, v3
static const DWORD kVertexShader[] = {
  0xFFFE0300,
  0x0200001F, 0x80000000, 0x900F0000,
  0x0200001F, 0x8000000A, 0x900F0001,
  0x0200001F, 0x80000005, 0x900F0002,
  0x0200001F, 0x80010005, 0x900F0003,
  0x0200001F, 0x80020005, 0x900F0004,
  0x0200001F, 0x80000000, 0xE00F0000,
  0x0200001F, 0x8000000A, 0xE00F0001,
  0x03000002, 0x800F0000, 0x90E40000, 0x90E40004,
  0x02000001, 0xE00F0000, 0x80E40000,
  0x03000002, 0x800F0001, 0x90E40001, 0x90E40002,
  0x03000002, 0xE00F0001, 0x80E40001, 0x90E40003,
  0x0000FFFF };

// ps_3_0 / dcl_color v0 / mov oC0, v0
static const DWORD kPixelShader[] = {
  0xFFFF0300,
  0x0200001F, 0x8000000A, 0x900F0000,
  0x02000001, 0x800F0800, 0x90E40000,
  0x0000FFFF };

struct PosColor { float x, y, z, w; uint32_t color, pad; };
struct Green    { float zero, g, pad; };
static_assert(sizeof(PosColor) == 24 && sizeof(Green) == 12, "stream strides");

constexpr int      kSize = 64, kCell = 8, kQuads = 17;
constexpr UINT     kOffset0 = 48, kOffset1 = 36, kOffset2 = 4, kOffset3 = 16;
constexpr uint32_t kClear = 0x0A141E, kSentinel = 0xFF00FF;
constexpr uint32_t kBlue = 0x40;

static uint32_t quadRed(int q)   { return uint32_t(14 * (q + 1)); }
static uint32_t quadGreen(int q) { return uint32_t(255 - 13 * q); }
static uint32_t quadRgb(int q)   { return quadRed(q) << 16 | quadGreen(q) << 8 | kBlue; }

static PosColor corner(int cell, int corner, uint32_t argb) {
  // Corners 0 TL, 1 TR, 2 BL, 3 BR, inset 1.25 px so that no edge is near a
  // pixel centre under either half-pixel convention.
  const float px = float(cell % 8 * kCell) + (corner & 1 ? 6.75f : 1.25f);
  const float py = float(cell / 8 * kCell) + (corner & 2 ? 6.75f : 1.25f);
  return { px / 32.0f - 1.0f, 1.0f - py / 32.0f, 0.5f, 1.0f, argb, 0 };
}

template <typename T>
static IDirect3DVertexBuffer9* vertexBuffer(IDirect3DDevice9* device, DWORD usage, D3DPOOL pool,
    const std::vector<T>& data) {
  const UINT size = UINT(data.size() * sizeof(T));
  IDirect3DVertexBuffer9* vb = nullptr;
  check(device->CreateVertexBuffer(size, usage, 0, pool, &vb, nullptr), "CreateVertexBuffer");
  void* p = nullptr;
  check(vb->Lock(0, 0, &p, 0), "Lock(vertex)");
  std::memcpy(p, data.data(), size);
  check(vb->Unlock(), "Unlock(vertex)");
  return vb;
}

static uint64_t fnv1a(const uint32_t* pixels, size_t count) {
  uint64_t h = 1469598103934665603ull;
  for (size_t i = 0; i < count; ++i)
    for (int c = 2; c >= 0; --c) { h ^= (pixels[i] >> (8 * c)) & 255u; h *= 1099511628211ull; }
  return h;
}

static int render(const char* dumpPath) {
  const char* env = std::getenv("DXVK_FORCE_BASE_VERTEX_FOLD");
  const bool forced = env && std::strcmp(env, "1") == 0;
  SDL_setenv("DXVK_CONFIG_FILE", SKYRIM_GRAPHICS_CONFIG_PATH, 1);
  if (SDL_Init(SDL_INIT_VIDEO) != 0) throw std::runtime_error(SDL_GetError());
  if (SDL_Vulkan_LoadLibrary(SKYRIM_MOLTENVK_LIBRARY_PATH) != 0)
    throw std::runtime_error(SDL_GetError());
  SDL_Window* window = SDL_CreateWindow("Skyrim base vertex probe", SDL_WINDOWPOS_UNDEFINED,
      SDL_WINDOWPOS_UNDEFINED, kSize, kSize, SDL_WINDOW_VULKAN | SDL_WINDOW_HIDDEN);
  if (!window) throw std::runtime_error(SDL_GetError());
  IDirect3D9* d3d = Direct3DCreate9(D3D_SDK_VERSION);
  if (!d3d || !d3d->GetAdapterCount()) throw std::runtime_error("No D3D9 adapter");
  D3DADAPTER_IDENTIFIER9 adapter{};
  check(d3d->GetAdapterIdentifier(0, 0, &adapter), "GetAdapterIdentifier");
  D3DPRESENT_PARAMETERS pp{};
  pp.BackBufferWidth = pp.BackBufferHeight = kSize;
  pp.BackBufferFormat = D3DFMT_A8R8G8B8;
  pp.BackBufferCount = 1;
  pp.SwapEffect = D3DSWAPEFFECT_DISCARD;
  pp.hDeviceWindow = dxvk::wsi::toHwnd(window);
  pp.Windowed = TRUE;
  pp.PresentationInterval = D3DPRESENT_INTERVAL_IMMEDIATE;
  IDirect3DDevice9* device = nullptr;
  check(d3d->CreateDevice(0, D3DDEVTYPE_HAL, pp.hDeviceWindow,
      D3DCREATE_HARDWARE_VERTEXPROCESSING, &pp, &device), "CreateDevice");

  // Stream 0: two sentinel vertices before offset 48, then 4 per quad.
  std::vector<PosColor> s0;
  s0.push_back(corner(1, 0, 0xFF000000u | kSentinel));
  s0.push_back(corner(1, 3, 0xFF000000u | kSentinel));
  for (int q = 0; q < kQuads; ++q)
    for (int c = 0; c < 4; ++c) s0.push_back(corner(q, c, 0xFF000000u | quadRed(q) << 16));
  // Stream 1: three sentinels before offset 36, then green per vertex.
  std::vector<Green> s1(3, Green{ 0.0f, 1.0f, 0.0f });
  for (int q = 0; q < kQuads; ++q)
    for (int c = 0; c < 4; ++c) s1.push_back({ 0.0f, float(quadGreen(q)) / 255.0f, 0.0f });
  // Stream 2: one float of padding, then the constant (0, 0, blue).
  const std::vector<float> s2 = { 9.0f, 0.0f, 0.0f, float(kBlue) / 255.0f };
  // Stream 3: a sentinel, instance 0 at rest, instance 1 one cell row down.
  const std::vector<float> s3 = { 0.5f, 0.5f, 0.0f, 0.0f,  0.0f, 0.0f, 0.0f, 0.0f,
                                  0.0f, -0.25f, 0.0f, 0.0f };

  IDirect3DVertexBuffer9* vb0 = vertexBuffer(device, D3DUSAGE_WRITEONLY, D3DPOOL_DEFAULT, s0);
  IDirect3DVertexBuffer9* vb1 = vertexBuffer(device, D3DUSAGE_WRITEONLY, D3DPOOL_DEFAULT, s1);
  IDirect3DVertexBuffer9* vb2 = vertexBuffer(device, 0, D3DPOOL_MANAGED, s2);
  IDirect3DVertexBuffer9* vb3 = vertexBuffer(device, D3DUSAGE_WRITEONLY, D3DPOOL_DEFAULT, s3);

  // 16-bit indices, a managed (staging-backed) buffer. Six per quad:
  // TL TR BL / BL TR BR relative to 4q, plus whatever the base takes away.
  auto quad = [](int first) {
    return std::vector<int>{ first, first + 1, first + 2, first + 2, first + 1, first + 3 };
  };
  std::vector<uint16_t> i16;
  for (int first : { 0, 18, 23, 24, 48, 1052, 63 })
    for (int i : quad(first)) i16.push_back(uint16_t(i));
  enum : UINT { G0 = 0, G1 = 6, G2 = 12, G3 = 18, G4 = 24, G5 = 30, G6 = 36 };
  IDirect3DIndexBuffer9* ib16 = nullptr;
  check(device->CreateIndexBuffer(UINT(i16.size() * 2), 0, D3DFMT_INDEX16, D3DPOOL_MANAGED,
      &ib16, nullptr), "CreateIndexBuffer(16)");
  void* p = nullptr;
  check(ib16->Lock(0, 0, &p, 0), "Lock(ib16)");
  std::memcpy(p, i16.data(), i16.size() * 2);
  check(ib16->Unlock(), "Unlock(ib16)");
  // 32-bit indices beyond 16 bits in a dynamic, directly mapped buffer.
  IDirect3DIndexBuffer9* ib32 = nullptr;
  check(device->CreateIndexBuffer(6 * 4, D3DUSAGE_DYNAMIC | D3DUSAGE_WRITEONLY, D3DFMT_INDEX32,
      D3DPOOL_DEFAULT, &ib32, nullptr), "CreateIndexBuffer(32)");
  check(ib32->Lock(0, 0, &p, D3DLOCK_DISCARD), "Lock(ib32)");
  std::vector<uint32_t> i32;
  for (int i : quad(70044)) i32.push_back(uint32_t(i));
  std::memcpy(p, i32.data(), i32.size() * 4);
  check(ib32->Unlock(), "Unlock(ib32)");

  const D3DVERTEXELEMENT9 elements[] = {
    { 0,  0, D3DDECLTYPE_FLOAT4,   D3DDECLMETHOD_DEFAULT, D3DDECLUSAGE_POSITION, 0 },
    { 0, 16, D3DDECLTYPE_D3DCOLOR, D3DDECLMETHOD_DEFAULT, D3DDECLUSAGE_COLOR,    0 },
    { 1,  0, D3DDECLTYPE_FLOAT2,   D3DDECLMETHOD_DEFAULT, D3DDECLUSAGE_TEXCOORD, 0 },
    { 2,  0, D3DDECLTYPE_FLOAT3,   D3DDECLMETHOD_DEFAULT, D3DDECLUSAGE_TEXCOORD, 1 },
    { 3,  0, D3DDECLTYPE_FLOAT4,   D3DDECLMETHOD_DEFAULT, D3DDECLUSAGE_TEXCOORD, 2 },
    D3DDECL_END() };
  IDirect3DVertexDeclaration9* decl = nullptr;
  IDirect3DVertexShader9* vs = nullptr;
  IDirect3DPixelShader9* ps = nullptr;
  check(device->CreateVertexDeclaration(elements, &decl), "CreateVertexDeclaration");
  check(device->CreateVertexShader(kVertexShader, &vs), "CreateVertexShader");
  check(device->CreatePixelShader(kPixelShader, &ps), "CreatePixelShader");

  check(device->SetRenderState(D3DRS_CULLMODE, D3DCULL_NONE), "CULLMODE");
  check(device->SetRenderState(D3DRS_LIGHTING, FALSE), "LIGHTING");
  check(device->SetRenderState(D3DRS_ZENABLE, FALSE), "ZENABLE");
  check(device->SetVertexDeclaration(decl), "SetVertexDeclaration");
  check(device->SetVertexShader(vs), "SetVertexShader");
  check(device->SetPixelShader(ps), "SetPixelShader");
  check(device->SetStreamSource(0, vb0, kOffset0, sizeof(PosColor)), "SetStreamSource(0)");
  check(device->SetStreamSource(1, vb1, kOffset1, sizeof(Green)), "SetStreamSource(1)");
  check(device->SetStreamSource(2, vb2, kOffset2, 0), "SetStreamSource(2)");
  check(device->SetStreamSource(3, vb3, kOffset3, 0), "SetStreamSource(3)");
  check(device->SetIndices(ib16), "SetIndices(16)");
  check(device->Clear(0, nullptr, D3DCLEAR_TARGET, 0xFF000000u | kClear, 1.0f, 0), "Clear");

  std::vector<int> expected(64, -1);  // cell -> quad
  auto dip = [&](INT base, UINT start, int q) {
    check(device->DrawIndexedPrimitive(D3DPT_TRIANGLELIST, base, 0, 4, start, 2), "DrawIndexedPrimitive");
    expected[q] = q;
  };
  auto strip = [&](int q) {
    check(device->DrawPrimitive(D3DPT_TRIANGLESTRIP, UINT(4 * q), 2), "DrawPrimitive");
    expected[q] = q;
  };

  check(device->BeginScene(), "BeginScene");
  dip(8, G0, 2);          // positive base: fold
  strip(3);               // non-indexed right after a fold: restored streams
  dip(-2, G1, 4);         // negative base, offsets 48-48 and 36-24: fold
  dip(-3, G2, 5);         // 48-72 < 0: rebased indices
  strip(6);               // non-indexed after a rebase
  dip(4, G3, 7);
  dip(36, G0, 9);         // the G0 indices again with two more bases
  dip(40, G0, 10);
  check(device->SetIndices(ib32), "SetIndices(32)");
  dip(-70000, 0, 11);     // 32-bit rebase, both streams unfoldable
  check(device->SetIndices(ib16), "SetIndices(16)");
  dip(0, G4, 12);         // no base vertex
  dip(-1000, G5, 13);     // 16-bit rebase, both streams unfoldable

  // Two instances; instance 1 is drawn one cell row (8 cells) further on.
  check(device->SetStreamSourceFreq(0, D3DSTREAMSOURCE_INDEXEDDATA | 2u), "SetStreamSourceFreq(0)");
  check(device->SetStreamSource(3, vb3, kOffset3, 16), "SetStreamSource(3, instanced)");
  check(device->SetStreamSourceFreq(3, D3DSTREAMSOURCE_INSTANCEDATA | 1u), "SetStreamSourceFreq(3)");
  dip(56, G0, 14);        // fold must leave the instance stream alone
  expected[22] = 14;
  dip(-3, G6, 15);        // rebased and instanced
  expected[23] = 15;
  check(device->SetStreamSourceFreq(0, 1), "SetStreamSourceFreq(0, 1)");
  check(device->SetStreamSourceFreq(3, 1), "SetStreamSourceFreq(3, 1)");
  check(device->SetStreamSource(3, vb3, kOffset3, 0), "SetStreamSource(3)");
  strip(16);
  check(device->EndScene(), "EndScene");

  IDirect3DSurface9 *backbuffer = nullptr, *readback = nullptr;
  check(device->GetRenderTarget(0, &backbuffer), "GetRenderTarget");
  check(device->CreateOffscreenPlainSurface(kSize, kSize, D3DFMT_A8R8G8B8, D3DPOOL_SYSTEMMEM,
      &readback, nullptr), "CreateOffscreenPlainSurface");
  check(device->GetRenderTargetData(backbuffer, readback), "GetRenderTargetData");
  D3DLOCKED_RECT locked{};
  check(readback->LockRect(&locked, nullptr, D3DLOCK_READONLY), "LockRect");
  std::vector<uint32_t> pixels(kSize * kSize);
  for (int y = 0; y < kSize; ++y)
    for (int x = 0; x < kSize; ++x) {
      uint32_t v;
      std::memcpy(&v, static_cast<const char*>(locked.pBits) + y * locked.Pitch + x * 4, 4);
      pixels[y * kSize + x] = v & 0xFFFFFFu;
    }
  check(readback->UnlockRect(), "UnlockRect");

  // Cell interiors (2..5) carry the quad colour; cell borders stay clear.
  int wrongInterior = 0, wrongBorder = 0, drawnCells = 0;
  std::string wrongCells;
  for (int cell = 0; cell < 64; ++cell) {
    const uint32_t want = expected[cell] < 0 ? kClear : quadRgb(expected[cell]);
    drawnCells += expected[cell] >= 0;
    bool cellOk = true;
    for (int dy = 0; dy < kCell; ++dy)
      for (int dx = 0; dx < kCell; ++dx) {
        const uint32_t got = pixels[(cell / 8 * kCell + dy) * kSize + cell % 8 * kCell + dx];
        const bool interior = dx >= 2 && dx < 6 && dy >= 2 && dy < 6;
        const bool border = dx == 0 || dx == 7 || dy == 0 || dy == 7;
        if (interior && got != want) { ++wrongInterior; cellOk = false; }
        if (border && got != kClear) { ++wrongBorder; cellOk = false; }
      }
    if (!cellOk) {
      char item[48];
      const uint32_t centre = pixels[(cell / 8 * kCell + 4) * kSize + cell % 8 * kCell + 4];
      std::snprintf(item, sizeof item, "%s\"%d:%06x\"", wrongCells.empty() ? "" : ",", cell, centre);
      wrongCells += item;
    }
  }
  const bool pass = wrongInterior == 0 && wrongBorder == 0;
  const uint64_t hash = fnv1a(pixels.data(), pixels.size());

  if (dumpPath) {
    FILE* f = std::fopen(dumpPath, "wb");
    if (!f || std::fwrite(pixels.data(), 4, pixels.size(), f) != pixels.size())
      throw std::runtime_error("cannot write pixel dump");
    std::fclose(f);
  }

  std::printf("{\"probe\":\"d3d9_base_vertex\",\"adapter\":\"%s\",\"fold\":\"%s\",\"drawn_cells\":%d,"
      "\"wrong_interior_px\":%d,\"wrong_border_px\":%d,\"wrong_cells\":[%s],\"rgb_fnv1a64\":\"%016llx\",\"pass\":%s}\n",
      adapter.Description, forced ? "forced" : "native", drawnCells, wrongInterior, wrongBorder,
      wrongCells.c_str(), (unsigned long long)hash, pass ? "true" : "false");
  std::fflush(stdout);

  readback->Release(); backbuffer->Release(); ps->Release(); vs->Release(); decl->Release();
  ib32->Release(); ib16->Release(); vb3->Release(); vb2->Release(); vb1->Release(); vb0->Release();
  device->Release(); d3d->Release();
  SDL_DestroyWindow(window); SDL_Vulkan_UnloadLibrary(); SDL_Quit();
  return pass ? 0 : 2;
}

// Runs this executable with DXVK_FORCE_BASE_VERTEX_FOLD=value and --dump.
static int runChild(const std::string& self, const char* value, const std::string& dump) {
  std::vector<std::string> env;
  for (char** e = environ; *e; ++e)
    if (std::strncmp(*e, "DXVK_FORCE_BASE_VERTEX_FOLD=", 28) != 0) env.emplace_back(*e);
  env.emplace_back(std::string("DXVK_FORCE_BASE_VERTEX_FOLD=") + value);
  std::vector<char*> envp;
  for (auto& s : env) envp.push_back(s.data());
  envp.push_back(nullptr);
  std::string flag = "--dump", path = dump, exe = self;
  char* argv[] = { exe.data(), flag.data(), path.data(), nullptr };
  pid_t pid = 0;
  if (posix_spawn(&pid, self.c_str(), nullptr, nullptr, argv, envp.data()) != 0)
    throw std::runtime_error("posix_spawn failed");
  int status = 0;
  if (waitpid(pid, &status, 0) < 0) throw std::runtime_error("waitpid failed");
  return WIFEXITED(status) ? WEXITSTATUS(status) : 128 + WTERMSIG(status);
}

static std::vector<uint32_t> readDump(const std::string& path) {
  std::vector<uint32_t> pixels(kSize * kSize);
  FILE* f = std::fopen(path.c_str(), "rb");
  const bool ok = f && std::fread(pixels.data(), 4, pixels.size(), f) == pixels.size();
  if (f) std::fclose(f);
  if (!ok) pixels.clear();
  return pixels;
}

static int compare() {
  char self[4096];
  uint32_t size = sizeof self;
  if (_NSGetExecutablePath(self, &size) != 0) throw std::runtime_error("executable path");
  const char* tmp = std::getenv("TMPDIR");
  const std::string base = std::string(tmp ? tmp : "/tmp") + "/base_vertex_fold_" + std::to_string(getpid());
  const int nativeRc = runChild(self, "0", base + ".native");
  const int foldedRc = runChild(self, "1", base + ".folded");
  const auto native = readDump(base + ".native"), folded = readDump(base + ".folded");
  std::remove((base + ".native").c_str());
  std::remove((base + ".folded").c_str());
  int differing = -1;
  if (!native.empty() && native.size() == folded.size()) {
    differing = 0;
    for (size_t i = 0; i < native.size(); ++i) differing += native[i] != folded[i];
  }
  const bool pass = nativeRc == 0 && foldedRc == 0 && differing == 0;
  std::printf("{\"probe\":\"d3d9_base_vertex_compare\",\"native_rc\":%d,\"folded_rc\":%d,"
      "\"differing_px\":%d,\"pass\":%s}\n", nativeRc, foldedRc, differing, pass ? "true" : "false");
  return pass ? 0 : 2;
}

int main(int argc, char** argv) {
  try {
    if (argc == 2 && std::strcmp(argv[1], "--compare") == 0) return compare();
    if (argc == 3 && std::strcmp(argv[1], "--dump") == 0) return render(argv[2]);
    if (argc == 1) return render(nullptr);
    std::fprintf(stderr, "usage: base_vertex_fold_smoke [--compare | --dump FILE]\n");
    return 1;
  } catch (const std::exception& e) {
    std::fprintf(stderr, "base_vertex_fold_smoke: %s\n", e.what());
    SDL_Quit();
    return 1;
  }
}
