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

// SHA-256 digest (32 bytes).
int nd_sha256(const uint8_t *input, size_t input_len, uint8_t output[32]);

// AES-128-ECB without padding (input_len must be a multiple of 16).
int nd_aes128_ecb_encrypt(const uint8_t key[16], const uint8_t *input, size_t input_len, uint8_t *output);
int nd_aes128_ecb_decrypt(const uint8_t key[16], const uint8_t *input, size_t input_len, uint8_t *output);

// RSA-SHA256 sign using PEM private key. Returns 0 on success.
int nd_sign_sha256_pem(
    const char *key_pem,
    const uint8_t *data,
    size_t data_len,
    uint8_t *sig_out,
    size_t *sig_len_inout
);

// RSA-SHA256 verify using PEM certificate. Returns 1 if valid, 0 if invalid, <0 on error.
int nd_verify_sha256_pem(
    const char *cert_pem,
    const uint8_t *data,
    size_t data_len,
    const uint8_t *sig,
    size_t sig_len
);

// Extracts the raw signature bytes from an X.509 PEM certificate. Returns 0 on success.
int nd_extract_cert_signature_pem(
    const char *cert_pem,
    uint8_t *sig_out,
    size_t *sig_len_inout
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
