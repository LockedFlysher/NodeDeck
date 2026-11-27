#include "Limelight.h"
#include <android/log.h>
#include <jni.h>
#include <pthread.h>
#include <stdlib.h>
#include <string.h>

#define LOG_TAG "NodeDeckJNI"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, LOG_TAG, __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, LOG_TAG, __VA_ARGS__)

static JavaVM* g_jvm = NULL;
static pthread_key_t g_jniDetachKey;
static pthread_once_t g_jniKeyOnce = PTHREAD_ONCE_INIT;

jclass g_cryptoBridgeClass = NULL;
jmethodID g_encryptAesGcmMethod = NULL;
jmethodID g_decryptAesGcmMethod = NULL;
jmethodID g_encryptAesCbcMethod = NULL;
jmethodID g_decryptAesCbcMethod = NULL;

static jclass g_nativeClass = NULL;
static jmethodID g_onVideoSetup = NULL;
static jmethodID g_onVideoCleanup = NULL;
static jmethodID g_onSubmitDecodeUnit = NULL;
static jmethodID g_onAudioInit = NULL;
static jmethodID g_onAudioDecode = NULL;
static jmethodID g_onAudioCleanup = NULL;
static jmethodID g_onStageStarting = NULL;
static jmethodID g_onStageFailed = NULL;
static jmethodID g_onConnectionStarted = NULL;
static jmethodID g_onConnectionTerminated = NULL;

static void detachThreadDestructor(void* value) {
    (void)value;
    if (g_jvm != NULL) {
        (*g_jvm)->DetachCurrentThread(g_jvm);
    }
}

static void createJniKey(void) {
    pthread_key_create(&g_jniDetachKey, detachThreadDestructor);
}

JNIEnv* nd_get_jni_env(void) {
    if (g_jvm == NULL) return NULL;
    JNIEnv* env = NULL;
    jint status = (*g_jvm)->GetEnv(g_jvm, (void**)&env, JNI_VERSION_1_6);
    if (status == JNI_OK) {
        return env;
    }
    if (status == JNI_EDETACHED) {
        pthread_once(&g_jniKeyOnce, createJniKey);
        if ((*g_jvm)->AttachCurrentThread(g_jvm, &env, NULL) == JNI_OK) {
            pthread_setspecific(g_jniDetachKey, (void*)1);
            return env;
        }
    }
    return NULL;
}

