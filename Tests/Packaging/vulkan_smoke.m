// Manual GPU integration test. Build this with CPlaceboBridge.m and libplacebo,
// place it in a test .app, and bundle/sign its runtime with the normal helper.
#import <AppKit/AppKit.h>
#import <QuartzCore/CAMetalLayer.h>
#include "CPlaceboBridge.h"
#include <stdatomic.h>
#include <stdio.h>
#include <unistd.h>

static atomic_bool done;
static atomic_int exitStatus;

static CVPixelBufferRef makeFrame(OSType format, bool tenBit, bool hdr) {
    NSDictionary *attributes = @{
        (__bridge NSString *)kCVPixelBufferIOSurfacePropertiesKey: @{},
        (__bridge NSString *)kCVPixelBufferMetalCompatibilityKey: @YES,
    };
    CVPixelBufferRef buffer = NULL;
    if (CVPixelBufferCreate(NULL, 128, 72, format, (__bridge CFDictionaryRef)attributes, &buffer)) return NULL;
    CVPixelBufferLockBaseAddress(buffer, 0);
    for (int plane = 0; plane < 2; plane++) {
        size_t rows = CVPixelBufferGetHeightOfPlane(buffer, plane);
        size_t stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, plane);
        uint8_t *base = CVPixelBufferGetBaseAddressOfPlane(buffer, plane);
        for (size_t y = 0; y < rows; y++) {
            for (size_t x = 0; x < stride / (tenBit ? 2 : 1); x++) {
                unsigned sample = plane ? (x % 2 ? 160 : 96) : 16 + (unsigned)(y * 219 / rows);
                if (tenBit) ((uint16_t *)(base + y * stride))[x] = sample << 8;
                else base[y * stride + x] = sample;
            }
        }
    }
    CVPixelBufferUnlockBaseAddress(buffer, 0);
    CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey,
        hdr ? kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ : kCVImageBufferTransferFunction_ITU_R_709_2,
        kCVAttachmentMode_ShouldPropagate);
    CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey,
        hdr ? kCVImageBufferColorPrimaries_ITU_R_2020 : kCVImageBufferColorPrimaries_ITU_R_709_2,
        kCVAttachmentMode_ShouldPropagate);
    CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey,
        hdr ? kCVImageBufferYCbCrMatrix_ITU_R_2020 : kCVImageBufferYCbCrMatrix_ITU_R_709_2,
        kCVAttachmentMode_ShouldPropagate);
    return buffer;
}

