// Test fixture only. Build as `codex`/`claude` (or a Claude version path) for
// the CLI's kernel ancestry walk, not an identity bypass or real-agent acceptance.
#include <libproc.h>
#include <fcntl.h>
#include <unistd.h>
#include <cstdlib>
#include <iostream>
#include <string>
int main(int argc, char** argv) {
  int rollout = -1;
  auto openRollout = [&](const char* path) {
    if (rollout >= 0) close(rollout);
    rollout = open(path, O_WRONLY | O_APPEND | O_NOFOLLOW | O_CLOEXEC);
    return rollout >= 0;
  };
  // Exercise the production writable-rollout reader, without a test identity bypass.
  if (argc == 3 && std::string(argv[1]) == "--rollout" && !openRollout(argv[2])) return 2;
  proc_bsdinfo info{};
  if (proc_pidinfo(getpid(), PROC_PIDTBSDINFO, 0, &info, sizeof(info)) != sizeof(info)) return 1;
  std::cout << "{\"pid\":" << getpid() << ",\"startSeconds\":" << info.pbi_start_tvsec
            << ",\"startMicros\":" << info.pbi_start_tvusec << "}" << std::endl;
  std::string command;
  while (std::getline(std::cin, command)) {
    if (command.starts_with(":rollout ")) {
      if (!openRollout(command.substr(9).c_str())) return 2;
      continue;
    }
    if (!command.empty()) (void)std::system(command.c_str());
  }
  if (rollout >= 0) close(rollout);
}
