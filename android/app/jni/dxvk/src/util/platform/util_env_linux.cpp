#include "util_env.h"
#ifdef __APPLE__
#include <pthread.h>
#include <pthread/qos.h>
#include <cstdio>
#include <cstdlib>
#endif

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
    // Skyrim Apple port: LB_QOS=1 puts DXVK's frame-critical threads (command stream, submission, queue) in the
    // user-interactive QoS class, so the scheduler keeps them on performance cores; others stay as they are.
    const char* qos = std::getenv("LB_QOS");
    if (qos && qos[0] == '1' && (name == "dxvk-cs" || name == "dxvk-submit" || name == "dxvk-queue")) {
      int r = pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0);
      std::fprintf(stderr, "qos: %s user-interactive (%d)\n", name.c_str(), r);
    }
#endif
  }


  bool createDirectory(const std::string& path) {
    return std::filesystem::create_directories(path);
  }

}