JNIEXPORT jint JNICALL JNI_OnLoad(JavaVM* vm, void* reserved) {
    (void)reserved;
    g_jvm = vm;

    JNIEnv* env = NULL;
    if ((*vm)->GetEnv(vm, (void**)&env, JNI_VERSION_1_6) != JNI_OK) {
        return JNI_ERR;
    }

    jclass localCrypto = (*env)->FindClass(env, "com/nodedeck/android/stream/MoonlightCryptoBridge");
    if (!localCrypto) {
        LOGE("Failed to find MoonlightCryptoBridge");
        return JNI_ERR;
    }
    g_cryptoBridgeClass = (*env)->NewGlobalRef(env, localCrypto);
    (*env)->DeleteLocalRef(env, localCrypto);

    g_encryptAesGcmMethod = (*env)->GetStaticMethodID(env, g_cryptoBridgeClass, "encryptAesGcm", "([B[B[BI)[B");
    g_decryptAesGcmMethod = (*env)->GetStaticMethodID(env, g_cryptoBridgeClass, "decryptAesGcm", "([B[B[B[B)[B");
    g_encryptAesCbcMethod = (*env)->GetStaticMethodID(env, g_cryptoBridgeClass, "encryptAesCbc", "([B[B[BZ)[B");
    g_decryptAesCbcMethod = (*env)->GetStaticMethodID(env, g_cryptoBridgeClass, "decryptAesCbc", "([B[B[BZ)[B");

    jclass localNative = (*env)->FindClass(env, "com/nodedeck/android/stream/MoonlightNative");
    if (!localNative) {
        LOGE("Failed to find MoonlightNative");
        return JNI_ERR;
    }
    g_nativeClass = (*env)->NewGlobalRef(env, localNative);
    (*env)->DeleteLocalRef(env, localNative);

    g_onVideoSetup = (*env)->GetStaticMethodID(env, g_nativeClass, "onVideoSetup", "(IIII)I");
    g_onVideoCleanup = (*env)->GetStaticMethodID(env, g_nativeClass, "onVideoCleanup", "()V");
    g_onSubmitDecodeUnit = (*env)->GetStaticMethodID(env, g_nativeClass, "onSubmitDecodeUnit", "([BIIJ)I");
    g_onAudioInit = (*env)->GetStaticMethodID(env, g_nativeClass, "onAudioInit", "(III)I");
    g_onAudioDecode = (*env)->GetStaticMethodID(env, g_nativeClass, "onAudioDecodeAndPlay", "([B)V");
    g_onAudioCleanup = (*env)->GetStaticMethodID(env, g_nativeClass, "onAudioCleanup", "()V");
    g_onStageStarting = (*env)->GetStaticMethodID(env, g_nativeClass, "onStageStarting", "(Ljava/lang/String;)V");
    g_onStageFailed = (*env)->GetStaticMethodID(env, g_nativeClass, "onStageFailed", "(Ljava/lang/String;I)V");
    g_onConnectionStarted = (*env)->GetStaticMethodID(env, g_nativeClass, "onConnectionStarted", "()V");
    g_onConnectionTerminated = (*env)->GetStaticMethodID(env, g_nativeClass, "onConnectionTerminated", "(I)V");

    if (!g_encryptAesGcmMethod || !g_decryptAesGcmMethod || !g_onVideoSetup || !g_onSubmitDecodeUnit) {
        LOGE("Missing JNI method IDs");
        return JNI_ERR;
    }

    LOGI("NodeDeck Moonlight JNI loaded successfully");
    return JNI_VERSION_1_6;
}

// MARK: - Limelight Callbacks

static int bridgeVideoSetup(int videoFormat, int width, int height, int redrawRate, void* context, int drFlags) {
    (void)context;
    (void)drFlags;
    JNIEnv* env = nd_get_jni_env();
    if (!env || !g_nativeClass) return -1;
    jint rc = (*env)->CallStaticIntMethod(env, g_nativeClass, g_onVideoSetup, videoFormat, width, height, redrawRate);
    if ((*env)->ExceptionCheck(env)) {
        (*env)->ExceptionClear(env);
        return -1;
    }
    return rc;
}

static void bridgeVideoCleanup(void) {
    JNIEnv* env = nd_get_jni_env();
    if (!env || !g_nativeClass) return;
    (*env)->CallStaticVoidMethod(env, g_nativeClass, g_onVideoCleanup);
    if ((*env)->ExceptionCheck(env)) (*env)->ExceptionClear(env);
}

static int bridgeSubmitDecodeUnit(PDECODE_UNIT decodeUnit) {
    if (!decodeUnit || decodeUnit->fullLength <= 0) {
        return DR_OK;
    }
    JNIEnv* env = nd_get_jni_env();
    if (!env || !g_nativeClass) return DR_OK;

    jbyteArray jData = (*env)->NewByteArray(env, decodeUnit->fullLength);
    if (!jData) return DR_OK;

    int offset = 0;
    PLENTRY entry = decodeUnit->bufferList;
    while (entry != NULL) {
        if (entry->data != NULL && entry->length > 0 && offset + entry->length <= decodeUnit->fullLength) {
            (*env)->SetByteArrayRegion(env, jData, offset, entry->length, (const jbyte*)entry->data);
            offset += entry->length;
        }
        entry = entry->next;
    }

    jint rc = (*env)->CallStaticIntMethod(
        env, g_nativeClass, g_onSubmitDecodeUnit,
        jData,
        (jint)decodeUnit->frameType,
        (jint)decodeUnit->frameHostProcessingLatency,
        (jlong)decodeUnit->presentationTimeUs
    );
    (*env)->DeleteLocalRef(env, jData);
    if ((*env)->ExceptionCheck(env)) {
        (*env)->ExceptionClear(env);
        return DR_NEED_IDR;
    }
    return rc;
}

