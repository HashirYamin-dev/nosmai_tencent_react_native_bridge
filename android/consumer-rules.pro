

# NOSMAI_TRTC_JNI_KEEP_V1 — Tencent LiteAV JNI uses class names / reflection.
# Based on Tencent RTC Android SDK documented R8/ProGuard rules.
-keep class com.tencent.** { *; }
# Nosmai native bridge + effects sdk reflection/JNI.
-keep class com.nosmai.** { *; }
# Tencent auxiliary visual-effect dependencies (safe if not installed).
-keep class org.light.** { *; }
-keep class org.libpag.** { *; }
-keep class org.extra.** { *; }
-keep class com.gyailib.** { *; }
-keep class androidx.exifinterface.** { *; }
