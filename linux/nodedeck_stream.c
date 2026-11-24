#include <SDL2/SDL.h>
#include <libavcodec/avcodec.h>
#include <libavutil/hwcontext.h>
#include <libavutil/imgutils.h>
#include <libswscale/swscale.h>
#include <opus/opus_multistream.h>

#include <signal.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "Limelight.h"

/* ---- Runtime state ---- */
static volatile bool g_running = true;
static SDL_Window *g_window = NULL;
static SDL_Renderer *g_renderer = NULL;
static SDL_Texture *g_texture = NULL;
static Uint32 g_tex_format = 0;
static int g_tex_w = 0, g_tex_h = 0;
static SDL_mutex *g_frame_mutex = NULL;

static const AVCodec *g_codec = NULL;
static AVCodecContext *g_codec_ctx = NULL;
static AVBufferRef *g_hw_device_ctx = NULL;
static enum AVPixelFormat g_hw_pix_fmt = AV_PIX_FMT_NONE;
static char g_decoder_backend[16] = "SW";
static char g_hwaccel_pref[16] = "auto";

static AVFrame *g_avframe = NULL;
static AVFrame *g_sw_frame = NULL;
static AVFrame *g_present_frame = NULL;
static AVPacket *g_avpkt = NULL;
static struct SwsContext *g_sws = NULL;
static enum AVPixelFormat g_sws_src_fmt = AV_PIX_FMT_NONE;
static int g_sws_src_w = 0, g_sws_src_h = 0;

static uint8_t *g_decode_buf = NULL;
static size_t g_decode_buf_cap = 0;
static bool g_has_new_frame = false;
static bool g_has_submitted_idr = false;

/* Live telemetry (updated under g_frame_mutex or on decode thread) */
static uint32_t g_stat_frames = 0;
static uint64_t g_stat_bytes = 0;
static int g_video_w = 1920, g_video_h = 1080;

static OpusMSDecoder *g_opus = NULL;
static SDL_AudioDeviceID g_audio_dev = 0;
static int g_audio_channels = 2;
static int g_audio_samples_per_frame = 240;

/* Input state */
#define MAX_PRESSED_KEYS 64
typedef struct {
    uint16_t vk;
    bool extended;
} PressedKey;

static PressedKey g_pressed_keys[MAX_PRESSED_KEYS];
static int g_pressed_count = 0;
static bool g_relative_mouse = false;
static bool g_fullscreen = false;
static bool g_show_stats_title = true;

static void handle_sigint(int sig) {
    (void)sig;
    g_running = false;
}

/* ---- FFmpeg HW decode selection ---- */
static enum AVPixelFormat hw_get_format(AVCodecContext *ctx, const enum AVPixelFormat *pix_fmts) {
    (void)ctx;
    for (const enum AVPixelFormat *p = pix_fmts; *p != AV_PIX_FMT_NONE; p++) {
        if (*p == g_hw_pix_fmt) {
            return *p;
        }
    }
    fprintf(stderr, "[nodedeck-stream] Hardware pixel format unavailable, falling back to software\n");
    g_hw_pix_fmt = AV_PIX_FMT_NONE;
    snprintf(g_decoder_backend, sizeof(g_decoder_backend), "SW");
    return pix_fmts[0];
}

static bool try_init_hwaccel(const AVCodec *codec, AVCodecContext *ctx, enum AVHWDeviceType type, const char *label) {
    enum AVPixelFormat target_fmt = AV_PIX_FMT_NONE;
    for (int i = 0;; i++) {
        const AVCodecHWConfig *cfg = avcodec_get_hw_config(codec, i);
        if (!cfg) break;
        if ((cfg->methods & AV_CODEC_HW_CONFIG_METHOD_HW_DEVICE_CTX) && cfg->device_type == type) {
            target_fmt = cfg->pix_fmt;
            break;
        }
    }
    if (target_fmt == AV_PIX_FMT_NONE) {
        return false;
    }

    AVBufferRef *hw_ctx = NULL;
    if (av_hwdevice_ctx_create(&hw_ctx, type, NULL, NULL, 0) < 0 || !hw_ctx) {
        return false;
    }

    g_hw_device_ctx = hw_ctx;
    g_hw_pix_fmt = target_fmt;
    ctx->hw_device_ctx = av_buffer_ref(hw_ctx);
    ctx->get_format = hw_get_format;
    snprintf(g_decoder_backend, sizeof(g_decoder_backend), "%s", label);
    fprintf(stderr, "[nodedeck-stream] Enabled %s hardware decoder\n", label);
    return true;
}

