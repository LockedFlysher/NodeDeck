#include "Limelight-internal.h"
#include <fcntl.h>
#include <jni.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

extern JNIEnv* nd_get_jni_env(void);
extern jclass g_cryptoBridgeClass;
extern jmethodID g_encryptAesGcmMethod;
extern jmethodID g_decryptAesGcmMethod;
extern jmethodID g_encryptAesCbcMethod;
extern jmethodID g_decryptAesCbcMethod;

typedef struct _ANDROID_CRYPTO_STATE {
    unsigned char lastCbcIv[16];
    bool hasCbcIv;
} ANDROID_CRYPTO_STATE;

static int addPkcs7PaddingInPlace(unsigned char* plaintext, int plaintextLen) {
    int paddedLength = ROUND_TO_PKCS7_PADDED_LEN(plaintextLen);
    unsigned char paddingByte = (unsigned char)(16 - (plaintextLen % 16));
    memset(&plaintext[plaintextLen], paddingByte, paddedLength - plaintextLen);
    return paddedLength;
}

static bool isReplay(PPLT_CRYPTO_CONTEXT ctx, int algorithm, int flags, unsigned char replayWindowIndex, unsigned int sequenceNumber) {
    if (algorithm == ALGORITHM_AES_CBC || (flags & CIPHER_FLAG_NO_REPLAY_CHECK)) {
        return false;
    }
    if (replayWindowIndex >= ctx->replayWindowCount) {
        return true;
    }
    PREPLAY_WINDOW window = &ctx->replayWindows[replayWindowIndex];
    if (!window->decryptedAuthedMessage) {
        return false;
    }
    uint32_t diff = sequenceNumber - window->lastDecryptedAuthedSeqNum;
    if (diff > 0 && diff < 0x80000000) {
        return false;
    }
    if (diff == 0) {
        return true;
    }
    uint32_t offset = window->lastDecryptedAuthedSeqNum - sequenceNumber;
    if (offset >= REPLAY_WINDOW_SIZE) {
        return true;
    }
    int wordIndex = (int)(offset / 64);
    int bitIndex = (int)(offset % 64);
    return (window->replayWindow[wordIndex] & ((uint64_t)1 << bitIndex)) != 0;
}

static void shiftReplayWindow(PREPLAY_WINDOW window, uint32_t shift) {
    if (shift >= REPLAY_WINDOW_SIZE) {
        memset(window->replayWindow, 0, sizeof(window->replayWindow));
        window->replayWindow[0] = 1;
        return;
    }
    int wordShift = (int)(shift / 64);
    int bitShift = (int)(shift % 64);
    for (int i = REPLAY_WINDOW_WORDS - 1; i >= 0; i--) {
        uint64_t val = 0;
        if (i >= wordShift) {
            val = window->replayWindow[i - wordShift] << bitShift;
            if (bitShift > 0 && i > wordShift) {
                val |= window->replayWindow[i - wordShift - 1] >> (64 - bitShift);
            }
        }
        window->replayWindow[i] = val;
    }
    window->replayWindow[0] |= 1;
}

static void recordSuccessfulAuthenticatedDecryption(PPLT_CRYPTO_CONTEXT ctx, int flags, unsigned char replayWindowIndex, unsigned int sequenceNumber) {
    if (flags & CIPHER_FLAG_NO_REPLAY_CHECK) {
        return;
    }
    if (replayWindowIndex >= ctx->replayWindowCount) {
        return;
    }
    PREPLAY_WINDOW window = &ctx->replayWindows[replayWindowIndex];
    if (!window->decryptedAuthedMessage) {
        window->decryptedAuthedMessage = true;
        window->lastDecryptedAuthedSeqNum = sequenceNumber;
        memset(window->replayWindow, 0, sizeof(window->replayWindow));
        window->replayWindow[0] = 1;
        return;
    }
    uint32_t diff = sequenceNumber - window->lastDecryptedAuthedSeqNum;
    if (diff > 0 && diff < 0x80000000) {
        shiftReplayWindow(window, diff);
        window->lastDecryptedAuthedSeqNum = sequenceNumber;
    } else if (diff >= 0x80000000) {
        uint32_t offset = window->lastDecryptedAuthedSeqNum - sequenceNumber;
        if (offset < REPLAY_WINDOW_SIZE) {
            int wordIndex = (int)(offset / 64);
            int bitIndex = (int)(offset % 64);
            window->replayWindow[wordIndex] |= ((uint64_t)1 << bitIndex);
        }
    }
}

static jbyteArray makeByteArray(JNIEnv* env, const unsigned char* data, int len) {
    jbyteArray arr = (*env)->NewByteArray(env, len);
    if (arr != NULL && len > 0 && data != NULL) {
        (*env)->SetByteArrayRegion(env, arr, 0, len, (const jbyte*)data);
    }
    return arr;
}

