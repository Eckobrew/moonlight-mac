#include "CPlaceboBridge.h"
#include <stdio.h>
#include <stdlib.h>

#if MOONLIGHT_LIBPLACEBO
#define VK_USE_PLATFORM_METAL_EXT
#include <libplacebo/vulkan.h>
#include <libplacebo/renderer.h>
#include <libplacebo/utils/upload.h>
#if PL_API_VER < 360
#error "The experimental renderer requires libplacebo API 360 or later"
#endif
#import <QuartzCore/CAMetalLayer.h>
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <dlfcn.h>
#include <math.h>

// Retain the decoded buffer and its CoreVideo texture wrappers until all GPU
// reads finish. Retaining just id<MTLTexture> does not keep decoder pools safe.
#define ML_MAX_IMPORTED_FRAMES 3
struct MLImportedFrame {
    CVPixelBufferRef buffer;
    CVMetalTextureRef metal[2];
    pl_tex planes[2];
};

struct MLPlacebo {
    void *loader;
    pl_log log;
    pl_vk_inst instance;
    VkSurfaceKHR surface;
    pl_vulkan vulkan;
    pl_swapchain swapchain;
    pl_renderer renderer;
    pl_tex acquireTexture;
    struct pl_overlay_part acquirePart;
    struct pl_overlay acquireOverlay;
    pl_tex planes[2];
    CVMetalTextureCacheRef textureCache;
    struct MLImportedFrame imported[ML_MAX_IMPORTED_FRAMES];
    struct pl_swapchain_frame frame;
    bool frameStarted;
    bool warnedUploadFallback;
    int requestedWidth, requestedHeight;
    MLPlaceboStats stats;
    PFN_vkDestroySurfaceKHR destroySurface;
};

static void fail(char *error, size_t size, const char *message) {
    if (error && size) snprintf(error, size, "%s", message);
}

bool MLPlaceboIsAvailable(void) { return true; }

static void releaseImported(MLPlacebo *p, struct MLImportedFrame *frame) {
    for (int i = 0; i < 2; i++) {
        pl_tex_destroy(p->vulkan->gpu, &frame->planes[i]);
        if (frame->metal[i]) CFRelease(frame->metal[i]);
        frame->metal[i] = NULL;
    }
    if (frame->buffer) CVPixelBufferRelease(frame->buffer);
    frame->buffer = NULL;
}

static void reapImported(MLPlacebo *p, bool wait) {
    for (int i = 0; i < ML_MAX_IMPORTED_FRAMES; i++) {
        struct MLImportedFrame *frame = &p->imported[i];
        if (!frame->buffer) continue;
        bool busy = false;
        for (int plane = 0; plane < 2; plane++) {
            if (!frame->planes[plane]) continue;
            bool pending;
            do {
                pending = pl_tex_poll(p->vulkan->gpu, frame->planes[plane], wait ? UINT64_MAX : 0);
            } while (wait && pending);
            busy |= pending;
        }
        if (!busy) releaseImported(p, frame);
    }
}

MLPlaceboStats MLPlaceboGetStats(MLPlacebo *p) {
    if (!p) return (MLPlaceboStats){0};
    MLPlaceboStats stats = p->stats;
    for (int i = 0; i < ML_MAX_IMPORTED_FRAMES; i++) stats.retainedFrames += p->imported[i].buffer != NULL;
    return stats;
}

void MLPlaceboDestroy(MLPlacebo *p) {
    if (!p) return;
    if (p->vulkan) {
        MLPlaceboDiscardFrame(p);
        pl_gpu_finish(p->vulkan->gpu);
        for (int i = 0; i < ML_MAX_IMPORTED_FRAMES; i++) releaseImported(p, &p->imported[i]);
        pl_renderer_destroy(&p->renderer);
        pl_tex_destroy(p->vulkan->gpu, &p->acquireTexture);
        for (int i = 0; i < 2; i++) pl_tex_destroy(p->vulkan->gpu, &p->planes[i]);
        pl_swapchain_destroy(&p->swapchain);
        pl_vulkan_destroy(&p->vulkan);
    }
    if (p->textureCache) CFRelease(p->textureCache);
    if (p->surface && p->destroySurface)
        p->destroySurface(p->instance->instance, p->surface, NULL);
    pl_vk_inst_destroy(&p->instance);
    pl_log_destroy(&p->log);
    if (p->loader) dlclose(p->loader);
    free(p);
}

