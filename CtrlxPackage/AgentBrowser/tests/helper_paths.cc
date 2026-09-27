#include "../HelperPaths.h"
#include <cassert>
#include <iostream>

int main() {
  for (const auto& bundle : {std::string("/Applications/CtrlX.app"),
      std::string("/tmp/Build With Spaces/CtrlX.app"),
      std::string("/Applications/CtrlX.app/Contents/Helpers/CtrlX Agent Browser.app")}) {
    for (const auto& suffix : {"", " (Renderer)", " (GPU)", " (Alerts)"}) {
      const auto frameworks = bundle + "/Contents/Frameworks";
      const auto helper = std::string("CtrlX Agent Browser Helper") + suffix;
      const auto exe = frameworks + "/" + helper + ".app/Contents/MacOS/" + helper;
      std::string type = "--type=relauncher", separator = "--", target = "/Some App/Next.app";
      char* argv[] = {const_cast<char*>(exe.c_str()), type.data(), separator.data(), target.data()};
      auto result = HelperArguments(exe, 4, argv);
      assert(result.size() == 6);
      assert(result[1] == "--framework-dir-path=" + frameworks + "/Chromium Embedded Framework.framework");
      assert(result[2] == "--main-bundle-path=" + bundle);
      assert(result[3] == type && result[4] == separator && result[5] == target);
      std::vector<char*> supplied;
      for (auto& arg : result) supplied.push_back(arg.data());
      assert(HelperArguments(exe, supplied.size(), supplied.data()) == result);
    }
  }
  char name[] = "helper";
  char* argv[] = {name};
  assert(HelperArguments("/Applications/Other.app/Contents/MacOS/helper", 1, argv).empty());
  std::cout << "PASS: nested/standalone helper paths, helper variants, argument boundaries, existing flags, invalid layout\n";
}
