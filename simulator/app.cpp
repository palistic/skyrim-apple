#include <SDL2/SDL.h>
#include <SDL2/SDL_vulkan.h>
#include <d3d9.h>
#include <wsi/native_wsi.h>
#include <cstdio>
#include <cstdint>
#include <cstring>
#include <stdexcept>
#include <string>
#include "d3d9_bridge.h"
#ifdef SKYRIM_FFMPEG_AUDIO
#include "codec_probe.h"
#endif
extern "C" {
#include "rt.h"
int simulator_cpu_probe(unsigned *total);
void simulator_prepare_paths(char *, size_t, char *, size_t);
void simulator_show_status(const char *);
int simulator_fixture_path(const char *,char *,size_t);
void platform_init(void);
void *platform_window(void);
}

static void check(HRESULT hr, const char *what) {
    if (FAILED(hr)) {
        char detail[160];
        std::snprintf(detail, sizeof detail, "%s failed: 0x%08x", what, unsigned(hr));
        throw std::runtime_error(detail);
    }
}

static uint32_t guest_method(CPU *cpu,uint32_t object,unsigned method,int count,const uint32_t *arguments) {
    uint32_t vtable=M32(object);
    if(!vtable || !M32(vtable+method*4)) throw std::runtime_error("Guest COM interface has no registered method");
    return rt_invoke(cpu,M32(vtable+method*4),count,arguments);
}

// Exercise the exact guest COM bridge used by the recompiled Windows game.
// The Simulator GPU lacks BC compression, so the real bridge must decode this
// authored DXT1 block into its host texture before an actual GPU sample/readback.
static bool probe_dxt1_bridge(IDirect3D9 *d3d,IDirect3DDevice9 *device,bool *native_bc) {
    *native_bc=SUCCEEDED(d3d->CheckDeviceFormat(0,D3DDEVTYPE_HAL,D3DFMT_X8R8G8B8,0,D3DRTYPE_TEXTURE,D3DFMT_DXT1));
    CPU *cpu=rt_current_cpu();
    if(!cpu) throw std::runtime_error("No genuine guest CPU for COM texture probe");
    uint32_t guest_device=d3d9_wrap(device,IFACE_IDirect3DDevice9);
    uint32_t output=gmalloc(4),locked_output=gmalloc(8);
    uint32_t create[]={guest_device,4,4,1,0,D3DFMT_DXT1,D3DPOOL_MANAGED,output,0};
    check((HRESULT)guest_method(cpu,guest_device,23,9,create),"Guest CreateTexture DXT1");
    uint32_t guest_texture=M32(output);
    if(!guest_texture) throw std::runtime_error("Guest texture result is null");
    uint32_t lock[]={guest_texture,0,locked_output,0,0};
    check((HRESULT)guest_method(cpu,guest_texture,19,5,lock),"Guest LockRect DXT1");
    if(M32(locked_output)!=8) throw std::runtime_error("Guest DXT1 pitch is not its compressed block size");
    const unsigned char red_block[8]={0x00,0xf8,0xe0,0x07,0,0,0,0};
    std::memcpy(GPTR(M32(locked_output+4)),red_block,sizeof red_block);
    uint32_t unlock[]={guest_texture,0};
    check((HRESULT)guest_method(cpu,guest_texture,20,2,unlock),"Guest UnlockRect DXT1");
    auto *texture=static_cast<IDirect3DTexture9 *>(com_host(guest_texture));
    check(device->SetTexture(0,texture),"Bind guest-created texture");
    check(device->SetTextureStageState(0,D3DTSS_COLOROP,D3DTOP_SELECTARG1),"Texture color operation");
    check(device->SetTextureStageState(0,D3DTSS_COLORARG1,D3DTA_TEXTURE),"Texture color argument");
    check(device->SetRenderState(D3DRS_CULLMODE,D3DCULL_NONE),"Texture culling");
    check(device->SetRenderState(D3DRS_LIGHTING,FALSE),"Texture lighting");
    check(device->SetRenderState(D3DRS_ZENABLE,FALSE),"Texture depth");
    check(device->SetFVF(D3DFVF_XYZRHW|D3DFVF_TEX1),"Texture FVF");
    struct Vertex {float x,y,z,rhw,u,v;};
    const Vertex quad[]={{0,0,0,1,0,0},{64,0,0,1,1,0},{0,64,0,1,0,1},{64,64,0,1,1,1}};
    check(device->Clear(0,nullptr,D3DCLEAR_TARGET,D3DCOLOR_XRGB(0,0,255),1,0),"Texture probe clear");
    check(device->BeginScene(),"Texture begin");
    check(device->DrawPrimitiveUP(D3DPT_TRIANGLESTRIP,2,quad,sizeof(Vertex)),"Sample guest DXT1 texture");
    check(device->EndScene(),"Texture end");
    IDirect3DSurface9 *target=nullptr,*readback=nullptr;
    check(device->GetRenderTarget(0,&target),"Texture render target");
    check(device->CreateOffscreenPlainSurface(64,64,D3DFMT_A8R8G8B8,D3DPOOL_SYSTEMMEM,&readback,nullptr),"Texture readback surface");
    check(device->GetRenderTargetData(target,readback),"Texture GPU readback");
    D3DLOCKED_RECT pixels{};check(readback->LockRect(&pixels,nullptr,D3DLOCK_READONLY),"Texture readback lock");
    uint32_t center;std::memcpy(&center,static_cast<char *>(pixels.pBits)+32*pixels.Pitch+32*4,4);
    check(readback->UnlockRect(),"Texture readback unlock");
    readback->Release();target->Release();
    check(device->SetTexture(0,nullptr),"Unbind guest texture");
    check(device->SetTextureStageState(0,D3DTSS_COLORARG1,D3DTA_DIFFUSE),"Restore vertex color");
    uint32_t release[]={guest_texture};guest_method(cpu,guest_texture,2,1,release);
    gfree(output);gfree(locked_output);
    return (center&0xffffffu)==0xff0000u;
}