MLPlacebo *MLPlaceboCreate(void *metalLayer, bool vsync, char *error, size_t errorSize) {
    MLPlacebo *p = calloc(1, sizeof(*p));
    if (!p) { fail(error, errorSize, "Could not allocate libplacebo renderer"); return NULL; }
    VkMetalSurfaceCreateInfoEXT surfaceInfo = {
        .sType = VK_STRUCTURE_TYPE_METAL_SURFACE_CREATE_INFO_EXT,
        .pLayer = (__bridge CAMetalLayer *)metalLayer,
    };
    // Packaged builds use MoltenVK directly: no global loader, ICD manifest, or
    // environment changes are needed. Keep the SDK loader for unbundled builds.
    NSString *bundled = [[NSBundle mainBundle].privateFrameworksPath
        stringByAppendingPathComponent:@"libMoltenVK.dylib"];
    bool hasBundledRuntime = bundled && [[NSFileManager defaultManager] fileExistsAtPath:bundled];
    p->loader = dlopen(hasBundledRuntime ? bundled.fileSystemRepresentation : "libvulkan.1.dylib",
                       RTLD_NOW | RTLD_LOCAL);
    PFN_vkGetInstanceProcAddr getProc = p->loader
        ? (PFN_vkGetInstanceProcAddr)dlsym(p->loader, "vkGetInstanceProcAddr") : NULL;
    const char *reason = hasBundledRuntime
        ? "Could not load the bundled MoltenVK runtime. Check the app signature and library dependencies."
        : "Vulkan loader missing. Package MoltenVK with the app or configure the Vulkan SDK.";
    if (!getProc) goto error;
    p->log = pl_log_create(PL_API_VER, pl_log_params(
        .log_cb = pl_log_simple, .log_priv = stderr, .log_level = PL_LOG_WARN));
    const char *extensions[] = {VK_KHR_SURFACE_EXTENSION_NAME, VK_EXT_METAL_SURFACE_EXTENSION_NAME};
    p->instance = pl_vk_inst_create(p->log, pl_vk_inst_params(
        .get_proc_addr = getProc, .extensions = extensions, .num_extensions = 2));
    reason = "Vulkan instance creation failed. Check the MoltenVK ICD and Vulkan 1.2 support.";
    if (!p->instance) goto error;
    PFN_vkCreateMetalSurfaceEXT createSurface = (PFN_vkCreateMetalSurfaceEXT)
        getProc(p->instance->instance, "vkCreateMetalSurfaceEXT");
    p->destroySurface = (PFN_vkDestroySurfaceKHR)getProc(p->instance->instance, "vkDestroySurfaceKHR");
    reason = "Could not create a Vulkan Metal surface";
    if (!createSurface || !p->destroySurface ||
        createSurface(p->instance->instance, &surfaceInfo, NULL, &p->surface) != VK_SUCCESS) goto error;
    p->vulkan = pl_vulkan_create(p->log, pl_vulkan_params(
        .instance = p->instance->instance, .get_proc_addr = getProc, .surface = p->surface,
        .async_transfer = false, .async_compute = false));
    reason = "Could not create the libplacebo Vulkan device";
    if (!p->vulkan) goto error;
    p->swapchain = pl_vulkan_create_swapchain(p->vulkan, pl_vulkan_swapchain_params(
        .surface = p->surface, .present_mode = vsync ? VK_PRESENT_MODE_MAILBOX_KHR : VK_PRESENT_MODE_IMMEDIATE_KHR,
        .swapchain_depth = 1));
    p->renderer = pl_renderer_create(p->log, p->vulkan->gpu);
    reason = "Could not create the libplacebo swapchain or renderer";
    if (!p->swapchain || !p->renderer) goto error;
    // A tiny transparent overlay forces MoltenVK's lazy drawable acquisition
    // during BeginFrame, before the mailbox is sampled. See Moonlight Qt's
    // PLVK_USE_EARLY_RENDER_TO_WAIT workaround in plvk.cpp/plvk.h.
    const uint8_t transparent[4] = {0};
    pl_fmt overlayFormat = pl_find_named_fmt(p->vulkan->gpu, "rgba8");
    reason = "Could not create the libplacebo drawable-acquisition overlay";
    if (!overlayFormat) goto error;
    p->acquireTexture = pl_tex_create(p->vulkan->gpu, pl_tex_params(
        .w = 1, .h = 1, .format = overlayFormat, .sampleable = true, .initial_data = transparent));
    if (!p->acquireTexture) goto error;
    p->acquirePart = (struct pl_overlay_part){.src = {0, 0, 1, 1}, .dst = {0, 0, 1, 1}};
    p->acquireOverlay = (struct pl_overlay){
        .tex = p->acquireTexture, .mode = PL_OVERLAY_NORMAL, .coords = PL_OVERLAY_COORDS_DST_FRAME,
        .repr = pl_color_repr_rgb, .color = pl_color_space_srgb,
        .num_parts = 1, .parts = &p->acquirePart,
    };
    p->acquireOverlay.repr.alpha = PL_ALPHA_PREMULTIPLIED;
    // Export the actual Metal device backing this Vulkan device, which can
    // differ from the system default on Macs with multiple GPUs.
    if (p->vulkan->gpu->import_caps.tex & PL_HANDLE_MTL_TEX) {
        PFN_vkExportMetalObjectsEXT exportMetal = (PFN_vkExportMetalObjectsEXT)
            getProc(p->instance->instance, "vkExportMetalObjectsEXT");
        if (exportMetal) {
            VkExportMetalDeviceInfoEXT deviceInfo = {.sType = VK_STRUCTURE_TYPE_EXPORT_METAL_DEVICE_INFO_EXT};
            VkExportMetalObjectsInfoEXT objects = {
                .sType = VK_STRUCTURE_TYPE_EXPORT_METAL_OBJECTS_INFO_EXT, .pNext = &deviceInfo,
            };
            exportMetal(p->vulkan->device, &objects);
            if (deviceInfo.mtlDevice)
                CVMetalTextureCacheCreate(NULL, NULL, deviceInfo.mtlDevice, NULL, &p->textureCache);
        }
    }
    // Initial backend outputs SDR; libplacebo tone maps PQ/HLG sources.
    pl_swapchain_colorspace_hint(p->swapchain, &pl_color_space_srgb);
    return p;
error:
    fail(error, errorSize, reason);
    MLPlaceboDestroy(p);
    return NULL;
}

