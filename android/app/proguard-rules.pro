# Flutter specific rules
-keep class io.flutter.app.** { *; }
-keep class io.flutter.plugin.** { *; }
-keep class io.flutter.util.** { *; }
-keep class io.flutter.view.** { *; }
-keep class io.flutter.** { *; }
-keep class io.flutter.plugins.** { *; }

# Google ML Kit Text Recognition
-keep class com.google.mlkit.** { *; }
-keep class com.google.android.gms.** { *; }
-dontwarn com.google.mlkit.**
-dontwarn com.google.android.gms.**

# Keep classes for google_mlkit_text_recognition plugin
-keep class com.google_mlkit_text_recognition.** { *; }
-keep class com.google_mlkit_commons.** { *; }

# Mobile Scanner / Barcode Scanner
-keep class dev.steenbakker.mobile_scanner.** { *; }
-keep class com.google.zxing.** { *; }
-dontwarn dev.steenbakker.mobile_scanner.**

# CameraX
-keep class androidx.camera.** { *; }
-dontwarn androidx.camera.**

# Suppress warnings for missing classes
-dontwarn org.checkerframework.**
-dontwarn javax.annotation.**
-dontwarn com.google.errorprone.**

# Keep Kotlin metadata
-keepattributes *Annotation*
-keepattributes Signature
-keepattributes InnerClasses
-keep class kotlin.Metadata { *; }
