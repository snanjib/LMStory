import 'package:lmstory/i18n/strings.g.dart';

/// 初始化国际化系统
///
/// 在 main() 中调用，必须在 runApp() 之前。
/// [savedLocaleTag] 从 SharedPreferences 读取的语言标签（如 'zh-CN'），
/// 若为 null 则使用系统语言。
Future<void> initI18n({String? savedLocaleTag}) async {
  if (savedLocaleTag != null && savedLocaleTag.isNotEmpty) {
    try {
      final appLocale = AppLocaleUtils.parse(savedLocaleTag);
      await LocaleSettings.setLocale(appLocale);
      return;
    } catch (_) {
      // 解析失败，回退到系统语言
    }
  }
  await LocaleSettings.useDeviceLocale();
  const supported = AppLocale.values;
  final device = LocaleSettings.currentLocale;
  if (!supported.contains(device)) {
    await LocaleSettings.setLocale(AppLocale.zhCn);
  }
}