bool PltEncryptMessage(PPLT_CRYPTO_CONTEXT ctx, int algorithm, int flags,
                       unsigned char* key, int keyLength,
                       unsigned char* iv, int ivLength,
                       unsigned char* tag, int tagLength,
                       unsigned char* inputData, int inputDataLength,
                       unsigned char* outputData, int* outputDataLength) {
    JNIEnv* env = nd_get_jni_env();
    if (!env || !g_cryptoBridgeClass) {
        return false;
    }

    ANDROID_CRYPTO_STATE* state = (ANDROID_CRYPTO_STATE*)ctx->ctx;
    bool ok = false;

    if (algorithm == ALGORITHM_AES_GCM) {
        jbyteArray jKey = makeByteArray(env, key, keyLength);
        jbyteArray jIv = makeByteArray(env, iv, ivLength);
        jbyteArray jIn = makeByteArray(env, inputData, inputDataLength);
        jbyteArray jOut = (jbyteArray)(*env)->CallStaticObjectMethod(
            env, g_cryptoBridgeClass, g_encryptAesGcmMethod, jKey, jIv, jIn, (jint)tagLength
        );
        if ((*env)->ExceptionCheck(env)) {
            (*env)->ExceptionClear(env);
            jOut = NULL;
        }
        if (jOut != NULL) {
            jsize totalLen = (*env)->GetArrayLength(env, jOut);
            if (totalLen >= tagLength) {
                int cipherLen = totalLen - tagLength;
                if (cipherLen > 0) {
                    (*env)->GetByteArrayRegion(env, jOut, 0, cipherLen, (jbyte*)outputData);
                }
                if (tag != NULL && tagLength > 0) {
                    (*env)->GetByteArrayRegion(env, jOut, cipherLen, tagLength, (jbyte*)tag);
                }
                *outputDataLength = cipherLen;
                ok = true;
            }
            (*env)->DeleteLocalRef(env, jOut);
        }
        (*env)->DeleteLocalRef(env, jKey);
        (*env)->DeleteLocalRef(env, jIv);
        (*env)->DeleteLocalRef(env, jIn);
        return ok;
    } else if (algorithm == ALGORITHM_AES_CBC) {
        unsigned char activeIv[16];
        if (!state->hasCbcIv || (flags & CIPHER_FLAG_RESET_IV)) {
            memset(activeIv, 0, sizeof(activeIv));
            if (iv && ivLength > 0) {
                memcpy(activeIv, iv, ivLength > 16 ? 16 : ivLength);
            }
        } else {
            memcpy(activeIv, state->lastCbcIv, 16);
        }

        int inLen = inputDataLength;
        bool usePkcs5 = false;
        if (flags & CIPHER_FLAG_PAD_TO_BLOCK_SIZE) {
            inLen = addPkcs7PaddingInPlace(inputData, inputDataLength);
            usePkcs5 = false;
        } else if (flags & CIPHER_FLAG_FINISH) {
            usePkcs5 = true;
        }

        jbyteArray jKey = makeByteArray(env, key, keyLength);
        jbyteArray jIv = makeByteArray(env, activeIv, 16);
        jbyteArray jIn = makeByteArray(env, inputData, inLen);
        jbyteArray jOut = (jbyteArray)(*env)->CallStaticObjectMethod(
            env, g_cryptoBridgeClass, g_encryptAesCbcMethod, jKey, jIv, jIn, (jboolean)(usePkcs5 ? JNI_TRUE : JNI_FALSE)
        );
        if ((*env)->ExceptionCheck(env)) {
            (*env)->ExceptionClear(env);
            jOut = NULL;
        }
        if (jOut != NULL) {
            jsize outLen = (*env)->GetArrayLength(env, jOut);
            if (outLen > 0) {
                (*env)->GetByteArrayRegion(env, jOut, 0, outLen, (jbyte*)outputData);
                if (outLen >= 16) {
                    memcpy(state->lastCbcIv, outputData + outLen - 16, 16);
                    state->hasCbcIv = true;
                }
            }
            *outputDataLength = outLen;
            ok = true;
            (*env)->DeleteLocalRef(env, jOut);
        }
        (*env)->DeleteLocalRef(env, jKey);
        (*env)->DeleteLocalRef(env, jIv);
        (*env)->DeleteLocalRef(env, jIn);
        return ok;
    }

    return false;
}