static bool attachmentEquals(CVPixelBufferRef buffer, CFStringRef key, CFStringRef value) {
    CFTypeRef attachment = CVBufferCopyAttachment(buffer, key, NULL);
    bool equal = attachment && CFEqual(attachment, value);
    if (attachment) CFRelease(attachment);
    return equal;
}

int MLPlaceboBeginFrame(MLPlacebo *p, int width, int height, char *error, size_t errorSize) {
    if (!p || width <= 0 || height <= 0) return 0;
    if (p->frameStarted) { fail(error, errorSize, "Previous libplacebo frame was not submitted"); return -1; }
    double begin = CACurrentMediaTime();
    // Throttle the previous submission before selecting a new decoded frame,
    // matching Qt's waitToRender ordering on macOS.
    pl_swapchain_swap_buffers(p->swapchain);
    reapImported(p, false);
    bool hasCapacity = false;
    for (int i = 0; i < ML_MAX_IMPORTED_FRAMES; i++) hasCapacity |= !p->imported[i].buffer;
    // This wait, if necessary, occurs before Swift selects the latest frame.
    if (!hasCapacity) reapImported(p, true);
    if (width != p->requestedWidth || height != p->requestedHeight) {
        int actualWidth = width, actualHeight = height;
        if (!pl_swapchain_resize(p->swapchain, &actualWidth, &actualHeight)) {
            fail(error, errorSize, "libplacebo swapchain resize failed"); return -1;
        }
        p->requestedWidth = width;
        p->requestedHeight = height;
    }
    p->frameStarted = pl_swapchain_start_frame(p->swapchain, &p->frame);
    if (!p->frameStarted) return 0;
    struct pl_frame target;
    pl_frame_from_swapchain(&target, &p->frame);
    target.overlays = &p->acquireOverlay;
    target.num_overlays = 1;
    if (!pl_render_image(p->renderer, NULL, &target, &pl_render_fast_params)) {
        MLPlaceboDiscardFrame(p);
        fail(error, errorSize, "Could not prepare the libplacebo drawable");
        return -1;
    }
    p->stats.earlyAcquireFrames++;
    p->stats.acquireTimeMs += (CACurrentMediaTime() - begin) * 1000.0;
    return 1;
}