static int video_setup(int videoFormat, int width, int height, int redrawRate, void *context, int drFlags) {
    (void)redrawRate;
    (void)context;
    (void)drFlags;

    enum AVCodecID codec_id = AV_CODEC_ID_H264;
    if (videoFormat & VIDEO_FORMAT_MASK_AV1) {
        codec_id = AV_CODEC_ID_AV1;
    } else if (videoFormat & VIDEO_FORMAT_MASK_H265) {
        codec_id = AV_CODEC_ID_HEVC;
    }

    g_codec = avcodec_find_decoder(codec_id);
    if (!g_codec) {
        fprintf(stderr, "[nodedeck-stream] Failed to find FFmpeg decoder for codec %d\n", codec_id);
        return -1;
    }

    g_codec_ctx = avcodec_alloc_context3(g_codec);
    if (!g_codec_ctx) return -2;

    g_codec_ctx->width = width;
    g_codec_ctx->height = height;
    g_codec_ctx->flags |= AV_CODEC_FLAG_LOW_DELAY;
    g_codec_ctx->flags2 |= AV_CODEC_FLAG2_FAST;

    g_hw_device_ctx = NULL;
    g_hw_pix_fmt = AV_PIX_FMT_NONE;
    snprintf(g_decoder_backend, sizeof(g_decoder_backend), "SW");

    bool hw_ok = false;
    if (strcmp(g_hwaccel_pref, "none") != 0 && strcmp(g_hwaccel_pref, "sw") != 0) {
        if (strcmp(g_hwaccel_pref, "vaapi") == 0) {
            hw_ok = try_init_hwaccel(g_codec, g_codec_ctx, AV_HWDEVICE_TYPE_VAAPI, "VAAPI");
        } else if (strcmp(g_hwaccel_pref, "cuda") == 0) {
            hw_ok = try_init_hwaccel(g_codec, g_codec_ctx, AV_HWDEVICE_TYPE_CUDA, "CUDA");
        } else {
            /* auto: prefer VAAPI on Intel/AMD Linux, then CUDA/NVDEC on NVIDIA */
            hw_ok = try_init_hwaccel(g_codec, g_codec_ctx, AV_HWDEVICE_TYPE_VAAPI, "VAAPI");
            if (!hw_ok) {
                hw_ok = try_init_hwaccel(g_codec, g_codec_ctx, AV_HWDEVICE_TYPE_CUDA, "CUDA");
            }
        }
    }

    if (!hw_ok) {
        g_codec_ctx->thread_count = 4;
        g_codec_ctx->thread_type = FF_THREAD_SLICE;
    } else {
        g_codec_ctx->thread_count = 1;
    }

    if (avcodec_open2(g_codec_ctx, g_codec, NULL) < 0) {
        fprintf(stderr, "[nodedeck-stream] Failed to open FFmpeg decoder (%s)\n", g_decoder_backend);
        if (hw_ok) {
            /* Retry pure software cleanly */
            avcodec_free_context(&g_codec_ctx);
            av_buffer_unref(&g_hw_device_ctx);
            g_hw_pix_fmt = AV_PIX_FMT_NONE;
            snprintf(g_decoder_backend, sizeof(g_decoder_backend), "SW");
            g_codec_ctx = avcodec_alloc_context3(g_codec);
            if (!g_codec_ctx) return -2;
            g_codec_ctx->width = width;
            g_codec_ctx->height = height;
            g_codec_ctx->thread_count = 4;
            g_codec_ctx->thread_type = FF_THREAD_SLICE;
            g_codec_ctx->flags |= AV_CODEC_FLAG_LOW_DELAY;
            if (avcodec_open2(g_codec_ctx, g_codec, NULL) < 0) {
                return -3;
            }
        } else {
            return -3;
        }
    }

    g_avframe = av_frame_alloc();
    g_sw_frame = av_frame_alloc();
    g_present_frame = av_frame_alloc();
    g_avpkt = av_packet_alloc();
    g_video_w = width;
    g_video_h = height;
    g_has_submitted_idr = false;
    return 0;
}

static void video_cleanup(void) {
    if (g_sws) { sws_freeContext(g_sws); g_sws = NULL; }
    g_sws_src_fmt = AV_PIX_FMT_NONE;
    g_sws_src_w = g_sws_src_h = 0;
    if (g_avpkt) { av_packet_free(&g_avpkt); }
    if (g_avframe) { av_frame_free(&g_avframe); }
    if (g_sw_frame) { av_frame_free(&g_sw_frame); }
    if (g_present_frame) { av_frame_free(&g_present_frame); }
    if (g_codec_ctx) { avcodec_free_context(&g_codec_ctx); }
    if (g_hw_device_ctx) { av_buffer_unref(&g_hw_device_ctx); }
    g_hw_pix_fmt = AV_PIX_FMT_NONE;
    free(g_decode_buf);
    g_decode_buf = NULL;
    g_decode_buf_cap = 0;
}