bool PltDecryptMessage(PPLT_CRYPTO_CONTEXT ctx, int algorithm, int flags,
                       unsigned char replayWindowIndex,
                       unsigned int sequenceNumber,
                       unsigned char* key, int keyLength,
                       unsigned char* iv, int ivLength,
                       unsigned char* tag, int tagLength,
                       unsigned char* inputData, int inputDataLength,
                       unsigned char* outputData, int* outputDataLength) {
    if (isReplay(ctx, algorithm, flags, replayWindowIndex, sequenceNumber)) {
        return false;
    }

    JNIEnv* env = nd_get_jni_env();
    if (!env || !g_cryptoBridgeClass) {
        return false;
    }

    ANDROID_CRYPTO_STATE* state = (ANDROID_CRYPTO_STATE*)ctx->ctx;
    bool ok = false;

    if (algorithm == ALGORITHM_AES_GCM) {
        jbyteArray jKey = makeByteArray(env, key, keyLength);
        jbyteArray jIv = makeByteArray(env, iv, ivLength);
        jbyteArray jIn = makeByteArray(env, inputData, inputDataLength);
        jbyteArray jTag = makeByteArray(env, tag, tagLength);
        jbyteArray jOut = (jbyteArray)(*env)->CallStaticObjectMethod(
            env, g_cryptoBridgeClass, g_decryptAesGcmMethod, jKey, jIv, jIn, jTag
        );
        if ((*env)->ExceptionCheck(env)) {
            (*env)->ExceptionClear(env);
            jOut = NULL;
        }
        if (jOut != NULL) {
            jsize outLen = (*env)->GetArrayLength(env, jOut);
            if (outLen > 0) {
                (*env)->GetByteArrayRegion(env, jOut, 0, outLen, (jbyte*)outputData);
            }
            *outputDataLength = outLen;
            recordSuccessfulAuthenticatedDecryption(ctx, flags, replayWindowIndex, sequenceNumber);
            ok = true;
            (*env)->DeleteLocalRef(env, jOut);
        }
        (*env)->DeleteLocalRef(env, jKey);
        (*env)->DeleteLocalRef(env, jIv);
        (*env)->DeleteLocalRef(env, jIn);
        (*env)->DeleteLocalRef(env, jTag);
        return ok;
    } else if (algorithm == ALGORITHM_AES_CBC) {
        unsigned char activeIv[16];
        if (!state->hasCbcIv || (flags & CIPHER_FLAG_RESET_IV)) {
            memset(activeIv, 0, sizeof(activeIv));
            if (iv && ivLength > 0) {
                memcpy(activeIv, iv, ivLength > 16 ? 16 : ivLength);
            }
        } else {
            memcpy(activeIv, state->lastCbcIv, 16);
        }

        bool usePkcs5 = (flags & CIPHER_FLAG_FINISH) != 0;
        jbyteArray jKey = makeByteArray(env, key, keyLength);
        jbyteArray jIv = makeByteArray(env, activeIv, 16);
        jbyteArray jIn = makeByteArray(env, inputData, inputDataLength);
        jbyteArray jOut = (jbyteArray)(*env)->CallStaticObjectMethod(
            env, g_cryptoBridgeClass, g_decryptAesCbcMethod, jKey, jIv, jIn, (jboolean)(usePkcs5 ? JNI_TRUE : JNI_FALSE)
        );
        if ((*env)->ExceptionCheck(env)) {
            (*env)->ExceptionClear(env);
            jOut = NULL;
        }
        if (jOut != NULL) {
            jsize outLen = (*env)->GetArrayLength(env, jOut);
            if (outLen > 0) {
                (*env)->GetByteArrayRegion(env, jOut, 0, outLen, (jbyte*)outputData);
            }
            if (inputDataLength >= 16) {
                memcpy(state->lastCbcIv, inputData + inputDataLength - 16, 16);
                state->hasCbcIv = true;
            }
            *outputDataLength = outLen;
            ok = true;
            (*env)->DeleteLocalRef(env, jOut);
        }
        (*env)->DeleteLocalRef(env, jKey);
        (*env)->DeleteLocalRef(env, jIv);
        (*env)->DeleteLocalRef(env, jIn);
        return ok;
    }

    return false;
}

PPLT_CRYPTO_CONTEXT PltCreateCryptoContext(unsigned char replayWindowCount) {
    PPLT_CRYPTO_CONTEXT ctx = calloc(1, sizeof(*ctx) + (replayWindowCount * sizeof(REPLAY_WINDOW)));
    if (!ctx) {
        return NULL;
    }
    ctx->replayWindowCount = replayWindowCount;
    ANDROID_CRYPTO_STATE* state = calloc(1, sizeof(ANDROID_CRYPTO_STATE));
    if (!state) {
        free(ctx);
        return NULL;
    }
    ctx->ctx = (EVP_CIPHER_CTX*)state;
    return ctx;
}

void PltDestroyCryptoContext(PPLT_CRYPTO_CONTEXT ctx) {
    if (!ctx) {
        return;
    }
    if (ctx->ctx) {
        free(ctx->ctx);
    }
    free(ctx);
}

void PltGenerateRandomData(unsigned char* data, int length) {
    if (!data || length <= 0) {
        return;
    }
    int fd = open("/dev/urandom", O_RDONLY);
    if (fd >= 0) {
        int off = 0;
        while (off < length) {
            ssize_t r = read(fd, data + off, (size_t)(length - off));
            if (r <= 0) break;
            off += (int)r;
        }
        close(fd);
        if (off == length) return;
    }
    for (int i = 0; i < length; i++) {
        data[i] = (unsigned char)(rand() & 0xFF);
    }
}