static int bridgeAudioInit(int audioConfiguration, const POPUS_MULTISTREAM_CONFIGURATION opusConfig, void* context, int arFlags) {
    (void)audioConfiguration;
    (void)context;
    (void)arFlags;
    if (!opusConfig) return -1;
    JNIEnv* env = nd_get_jni_env();
    if (!env || !g_nativeClass) return -1;
    jint rc = (*env)->CallStaticIntMethod(
        env, g_nativeClass, g_onAudioInit,
        (jint)opusConfig->sampleRate,
        (jint)opusConfig->channelCount,
        (jint)opusConfig->samplesPerFrame
    );
    if ((*env)->ExceptionCheck(env)) {
        (*env)->ExceptionClear(env);
        return -1;
    }
    return rc;
}

static void bridgeAudioCleanup(void) {
    JNIEnv* env = nd_get_jni_env();
    if (!env || !g_nativeClass) return;
    (*env)->CallStaticVoidMethod(env, g_nativeClass, g_onAudioCleanup);
    if ((*env)->ExceptionCheck(env)) (*env)->ExceptionClear(env);
}

static void bridgeAudioDecodeAndPlay(char* sampleData, int sampleLength) {
    if (!sampleData || sampleLength <= 0) return;
    JNIEnv* env = nd_get_jni_env();
    if (!env || !g_nativeClass) return;
    jbyteArray jBuf = (*env)->NewByteArray(env, sampleLength);
    if (!jBuf) return;
    (*env)->SetByteArrayRegion(env, jBuf, 0, sampleLength, (const jbyte*)sampleData);
    (*env)->CallStaticVoidMethod(env, g_nativeClass, g_onAudioDecode, jBuf);
    (*env)->DeleteLocalRef(env, jBuf);
    if ((*env)->ExceptionCheck(env)) (*env)->ExceptionClear(env);
}

static void bridgeStageStarting(int stage) {
    JNIEnv* env = nd_get_jni_env();
    if (!env || !g_nativeClass) return;
    const char* name = LiGetStageName(stage);
    jstring jName = (*env)->NewStringUTF(env, name ? name : "Connecting");
    (*env)->CallStaticVoidMethod(env, g_nativeClass, g_onStageStarting, jName);
    (*env)->DeleteLocalRef(env, jName);
    if ((*env)->ExceptionCheck(env)) (*env)->ExceptionClear(env);
}

static void bridgeStageFailed(int stage, int errorCode) {
    JNIEnv* env = nd_get_jni_env();
    if (!env || !g_nativeClass) return;
    const char* name = LiGetStageName(stage);
    jstring jName = (*env)->NewStringUTF(env, name ? name : "Stage");
    (*env)->CallStaticVoidMethod(env, g_nativeClass, g_onStageFailed, jName, (jint)errorCode);
    (*env)->DeleteLocalRef(env, jName);
    if ((*env)->ExceptionCheck(env)) (*env)->ExceptionClear(env);
}

static void bridgeConnectionStarted(void) {
    JNIEnv* env = nd_get_jni_env();
    if (!env || !g_nativeClass) return;
    (*env)->CallStaticVoidMethod(env, g_nativeClass, g_onConnectionStarted);
    if ((*env)->ExceptionCheck(env)) (*env)->ExceptionClear(env);
}

static void bridgeConnectionTerminated(int errorCode) {
    JNIEnv* env = nd_get_jni_env();
    if (!env || !g_nativeClass) return;
    (*env)->CallStaticVoidMethod(env, g_nativeClass, g_onConnectionTerminated, (jint)errorCode);
    if ((*env)->ExceptionCheck(env)) (*env)->ExceptionClear(env);
}

