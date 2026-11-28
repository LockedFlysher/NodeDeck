plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("org.jetbrains.kotlin.plugin.compose")
    id("org.jetbrains.kotlin.plugin.serialization")
}

android {
    namespace = "com.nodedeck.android"
    compileSdk = 36
    ndkVersion = "27.3.13750724"

    defaultConfig {
        applicationId = "com.nodedeck.android"
        minSdk = 28
        targetSdk = 36
        versionCode = 2
        versionName = "2.1.0"

        ndk {
            abiFilters += listOf("arm64-v8a")
        }

        externalNativeBuild {
            cmake {
                cFlags += listOf(
                    "-O2",
                    "-DHAS_FCNTL=1",
                    "-DHAS_IOCTL=1",
                    "-DHAS_POLL=1",
                    "-DHAS_GETNAMEINFO=1",
                    "-DHAS_GETADDRINFO=1",
                    "-DHAS_INET_PTON=1",
                    "-DHAS_INET_NTOP=1",
                    "-DHAS_MSGHDR_FLAGS=1",
                    "-DHAS_SOCKLEN_T=1",
                    "-DNDEBUG=1"
                )
            }
        }
    }

    buildTypes {
        release {
            isMinifyEnabled = false
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = "17"
    }

    buildFeatures {
        compose = true
    }

    externalNativeBuild {
        cmake {
            path = file("src/main/cpp/CMakeLists.txt")
            version = "3.31.6"
        }
    }

    packaging {
        resources {
            excludes += listOf(
                "META-INF/LICENSE*",
                "META-INF/NOTICE*",
                "META-INF/DEPENDENCIES",
                "META-INF/versions/*/OSGI-INF/MANIFEST.MF",
                "META-INF/versions/9/OSGI-INF/MANIFEST.MF",
                "META-INF/versions/15/OSGI-INF/MANIFEST.MF"
            )
        }
    }
}

dependencies {
    val composeBom = platform("androidx.compose:compose-bom:2025.04.01")
    implementation(composeBom)

    implementation("androidx.core:core-ktx:1.15.0")
    implementation("androidx.lifecycle:lifecycle-runtime-ktx:2.8.7")
    implementation("androidx.lifecycle:lifecycle-viewmodel-compose:2.8.7")
    implementation("androidx.activity:activity-compose:1.10.1")

    implementation("androidx.compose.ui:ui")
    implementation("androidx.compose.ui:ui-graphics")
    implementation("androidx.compose.material3:material3")
    implementation("androidx.compose.material:material-icons-extended")

    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.9.0")
    implementation("org.jetbrains.kotlinx:kotlinx-serialization-json:1.8.0")

    // Modern JSch fork with Ed25519, RSA-SHA2, OpenSSH key, ProxyJump, PTY, SFTP & port forwarding
    implementation("com.github.mwiede:jsch:0.2.21")

    // BouncyCastle for local RSA-2048 X.509 self-signed cert generation & PEM encoding (Moonlight/Sunshine mutual TLS)
    implementation("org.bouncycastle:bcprov-jdk18on:1.80")
    implementation("org.bouncycastle:bcpkix-jdk18on:1.80")

    testImplementation("junit:junit:4.13.2")
}