void MLPlaceboDiscardFrame(MLPlacebo *p) {
    if (!p || !p->frameStarted) return;
    struct pl_frame target;
    pl_frame_from_swapchain(&target, &p->frame);
    const float black[3] = {0};
    pl_frame_clear(p->vulkan->gpu, &target, black);
    pl_swapchain_submit_frame(p->swapchain);
    p->frameStarted = false;
}

static bool importFrame(MLPlacebo *p, CVPixelBufferRef buffer, bool tenBit, struct pl_frame *image) {
    if (!p->textureCache || !CVPixelBufferGetIOSurface(buffer)) return false;
    struct MLImportedFrame *frame = NULL;
    for (int i = 0; i < ML_MAX_IMPORTED_FRAMES; i++) {
        if (!p->imported[i].buffer) { frame = &p->imported[i]; break; }
    }
    if (!frame) return false;
    frame->buffer = CVPixelBufferRetain(buffer);
    for (int i = 0; i < 2; i++) {
        MTLPixelFormat format = i ? (tenBit ? MTLPixelFormatRG16Unorm : MTLPixelFormatRG8Unorm)
                                  : (tenBit ? MTLPixelFormatR16Unorm : MTLPixelFormatR8Unorm);
        pl_fmt gpuFormat = pl_find_named_fmt(p->vulkan->gpu, i ? (tenBit ? "rg16" : "rg8") : (tenBit ? "r16" : "r8"));
        size_t width = CVPixelBufferGetWidthOfPlane(buffer, i), height = CVPixelBufferGetHeightOfPlane(buffer, i);
        if (!gpuFormat || CVMetalTextureCacheCreateTextureFromImage(NULL, p->textureCache, buffer, NULL,
                format, width, height, i, &frame->metal[i]) != kCVReturnSuccess) goto error;
        id<MTLTexture> texture = CVMetalTextureGetTexture(frame->metal[i]);
        if (!texture) goto error;
        frame->planes[i] = pl_tex_create(p->vulkan->gpu, pl_tex_params(
            .w = (int)width, .h = (int)height, .format = gpuFormat, .sampleable = true,
            .import_handle = PL_HANDLE_MTL_TEX,
            .shared_mem = {.handle.handle = (__bridge void *)texture}));
        if (!frame->planes[i]) goto error;
    }
    for (int i = 0; i < 2; i++) {
        image->planes[i] = (struct pl_plane) {
            .texture = frame->planes[i], .components = i ? 2 : 1,
            .component_mapping = {i ? 1 : 0, i ? 2 : -1, -1, -1},
        };
    }
    p->stats.importedFrames++;
    uint32_t retained = MLPlaceboGetStats(p).retainedFrames;
    if (retained > p->stats.peakRetainedFrames) p->stats.peakRetainedFrames = retained;
    return true;
error:
    // No GPU reads have been queued against this partially imported frame.
    releaseImported(p, frame);
    CVMetalTextureCacheFlush(p->textureCache, 0);
    return false;
}

static struct pl_frame describeFrame(CVPixelBufferRef buffer, bool tenBit, bool fullRange) {
    struct pl_frame image = {.num_planes = 2};
    image.repr = (struct pl_color_repr) {
        .sys = PL_COLOR_SYSTEM_BT_709,
        .levels = fullRange ? PL_COLOR_LEVELS_FULL : PL_COLOR_LEVELS_LIMITED,
        .bits = {.sample_depth = tenBit ? 16 : 8, .color_depth = tenBit ? 10 : 8,
                 .bit_shift = tenBit ? 6 : 0},
    };
    image.color = pl_color_space_bt709;
    if (attachmentEquals(buffer, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_2020))
        image.repr.sys = PL_COLOR_SYSTEM_BT_2020_NC;
    else if (attachmentEquals(buffer, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_601_4))
        image.repr.sys = PL_COLOR_SYSTEM_BT_601;
    if (attachmentEquals(buffer, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_2020))
        image.color.primaries = PL_COLOR_PRIM_BT_2020;
    if (attachmentEquals(buffer, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ))
        image.color.transfer = PL_COLOR_TRC_PQ;
    else if (attachmentEquals(buffer, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_2100_HLG))
        image.color.transfer = PL_COLOR_TRC_HLG;
    image.crop = (pl_rect2df){0, 0, CVPixelBufferGetWidth(buffer), CVPixelBufferGetHeight(buffer)};

    return image;
}

