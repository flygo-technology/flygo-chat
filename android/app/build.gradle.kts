import java.util.Properties

plugins {
    id("com.android.application")
    // Firebase Cloud Messaging (thông báo đẩy), đọc android/app/google-services.json.
    id("com.google.gms.google-services")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "vn.flygo.chat"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
        // flutter_local_notifications cần desugaring cho API java.time trên Android cũ.
        isCoreLibraryDesugaringEnabled = true
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "vn.flygo.chat"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    // Khoá upload Google Play: android/key.properties (không đưa vào git), trỏ tới tệp .jks.
    val playKey = Properties().apply {
        val f = rootProject.file("key.properties")
        if (f.exists()) f.inputStream().use { load(it) }
    }
    signingConfigs {
        if (playKey.getProperty("storeFile") != null) {
            create("play") {
                storeFile = file(playKey.getProperty("storeFile"))
                storePassword = playKey.getProperty("storePassword")
                keyAlias = playKey.getProperty("keyAlias")
                keyPassword = playKey.getProperty("keyPassword")
            }
        }
    }

    // sideload: bản tự cập nhật từ máy chủ đang dùng, ký khoá debug như trước (giữ chữ ký cho máy đã cài).
    // play: bản Google Play (AAB), ký khoá upload, không tự cập nhật, không có REQUEST_INSTALL_PACKAGES.
    flavorDimensions += "store"
    productFlavors {
        create("sideload") {
            dimension = "store"
            signingConfig = signingConfigs.getByName("debug")
        }
        create("play") {
            dimension = "store"
            signingConfig = signingConfigs.findByName("play")
        }
    }

    buildTypes {
        release {
            // Chữ ký lấy theo flavor ở trên.
            signingConfig = null
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

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.5")
}
