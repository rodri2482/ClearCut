// Native ad-block engine from NoFlix (originally Edsuns/AdblockAndroid, Apache-2.0).
plugins {
    id("com.android.library")
    id("org.jetbrains.kotlin.android")
}

android {
    namespace = "io.github.edsuns.adblockclient"
    compileSdk = 36
    // r28+ links 64-bit libraries with 16 KB page alignment (Android 15+ devices).
    ndkVersion = "28.2.13676358"

    defaultConfig {
        minSdk = 24
        consumerProguardFiles("consumer-rules.pro")
    }

    externalNativeBuild {
        cmake {
            path = file("CMakeLists.txt")
            version = "3.22.1"
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions { jvmTarget = "17" }
}

dependencies {
    implementation("com.jakewharton.timber:timber:5.0.1")
}
