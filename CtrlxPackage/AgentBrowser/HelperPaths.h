#pragma once

#include <filesystem>
#include <string>
#include <vector>

// Auxiliary processes started during Chromium shutdown do not necessarily
// inherit CefSettings. Resolve from this helper, never the outer CtrlX.app.
inline std::vector<std::string> HelperArguments(
    const std::filesystem::path& executable, int argc, char* const argv[]) {
  auto helper = executable.parent_path().parent_path().parent_path();
  auto frameworks = helper.parent_path();
  auto bundle = frameworks.parent_path().parent_path();
  if (executable.parent_path().filename() != "MacOS" ||
      executable.parent_path().parent_path().filename() != "Contents" ||
      helper.extension() != ".app" || frameworks.filename() != "Frameworks" ||
      frameworks.parent_path().filename() != "Contents" ||
      (bundle.filename() != "CtrlX.app" && bundle.filename() != "CtrlX Agent Browser.app") || argc < 1) {
    return {};
  }
  std::vector<std::string> result{argv[0]};
  for (auto& [name, path] : std::vector<std::pair<std::string, std::filesystem::path>>{
           {"framework-dir-path", frameworks / "Chromium Embedded Framework.framework"},
           {"main-bundle-path", bundle}}) {
    const auto flag = "--" + name;
    bool supplied = false;
    for (int i = 1; i < argc && std::string(argv[i]) != "--"; ++i) {
      const std::string value = argv[i];
      if (value == flag || value.starts_with(flag + "=")) supplied = true;
    }
    if (!supplied) result.push_back(flag + "=" + path.string());
  }
  for (int i = 1; i < argc; ++i) result.emplace_back(argv[i]);
  return result;
}