static int uploadFrame(MLPlacebo *p, CVPixelBufferRef buffer, bool tenBit, struct pl_frame *image) {
    if (CVPixelBufferLockBaseAddress(buffer, kCVPixelBufferLock_ReadOnly) != kCVReturnSuccess) {
        return 0;
    }
    bool uploaded = true;
    for (int i = 0; i < 2; i++) {
        int bits = tenBit ? 16 : 8;
        struct pl_plane_data data = {
            .type = PL_FMT_UNORM,
            .width = (int)CVPixelBufferGetWidthOfPlane(buffer, i),
            .height = (int)CVPixelBufferGetHeightOfPlane(buffer, i),
            .component_size = {bits, i ? bits : 0},
            .component_map = {i ? 1 : 0, i ? 2 : -1, -1, -1},
            .pixel_stride = (i ? 2 : 1) * (tenBit ? 2 : 1),
            .row_stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, i),
            .pixels = CVPixelBufferGetBaseAddressOfPlane(buffer, i),
        };
        // With no upload callback, libplacebo consumes host memory before return.
        if (!data.pixels || !pl_upload_plane(p->vulkan->gpu, &image->planes[i], &p->planes[i], &data)) {
            uploaded = false; break;
        }
    }
    CVPixelBufferUnlockBaseAddress(buffer, kCVPixelBufferLock_ReadOnly);
    return uploaded ? 1 : -1;
}

#ifdef MLPLACEBO_TESTING
bool MLPlaceboTestCompareImport(MLPlacebo *p, CVPixelBufferRef buffer, bool tenBit, bool fullRange,
                              char *error, size_t errorSize) {
    struct pl_frame images[2] = {describeFrame(buffer, tenBit, fullRange), describeFrame(buffer, tenBit, fullRange)};
    pl_tex targets[2] = {0};
    uint8_t pixels[2][64 * 64 * 4];
    reapImported(p, true);
    bool ok = importFrame(p, buffer, tenBit, &images[0]) && uploadFrame(p, buffer, tenBit, &images[1]) == 1;
    for (int i = 0; ok && i < 2; i++) {
        targets[i] = pl_tex_create(p->vulkan->gpu, pl_tex_params(
            .w = 64, .h = 64, .format = pl_find_named_fmt(p->vulkan->gpu, "rgba8"),
            .renderable = true, .host_readable = true));
        if (!targets[i]) { ok = false; break; }
        struct pl_frame target = {
            .num_planes = 1, .planes = {{.texture = targets[i], .components = 4, .component_mapping = {0, 1, 2, 3}}},
            .repr = pl_color_repr_rgb, .color = pl_color_space_srgb, .crop = {0, 0, 64, 64},
        };
        ok = pl_render_image(p->renderer, &images[i], &target, &pl_render_fast_params) &&
            pl_tex_download(p->vulkan->gpu, pl_tex_transfer_params(.tex = targets[i], .ptr = pixels[i]));
    }
    for (size_t i = 0; ok && i < sizeof(pixels[0]); i++) {
        // Allow two code values for shader rounding/dithering differences.
        if (abs((int)pixels[0][i] - (int)pixels[1][i]) > 2) ok = false;
    }
    pl_gpu_finish(p->vulkan->gpu);
    for (int i = 0; i < 2; i++) pl_tex_destroy(p->vulkan->gpu, &targets[i]);
    reapImported(p, true);
    if (!ok) fail(error, errorSize, "Imported pixels differ from CPU-upload reference output");
    return ok;
}
#endif

