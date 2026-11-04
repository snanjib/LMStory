# LMStory ProGuard Rules
#
# 项目实际使用的原生依赖：
# - sqlite3_flutter_libs: SQLite JNI 绑定，必须保留
# - drift: 纯 Dart，运行时无需特殊保留
# - json_serializable: 编译时代码生成，运行时无反射
# - uuid: 纯 Dart，无原生代码

# 保留 Flutter 引擎和插件相关类
-keep class io.flutter.app.** { *; }
-keep class io.flutter.plugin.** { *; }
-keep class io.flutter.util.** { *; }
-keep class io.flutter.view.** { *; }
-keep class io.flutter.** { *; }
-keep class io.flutter.plugins.** { *; }

# 保留 sqlite3_flutter_libs 的 JNI 绑定类（数据库核心依赖）
-keep class io.sqlite3.** { *; }
-keep class com.alexmercerind.sqlite3.** { *; }

# 保留 flutter_secure_storage 的原生实现
-keep class com.it_nomads.fluttersecurestorage.** { *; }

# 保留 image_picker 的原生实现
-keep class io.flutter.plugins.imagepicker.** { *; }

# 忽略 Google Play Core 缺失类
# Flutter 引擎的 PlayStoreDeferredComponentManager 引用了 Play Core 库，
# 但本项目不使用 Play Store 延迟组件功能，未添加该依赖。
# 加 -dontwarn 让 R8 忽略缺失类，避免 release 构建失败。
-dontwarn com.google.android.play.core.**