static int video_submit_decode_unit(PDECODE_UNIT decodeUnit) {
    if (!decodeUnit || !g_codec_ctx) return DR_OK;

    if (decodeUnit->frameType == FRAME_TYPE_IDR) {
        g_has_submitted_idr = true;
    } else if (!g_has_submitted_idr) {
        return DR_NEED_IDR;
    }

    size_t needed = (size_t)decodeUnit->fullLength + AV_INPUT_BUFFER_PADDING_SIZE;
    if (needed > g_decode_buf_cap) {
        uint8_t *nb = (uint8_t *)realloc(g_decode_buf, needed);
        if (!nb) return DR_NEED_IDR;
        g_decode_buf = nb;
        g_decode_buf_cap = needed;
    }

    size_t offset = 0;
    for (PLENTRY entry = decodeUnit->bufferList; entry != NULL; entry = entry->next) {
        if (entry->data && entry->length > 0) {
            memcpy(g_decode_buf + offset, entry->data, (size_t)entry->length);
            offset += (size_t)entry->length;
        }
    }
    memset(g_decode_buf + offset, 0, AV_INPUT_BUFFER_PADDING_SIZE);

    av_packet_unref(g_avpkt);
    g_avpkt->data = g_decode_buf;
    g_avpkt->size = (int)offset;

    if (avcodec_send_packet(g_codec_ctx, g_avpkt) < 0) {
        g_has_submitted_idr = false;
        return DR_NEED_IDR;
    }

    while (avcodec_receive_frame(g_codec_ctx, g_avframe) == 0) {
        AVFrame *src = g_avframe;
        if (g_hw_pix_fmt != AV_PIX_FMT_NONE && g_avframe->format == g_hw_pix_fmt) {
            av_frame_unref(g_sw_frame);
            if (av_hwframe_transfer_data(g_sw_frame, g_avframe, 0) < 0) {
                continue;
            }
            src = g_sw_frame;
        }

        SDL_LockMutex(g_frame_mutex);
        g_stat_frames++;
        g_stat_bytes += (uint64_t)decodeUnit->fullLength;
        g_video_w = src->width;
        g_video_h = src->height;

        /* Zero-sws fast path for NV12 and YUV420P */
        if (src->format == AV_PIX_FMT_NV12 || src->format == AV_PIX_FMT_YUV420P) {
            av_frame_unref(g_present_frame);
            if (av_frame_ref(g_present_frame, src) == 0) {
                g_has_new_frame = true;
            }
        } else {
            /* Rare fallback (e.g., 10-bit or YUVJ420P) -> convert to YUV420P */
            if (g_present_frame->format != AV_PIX_FMT_YUV420P ||
                g_present_frame->width != src->width ||
                g_present_frame->height != src->height) {
                av_frame_unref(g_present_frame);
                g_present_frame->format = AV_PIX_FMT_YUV420P;
                g_present_frame->width = src->width;
                g_present_frame->height = src->height;
                av_frame_get_buffer(g_present_frame, 32);
            }
            if (!g_sws || g_sws_src_fmt != (enum AVPixelFormat)src->format ||
                g_sws_src_w != src->width || g_sws_src_h != src->height) {
                if (g_sws) sws_freeContext(g_sws);
                g_sws_src_fmt = (enum AVPixelFormat)src->format;
                g_sws_src_w = src->width;
                g_sws_src_h = src->height;
                g_sws = sws_getContext(
                    src->width, src->height, (enum AVPixelFormat)src->format,
                    src->width, src->height, AV_PIX_FMT_YUV420P,
                    SWS_FAST_BILINEAR, NULL, NULL, NULL
                );
            }
            if (g_sws) {
                sws_scale(
                    g_sws,
                    (const uint8_t *const *)src->data, src->linesize,
                    0, src->height,
                    g_present_frame->data, g_present_frame->linesize
                );
                g_has_new_frame = true;
            }
        }
        SDL_UnlockMutex(g_frame_mutex);
    }

    return DR_OK;
}

/* ---- Audio ---- */
static int audio_init(int audioConfiguration, const POPUS_MULTISTREAM_CONFIGURATION opusConfig, void *context, int arFlags) {
    (void)audioConfiguration;
    (void)context;
    (void)arFlags;
    if (!opusConfig) return -1;

    int err = 0;
    g_opus = opus_multistream_decoder_create(
        opusConfig->sampleRate,
        opusConfig->channelCount,
        opusConfig->streams,
        opusConfig->coupledStreams,
        opusConfig->mapping,
        &err
    );
    if (err != OPUS_OK || !g_opus) return -2;

    g_audio_channels = opusConfig->channelCount;
    g_audio_samples_per_frame = opusConfig->samplesPerFrame;

    SDL_AudioSpec want;
    SDL_zero(want);
    want.freq = opusConfig->sampleRate;
    want.format = AUDIO_S16SYS;
    want.channels = (Uint8)opusConfig->channelCount;
    want.samples = (Uint16)opusConfig->samplesPerFrame;
    g_audio_dev = SDL_OpenAudioDevice(NULL, 0, &want, NULL, 0);
    if (g_audio_dev != 0) {
        SDL_PauseAudioDevice(g_audio_dev, 0);
    }
    return 0;
}

static void audio_cleanup(void) {
    if (g_audio_dev != 0) {
        SDL_CloseAudioDevice(g_audio_dev);
        g_audio_dev = 0;
    }
    if (g_opus) {
        opus_multistream_decoder_destroy(g_opus);
        g_opus = NULL;
    }
}

static void audio_decode_and_play(char *sampleData, int sampleLength) {
    if (!g_opus || g_audio_dev == 0 || !sampleData || sampleLength <= 0) return;
    int16_t pcm[4096];
    int frames = opus_multistream_decode(g_opus, (const unsigned char *)sampleData, sampleLength, pcm, g_audio_samples_per_frame, 0);
    if (frames > 0) {
        if (SDL_GetQueuedAudioSize(g_audio_dev) < (Uint32)(frames * g_audio_channels * 2 * 6)) {
            SDL_QueueAudio(g_audio_dev, pcm, (Uint32)(frames * g_audio_channels * sizeof(int16_t)));
        }
    }
}

