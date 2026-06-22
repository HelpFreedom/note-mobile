plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "dev.qtnotes.qtnotes_mobile"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "dev.qtnotes.qtnotes_mobile"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
            // AGP 9 по умолчанию включает R8 (shrink+обфускация) в release. Без keep-правил
            // это ломает mobile_scanner / ML Kit barcode (класс вырезается → NPE getClass()
            // on null, камера не стартует, в UI «!»). Отключаем shrink/minify — как в
            // дефолтном Flutter-проекте; сканер QR и нативные каналы работают.
            isMinifyEnabled = false
            isShrinkResources = false
        }
    }
}

dependencies {
    // BiometricPrompt (отпечаток/код устройства) для опциональной разблокировки с
    // аппаратным гейтом ключа (setUserAuthenticationRequired).
    implementation("androidx.biometric:biometric:1.1.0")
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}
