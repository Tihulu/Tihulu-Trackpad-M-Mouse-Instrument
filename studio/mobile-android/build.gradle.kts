plugins {
    id("com.android.library") version "8.7.3"
    id("com.android.application") version "8.7.3" apply false
    id("org.jetbrains.kotlin.android") version "2.0.21"
}
android {
    namespace = "com.tihulu.mobile.air"
    compileSdk = 35
    defaultConfig { minSdk = 26 }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions { jvmTarget = "17" }
}
dependencies {
    // Experimental native LAN adapter. No network permission in diagnostic APK.
    implementation("com.squareup.okhttp3:okhttp:4.12.0")
    implementation("com.google.zxing:core:3.5.4") // local address QR only
    implementation("androidx.camera:camera-camera2:1.4.2")
    implementation("androidx.camera:camera-lifecycle:1.4.2")
    implementation("androidx.core:core-ktx:1.15.0")
    implementation("androidx.activity:activity-ktx:1.10.1")
    implementation("com.google.mediapipe:tasks-vision:0.10.26")
    // Optional in the embedding app; RGB-only clients need no ARCore runtime.
    compileOnly("com.google.ar:core:1.48.0")
    testImplementation("junit:junit:4.13.2")
}
