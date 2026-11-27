package com.nodedeck.android.ui.theme

import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Typography
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.sp

object NodeDeckColors {
    val Accent = Color(0xFF1F6F78)
    val AccentLight = Color(0xFF39A3AE)
    val AccentContainerDark = Color(0xFF123E44)
    val AccentContainerLight = Color(0xFFD2EEF1)

    val Online = Color(0xFF2ECC71)
    val Offline = Color(0xFFE74C3C)
    val Warning = Color(0xFFF39C12)
    val GpuNvidia = Color(0xFF76B900)
    val GpuAmd = Color(0xFFED1C24)

    val DarkBg = Color(0xFF0E1318)
    val DarkSurface = Color(0xFF161D24)
    val DarkSurfaceVariant = Color(0xFF1E2730)
    val DarkOutline = Color(0xFF2D3A46)

    val LightBg = Color(0xFFF4F7F9)
    val LightSurface = Color(0xFFFFFFFF)
    val LightSurfaceVariant = Color(0xFFE9EFF3)
    val LightOutline = Color(0xFFD0DBE2)
}

private val DarkColors = darkColorScheme(
    primary = NodeDeckColors.AccentLight,
    onPrimary = Color(0xFF042024),
    primaryContainer = NodeDeckColors.AccentContainerDark,
    onPrimaryContainer = Color(0xFFC0F0F5),
    secondary = Color(0xFF64B5F6),
    onSecondary = Color(0xFF082032),
    secondaryContainer = NodeDeckColors.AccentContainerDark,
    onSecondaryContainer = Color(0xFFC0F0F5),
    background = NodeDeckColors.DarkBg,
    onBackground = Color(0xFFEBF2F7),
    surface = NodeDeckColors.DarkSurface,
    onSurface = Color(0xFFEBF2F7),
    surfaceVariant = NodeDeckColors.DarkSurfaceVariant,
    onSurfaceVariant = Color(0xFF9FB0BE),
    outline = NodeDeckColors.DarkOutline,
    error = Color(0xFFFF6B6B)
)

private val LightColors = lightColorScheme(
    primary = NodeDeckColors.Accent,
    onPrimary = Color.White,
    primaryContainer = NodeDeckColors.AccentContainerLight,
    onPrimaryContainer = Color(0xFF0A3237),
    secondary = Color(0xFF2563EB),
    onSecondary = Color.White,
    secondaryContainer = NodeDeckColors.AccentContainerLight,
    onSecondaryContainer = Color(0xFF0A3237),
    background = NodeDeckColors.LightBg,
    onBackground = Color(0xFF101920),
    surface = NodeDeckColors.LightSurface,
    onSurface = Color(0xFF101920),
    surfaceVariant = NodeDeckColors.LightSurfaceVariant,
    onSurfaceVariant = Color(0xFF536574),
    outline = NodeDeckColors.LightOutline,
    error = Color(0xFFD32F2F)
)

private val NodeDeckTypography = Typography(
    titleLarge = TextStyle(
        fontWeight = FontWeight.SemiBold,
        fontSize = 20.sp,
        lineHeight = 26.sp
    ),
    titleMedium = TextStyle(
        fontWeight = FontWeight.SemiBold,
        fontSize = 16.sp,
        lineHeight = 22.sp
    ),
    titleSmall = TextStyle(
        fontWeight = FontWeight.Medium,
        fontSize = 14.sp,
        lineHeight = 20.sp
    ),
    bodyMedium = TextStyle(
        fontSize = 14.sp,
        lineHeight = 20.sp
    ),
    bodySmall = TextStyle(
        fontSize = 12.sp,
        lineHeight = 16.sp
    ),
    labelMedium = TextStyle(
        fontWeight = FontWeight.Medium,
        fontSize = 12.sp,
        lineHeight = 16.sp
    ),
    labelSmall = TextStyle(
        fontWeight = FontWeight.Medium,
        fontSize = 11.sp,
        lineHeight = 14.sp,
        fontFamily = FontFamily.Monospace
    )
)

@Composable
fun NodeDeckTheme(
    darkTheme: Boolean = isSystemInDarkTheme(),
    content: @Composable () -> Unit
) {
    MaterialTheme(
        colorScheme = if (darkTheme) DarkColors else LightColors,
        typography = NodeDeckTypography,
        content = content
    )
}