// MARK: - JNI Exports

JNIEXPORT jint JNICALL Java_com_nodedeck_android_stream_MoonlightNative_nativeStartConnection(
    JNIEnv* env, jclass clazz,
    jstring jAddress,
    jstring jAppVersion,
    jstring jGfeVersion,
    jstring jRtspUrl,
    jint serverCodecModeSupport,
    jint width,
    jint height,
    jint fps,
    jint bitrateKbps,
    jbyteArray jRikey,
    jint rikeyId,
    jboolean enableHevc
) {
    (void)clazz;
    const char* address = (*env)->GetStringUTFChars(env, jAddress, NULL);
    const char* appVer = (*env)->GetStringUTFChars(env, jAppVersion, NULL);
    const char* gfeVer = (*env)->GetStringUTFChars(env, jGfeVersion, NULL);
    const char* rtspUrl = (*env)->GetStringUTFChars(env, jRtspUrl, NULL);

    SERVER_INFORMATION serverInfo;
    LiInitializeServerInformation(&serverInfo);
    serverInfo.address = address;
    serverInfo.serverInfoAppVersion = appVer;
    serverInfo.serverInfoGfeVersion = gfeVer;
    serverInfo.rtspSessionUrl = rtspUrl;
    serverInfo.serverCodecModeSupport = serverCodecModeSupport;

    STREAM_CONFIGURATION streamConfig;
    LiInitializeStreamConfiguration(&streamConfig);
    streamConfig.width = width;
    streamConfig.height = height;
    streamConfig.fps = fps;
    streamConfig.clientRefreshRateX100 = fps * 100;
    streamConfig.bitrate = bitrateKbps;
    streamConfig.packetSize = 1392;
    streamConfig.streamingRemotely = STREAM_CFG_AUTO;
    streamConfig.audioConfiguration = AUDIO_CONFIGURATION_STEREO;
    streamConfig.supportedVideoFormats = enableHevc ? (VIDEO_FORMAT_H265 | VIDEO_FORMAT_H264) : VIDEO_FORMAT_H264;
    streamConfig.colorSpace = COLORSPACE_REC_709;
    streamConfig.colorRange = COLOR_RANGE_LIMITED;

    if (jRikey != NULL) {
        jsize len = (*env)->GetArrayLength(env, jRikey);
        if (len > 16) len = 16;
        (*env)->GetByteArrayRegion(env, jRikey, 0, len, (jbyte*)streamConfig.remoteInputAesKey);
    }
    uint32_t uid = (uint32_t)rikeyId;
    streamConfig.remoteInputAesIv[0] = (char)((uid >> 24) & 0xFF);
    streamConfig.remoteInputAesIv[1] = (char)((uid >> 16) & 0xFF);
    streamConfig.remoteInputAesIv[2] = (char)((uid >> 8) & 0xFF);
    streamConfig.remoteInputAesIv[3] = (char)(uid & 0xFF);

    DECODER_RENDERER_CALLBACKS dr;
    LiInitializeVideoCallbacks(&dr);
    dr.setup = bridgeVideoSetup;
    dr.cleanup = bridgeVideoCleanup;
    dr.submitDecodeUnit = bridgeSubmitDecodeUnit;
    dr.capabilities = CAPABILITY_DIRECT_SUBMIT;

    AUDIO_RENDERER_CALLBACKS ar;
    LiInitializeAudioCallbacks(&ar);
    ar.init = bridgeAudioInit;
    ar.cleanup = bridgeAudioCleanup;
    ar.decodeAndPlaySample = bridgeAudioDecodeAndPlay;
    ar.capabilities = CAPABILITY_DIRECT_SUBMIT;

    CONNECTION_LISTENER_CALLBACKS cl;
    LiInitializeConnectionCallbacks(&cl);
    cl.stageStarting = bridgeStageStarting;
    cl.stageFailed = bridgeStageFailed;
    cl.connectionStarted = bridgeConnectionStarted;
    cl.connectionTerminated = bridgeConnectionTerminated;

    int rc = LiStartConnection(&serverInfo, &streamConfig, &cl, &dr, &ar, NULL, 0, NULL, 0);

    (*env)->ReleaseStringUTFChars(env, jAddress, address);
    (*env)->ReleaseStringUTFChars(env, jAppVersion, appVer);
    (*env)->ReleaseStringUTFChars(env, jGfeVersion, gfeVer);
    (*env)->ReleaseStringUTFChars(env, jRtspUrl, rtspUrl);
    return rc;
}