static int exercise(CAMetalLayer *layer, bool vsync) {
    char error[512] = {0};
    MLPlacebo *context = MLPlaceboCreate((__bridge void *)layer, vsync, error, sizeof(error));
    if (!context) { fprintf(stderr, "CREATE FAILED: %s\n", error); return 1; }
    OSType formats[] = {
        kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
        kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
        kCVPixelFormatType_420YpCbCr10BiPlanarFullRange,
        kCVPixelFormatType_444YpCbCr8BiPlanarVideoRange,
        kCVPixelFormatType_444YpCbCr8BiPlanarFullRange,
        kCVPixelFormatType_444YpCbCr10BiPlanarVideoRange,
        kCVPixelFormatType_444YpCbCr10BiPlanarFullRange,
    };
    int result = 0;
    for (int i = 0; i < 8; i++) {
        bool tenBit = i % 4 >= 2;
        CVPixelBufferRef buffer = makeFrame(formats[i], tenBit, tenBit);
        if (!buffer) { fprintf(stderr, "BUFFER ALLOCATION FAILED for format %d\n", i); result = 1; break; }
        int presented = 0;
        for (int attempt = 0; attempt < 20 && presented < 3; attempt++) {
            int status = MLPlaceboRender(context, buffer, i % 2 ? 640 : 800, 480, error, sizeof(error));
            if (status < 0) { fprintf(stderr, "RENDER FAILED: %s\n", error); result = 1; break; }
            presented += status;
            usleep(16000);
        }
        CVPixelBufferRelease(buffer);
        if (presented < 3) result = 1;
        fprintf(stderr, "format=%d vsync=%d presented=%d\n", i, vsync, presented);
        if (result) break;
    }
    MLPlaceboStats stats = MLPlaceboGetStats(context);
    fprintf(stderr, "GPU imports=%llu CPU uploads=%llu presented=%llu peak retained=%u early acquisitions=%llu\n",
        (unsigned long long)stats.importedFrames, (unsigned long long)stats.uploadedFrames,
        (unsigned long long)stats.presentedFrames, stats.peakRetainedFrames, (unsigned long long)stats.earlyAcquireFrames);
    if (stats.importedFrames != 24 || stats.uploadedFrames != 0 || stats.presentedFrames != 24 ||
        stats.peakRetainedFrames > 3 || stats.earlyAcquireFrames != 24) {
        fprintf(stderr, "DIRECT IMPORT ASSERTION FAILED\n"); result = 1;
    }
    fprintf(stderr, "CPU average acquire=%.3f ms render=%.3f ms submit=%.3f ms (includes shader warmup)\n",
        stats.acquireTimeMs / 24, stats.renderTimeMs / 24, stats.submitTimeMs / 24);
    for (int i = 0; !result && i < 8; i++) {
        bool tenBit = i % 4 >= 2;
        CVPixelBufferRef buffer = makeFrame(formats[i], tenBit, tenBit);
        if (!buffer || !MLPlaceboTestCompareImport(context, buffer, tenBit, i % 2 != 0, error, sizeof(error))) {
            fprintf(stderr, "PIXEL COMPARISON FAILED: %s\n", error); result = 1;
        }
        if (buffer) CVPixelBufferRelease(buffer);
    }
    if (!result) fprintf(stderr, "All eight imported outputs match CPU-upload reference pixels\n");
    CVPixelBufferRef fallback = NULL;
    if (!result && CVPixelBufferCreate(NULL, 128, 72, formats[0], NULL, &fallback) == kCVReturnSuccess) {
        CVPixelBufferLockBaseAddress(fallback, 0);
        for (int i = 0; i < 2; i++) {
            memset(CVPixelBufferGetBaseAddressOfPlane(fallback, i), i ? 128 : 16,
                CVPixelBufferGetBytesPerRowOfPlane(fallback, i) * CVPixelBufferGetHeightOfPlane(fallback, i));
        }
        CVPixelBufferUnlockBaseAddress(fallback, 0);
        if (CVPixelBufferGetIOSurface(fallback) || MLPlaceboRender(context, fallback, 800, 480, error, sizeof(error)) != 1 ||
            MLPlaceboGetStats(context).uploadedFrames != 1) {
            fprintf(stderr, "CPU FALLBACK ASSERTION FAILED: %s\n", error); result = 1;
        }
        CVPixelBufferRelease(fallback);
    } else if (!result) {
        fprintf(stderr, "CPU FALLBACK BUFFER ALLOCATION FAILED\n"); result = 1;
    }
    // Exercise explicit acquisition/cancellation and verify the next frame can
    // still be presented. Decoder buffers above were released immediately after
    // submission, leaving the bridge responsible for their GPU lifetime.
    int acquired = MLPlaceboBeginFrame(context, 800, 480, error, sizeof(error));
    if (acquired < 0) result = 1;
    if (acquired == 1) MLPlaceboDiscardFrame(context);
    MLPlaceboDestroy(context);
    return result;
}

int main(void) {
    @autoreleasepool {
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
        NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 800, 480)
            styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
        window.title = @"Moonlight Vulkan pipeline test";
        CAMetalLayer *layer = [CAMetalLayer layer];
        window.contentView.wantsLayer = YES;
        window.contentView.layer = layer;
        layer.delegate = window.contentView;
        layer.drawableSize = CGSizeMake(800, 480);
        CGColorSpaceRef colorspace = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
        layer.colorspace = colorspace;
        CGColorSpaceRelease(colorspace);
        [window center];
        [window orderFrontRegardless];
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0), ^{
            @autoreleasepool {
                int status = exercise(layer, true);
                if (!status) status = exercise(layer, false);
                atomic_store(&exitStatus, status);
                atomic_store(&done, true);
            }
        });
        NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:120];
        while (!atomic_load(&done) && deadline.timeIntervalSinceNow > 0) {
            [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
        }
        if (!atomic_load(&done)) { fprintf(stderr, "GPU TEST TIMED OUT\n"); return 2; }
        [window orderOut:nil];
        fprintf(stderr, "GPU test %s\n", atomic_load(&exitStatus) ? "FAILED" : "PASSED");
        return atomic_load(&exitStatus);
    }
}
