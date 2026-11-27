package com.nodedeck.android.stream

import javax.crypto.Cipher
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.IvParameterSpec
import javax.crypto.spec.SecretKeySpec

object MoonlightCryptoBridge {
    @JvmStatic
    fun encryptAesGcm(key: ByteArray, iv: ByteArray, input: ByteArray, tagLength: Int): ByteArray? =
        runCatching {
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(Cipher.ENCRYPT_MODE, SecretKeySpec(key, "AES"), GCMParameterSpec(tagLength * 8, iv))
            cipher.doFinal(input)
        }.getOrNull()

    @JvmStatic
    fun decryptAesGcm(key: ByteArray, iv: ByteArray, input: ByteArray, tag: ByteArray): ByteArray? =
        runCatching {
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(Cipher.DECRYPT_MODE, SecretKeySpec(key, "AES"), GCMParameterSpec(tag.size * 8, iv))
            val combined = ByteArray(input.size + tag.size)
            System.arraycopy(input, 0, combined, 0, input.size)
            System.arraycopy(tag, 0, combined, input.size, tag.size)
            cipher.doFinal(combined)
        }.getOrNull()

    @JvmStatic
    fun encryptAesCbc(key: ByteArray, iv: ByteArray, input: ByteArray, usePkcs5: Boolean): ByteArray? =
        runCatching {
            val transform = if (usePkcs5) "AES/CBC/PKCS5Padding" else "AES/CBC/NoPadding"
            val cipher = Cipher.getInstance(transform)
            cipher.init(Cipher.ENCRYPT_MODE, SecretKeySpec(key, "AES"), IvParameterSpec(iv))
            cipher.doFinal(input)
        }.getOrNull()

    @JvmStatic
    fun decryptAesCbc(key: ByteArray, iv: ByteArray, input: ByteArray, usePkcs5: Boolean): ByteArray? =
        runCatching {
            val transform = if (usePkcs5) "AES/CBC/PKCS5Padding" else "AES/CBC/NoPadding"
            val cipher = Cipher.getInstance(transform)
            cipher.init(Cipher.DECRYPT_MODE, SecretKeySpec(key, "AES"), IvParameterSpec(iv))
            cipher.doFinal(input)
        }.getOrNull()
}
