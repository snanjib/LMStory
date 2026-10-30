import 'package:lmstory/i18n/strings.g.dart';

/// 初始化国际化系统
///
/// 在 main() 中调用，必须在 runApp() 之前。
/// [savedLocaleTag] 从 SharedPreferences 读取的语言标签（如 'zh-CN'），
/// 若为 null 则使用系统语言。
///
/// 注意：slang 的 [AppLocaleUtils.parse] 对非法标签**不抛异常**而是静默
/// 回退 base locale（zh-CN）——「非法保存值回退基础语言」是被测试钉死的
/// 既有行为，勿按「回退系统语言」理解（曾有过这样的死 catch 与错误注释）。
Future<void> initI18n({String? savedLocaleTag}) async {
  if (savedLocaleTag != null && savedLocaleTag.isNotEmpty) {
    await LocaleSettings.setLocale(AppLocaleUtils.parse(savedLocaleTag));
    return;
  }
  await LocaleSettings.useDeviceLocale();
  const supported = AppLocale.values;
  final device = LocaleSettings.currentLocale;
  if (!supported.contains(device)) {
    await LocaleSettings.setLocale(AppLocale.zhCn);
  }
}
