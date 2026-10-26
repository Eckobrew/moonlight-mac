#pragma once
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <CoreVideo/CoreVideo.h>

typedef struct MLPlacebo MLPlacebo;
bool MLPlaceboIsAvailable(void);
// All context operations must run on the same serial queue. The caller retains
// the CAMetalLayer until destroy returns. No Vulkan types cross into Swift.
MLPlacebo *MLPlaceboCreate(void *metalLayer, bool vsync, char *error, size_t errorSize);
// Acquire presentation capacity before choosing the newest decoded frame.
// Same return values as Render; a successful Begin must be followed by Render
// or Discard. Render can also acquire internally for simple synchronous callers.
int MLPlaceboBeginFrame(MLPlacebo *context, int width, int height, char *error, size_t errorSize);
void MLPlaceboDiscardFrame(MLPlacebo *context);
// 1 = presented, 0 = temporarily unavailable, -1 = fatal error.
int MLPlaceboRender(MLPlacebo *context, CVPixelBufferRef buffer, int width, int height,
                   char *error, size_t errorSize);
void MLPlaceboDestroy(MLPlacebo *context);

typedef struct {
    uint64_t importedFrames;
    uint64_t uploadedFrames;
    uint64_t presentedFrames;
    uint32_t retainedFrames;
    uint32_t peakRetainedFrames;
    uint64_t earlyAcquireFrames;
    double acquireTimeMs;
    double renderTimeMs;
    double submitTimeMs;
} MLPlaceboStats;
// Queue-confined diagnostics, including an explicit count of CPU fallback frames.
MLPlaceboStats MLPlaceboGetStats(MLPlacebo *context);
#ifdef MLPLACEBO_TESTING
// Test-only GPU readback compares imported and uploaded render results. This
// symbol and its synchronous readbacks are absent from production builds.
bool MLPlaceboTestCompareImport(MLPlacebo *context, CVPixelBufferRef buffer,
                              bool tenBit, bool fullRange, char *error, size_t errorSize);
#endif
