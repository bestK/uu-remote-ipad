// In-process H.264/H.265 encoder for the iPad host: JPEG (from SpringBoard via frida)
// -> VideoToolbox -> Annex-B access units with AUD, the shape video.rs expects.
#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <ImageIO/ImageIO.h>
#import <VideoToolbox/VideoToolbox.h>

#include <stdio.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

typedef void (*uu_au_cb)(const unsigned char *data, size_t len, int keyframe, void *user);

typedef struct uu_vt uu_vt;
typedef struct {
    uu_vt *vt;
    uu_au_cb cb;
    void *user;
} uu_vt_sink;

struct uu_vt {
    VTCompressionSessionRef session;
    uu_vt_sink sink;
    int width, height, fps, gop, hevc;
    int64_t frame_index;
    int force_idr;
};

typedef struct {
    unsigned char *data;
    size_t len, cap;
} uu_buf;

static int buf_reserve(uu_buf *b, size_t extra) {
    if (b->len + extra <= b->cap) return 0;
    size_t cap = b->cap ? b->cap : 65536;
    while (cap < b->len + extra) cap *= 2;
    unsigned char *p = realloc(b->data, cap);
    if (!p) return -1;
    b->data = p; b->cap = cap;
    return 0;
}

static int buf_start_code(uu_buf *b) {
    static const unsigned char sc[4] = {0, 0, 0, 1};
    if (buf_reserve(b, 4)) return -1;
    memcpy(b->data + b->len, sc, 4); b->len += 4;
    return 0;
}

static int buf_append(uu_buf *b, const unsigned char *p, size_t n) {
    if (buf_reserve(b, n)) return -1;
    memcpy(b->data + b->len, p, n); b->len += n;
    return 0;
}

static int buf_aud(uu_buf *b, int hevc) {
    static const unsigned char h264[2] = {0x09, 0xF0};
    static const unsigned char h265[3] = {0x46, 0x01, 0x50};
    if (buf_start_code(b)) return -1;
    return hevc ? buf_append(b, h265, 3) : buf_append(b, h264, 2);
}

static int buf_parameter_sets(uu_buf *b, CMFormatDescriptionRef fmt, int hevc) {
    size_t count = 0;
    OSStatus st = hevc
        ? CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(fmt, 0, NULL, NULL, &count, NULL)
        : CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fmt, 0, NULL, NULL, &count, NULL);
    if (st != noErr) return -1;
    for (size_t i = 0; i < count; i++) {
        const uint8_t *set = NULL; size_t size = 0; int nal_len = 0;
        st = hevc
            ? CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(fmt, i, &set, &size, NULL, &nal_len)
            : CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fmt, i, &set, &size, NULL, &nal_len);
        if (st != noErr || !set) continue;
        if (buf_start_code(b) || buf_append(b, set, size)) return -1;
    }
    return 0;
}

// VideoToolbox hands back AVCC (4-byte lengths); the host pipeline speaks Annex-B.
static void vt_emit(uu_vt_sink *sink, CMSampleBufferRef sample) {
    uu_vt *ctx = sink->vt;
    CMFormatDescriptionRef fmt = CMSampleBufferGetFormatDescription(sample);
    if (!fmt) return;

    int keyframe = 1;
    CFArrayRef atts = CMSampleBufferGetSampleAttachmentsArray(sample, false);
    if (atts && CFArrayGetCount(atts) > 0) {
        CFDictionaryRef d = (CFDictionaryRef)CFArrayGetValueAtIndex(atts, 0);
        CFBooleanRef not_sync = (CFBooleanRef)CFDictionaryGetValue(d, kCMSampleAttachmentKey_NotSync);
        if (not_sync && CFBooleanGetValue(not_sync)) keyframe = 0;
    }

    CMBlockBufferRef block = CMSampleBufferGetDataBuffer(sample);
    if (!block) return;
    size_t total = 0; char *base = NULL;
    if (CMBlockBufferGetDataPointer(block, 0, NULL, &total, &base) != noErr || !base) return;

    uu_buf out = {0};
    if (buf_aud(&out, ctx->hevc)) { free(out.data); return; }
    if (keyframe && buf_parameter_sets(&out, fmt, ctx->hevc)) { free(out.data); return; }

    size_t off = 0;
    while (off + 4 <= total) {
        uint32_t n = ((uint32_t)(unsigned char)base[off] << 24) | ((uint32_t)(unsigned char)base[off+1] << 16)
                   | ((uint32_t)(unsigned char)base[off+2] << 8) | (uint32_t)(unsigned char)base[off+3];
        off += 4;
        if (n == 0 || off + n > total) break;
        if (buf_start_code(&out) || buf_append(&out, (const unsigned char *)base + off, n)) { free(out.data); return; }
        off += n;
    }
    if (out.len) sink->cb(out.data, out.len, keyframe, sink->user);
    free(out.data);
}