int MLPlaceboRender(MLPlacebo *p, CVPixelBufferRef buffer, int width, int height,
                   char *error, size_t errorSize) {
    if (!p) return 0;
    if (!buffer || width <= 0 || height <= 0) { MLPlaceboDiscardFrame(p); return 0; }
    OSType format = CVPixelBufferGetPixelFormatType(buffer);
    bool tenBit = false, fullRange = false;
    switch (format) {
    case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange:
    case kCVPixelFormatType_444YpCbCr8BiPlanarVideoRange: break;
    case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange:
    case kCVPixelFormatType_444YpCbCr8BiPlanarFullRange: fullRange = true; break;
    case kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange:
    case kCVPixelFormatType_444YpCbCr10BiPlanarVideoRange: tenBit = true; break;
    case kCVPixelFormatType_420YpCbCr10BiPlanarFullRange:
    case kCVPixelFormatType_444YpCbCr10BiPlanarFullRange: tenBit = true; fullRange = true; break;
    default: MLPlaceboDiscardFrame(p); fail(error, errorSize, "Unsupported libplacebo pixel buffer format"); return -1;
    }
    if (CVPixelBufferGetPlaneCount(buffer) != 2) {
        MLPlaceboDiscardFrame(p); fail(error, errorSize, "libplacebo requires a biplanar pixel buffer"); return -1;
    }
    if (!p->frameStarted) {
        int status = MLPlaceboBeginFrame(p, width, height, error, errorSize);
        if (status != 1) return status;
    }
    double renderBegin = CACurrentMediaTime();
    struct pl_frame image = describeFrame(buffer, tenBit, fullRange);

    bool imported = importFrame(p, buffer, tenBit, &image);
    if (!imported) {
        if (!p->warnedUploadFallback) {
            fprintf(stderr, "[Libplacebo] Direct Metal texture import unavailable for this buffer; using CPU upload fallback\n");
            p->warnedUploadFallback = true;
        }
        int uploaded = uploadFrame(p, buffer, tenBit, &image);
        if (uploaded != 1) {
            MLPlaceboDiscardFrame(p);
            if (uploaded < 0) fail(error, errorSize, "libplacebo plane upload failed");
            return uploaded;
        }
        p->stats.uploadedFrames++;
    }
    enum pl_chroma_location chroma = PL_CHROMA_LEFT;
    if (attachmentEquals(buffer, kCVImageBufferChromaLocationTopFieldKey, kCVImageBufferChromaLocation_Center))
        chroma = PL_CHROMA_CENTER;
    else if (attachmentEquals(buffer, kCVImageBufferChromaLocationTopFieldKey, kCVImageBufferChromaLocation_TopLeft))
        chroma = PL_CHROMA_TOP_LEFT;
    pl_frame_set_chroma_location(&image, chroma);
    struct pl_frame target;
    pl_frame_from_swapchain(&target, &p->frame);
    // Preserve orientation (including vertically flipped swapchain targets).
    float scale = fminf(fabsf(target.crop.x1 - target.crop.x0) / image.crop.x1,
                        fabsf(target.crop.y1 - target.crop.y0) / image.crop.y1);
    float cx = (target.crop.x0 + target.crop.x1) * 0.5f;
    float cy = (target.crop.y0 + target.crop.y1) * 0.5f;
    float dx = copysignf(image.crop.x1 * scale * 0.5f, target.crop.x1 - target.crop.x0);
    float dy = copysignf(image.crop.y1 * scale * 0.5f, target.crop.y1 - target.crop.y0);
    target.crop = (pl_rect2df){cx - dx, cy - dy, cx + dx, cy + dy};
    const float black[3] = {0, 0, 0};
    pl_frame_clear(p->vulkan->gpu, &target, black);
    bool rendered = pl_render_image(p->renderer, &image, &target, &pl_render_fast_params);
    p->stats.renderTimeMs += (CACurrentMediaTime() - renderBegin) * 1000.0;
    // Always balance start/submit, including render failure.
    double submitBegin = CACurrentMediaTime();
    bool submitted = pl_swapchain_submit_frame(p->swapchain);
    p->frameStarted = false;
    p->stats.submitTimeMs += (CACurrentMediaTime() - submitBegin) * 1000.0;
    reapImported(p, false);
    if (!rendered || !submitted) { fail(error, errorSize, "libplacebo rendering or presentation failed"); return -1; }
    p->stats.presentedFrames++;
    return 1;
}
#else
bool MLPlaceboIsAvailable(void) { return false; }
MLPlacebo *MLPlaceboCreate(void *layer, bool vsync, char *error, size_t size) {
    if (error && size) snprintf(error, size, "Build with MOONLIGHT_LIBPLACEBO=1 to enable libplacebo/Vulkan");
    return NULL;
}
int MLPlaceboRender(MLPlacebo *p, CVPixelBufferRef b, int w, int h, char *e, size_t n) { return -1; }
int MLPlaceboBeginFrame(MLPlacebo *p, int w, int h, char *e, size_t n) { return -1; }
void MLPlaceboDiscardFrame(MLPlacebo *p) {}
MLPlaceboStats MLPlaceboGetStats(MLPlacebo *p) { return (MLPlaceboStats){0}; }
void MLPlaceboDestroy(MLPlacebo *p) {}
#endif
