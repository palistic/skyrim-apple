/* Actual game frontend: built only with privately generated Windows game code. */
#include <SDL2/SDL.h>
#include <cstdio>
extern "C" {
int skyrim_guest_main(int, char **);
int simulator_validate_game_inputs(char *, size_t, char *, size_t, char *, size_t);
}

int main(int argc, char **argv) {
    (void)argc; (void)argv;
    char game[1400], save[1400], error[2048];
    if (!simulator_validate_game_inputs(game,sizeof game,save,sizeof save,error,sizeof error)) {
        std::fprintf(stderr,"Skyrim input validation failed: %s\n",error);
        SDL_ShowSimpleMessageBox(SDL_MESSAGEBOX_ERROR,"Skyrim files required",error,nullptr);
        return 2;
    }
    char config[1600];
    std::snprintf(config,sizeof config,"%s/dxvk.conf",save);
    FILE *file=std::fopen(config,"wb");
    if(!file) { std::fprintf(stderr,"Cannot create separate Skyrim renderer settings\n");return 2; }
    std::fputs("dxvk.numCompilerThreads = 2\n"
               // Same legacy D3D9 shader math as macos/runtime.conf (no NaN HDR/DoF output).
               "d3d9.floatEmulation = True\n",file);std::fclose(file);
    SDL_setenv("DXVK_CONFIG_FILE",config,1);
    SDL_setenv("DXVK_STATE_CACHE_PATH",save,1);
    // As macos/run.sh: DXVK logs beside the saves, never inside the game folder.
    SDL_setenv("DXVK_LOG_PATH",save,0);
    // Discrete Metal bindings: the Simulator serializes every argument-buffer
    // descriptor write to the host GPU process, which held Skyrim at ~8-13 fps
    // with DXVK's per-draw descriptor updates; discrete binding ran the same
    // scenes at ~145 fps with no failed pipelines. Overridable from launch env.
    SDL_setenv("MVK_CONFIG_USE_METAL_ARGUMENT_BUFFERS","0",0);
    // No CPU translator or executable guest-memory allocator is introduced here.
    char executable[]="Skyrim";
    char *arguments[]={executable,game,save,nullptr};
    return skyrim_guest_main(3,arguments);
}
