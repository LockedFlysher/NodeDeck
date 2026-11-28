#ifndef CMOONLIGHT_BRIDGE_H
#define CMOONLIGHT_BRIDGE_H

#include <stddef.h>
#include <stdint.h>
#include "Limelight.h"

#ifdef __cplusplus
extern "C" {
#endif

// Generates a 2048-bit RSA key + self-signed X.509 cert (PEM) + PKCS#12 bundle for URLSession client TLS.
// Returns 0 on success, non-zero on failure.
int nd_generate_client_identity(
    const char *cert_path,
    const char *key_path,
    const char *p12_path,
    const char *p12_password
);

// Thin Opus multistream decoder wrapper for Swift audio playback.
typedef void *NDOpusDecoder;

NDOpusDecoder nd_opus_create(
    int sample_rate,
    int channels,
    int streams,
    int coupled_streams,
    const uint8_t *mapping
);

int nd_opus_decode_float(
    NDOpusDecoder decoder,
    const uint8_t *data,
    int len,
    float *pcm_out,
    int frame_size
);

void nd_opus_destroy(NDOpusDecoder decoder);

#ifdef __cplusplus
}
#endif

#endif // CMOONLIGHT_BRIDGE_H
