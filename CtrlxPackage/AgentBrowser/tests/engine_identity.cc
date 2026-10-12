// Test fixture only. Build as `codex`/`claude` (or a Claude version path) for
// the CLI's kernel ancestry walk, not an identity bypass or real-agent acceptance.
#include <libproc.h>
#include <unistd.h>
#include <cstdlib>
#include <iostream>
#include <string>
int main() {
  proc_bsdinfo info{};
  if (proc_pidinfo(getpid(), PROC_PIDTBSDINFO, 0, &info, sizeof(info)) != sizeof(info)) return 1;
  std::cout << "{\"pid\":" << getpid() << ",\"startSeconds\":" << info.pbi_start_tvsec
            << ",\"startMicros\":" << info.pbi_start_tvusec << "}" << std::endl;
  std::string command;
  while (std::getline(std::cin, command)) {
    if (!command.empty()) (void)std::system(command.c_str());
  }
}
