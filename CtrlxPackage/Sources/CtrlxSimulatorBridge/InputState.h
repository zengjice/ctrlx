#pragma once
#include <stdint.h>
#include <stdatomic.h>

typedef struct {
    uint64_t protocolVersion;
    _Atomic uint64_t geometry;
    _Atomic uint64_t inputReady;
} CXSimulatorInputState;
