// The native Skyrim runtime's C interface (ipad/native_bridge.mm). Only physical iPad builds
// made by ipad/build.py link it; Swift uses it under SKYRIM_NATIVE_RUNTIME.
#ifndef SkyrimNativeBridge_h
#define SkyrimNativeBridge_h
#include <stddef.h>

int skyrim_native_runtime_linked(void);
const char *skyrim_native_identity(void);
int skyrim_native_state(void);
int skyrim_native_validate(char *error, size_t error_size);
int skyrim_native_run(const char *save_root, char *error, size_t error_size);
void skyrim_native_set_paused(int paused);
void skyrim_native_request_quit(void);

#endif