static void conn_terminated(int errorCode) {
    fprintf(stderr, "[nodedeck-stream] Stream terminated (code %d)\n", errorCode);
    g_running = false;
}

static int hex_to_bytes(const char *hex, uint8_t *out, size_t max_len) {
    size_t len = strlen(hex);
    if (len / 2 > max_len) return -1;
    for (size_t i = 0; i < len / 2; i++) {
        unsigned int v = 0;
        if (sscanf(hex + 2 * i, "%2x", &v) != 1) return -1;
        out[i] = (uint8_t)v;
    }
    return (int)(len / 2);
}

/* ---- Native Moonlight Keyboard Engine ---- */
static uint16_t sdl_scancode_to_vk(SDL_Scancode sc, bool *is_extended) {
    *is_extended = false;
    if (sc >= SDL_SCANCODE_A && sc <= SDL_SCANCODE_Z) {
        return (uint16_t)(0x41 + (sc - SDL_SCANCODE_A));
    }
    if (sc >= SDL_SCANCODE_1 && sc <= SDL_SCANCODE_9) {
        return (uint16_t)(0x31 + (sc - SDL_SCANCODE_1));
    }
    if (sc == SDL_SCANCODE_0) return 0x30;
    if (sc >= SDL_SCANCODE_F1 && sc <= SDL_SCANCODE_F12) {
        return (uint16_t)(0x70 + (sc - SDL_SCANCODE_F1));
    }
    if (sc >= SDL_SCANCODE_F13 && sc <= SDL_SCANCODE_F24) {
        return (uint16_t)(0x7C + (sc - SDL_SCANCODE_F13));
    }

    switch (sc) {
        case SDL_SCANCODE_RETURN:       return 0x0D;
        case SDL_SCANCODE_ESCAPE:       return 0x1B;
        case SDL_SCANCODE_BACKSPACE:    return 0x08;
        case SDL_SCANCODE_TAB:          return 0x09;
        case SDL_SCANCODE_SPACE:        return 0x20;
        case SDL_SCANCODE_MINUS:        return 0xBD;
        case SDL_SCANCODE_EQUALS:       return 0xBB;
        case SDL_SCANCODE_LEFTBRACKET:  return 0xDB;
        case SDL_SCANCODE_RIGHTBRACKET: return 0xDD;
        case SDL_SCANCODE_BACKSLASH:    return 0xDC;
        case SDL_SCANCODE_NONUSHASH:    return 0xDC;
        case SDL_SCANCODE_SEMICOLON:    return 0xBA;
        case SDL_SCANCODE_APOSTROPHE:   return 0xDE;
        case SDL_SCANCODE_GRAVE:        return 0xC0;
        case SDL_SCANCODE_COMMA:        return 0xBC;
        case SDL_SCANCODE_PERIOD:       return 0xBE;
        case SDL_SCANCODE_SLASH:        return 0xBF;
        case SDL_SCANCODE_CAPSLOCK:     return 0x14;

        case SDL_SCANCODE_PRINTSCREEN:  *is_extended = true; return 0x2C;
        case SDL_SCANCODE_SCROLLLOCK:   return 0x91;
        case SDL_SCANCODE_PAUSE:        return 0x13;
        case SDL_SCANCODE_INSERT:       *is_extended = true; return 0x2D;
        case SDL_SCANCODE_HOME:         *is_extended = true; return 0x24;
        case SDL_SCANCODE_PAGEUP:       *is_extended = true; return 0x21;
        case SDL_SCANCODE_DELETE:       *is_extended = true; return 0x2E;
        case SDL_SCANCODE_END:          *is_extended = true; return 0x23;
        case SDL_SCANCODE_PAGEDOWN:     *is_extended = true; return 0x22;
        case SDL_SCANCODE_RIGHT:        *is_extended = true; return 0x27;
        case SDL_SCANCODE_LEFT:         *is_extended = true; return 0x25;
        case SDL_SCANCODE_DOWN:         *is_extended = true; return 0x28;
        case SDL_SCANCODE_UP:           *is_extended = true; return 0x26;

        case SDL_SCANCODE_NUMLOCKCLEAR: return 0x90;
        case SDL_SCANCODE_KP_DIVIDE:    *is_extended = true; return 0x6F;
        case SDL_SCANCODE_KP_MULTIPLY:  return 0x6A;
        case SDL_SCANCODE_KP_MINUS:     return 0x6D;
        case SDL_SCANCODE_KP_PLUS:      return 0x6B;
        case SDL_SCANCODE_KP_ENTER:     *is_extended = true; return 0x0D;
        case SDL_SCANCODE_KP_1:         return 0x61;
        case SDL_SCANCODE_KP_2:         return 0x62;
        case SDL_SCANCODE_KP_3:         return 0x63;
        case SDL_SCANCODE_KP_4:         return 0x64;
        case SDL_SCANCODE_KP_5:         return 0x65;
        case SDL_SCANCODE_KP_6:         return 0x66;
        case SDL_SCANCODE_KP_7:         return 0x67;
        case SDL_SCANCODE_KP_8:         return 0x68;
        case SDL_SCANCODE_KP_9:         return 0x69;
        case SDL_SCANCODE_KP_0:         return 0x60;
        case SDL_SCANCODE_KP_PERIOD:    return 0x6E;

        case SDL_SCANCODE_LSHIFT:       return 0xA0;
        case SDL_SCANCODE_RSHIFT:       return 0xA1;
        case SDL_SCANCODE_LCTRL:        return 0xA2;
        case SDL_SCANCODE_RCTRL:        *is_extended = true; return 0xA3;
        case SDL_SCANCODE_LALT:         return 0xA4;
        case SDL_SCANCODE_RALT:         *is_extended = true; return 0xA5;
        case SDL_SCANCODE_LGUI:         *is_extended = true; return 0x5B;
        case SDL_SCANCODE_RGUI:         *is_extended = true; return 0x5C;
        case SDL_SCANCODE_APPLICATION:  *is_extended = true; return 0x5D;

        default: return 0;
    }
}

