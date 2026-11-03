#include "util_env.h"

 #include <array>
#include <filesystem>
#include <unistd.h>
#include <limits.h>
#ifdef __APPLE__
#include <mach-o/dyld.h>
#include <pthread.h>
#endif

namespace dxvk::env {

  std::string getExePath() {
#ifdef __APPLE__
    uint32_t size = 0;
    _NSGetExecutablePath(nullptr, &size);
    std::string path(size, '\0');
    if (_NSGetExecutablePath(path.data(), &size) != 0)
      return std::string();
    path.resize(std::strlen(path.c_str()));
    return path;
#else
    std::array<char, PATH_MAX> exePath = {};

    ssize_t count = readlink("/proc/self/exe", exePath.data(), exePath.size());
    if (count < 0) return std::string();

    return std::string(exePath.begin(), exePath.begin() + count);
#endif
  }
  
  
  void setThreadName(const std::string& name) {
#ifdef __APPLE__
    pthread_setname_np(name.substr(0, 63).c_str());
#endif
  }


  bool createDirectory(const std::string& path) {
    return std::filesystem::create_directories(path);
  }

}
