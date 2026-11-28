#include "CMoonlightBridge.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <openssl/bio.h>
#include <openssl/err.h>
#include <openssl/evp.h>
#include <openssl/pem.h>
#include <openssl/pkcs12.h>
#include <openssl/rsa.h>
#include <openssl/sha.h>
#include <openssl/x509.h>
#include <opus/opus_multistream.h>

int nd_generate_client_identity(
    const char *cert_path,
    const char *key_path,
    const char *p12_path,
    const char *p12_password
) {
    EVP_PKEY *pkey = EVP_RSA_gen(2048);
    if (!pkey) {
        return -1;
    }

    X509 *x509 = X509_new();
    if (!x509) {
        EVP_PKEY_free(pkey);
        return -2;
    }

    X509_set_version(x509, 2);
    ASN1_INTEGER_set(X509_get_serialNumber(x509), 1);
    X509_gmtime_adj(X509_get_notBefore(x509), -86400L);
    X509_gmtime_adj(X509_get_notAfter(x509), 60L * 60L * 24L * 365L * 20L);
    X509_set_pubkey(x509, pkey);

    X509_NAME *name = X509_get_subject_name(x509);
    X509_NAME_add_entry_by_txt(name, "CN", MBSTRING_ASC, (const unsigned char *)"NVIDIA GameStream Client", -1, -1, 0);
    X509_set_issuer_name(x509, name);

    if (X509_sign(x509, pkey, EVP_sha256()) == 0) {
        X509_free(x509);
        EVP_PKEY_free(pkey);
        return -3;
    }

    FILE *cert_fp = fopen(cert_path, "wb");
    if (!cert_fp) {
        X509_free(x509);
        EVP_PKEY_free(pkey);
        return -4;
    }
    int ok1 = PEM_write_X509(cert_fp, x509);
    fclose(cert_fp);

    FILE *key_fp = fopen(key_path, "wb");
    if (!key_fp) {
        X509_free(x509);
        EVP_PKEY_free(pkey);
        return -5;
    }
    int ok2 = PEM_write_PrivateKey(key_fp, pkey, NULL, NULL, 0, NULL, NULL);
    fclose(key_fp);

    int ok3 = 1;
    if (p12_path && p12_path[0] != '\0') {
        PKCS12 *p12 = PKCS12_create(
            p12_password ? p12_password : "",
            "NodeDeck Moonlight Client",
            pkey,
            x509,
            NULL,
            NID_pbe_WithSHA1And3_Key_TripleDES_CBC,
            NID_pbe_WithSHA1And40BitRC2_CBC,
            2048,
            1,
            0
        );
        if (!p12) {
            ok3 = 0;
        } else {
            FILE *p12_fp = fopen(p12_path, "wb");
            if (!p12_fp) {
                ok3 = 0;
            } else {
                ok3 = i2d_PKCS12_fp(p12_fp, p12);
                fclose(p12_fp);
            }
            PKCS12_free(p12);
        }
    }

    X509_free(x509);
    EVP_PKEY_free(pkey);
    return (ok1 && ok2 && ok3) ? 0 : -6;
}

NDOpusDecoder nd_opus_create(
    int sample_rate,
    int channels,
    int streams,
    int coupled_streams,
    const uint8_t *mapping
) {
    int err = 0;
    OpusMSDecoder *dec = opus_multistream_decoder_create(
        sample_rate,
        channels,
        streams,
        coupled_streams,
        mapping,
        &err
    );
    if (err != OPUS_OK) {
        return NULL;
    }
    return (NDOpusDecoder)dec;
}

int nd_opus_decode_float(
    NDOpusDecoder decoder,
    const uint8_t *data,
    int len,
    float *pcm_out,
    int frame_size
) {
    if (!decoder) return -1;
    return opus_multistream_decode_float((OpusMSDecoder *)decoder, data, len, pcm_out, frame_size, 0);
}

void nd_opus_destroy(NDOpusDecoder decoder) {
    if (decoder) {
        opus_multistream_decoder_destroy((OpusMSDecoder *)decoder);
    }
}