static char sdl_mods_to_moonlight(SDL_Keymod mod) {
    char m = 0;
    if (mod & KMOD_SHIFT) m |= MODIFIER_SHIFT;
    if (mod & KMOD_CTRL)  m |= MODIFIER_CTRL;
    if (mod & KMOD_ALT)   m |= MODIFIER_ALT;
    if (mod & KMOD_GUI)   m |= MODIFIER_META;
    return m;
}

static void track_key_down(uint16_t vk, bool extended) {
    for (int i = 0; i < g_pressed_count; i++) {
        if (g_pressed_keys[i].vk == vk && g_pressed_keys[i].extended == extended) {
            return;
        }
    }
    if (g_pressed_count < MAX_PRESSED_KEYS) {
        g_pressed_keys[g_pressed_count].vk = vk;
        g_pressed_keys[g_pressed_count].extended = extended;
        g_pressed_count++;
    }
}

static void track_key_up(uint16_t vk, bool extended) {
    for (int i = 0; i < g_pressed_count; i++) {
        if (g_pressed_keys[i].vk == vk && g_pressed_keys[i].extended == extended) {
            g_pressed_keys[i] = g_pressed_keys[g_pressed_count - 1];
            g_pressed_count--;
            return;
        }
    }
}

static void send_moonlight_key(uint16_t vk, bool down, char mods, bool extended) {
    if (extended) {
        mods |= MODIFIER_EXTENDED;
    }
    short encoded = (short)(0x8000 | (vk & 0xFF));
    LiSendKeyboardEvent2(encoded, down ? KEY_ACTION_DOWN : KEY_ACTION_UP, mods, 0);
}

static void raise_all_keys(void) {
    for (int i = g_pressed_count - 1; i >= 0; i--) {
        send_moonlight_key(g_pressed_keys[i].vk, false, 0, g_pressed_keys[i].extended);
    }
    g_pressed_count = 0;
}

/* ---- Aspect-ratio letterbox geometry ---- */
static SDL_Rect compute_letterbox_rect(int container_w, int container_h, int video_w, int video_h) {
    SDL_Rect r = {0, 0, container_w, container_h};
    if (container_w <= 0 || container_h <= 0 || video_w <= 0 || video_h <= 0) {
        return r;
    }
    double win_aspect = (double)container_w / (double)container_h;
    double vid_aspect = (double)video_w / (double)video_h;
    if (win_aspect > vid_aspect) {
        r.h = container_h;
        r.w = (int)((double)container_h * vid_aspect + 0.5);
        if (r.w < 1) r.w = 1;
        r.x = (container_w - r.w) / 2;
        r.y = 0;
    } else {
        r.w = container_w;
        r.h = (int)((double)container_w / vid_aspect + 0.5);
        if (r.h < 1) r.h = 1;
        r.x = 0;
        r.y = (container_h - r.h) / 2;
    }
    return r;
}

static void send_absolute_mouse(int mx, int my) {
    int win_w = 1, win_h = 1;
    SDL_GetWindowSize(g_window, &win_w, &win_h);
    SDL_Rect dst = compute_letterbox_rect(win_w, win_h, g_video_w, g_video_h);
    int rel_x = mx - dst.x;
    int rel_y = my - dst.y;
    if (rel_x < 0) rel_x = 0;
    if (rel_y < 0) rel_y = 0;
    if (rel_x >= dst.w) rel_x = dst.w - 1;
    if (rel_y >= dst.h) rel_y = dst.h - 1;
    LiSendMousePositionEvent((short)rel_x, (short)rel_y, (short)dst.w, (short)dst.h);
}

static void set_relative_mouse(bool enabled) {
    g_relative_mouse = enabled;
    SDL_SetRelativeMouseMode(enabled ? SDL_TRUE : SDL_FALSE);
    raise_all_keys();
}

