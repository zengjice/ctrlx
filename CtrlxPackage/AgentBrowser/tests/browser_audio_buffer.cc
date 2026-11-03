#include "../BrowserAudioBuffer.h"
#include <cassert>
#include <iostream>

int main() {
  BrowserAudioBuffer buffer;
  std::vector<float> left(10000), right(10000), output(8192 * 2);
  for (int i = 0; i < 10000; ++i) { left[i] = i; right[i] = -i; }
  const float* input[] = {left.data(), right.data()};
  buffer.Push(input, 10000);
  assert(buffer.Read(output.data(), 8192, true) == 0);
  assert(buffer.Read(output.data(), 8192, false) == 8192);
  assert(output[0] == 1808 && output[1] == -1808 && output[16382] == 9999);
  buffer.Push(input, 1024);
  buffer.Route(true, true);
  assert(buffer.Read(output.data(), 8192, true) == 0); // no Host backlog after takeover
  buffer.Push(input, 1024);
  assert(buffer.Read(output.data(), 8192, false) == 0);
  assert(buffer.Read(output.data(), 8192, true) == 1024);
  buffer.Route(true, false);
  buffer.Push(input, 1024);
  assert(buffer.Read(output.data(), 8192, true) == 0);
  buffer.Route(false, false);
  assert(buffer.Read(output.data(), 8192, false) == 0); // no remote backlog after release
  buffer.Push(input, 1024);
  assert(buffer.Read(output.data(), 8192, false) == 1024);
  // The runtime must drain a full capture ring after a delayed poll. With the
  // old 4096-frame read, a 100 ms poll lost 640 ms of audio in five seconds.
  BrowserAudioBuffer delayed;
  delayed.Route(true, true);
  int produced = 0, consumed = 0;
  for (int tick = 1; tick <= 50; ++tick) {
    while (produced + 1024 <= tick * 4800) {
      for (int i = 0; i < 1024; ++i) { left[i] = produced + i; right[i] = -left[i]; }
      delayed.Push(input, 1024);
      produced += 1024;
    }
    const auto count = delayed.Read(output.data(), BrowserAudioBuffer::maximumReadFrames, true);
    for (size_t i = 0; i < count; ++i) assert(output[i * 2] == consumed++);
  }
  assert(consumed == produced && delayed.Status().dropped == 0);
  assert(buffer.Status().dropped == 1808);
  std::cout << "Browser audio bounded buffer and destination switching passed\n";
}
