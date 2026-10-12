#import <IOSurface/IOSurface.h>
#include <stdbool.h>
#include <stdint.h>

// This decoder is used only by the opt-in, 64-bit performance fixture trace.
typedef struct {
    size_t width, height, x, y;
    double cell;
    bool cached;
} CXSimulatorTraceMarker;

static bool CXSimulatorTraceRead(const uint8_t *row, size_t width, size_t x, double cell, uint64_t *word) {
    if (cell < 3 || (double)x + cell * 67.5 >= (double)width) return false;
    const uint8_t *m = row + (size_t)(x + cell * 0.5) * 4;
    const uint8_t *c = row + (size_t)(x + cell * 1.5) * 4;
    const uint8_t *y = row + (size_t)(x + cell * 2.5) * 4;
    const uint8_t *g = row + (size_t)(x + cell * 67.5) * 4;
    if (!(m[0] > 200 && m[2] > 200 && m[1] < 60 &&
          c[0] > 200 && c[1] > 200 && c[2] < 150 &&
          y[0] < 150 && y[1] > 200 && y[2] > 200 &&
          g[0] < 150 && g[1] > 200 && g[2] < 150)) return false;
    uint64_t value = 0;
    for (int i = 0; i < 64; i++) {
        const uint8_t *p = row + (size_t)(x + cell * (i + 3.5)) * 4;
        unsigned sum = p[0] + p[1] + p[2];
        if (sum > 600) value |= (uint64_t)1 << i;
        else if (sum >= 150) return false;
    }
    uint8_t check = (uint8_t)(value ^ (value >> 8) ^ (value >> 16) ^ (value >> 24) ^
                            (value >> 32) ^ (value >> 40) ^ (value >> 48) ^ 0xa5);
    if (check != (uint8_t)(value >> 56)) return false;
    *word = value;
    return true;
}

static bool CXSimulatorTraceDecode(IOSurfaceRef surface, CXSimulatorTraceMarker *marker, uint64_t *word) {
    if (IOSurfaceGetPixelFormat(surface) != 0x42475241 ||
        IOSurfaceLock(surface, kIOSurfaceLockReadOnly, NULL) != 0) return false;
    const uint8_t *data = IOSurfaceGetBaseAddress(surface);
    size_t width = IOSurfaceGetWidth(surface), height = IOSurfaceGetHeight(surface);
    size_t stride = IOSurfaceGetBytesPerRow(surface);
    bool valid = false;
    if (data && marker->cached && marker->width == width && marker->height == height) {
        valid = CXSimulatorTraceRead(data + marker->y * stride, width, marker->x, marker->cell, word);
    }
    if (!valid && data) {
        marker->cached = false;
        for (size_t y = 0; y < height && !valid; y += 4) {
            const uint8_t *row = data + y * stride;
            for (size_t x = 0; x < width && !valid; x++) {
                const uint8_t *p = row + x * 4;
                if (!(p[0] > 200 && p[2] > 200 && p[1] < 60)) continue;
                size_t end = x;
                while (end < width) {
                    p = row + end * 4;
                    if (!(p[0] > 200 && p[2] > 200 && p[1] < 60)) break;
                    end++;
                }
                if (end - x < 3) { x = end; continue; }
                size_t green = x + 3 * (end - x);
                while (green < width) {
                    p = row + green * 4;
                    if (p[0] < 150 && p[1] > 200 && p[2] < 150) break;
                    green++;
                }
                if (green < width) {
                    double cell = (double)(green - x) / 67;
                    valid = CXSimulatorTraceRead(row, width, x, cell, word);
                    if (valid) *marker = (CXSimulatorTraceMarker){width, height, x, y, cell, true};
                }
                x = end;
            }
        }
    }
    IOSurfaceUnlock(surface, kIOSurfaceLockReadOnly, NULL);
    return valid;
}
