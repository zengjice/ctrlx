// The Chromium subprocess must initialize its sandbox before loading CEF.
#include "include/cef_app.h"
#include "include/cef_sandbox_mac.h"
#include "include/wrapper/cef_library_loader.h"
#include "HelperPaths.h"
#include <mach-o/dyld.h>
#include <cstdio>

int main(int argc, char* argv[]) {
  // Late helpers (for example Chromium's relauncher) omit the path switches
  // passed to ordinary renderers. Without defaults CEF resolves the OUTER app,
  // then traps in SetOverrideFrameworkBundlePath before logging is initialized.
  uint32_t size = 0;
  _NSGetExecutablePath(nullptr, &size);
  std::vector<char> path(size);
  if (_NSGetExecutablePath(path.data(), &size) != 0) return 1;
  std::error_code error;
  auto executable = std::filesystem::canonical(path.data(), error);
  if (error) {
    fprintf(stderr, "Cannot resolve Agent Browser helper: %s\n", error.message().c_str());
    return 1;
  }
  auto arguments = HelperArguments(executable, argc, argv);
  if (arguments.empty()) {
    fprintf(stderr, "Unexpected Agent Browser helper bundle layout.\n");
    return 1;
  }
  std::vector<char*> pointers;
  for (auto& argument : arguments) pointers.push_back(argument.data());
  pointers.push_back(nullptr);
  argc = static_cast<int>(arguments.size());
  argv = pointers.data();
  CefScopedSandboxContext sandbox;
  if (!sandbox.Initialize(argc, argv)) {
    return 1;
  }
  CefScopedLibraryLoader loader;
  if (!loader.LoadInHelper()) {
    return 1;
  }
  return CefExecuteProcess(CefMainArgs(argc, argv), nullptr, nullptr);
}
