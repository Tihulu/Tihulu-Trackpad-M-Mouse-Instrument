plugins { id("com.android.application") }
android {
    namespace = "com.tihulu.mobile.paired"
    compileSdk = 35
    defaultConfig {
        applicationId = "com.tihulu.mobile.paired"
        minSdk = 26
        targetSdk = 35
        versionCode = 1
        versionName = "0.3.0-paired-experimental"
    }
    compileOptions { sourceCompatibility = JavaVersion.VERSION_17; targetCompatibility = JavaVersion.VERSION_17 }
}
dependencies { implementation(project(":")); implementation("com.google.ar:core:1.48.0") }