static void vt_callback(void *refcon, void *frame_refcon, OSStatus status,
                        VTEncodeInfoFlags flags, CMSampleBufferRef sample) {
    (void)frame_refcon; (void)flags;
    if (status != noErr || !sample) return;
    vt_emit((uu_vt_sink *)refcon, sample);
}

static CVPixelBufferRef decode_jpeg(const unsigned char *jpeg, size_t len, int dst_w, int dst_h, int *out_w, int *out_h) {
    CFDataRef data = CFDataCreate(NULL, jpeg, (CFIndex)len);
    if (!data) return NULL;
    CGImageSourceRef src = CGImageSourceCreateWithData(data, NULL);
    CFRelease(data);
    if (!src) { fprintf(stderr, "[ios_video] image source failed (%zu bytes)\n", len); return NULL; }
    // Ask ImageIO for a scaled decode when the encoder runs below the panel size:
    // JPEG DCT scaling is far cheaper than a full decode followed by a resample.
    size_t full_w = 0, full_h = 0;
    int orientation = 1;
    CFDictionaryRef props = CGImageSourceCopyPropertiesAtIndex(src, 0, NULL);
    if (props) {
        CFNumberRef pw = CFDictionaryGetValue(props, kCGImagePropertyPixelWidth);
        CFNumberRef ph = CFDictionaryGetValue(props, kCGImagePropertyPixelHeight);
        CFNumberRef po = CFDictionaryGetValue(props, kCGImagePropertyOrientation);
        if (pw) CFNumberGetValue(pw, kCFNumberSInt64Type, &full_w);
        if (ph) CFNumberGetValue(ph, kCFNumberSInt64Type, &full_h);
        if (po) CFNumberGetValue(po, kCFNumberIntType, &orientation);
        CFRelease(props);
    }
    static _Atomic uint64_t last_size = 0;
    uint64_t size = ((uint64_t)(orientation & 0xff) << 56) | ((uint64_t)full_w << 28) | full_h;
    if (full_w && full_h && atomic_exchange(&last_size, size) != size)
        fprintf(stderr, "[ios_video] captured JPEG dimensions: %zux%zu, orientation=%d, encoder: %dx%d\n", full_w, full_h, orientation, dst_w, dst_h);
    CGImageRef image = NULL;
    if (orientation != 1 || (dst_w > 0 && dst_h > 0 && full_w > (size_t)dst_w && full_h > (size_t)dst_h)) {
        size_t max_pixel = dst_w > 0 && dst_h > 0 ? (size_t)(dst_w > dst_h ? dst_w : dst_h) : (full_w > full_h ? full_w : full_h);
        NSDictionary *thumb = @{(id)kCGImageSourceCreateThumbnailFromImageAlways: @YES,
                                (id)kCGImageSourceCreateThumbnailWithTransform: @YES,
                                (id)kCGImageSourceThumbnailMaxPixelSize: @(max_pixel),
                                (id)kCGImageSourceShouldCache: @NO};
        image = CGImageSourceCreateThumbnailAtIndex(src, 0, (__bridge CFDictionaryRef)thumb);
    }
    if (!image) image = CGImageSourceCreateImageAtIndex(src, 0, NULL);
    CFRelease(src);
    if (!image) { fprintf(stderr, "[ios_video] image decode failed\n"); return NULL; }
    size_t w = CGImageGetWidth(image), h = CGImageGetHeight(image);
    if (!w || !h) { CGImageRelease(image); return NULL; }
    // Encode smaller than the native panel: JPEG decode + draw dominates the frame budget.
    size_t tw = dst_w > 0 ? (size_t)dst_w : w;
    size_t th = dst_h > 0 ? (size_t)dst_h : h;

    CVPixelBufferRef px = NULL;
    CVReturn cv = CVPixelBufferCreate(NULL, tw, th, kCVPixelFormatType_32BGRA, NULL, &px);
    if (cv != kCVReturnSuccess || !px) {
        fprintf(stderr, "[ios_video] pixel buffer failed %zux%zu cv=%d\n", tw, th, (int)cv);
        CGImageRelease(image); return NULL;
    }
    CVPixelBufferLockBaseAddress(px, 0);
    void *base = CVPixelBufferGetBaseAddress(px);
    size_t stride = CVPixelBufferGetBytesPerRow(px);
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    CGContextRef cg = CGBitmapContextCreate(base, tw, th, 8, stride, space,
        kCGBitmapByteOrder32Little | kCGImageAlphaPremultipliedFirst);
    CGColorSpaceRelease(space);
    if (!cg) { fprintf(stderr, "[ios_video] bitmap context failed\n"); CVPixelBufferUnlockBaseAddress(px, 0); CVPixelBufferRelease(px); CGImageRelease(image); return NULL; }
    CGContextSetInterpolationQuality(cg, kCGInterpolationLow);
    CGContextDrawImage(cg, CGRectMake(0, 0, (CGFloat)tw, (CGFloat)th), image);
    CGContextRelease(cg);
    CVPixelBufferUnlockBaseAddress(px, 0);
    CGImageRelease(image);
    if (out_w) *out_w = (int)tw;
    if (out_h) *out_h = (int)th;
    return px;
}