int main(int argc, char **argv) {
    (void)argc; (void)argv;
    try {
        simulator_prepare_paths(g_game_dir, sizeof g_game_dir, g_save_dir, sizeof g_save_dir);
        char config[1400];
        std::snprintf(config, sizeof config, "%s/dxvk.conf", g_save_dir);
        FILE *f = std::fopen(config, "wb");
        if (!f) throw std::runtime_error("Cannot write private diagnostic renderer config");
        std::fputs("dxvk.numCompilerThreads = 2\n", f);
        std::fclose(f);
        SDL_setenv("DXVK_CONFIG_FILE", config, 1);
        SDL_setenv("DXVK_STATE_CACHE_PATH", g_save_dir, 1);
        unsigned cpu_total = 0;
        int cpu_passed = simulator_cpu_probe(&cpu_total);
        unsigned audio_checks=0,audio_mono_frames=0,audio_surround_frames=0;
#ifdef SKYRIM_FFMPEG_AUDIO
        AudioCodecProbeResult mono{},surround{};
        char sample[1600],audio_error[512]="Bundled codec fixture is missing";
        if(!simulator_fixture_path("musicmono_xwma.wav",sample,sizeof sample) ||
           audio_codec_probe_file(sample,nullptr,&mono,audio_error,sizeof audio_error)!=0)
            throw std::runtime_error(std::string("Native mono xWMA decode: ")+audio_error);
        if(!simulator_fixture_path("musicsurround_xwma.wav",sample,sizeof sample) ||
           audio_codec_probe_file(sample,nullptr,&surround,audio_error,sizeof audio_error)!=0)
            throw std::runtime_error(std::string("Native surround xWMA decode: ")+audio_error);
        if(mono.tag!=0x161 || mono.channels!=1 || surround.tag!=0x162 || surround.channels!=6)
            throw std::runtime_error("Native xWMA corpus formats do not match expected WMAv2/WMAPro inputs");
        audio_checks=mono.checks+surround.checks;
        audio_mono_frames=mono.decoded_frames;
        audio_surround_frames=surround.decoded_frames;
#endif
        if (SDL_Init(SDL_INIT_VIDEO) != 0) throw std::runtime_error(SDL_GetError());
        if (SDL_Vulkan_LoadLibrary(nullptr) != 0) throw std::runtime_error(SDL_GetError());
        platform_init();
        SDL_Window *window = static_cast<SDL_Window *>(platform_window());
        uint32_t sdk_version=D3D_SDK_VERSION;
        uint32_t guest_d3d=rt_invoke(rt_current_cpu(),rt_import("d3d9.dll","Direct3DCreate9"),1,&sdk_version);
        IDirect3D9 *d3d = static_cast<IDirect3D9 *>(com_host(guest_d3d));
        if (!d3d || !d3d->GetAdapterCount()) throw std::runtime_error("No native Simulator D3D9 adapter");
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
        IDirect3DDevice9 *device = nullptr;
        check(d3d->CreateDevice(0, D3DDEVTYPE_HAL, pp.hDeviceWindow,
              D3DCREATE_HARDWARE_VERTEXPROCESSING, &pp, &device), "CreateDevice");
        bool native_bc=false;
        bool dxt1_pass=probe_dxt1_bridge(d3d,device,&native_bc);
        if(!dxt1_pass) throw std::runtime_error("Guest COM DXT1 texture did not survive bridge upload and GPU sampling");
        check(device->Clear(0, nullptr, D3DCLEAR_TARGET, D3DCOLOR_XRGB(255, 0, 0), 1, 0), "Clear");
        check(device->SetRenderState(D3DRS_CULLMODE, D3DCULL_NONE), "Cull");
        check(device->SetRenderState(D3DRS_LIGHTING, FALSE), "Lighting");
        check(device->SetRenderState(D3DRS_ZENABLE, FALSE), "Depth");
        check(device->SetFVF(D3DFVF_XYZRHW | D3DFVF_DIFFUSE), "FVF");
        struct Vertex { float x, y, z, rhw; DWORD color; };
        const Vertex vertices[] = {{8, 8, 0, 1, D3DCOLOR_XRGB(0,255,0)}, {56,8,0,1,D3DCOLOR_XRGB(0,255,0)}, {32,56,0,1,D3DCOLOR_XRGB(0,255,0)}};
        check(device->BeginScene(), "BeginScene");
        check(device->DrawPrimitiveUP(D3DPT_TRIANGLELIST, 1, vertices, sizeof(Vertex)), "Triangle");
        check(device->EndScene(), "EndScene");
        IDirect3DSurface9 *target = nullptr, *readback = nullptr;
        check(device->GetRenderTarget(0, &target), "RenderTarget");
        check(device->CreateOffscreenPlainSurface(64,64,D3DFMT_A8R8G8B8,D3DPOOL_SYSTEMMEM,&readback,nullptr), "ReadbackSurface");
        check(device->GetRenderTargetData(target,readback), "GPUReadback");
        D3DLOCKED_RECT locked{};
        check(readback->LockRect(&locked,nullptr,D3DLOCK_READONLY), "ReadbackLock");
        auto pixel = [&](int x,int y) { uint32_t p; std::memcpy(&p,static_cast<char *>(locked.pBits)+y*locked.Pitch+x*4,4); return p & 0xffffffu; };
        unsigned red=0,green=0;
        uint64_t hash=14695981039346656037ull;
        uint32_t corner=pixel(1,1),center=pixel(32,24);
        for(int y=0;y<64;y++) for(int x=0;x<64;x++) {
            uint32_t p=pixel(x,y); red+=p==0xff0000u; green+=p==0x00ff00u;
            for(int b=0;b<3;b++) { hash^=(p>>(b*8))&255;hash*=1099511628211ull; }
        }
        check(readback->UnlockRect(), "ReadbackUnlock");
        bool gpu_pass=corner==0xff0000u && center==0x00ff00u && red>2000 && green>1000;
        if(!gpu_pass) throw std::runtime_error("Simulator GPU readback did not match expected authored triangle");
        check(device->Present(nullptr,nullptr,nullptr,nullptr), "Present");
        char result[2048];
        std::snprintf(result,sizeof result,"{\"scope\":\"game-free-ipad-simulator\",\"aot_passed\":%d,\"aot_total\":%u,\"guest_memory_executable\":false,\"gpu_readback_pass\":true,\"guest_dxt1_bridge_pass\":%s,\"native_bc_supported\":%s,\"native_xwma_decode_checks\":%u,\"wmav2_mono_frames\":%u,\"wmapro_surround_frames\":%u,\"device_audio_heard\":false,\"adapter\":\"%s\",\"red_pixels\":%u,\"green_pixels\":%u,\"rgb_fnv1a64\":\"%016llx\",\"gameplay_tested\":false}\n",cpu_passed,cpu_total,dxt1_pass?"true":"false",native_bc?"true":"false",audio_checks,audio_mono_frames,audio_surround_frames,adapter.Description,red,green,static_cast<unsigned long long>(hash));
        std::printf("%s",result); std::fflush(stdout);
        char report[1400]; std::snprintf(report,sizeof report,"%s/diagnostic-result.json",g_save_dir);
        f=std::fopen(report,"wb"); if(f) {std::fputs(result,f);std::fclose(f);}
        char status[512];
        std::snprintf(status,sizeof status,"Skyrim JITless port diagnostics\nAuthored Windows x86 → native ARM64: %d/%u checks\nDirect3D 9 / guest DXT1 COM bridge: GPU PASS\nNative WMAv2/WMAPro decode: %u checks\nNo game files loaded. Skyrim gameplay is not tested.",cpu_passed,cpu_total,audio_checks);
        simulator_show_status(status);
        bool running=true;
        while(running) {
            SDL_Event event;
            while(SDL_PollEvent(&event)) if(event.type==SDL_QUIT) running=false;
            SDL_Delay(16);
        }
        readback->Release();target->Release();device->Release();d3d->Release();
        SDL_Quit();
        return 0;
    } catch(const std::exception &error) {
        std::fprintf(stderr,"simulator_probe: %s\n",error.what()); std::fflush(stderr);
        SDL_ShowSimpleMessageBox(SDL_MESSAGEBOX_ERROR,"Skyrim Runtime Probe",error.what(),nullptr);
        return 1;
    }
}
