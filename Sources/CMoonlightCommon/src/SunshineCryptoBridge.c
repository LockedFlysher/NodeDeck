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

int nd_sha256(const uint8_t *input, size_t input_len, uint8_t output[32]) {
    if (!SHA256(input, input_len, output)) {
        return -1;
    }
    return 0;
}

int nd_aes128_ecb_encrypt(const uint8_t key[16], const uint8_t *input, size_t input_len, uint8_t *output) {
    EVP_CIPHER_CTX *ctx = EVP_CIPHER_CTX_new();
    if (!ctx) return -1;
    int out_len1 = 0, out_len2 = 0;
    int ok = EVP_EncryptInit_ex(ctx, EVP_aes_128_ecb(), NULL, key, NULL) &&
             EVP_CIPHER_CTX_set_padding(ctx, 0) &&
             EVP_EncryptUpdate(ctx, output, &out_len1, input, (int)input_len) &&
             EVP_EncryptFinal_ex(ctx, output + out_len1, &out_len2);
    EVP_CIPHER_CTX_free(ctx);
    return ok ? 0 : -2;
}

int nd_aes128_ecb_decrypt(const uint8_t key[16], const uint8_t *input, size_t input_len, uint8_t *output) {
    EVP_CIPHER_CTX *ctx = EVP_CIPHER_CTX_new();
    if (!ctx) return -1;
    int out_len1 = 0, out_len2 = 0;
    int ok = EVP_DecryptInit_ex(ctx, EVP_aes_128_ecb(), NULL, key, NULL) &&
             EVP_CIPHER_CTX_set_padding(ctx, 0) &&
             EVP_DecryptUpdate(ctx, output, &out_len1, input, (int)input_len) &&
             EVP_DecryptFinal_ex(ctx, output + out_len1, &out_len2);
    EVP_CIPHER_CTX_free(ctx);
    return ok ? 0 : -2;
}

int nd_sign_sha256_pem(
    const char *key_pem,
    const uint8_t *data,
    size_t data_len,
    uint8_t *sig_out,
    size_t *sig_len_inout
) {
    BIO *bio = BIO_new_mem_buf(key_pem, -1);
    if (!bio) return -1;
    EVP_PKEY *pkey = PEM_read_bio_PrivateKey(bio, NULL, NULL, NULL);
    BIO_free(bio);
    if (!pkey) return -2;

    EVP_MD_CTX *mdctx = EVP_MD_CTX_new();
    if (!mdctx) {
        EVP_PKEY_free(pkey);
        return -3;
    }

    int ok = EVP_DigestSignInit(mdctx, NULL, EVP_sha256(), NULL, pkey) == 1 &&
             EVP_DigestSignUpdate(mdctx, data, data_len) == 1 &&
             EVP_DigestSignFinal(mdctx, sig_out, sig_len_inout) == 1;

    EVP_MD_CTX_free(mdctx);
    EVP_PKEY_free(pkey);
    return ok ? 0 : -4;
}

int nd_verify_sha256_pem(
    const char *cert_pem,
    const uint8_t *data,
    size_t data_len,
    const uint8_t *sig,
    size_t sig_len
) {
    BIO *bio = BIO_new_mem_buf(cert_pem, -1);
    if (!bio) return -1;
    X509 *cert = PEM_read_bio_X509(bio, NULL, NULL, NULL);
    BIO_free(bio);
    if (!cert) return -2;

    EVP_PKEY *pkey = X509_get_pubkey(cert);
    X509_free(cert);
    if (!pkey) return -3;

    EVP_MD_CTX *mdctx = EVP_MD_CTX_new();
    if (!mdctx) {
        EVP_PKEY_free(pkey);
        return -4;
    }

    int rc = -5;
    if (EVP_DigestVerifyInit(mdctx, NULL, EVP_sha256(), NULL, pkey) == 1 &&
        EVP_DigestVerifyUpdate(mdctx, data, data_len) == 1) {
        rc = EVP_DigestVerifyFinal(mdctx, sig, sig_len);
    }

    EVP_MD_CTX_free(mdctx);
    EVP_PKEY_free(pkey);
    return rc;
}

int nd_extract_cert_signature_pem(
    const char *cert_pem,
    uint8_t *sig_out,
    size_t *sig_len_inout
) {
    BIO *bio = BIO_new_mem_buf(cert_pem, -1);
    if (!bio) return -1;
    X509 *cert = PEM_read_bio_X509(bio, NULL, NULL, NULL);
    BIO_free(bio);
    if (!cert) return -2;

    const ASN1_BIT_STRING *sig = NULL;
    X509_get0_signature(&sig, NULL, cert);
    if (!sig || !sig->data || sig->length <= 0) {
        X509_free(cert);
        return -3;
    }
    if ((size_t)sig->length > *sig_len_inout) {
        X509_free(cert);
        return -4;
    }

    memcpy(sig_out, sig->data, (size_t)sig->length);
    *sig_len_inout = (size_t)sig->length;
    X509_free(cert);
    return 0;
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
