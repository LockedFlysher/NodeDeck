package com.nodedeck.android.core

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import java.util.Locale

enum class AppLanguage(val storageValue: String) {
    SYSTEM("system"),
    ZH_HANS("zh-Hans"),
    EN("en");

    companion object {
        fun fromStorage(raw: String?): AppLanguage =
            entries.firstOrNull { it.storageValue == raw } ?: SYSTEM
    }
}

object AppLocalization {
    private val _language = MutableStateFlow(AppLanguage.SYSTEM)
    val language: StateFlow<AppLanguage> = _language.asStateFlow()

    fun setLanguage(lang: AppLanguage) {
        _language.value = lang
    }

    fun isChinese(lang: AppLanguage = _language.value): Boolean = when (lang) {
        AppLanguage.ZH_HANS -> true
        AppLanguage.EN -> false
        AppLanguage.SYSTEM -> Locale.getDefault().language.lowercase().startsWith("zh")
    }

    fun t(zh: String, en: String, lang: AppLanguage = _language.value): String =
        if (isChinese(lang)) zh else en
}
