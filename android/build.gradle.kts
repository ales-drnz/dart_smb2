import java.io.FileOutputStream
import java.net.URL
import java.security.MessageDigest

group = "com.alesdrnz.dart_smb2"
version = "0.1.1"

buildscript {
    repositories {
        google()
        mavenCentral()
    }
    dependencies {
        classpath("com.android.tools.build:gradle:8.7.2")
    }
}

allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

plugins {
    id("com.android.library")
}

android {
    namespace = "com.alesdrnz.dart_smb2"

    compileSdk = 36
    ndkVersion = "28.2.13676358"

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    sourceSets {
        getByName("main") {
            jniLibs.srcDirs("src/main/jniLibs")
        }
    }

    defaultConfig {
        minSdk = 24

        // ── dart_smb2 NDK Integration ──────────────────────────────────────
        // Pre-built libsmb2.so files are downloaded from GitHub Releases
        // and placed into src/main/jniLibs before the build.
        ndk {
            abiFilters += listOf("arm64-v8a", "armeabi-v7a", "x86_64")
        }
    }
}

val SMB2_RELEASE_VERSION = "libsmb2-r6"
val SMB2_BASE_URL = "https://github.com/ales-drnz/dart_smb2/releases/download/${SMB2_RELEASE_VERSION}"

val downloadSmb2Task = tasks.register("downloadSmb2Libraries") {
    // Replace these SHA-256 hashes after building and uploading to GitHub Releases.
    val abis = mapOf(
        "arm64-v8a" to mapOf(
            "file"   to "libsmb2_android-arm64-v8a.so",
            "sha256" to "dab660afab1958f2fe5f8c2a3d857ee54bf660bdd13e5823b762006e85318e8e"
        ),
        "armeabi-v7a" to mapOf(
            "file"   to "libsmb2_android-armeabi-v7a.so",
            "sha256" to "16765a1f89b9c93cb624433964031b607c236bc028868ea313852f9172aaee82"
        ),
        "x86_64" to mapOf(
            "file"   to "libsmb2_android-x86_64.so",
            "sha256" to "168fc1b11d8ed14e7fdcfb428b0140e453bb99d20abd754bfa237c74c6ea3964"
        )
    )

    doLast {
        val jniLibsDir = file("src/main/jniLibs")
        val abiFilters = android.defaultConfig.ndk.abiFilters.ifEmpty { abis.keys }
        abis.filter { it.key in abiFilters }.forEach { (abi, info) ->
            val filename     = info["file"]!!
            val expectedHash = info["sha256"]!!
            val abiDir = file("${jniLibsDir}/${abi}")
            if (!abiDir.exists()) abiDir.mkdirs()

            val targetFile = file("${abiDir}/libsmb2.so")
            var isValid = false

            if (targetFile.exists()) {
                val bytes = targetFile.readBytes()
                val digest = MessageDigest.getInstance("SHA-256").digest(bytes)
                val calculatedHash = digest.joinToString("") { "%02x".format(it) }
                if (calculatedHash == expectedHash) {
                    isValid = true
                } else {
                    println("[dart_smb2] SHA-256 mismatch for ${abi}. Expected: ${expectedHash}, Got: ${calculatedHash}. Redownloading...")
                    targetFile.delete()
                }
            }

            if (!isValid) {
                val url = "${SMB2_BASE_URL}/${filename}"
                println("[dart_smb2] Downloading libsmb2.so for ${abi} from ${url}")
                try {
                    URL(url).openStream().use { input ->
                        FileOutputStream(targetFile).use { output ->
                            input.copyTo(output)
                        }
                    }
                    val bytes = targetFile.readBytes()
                    val digest = MessageDigest.getInstance("SHA-256").digest(bytes)
                    val calculatedHash = digest.joinToString("") { "%02x".format(it) }

                    if (calculatedHash != expectedHash) {
                        targetFile.delete()
                        throw GradleException("[dart_smb2] SHA-256 verification failed for downloaded ${filename}!")
                    }
                } catch (e: Exception) {
                    if (targetFile.exists()) targetFile.delete()
                    throw GradleException("[dart_smb2] Failed to download libsmb2.so for ${abi}: ${e.message}")
                }
            }
        }
    }
}

tasks.configureEach {
    if (name.contains("preBuild")) {
        dependsOn(downloadSmb2Task)
    }
}