static void toggle_fullscreen(void) {
    g_fullscreen = !g_fullscreen;
    SDL_SetWindowFullscreen(g_window, g_fullscreen ? SDL_WINDOW_FULLSCREEN_DESKTOP : 0);
    raise_all_keys();
}

/* ---- Direct texture upload (NV12 / IYUV) ---- */
static void upload_frame_to_texture(const AVFrame *frame) {
    Uint32 desired_fmt = (frame->format == AV_PIX_FMT_NV12) ? SDL_PIXELFORMAT_NV12 : SDL_PIXELFORMAT_IYUV;
    if (!g_texture || g_tex_w != frame->width || g_tex_h != frame->height || g_tex_format != desired_fmt) {
        if (g_texture) SDL_DestroyTexture(g_texture);
        g_tex_w = frame->width;
        g_tex_h = frame->height;
        g_tex_format = desired_fmt;
        SDL_SetHint(SDL_HINT_RENDER_SCALE_QUALITY, "1");
        g_texture = SDL_CreateTexture(g_renderer, desired_fmt, SDL_TEXTUREACCESS_STREAMING, g_tex_w, g_tex_h);
    }
    if (!g_texture) return;

    if (desired_fmt == SDL_PIXELFORMAT_IYUV) {
        SDL_UpdateYUVTexture(
            g_texture, NULL,
            frame->data[0], frame->linesize[0],
            frame->data[1], frame->linesize[1],
            frame->data[2], frame->linesize[2]
        );
    } else {
        /* SDL_PIXELFORMAT_NV12: Y plane (h rows of w bytes) + UV plane (h/2 rows of w bytes) */
        void *pixels = NULL;
        int pitch = 0;
        if (SDL_LockTexture(g_texture, NULL, &pixels, &pitch) == 0) {
            uint8_t *dst_y = (uint8_t *)pixels;
            for (int y = 0; y < frame->height; y++) {
                memcpy(dst_y + y * pitch, frame->data[0] + y * frame->linesize[0], (size_t)frame->width);
            }
            uint8_t *dst_uv = dst_y + pitch * frame->height;
            int uv_h = frame->height / 2;
            for (int y = 0; y < uv_h; y++) {
                memcpy(dst_uv + y * pitch, frame->data[1] + y * frame->linesize[1], (size_t)frame->width);
            }
            SDL_UnlockTexture(g_texture);
        }
    }
}