void *uu_vt_create(int width, int height, int fps, int gop, int max_kbps, int hevc) {
    if (width <= 0 || height <= 0 || fps <= 0) return NULL;
    uu_vt *ctx = calloc(1, sizeof(uu_vt));
    if (!ctx) return NULL;
    ctx->width = width; ctx->height = height; ctx->fps = fps;
    ctx->gop = gop > 0 ? gop : fps * 2;
    ctx->hevc = hevc != 0;
    ctx->force_idr = 1;
    ctx->sink.vt = ctx;

    NSDictionary *spec = @{(id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
                           (id)kCVPixelBufferWidthKey: @(width),
                           (id)kCVPixelBufferHeightKey: @(height),
                           (id)kCVPixelBufferIOSurfacePropertiesKey: @{}};
    OSStatus st = VTCompressionSessionCreate(NULL, width, height,
        ctx->hevc ? kCMVideoCodecType_HEVC : kCMVideoCodecType_H264,
        NULL, (__bridge CFDictionaryRef)spec, NULL, vt_callback, &ctx->sink, &ctx->session);
    if (st != noErr || !ctx->session) { free(ctx); return NULL; }

    CFStringRef profile = ctx->hevc ? kVTProfileLevel_HEVC_Main_AutoLevel : kVTProfileLevel_H264_Main_AutoLevel;
    VTSessionSetProperty(ctx->session, kVTCompressionPropertyKey_ProfileLevel, profile);
    VTSessionSetProperty(ctx->session, kVTCompressionPropertyKey_RealTime, kCFBooleanTrue);
    VTSessionSetProperty(ctx->session, kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse);
    VTSessionSetProperty(ctx->session, kVTCompressionPropertyKey_MaxKeyFrameInterval, (__bridge CFTypeRef)@(ctx->gop));
    if (max_kbps > 0) {
        int64_t bps = (int64_t)max_kbps * 1000;
        VTSessionSetProperty(ctx->session, kVTCompressionPropertyKey_AverageBitRate, (__bridge CFTypeRef)@(bps));
        NSArray *limits = @[@(bps / 8), @1.0];
        VTSessionSetProperty(ctx->session, kVTCompressionPropertyKey_DataRateLimits, (__bridge CFTypeRef)limits);
    }
    VTCompressionSessionPrepareToEncodeFrames(ctx->session);
    return ctx;
}

void uu_vt_set_callback(void *handle, uu_au_cb cb, void *user) {
    uu_vt *ctx = (uu_vt *)handle;
    if (!ctx) return;
    ctx->sink.cb = cb;
    ctx->sink.user = user;
}

void uu_vt_force_keyframe(void *handle) {
    uu_vt *ctx = (uu_vt *)handle;
    if (ctx) ctx->force_idr = 1;
}

// Encodes one JPEG. The callback runs on this thread because the frame is flushed before returning.
int uu_vt_encode(void *handle, const unsigned char *jpeg, size_t len, uu_au_cb cb, void *user) {
    uu_vt *ctx = (uu_vt *)handle;
    if (!ctx || !ctx->session || !cb) return -1;
    ctx->sink.cb = cb;
    ctx->sink.user = user;

    int w = 0, h = 0;
    CVPixelBufferRef px = decode_jpeg(jpeg, len, ctx->width, ctx->height, &w, &h);
    if (!px) return -2;
    if (w != ctx->width || h != ctx->height) {
        CVPixelBufferRelease(px);
        return -3;
    }

    NSDictionary *frame_props = nil;
    if (ctx->force_idr) {
        frame_props = @{(id)kVTEncodeFrameOptionKey_ForceKeyFrame: @YES};
        ctx->force_idr = 0;
    }
    CMTime pts = CMTimeMake(ctx->frame_index, ctx->fps);
    CMTime dur = CMTimeMake(1, ctx->fps);
    ctx->frame_index++;
    OSStatus st = VTCompressionSessionEncodeFrame(ctx->session, px, pts, dur,
        (__bridge CFDictionaryRef)frame_props, NULL, NULL);
    CVPixelBufferRelease(px);
    if (st != noErr) return -4;
    // Drain synchronously so access units stay in capture order and the JPEG buffer can be freed.
    st = VTCompressionSessionCompleteFrames(ctx->session, kCMTimeInvalid);
    return st == noErr ? 0 : -5;
}

void uu_vt_destroy(void *handle) {
    uu_vt *ctx = (uu_vt *)handle;
    if (!ctx) return;
    if (ctx->session) {
        VTCompressionSessionCompleteFrames(ctx->session, kCMTimeInvalid);
        VTCompressionSessionInvalidate(ctx->session);
        CFRelease(ctx->session);
    }
    free(ctx);
}

int uu_vt_decode_jpeg(const unsigned char *jpeg, size_t len, unsigned char *bgra, size_t cap, int *w, int *h) {
    CVPixelBufferRef px = decode_jpeg(jpeg, len, 0, 0, w, h);
    if (!px) return -1;
    CVPixelBufferLockBaseAddress(px, kCVPixelBufferLock_ReadOnly);
    size_t stride = CVPixelBufferGetBytesPerRow(px);
    int width = (int)CVPixelBufferGetWidth(px), height = (int)CVPixelBufferGetHeight(px);
    size_t need = (size_t)width * (size_t)height * 4;
    if (cap < need) { CVPixelBufferUnlockBaseAddress(px, kCVPixelBufferLock_ReadOnly); CVPixelBufferRelease(px); return -2; }
    const unsigned char *base = (const unsigned char *)CVPixelBufferGetBaseAddress(px);
    for (int y = 0; y < height; y++) memcpy(bgra + (size_t)y * width * 4, base + (size_t)y * stride, (size_t)width * 4);
    CVPixelBufferUnlockBaseAddress(px, kCVPixelBufferLock_ReadOnly);
    CVPixelBufferRelease(px);
    return 0;
}