JNIEXPORT void JNICALL Java_com_nodedeck_android_stream_MoonlightNative_nativeStopConnection(JNIEnv* env, jclass clazz) {
    (void)env;
    (void)clazz;
    LiStopConnection();
}

JNIEXPORT void JNICALL Java_com_nodedeck_android_stream_MoonlightNative_nativeInterruptConnection(JNIEnv* env, jclass clazz) {
    (void)env;
    (void)clazz;
    LiInterruptConnection();
}

JNIEXPORT jlong JNICALL Java_com_nodedeck_android_stream_MoonlightNative_nativeGetEstimatedRttPacked(JNIEnv* env, jclass clazz) {
    (void)env;
    (void)clazz;
    uint32_t rtt = 0, rttVar = 0;
    if (!LiGetEstimatedRttInfo(&rtt, &rttVar)) {
        return 0;
    }
    return ((jlong)rtt << 32) | ((jlong)rttVar & 0xFFFFFFFFL);
}

JNIEXPORT jint JNICALL Java_com_nodedeck_android_stream_MoonlightNative_nativeSendMouseMove(JNIEnv* env, jclass clazz, jshort dx, jshort dy) {
    (void)env; (void)clazz;
    return LiSendMouseMoveEvent(dx, dy);
}

JNIEXPORT jint JNICALL Java_com_nodedeck_android_stream_MoonlightNative_nativeSendMousePosition(JNIEnv* env, jclass clazz, jshort x, jshort y, jshort w, jshort h) {
    (void)env; (void)clazz;
    return LiSendMousePositionEvent(x, y, w, h);
}

JNIEXPORT jint JNICALL Java_com_nodedeck_android_stream_MoonlightNative_nativeSendMouseButton(JNIEnv* env, jclass clazz, jbyte action, jint button) {
    (void)env; (void)clazz;
    return LiSendMouseButtonEvent((char)action, button);
}

JNIEXPORT jint JNICALL Java_com_nodedeck_android_stream_MoonlightNative_nativeSendHighResScroll(JNIEnv* env, jclass clazz, jshort amount) {
    (void)env; (void)clazz;
    return LiSendHighResScrollEvent(amount);
}

JNIEXPORT jint JNICALL Java_com_nodedeck_android_stream_MoonlightNative_nativeSendHighResHScroll(JNIEnv* env, jclass clazz, jshort amount) {
    (void)env; (void)clazz;
    return LiSendHighResHScrollEvent(amount);
}

JNIEXPORT jint JNICALL Java_com_nodedeck_android_stream_MoonlightNative_nativeSendKeyboardEvent2(JNIEnv* env, jclass clazz, jshort keyCode, jbyte keyAction, jbyte modifiers, jbyte flags) {
    (void)env; (void)clazz;
    return LiSendKeyboardEvent2(keyCode, (char)keyAction, (char)modifiers, (char)flags);
}

JNIEXPORT jint JNICALL Java_com_nodedeck_android_stream_MoonlightNative_nativeSendUtf8Text(JNIEnv* env, jclass clazz, jstring jText) {
    (void)clazz;
    if (!jText) return 0;
    const char* utf8 = (*env)->GetStringUTFChars(env, jText, NULL);
    if (!utf8) return -1;
    int rc = LiSendUtf8TextEvent(utf8, (unsigned int)strlen(utf8));
    (*env)->ReleaseStringUTFChars(env, jText, utf8);
    return rc;
}
