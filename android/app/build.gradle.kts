import java.io.FileInputStream
import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// 发布签名：android/key.properties 存在时用正式 keystore（本机由 signing/ 目录的
// 凭据手工生成，CI 由 workflow 从 Secrets 现场生成）。不存在时 release 构建默认
// fail-fast（拒绝产出 debug 签名的 release 包——同名产物误分发即断升级链）；
// 仅 -PallowUnsignedRelease=true 逃生（本地联调/CI 无 Secrets 冒烟）。
val keystorePropertiesFile = rootProject.file("key.properties")
val keystoreProperties = Properties().apply {
    if (keystorePropertiesFile.exists()) {
        load(FileInputStream(keystorePropertiesFile))
    }
}

android {
    namespace = "com.lmstory.app"
    compileSdk = 36
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.lmstory.app"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        create("release") {
            if (keystorePropertiesFile.exists()) {
                keyAlias = keystoreProperties["keyAlias"] as String
                keyPassword = keystoreProperties["keyPassword"] as String
                storeFile = file(keystoreProperties["storeFile"] as String)
                storePassword = keystoreProperties["storePassword"] as String
            }
        }
    }

    buildTypes {
        // debug 应用id 加 .debug 后缀：与正式包（com.lmstory.app）作为两个
        // 独立应用共存，日常 flutter run 不再与手机上的正式包互相覆盖。
        // 代价：打开方式/分享选单里 png/json 会同时出现两个应用。
        debug {
            applicationIdSuffix = ".debug"
        }
        release {
            isMinifyEnabled = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )
            // 签名 fail-fast：缺正式 keystore 的 release 构建直接报错，
            // 不再静默回落 debug 签名（防误分发断升级链）。
            val allowUnsignedRelease = providers
                .gradleProperty("allowUnsignedRelease")
                .map { it.toBoolean() }
                .getOrElse(false)
            if (!keystorePropertiesFile.exists() && !allowUnsignedRelease) {
                throw GradleException(
                    "缺少正式签名配置（android/key.properties 不存在），拒绝产出 debug 签名的 release 包。" +
                        "本地联调可加 -PallowUnsignedRelease=true 逃生；正式发版请先配置 signing/ 凭据（见 signing/README.md）。"
                )
            }
            signingConfig = if (keystorePropertiesFile.exists()) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
            }
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}
