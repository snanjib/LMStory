/// 应用构建身份常量（运行时显示面的单源桥）
///
/// 应用版本的真源是 `pubspec.yaml`（构建工具链消费：Android versionName
/// 等均由此生成）。本常量是 Dart 运行时显示面的唯一桥接点——版本 bump
/// 时同步这一处，由 `test/core/meta/app_meta_guard_test.dart` 对账
/// pubspec 强制执行，漂移在 CI 即红。
const String kAppVersion = '0.4.1';
