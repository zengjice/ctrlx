#include <libproc.h>
#include <unistd.h>
#include <iostream>
int main() {
  proc_bsdinfo info{};
  if (proc_pidinfo(getpid(), PROC_PIDTBSDINFO, 0, &info, sizeof(info)) != sizeof(info)) return 1;
  std::cout << "{\"pid\":" << getpid() << ",\"startSeconds\":" << info.pbi_start_tvsec
            << ",\"startMicros\":" << info.pbi_start_tvusec << "}" << std::endl;
  char c; std::cin.get(c); // Test owns stdin; EOF ends this exact test process.
}