int main(int argc, char **argv) {
    const char *host = NULL;
    const char *appver = "7.1.431.0";
    const char *gfever = "3.23.0.74";
    const char *rtsp = NULL;
    const char *rikey_hex = NULL;
    uint32_t rikeyid = 1;
    int width = 1920, height = 1080, fps = 60, bitrate = 20000, codec_support = 0;

    for (int i = 1; i + 1 < argc; i += 2) {
        if (strcmp(argv[i], "--host") == 0) host = argv[i + 1];
        else if (strcmp(argv[i], "--appver") == 0) appver = argv[i + 1];
        else if (strcmp(argv[i], "--gfever") == 0) gfever = argv[i + 1];
        else if (strcmp(argv[i], "--rtsp") == 0) rtsp = argv[i + 1];
        else if (strcmp(argv[i], "--rikey") == 0) rikey_hex = argv[i + 1];
        else if (strcmp(argv[i], "--rikeyid") == 0) rikeyid = (uint32_t)strtoul(argv[i + 1], NULL, 10);
        else if (strcmp(argv[i], "--width") == 0) width = atoi(argv[i + 1]);
        else if (strcmp(argv[i], "--height") == 0) height = atoi(argv[i + 1]);
        else if (strcmp(argv[i], "--fps") == 0) fps = atoi(argv[i + 1]);
        else if (strcmp(argv[i], "--bitrate") == 0) bitrate = atoi(argv[i + 1]);
        else if (strcmp(argv[i], "--codec-support") == 0) codec_support = atoi(argv[i + 1]);
        else if (strcmp(argv[i], "--hwaccel") == 0) snprintf(g_hwaccel_pref, sizeof(g_hwaccel_pref), "%s", argv[i + 1]);
    }

    if (!host || !rtsp || !rikey_hex) {
        fprintf(stderr, "Usage: nodedeck-stream --host IP --rtsp URL --rikey HEX --rikeyid ID [--hwaccel auto|vaapi|cuda|none]\n");
        return 1;
    }

    signal(SIGINT, handle_sigint);
    signal(SIGTERM, handle_sigint);

    if (SDL_Init(SDL_INIT_VIDEO | SDL_INIT_AUDIO | SDL_INIT_EVENTS) != 0) {
        fprintf(stderr, "SDL_Init failed: %s\n", SDL_GetError());
        return 2;
    }

    g_frame_mutex = SDL_CreateMutex();
    char title[256];
    snprintf(title, sizeof(title), "NodeDeck Remote Desktop — %s", host);
    g_window = SDL_CreateWindow(
        title,
        SDL_WINDOWPOS_CENTERED, SDL_WINDOWPOS_CENTERED,
        1280, 720,
        SDL_WINDOW_RESIZABLE | SDL_WINDOW_ALLOW_HIGHDPI
    );
    g_renderer = SDL_CreateRenderer(g_window, -1, SDL_RENDERER_ACCELERATED | SDL_RENDERER_PRESENTVSYNC);

    SERVER_INFORMATION serverInfo;
    LiInitializeServerInformation(&serverInfo);
    serverInfo.address = host;
    serverInfo.serverInfoAppVersion = appver;
    serverInfo.serverInfoGfeVersion = gfever;
    serverInfo.rtspSessionUrl = rtsp;
    serverInfo.serverCodecModeSupport = codec_support;

    STREAM_CONFIGURATION streamConfig;
    LiInitializeStreamConfiguration(&streamConfig);
    streamConfig.width = width;
    streamConfig.height = height;
    streamConfig.fps = fps;
    streamConfig.bitrate = bitrate;
    streamConfig.packetSize = 1392;
    streamConfig.streamingRemotely = STREAM_CFG_AUTO;
    streamConfig.audioConfiguration = AUDIO_CONFIGURATION_STEREO;
    streamConfig.supportedVideoFormats = VIDEO_FORMAT_H265 | VIDEO_FORMAT_H264;
    if (avcodec_find_decoder(AV_CODEC_ID_AV1) != NULL) {
        streamConfig.supportedVideoFormats |= VIDEO_FORMAT_AV1_MAIN8;
    }
    streamConfig.colorSpace = COLORSPACE_REC_709;
    streamConfig.colorRange = COLOR_RANGE_LIMITED;

    hex_to_bytes(rikey_hex, (uint8_t *)streamConfig.remoteInputAesKey, 16);
    streamConfig.remoteInputAesIv[0] = (char)((rikeyid >> 24) & 0xFF);
    streamConfig.remoteInputAesIv[1] = (char)((rikeyid >> 16) & 0xFF);
    streamConfig.remoteInputAesIv[2] = (char)((rikeyid >> 8) & 0xFF);
    streamConfig.remoteInputAesIv[3] = (char)(rikeyid & 0xFF);

    DECODER_RENDERER_CALLBACKS dr = {0};
    LiInitializeVideoCallbacks(&dr);
    dr.setup = video_setup;
    dr.cleanup = video_cleanup;
    dr.submitDecodeUnit = video_submit_decode_unit;
    dr.capabilities = CAPABILITY_DIRECT_SUBMIT;

    AUDIO_RENDERER_CALLBACKS ar = {0};
    LiInitializeAudioCallbacks(&ar);
    ar.init = audio_init;
    ar.cleanup = audio_cleanup;
    ar.decodeAndPlaySample = audio_decode_and_play;
    ar.capabilities = CAPABILITY_DIRECT_SUBMIT;

    CONNECTION_LISTENER_CALLBACKS cl = {0};
    LiInitializeConnectionCallbacks(&cl);
    cl.connectionTerminated = conn_terminated;

    int rc = LiStartConnection(&serverInfo, &streamConfig, &cl, &dr, &ar, NULL, 0, NULL, 0);
    if (rc != 0) {
        fprintf(stderr, "LiStartConnection failed: %d\n", rc);
        SDL_Quit();
        return 3;
    }

    Uint32 last_stats_tick = SDL_GetTicks();

    while (g_running) {
        SDL_Event ev;
        while (SDL_PollEvent(&ev)) {
            if (ev.type == SDL_QUIT) {
                g_running = false;
            } else if (ev.type == SDL_WINDOWEVENT) {
                if (ev.window.event == SDL_WINDOWEVENT_FOCUS_LOST ||
                    ev.window.event == SDL_WINDOWEVENT_MINIMIZED) {
                    raise_all_keys();
                    if (g_relative_mouse) {
                        set_relative_mouse(false);
                    }
                }
            } else if (ev.type == SDL_MOUSEMOTION) {
                if (g_relative_mouse) {
                    LiSendMouseMoveEvent((short)ev.motion.xrel, (short)ev.motion.yrel);
                } else {
                    send_absolute_mouse(ev.motion.x, ev.motion.y);
                }
            } else if (ev.type == SDL_MOUSEBUTTONDOWN || ev.type == SDL_MOUSEBUTTONUP) {
                if (!g_relative_mouse) {
                    send_absolute_mouse(ev.button.x, ev.button.y);
                }
                int btn = 0;
                switch (ev.button.button) {
                    case SDL_BUTTON_LEFT:   btn = BUTTON_LEFT; break;
                    case SDL_BUTTON_RIGHT:  btn = BUTTON_RIGHT; break;
                    case SDL_BUTTON_MIDDLE: btn = BUTTON_MIDDLE; break;
                    case SDL_BUTTON_X1:     btn = BUTTON_X1; break;
                    case SDL_BUTTON_X2:     btn = BUTTON_X2; break;
                    default: break;
                }
                if (btn != 0) {
                    char act = ev.type == SDL_MOUSEBUTTONDOWN ? BUTTON_ACTION_PRESS : BUTTON_ACTION_RELEASE;
                    LiSendMouseButtonEvent(act, btn);
                }
            } else if (ev.type == SDL_MOUSEWHEEL) {
                int flip = (ev.wheel.direction == SDL_MOUSEWHEEL_FLIPPED) ? -1 : 1;
                if (ev.wheel.y != 0) {
                    LiSendHighResScrollEvent((short)(ev.wheel.y * 120 * flip));
                }
                if (ev.wheel.x != 0) {
                    LiSendHighResHScrollEvent((short)(ev.wheel.x * 120 * flip));
                }
            } else if (ev.type == SDL_KEYDOWN || ev.type == SDL_KEYUP) {
                if (ev.type == SDL_KEYDOWN && ev.key.repeat != 0) {
                    continue;
                }

                SDL_Keymod kmod = (SDL_Keymod)ev.key.keysym.mod;
                bool combo = (kmod & KMOD_CTRL) && (kmod & KMOD_ALT) && (kmod & KMOD_SHIFT);

                if (ev.type == SDL_KEYDOWN) {
                    if (ev.key.keysym.scancode == SDL_SCANCODE_F11 || (combo && ev.key.keysym.scancode == SDL_SCANCODE_F)) {
                        toggle_fullscreen();
                        continue;
                    }
                    if (combo && ev.key.keysym.scancode == SDL_SCANCODE_Q) {
                        raise_all_keys();
                        g_running = false;
                        continue;
                    }
                    if (combo && ev.key.keysym.scancode == SDL_SCANCODE_M) {
                        set_relative_mouse(!g_relative_mouse);
                        continue;
                    }
                    if (combo && ev.key.keysym.scancode == SDL_SCANCODE_Z) {
                        set_relative_mouse(false);
                        continue;
                    }
                    if (combo && ev.key.keysym.scancode == SDL_SCANCODE_S) {
                        g_show_stats_title = !g_show_stats_title;
                        if (!g_show_stats_title) {
                            snprintf(title, sizeof(title), "NodeDeck Remote Desktop — %s", host);
                            SDL_SetWindowTitle(g_window, title);
                        }
                        continue;
                    }
                }

                bool is_extended = false;
                uint16_t vk = sdl_scancode_to_vk(ev.key.keysym.scancode, &is_extended);
                if (vk != 0) {
                    char mods = sdl_mods_to_moonlight(kmod);
                    bool down = (ev.type == SDL_KEYDOWN);
                    if (down) {
                        track_key_down(vk, is_extended);
                    } else {
                        track_key_up(vk, is_extended);
                    }
                    send_moonlight_key(vk, down, mods, is_extended);
                }
            }
        }

        /* Present newest frame with exact aspect-ratio letterboxing */
        SDL_LockMutex(g_frame_mutex);
        if (g_has_new_frame && g_present_frame && g_present_frame->width > 0) {
            upload_frame_to_texture(g_present_frame);
            g_has_new_frame = false;
            int vw = g_present_frame->width;
            int vh = g_present_frame->height;
            SDL_UnlockMutex(g_frame_mutex);

            int out_w = 1, out_h = 1;
            SDL_GetRendererOutputSize(g_renderer, &out_w, &out_h);
            SDL_Rect dst = compute_letterbox_rect(out_w, out_h, vw, vh);

            SDL_SetRenderDrawColor(g_renderer, 0, 0, 0, 255);
            SDL_RenderClear(g_renderer);
            if (g_texture) {
                SDL_RenderCopy(g_renderer, g_texture, NULL, &dst);
            }
            SDL_RenderPresent(g_renderer);
        } else {
            SDL_UnlockMutex(g_frame_mutex);
            SDL_Delay(2);
        }

        /* Update live telemetry window title every 1s */
        Uint32 now = SDL_GetTicks();
        if (g_show_stats_title && now - last_stats_tick >= 1000) {
            double sec = (double)(now - last_stats_tick) / 1000.0;
            SDL_LockMutex(g_frame_mutex);
            uint32_t frames = g_stat_frames;
            uint64_t bytes = g_stat_bytes;
            int vw = g_video_w, vh = g_video_h;
            g_stat_frames = 0;
            g_stat_bytes = 0;
            SDL_UnlockMutex(g_frame_mutex);

            uint32_t rtt = 0, rtt_var = 0;
            LiGetEstimatedRttInfo(&rtt, &rtt_var);
            int measured_fps = (int)(frames / sec + 0.5);
            double mbps = ((double)bytes * 8.0) / (sec * 1000000.0);

            snprintf(
                title, sizeof(title),
                "NodeDeck — %s [%s %dx%d @ %dfps | %.1f Mbps | %ums | %s] (Ctrl+Alt+Shift+M/F/Q)",
                host, g_decoder_backend, vw, vh, measured_fps, mbps, rtt,
                g_relative_mouse ? "RelMouse" : "AbsMouse"
            );
            SDL_SetWindowTitle(g_window, title);
            last_stats_tick = now;
        }
    }

    raise_all_keys();
    LiStopConnection();
    if (g_texture) SDL_DestroyTexture(g_texture);
    if (g_renderer) SDL_DestroyRenderer(g_renderer);
    if (g_window) SDL_DestroyWindow(g_window);
    if (g_frame_mutex) SDL_DestroyMutex(g_frame_mutex);
    SDL_Quit();
    return 0;
}
