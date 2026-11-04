import 'package:flutter/material.dart' show Locale;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/di/providers.dart';
import 'package:lmstory/core/storage/preferences.dart';
import 'package:lmstory/i18n/i18n.dart';
import 'package:lmstory/i18n/strings.g.dart';
import 'package:lmstory/i18n/strings_en_US.g.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// en-US locale 基础设施测试：
/// 枚举存在性、flutterLocale、初始化回退链、切换持久化与重启恢复。
///
/// 用普通 test 而非 testWidgets：slang 非 base locale 走 deferred
/// 加载，fake-async zone 内其异步链不自走会挂死用例。
void main() {
  setUpAll(TestWidgetsFlutterBinding.ensureInitialized);

  tearDown(() async {
    // 复位全局 slang 状态，避免污染后续用例
    await LocaleSettings.setLocale(AppLocale.zhCn);
  });

  group('AppLocale.enUs 枚举', () {
    test('存在于 AppLocale.values', () {
      expect(AppLocale.values, contains(AppLocale.enUs));
    });

    test('flutterLocale 为 en-US', () {
      expect(AppLocale.enUs.flutterLocale, const Locale('en', 'US'));
    });

    test('languageTag 为 en-US', () {
      expect(AppLocale.enUs.languageTag, 'en-US');
    });

    test('英文翻译实例可构建且非空', () async {
      final translations = await AppLocale.enUs.build();
      expect(translations, isA<TranslationsEnUs>());
      expect(translations.settings.general.language, isNotEmpty);
    });
  });

  group('initI18n 回退链', () {
    test('保存值为 en-US 时应用英文', () async {
      await initI18n(savedLocaleTag: 'en-US');
      expect(LocaleSettings.currentLocale, AppLocale.enUs);
    });

    test('保存值为 zh-CN 时应用中文', () async {
      await initI18n(savedLocaleTag: 'zh-CN');
      expect(LocaleSettings.currentLocale, AppLocale.zhCn);
    });

    test('空保存值回退到设备 locale 解析结果', () async {
      await initI18n();
      expect(LocaleSettings.currentLocale, AppLocaleUtils.findDeviceLocale());
    });

    test('非法保存值回退到基础语言 zhCn', () async {
      // slang 的 parse 对不可解析标签不抛异常而是回退 base locale
      // （zh-CN），initI18n 的 catch 分支不触发
      await initI18n(savedLocaleTag: 'not-a-locale-tag!');
      expect(LocaleSettings.currentLocale, AppLocale.zhCn);
    });

    test('语言-only 标签 en 解析为 enUs', () async {
      await initI18n(savedLocaleTag: 'en');
      expect(LocaleSettings.currentLocale, AppLocale.enUs);
    });

    test('语言-only 标签 zh 解析为 zhCn', () async {
      await initI18n(savedLocaleTag: 'zh');
      expect(LocaleSettings.currentLocale, AppLocale.zhCn);
    });
  });

  group('LocaleNotifier 持久化与重启恢复', () {
    test('switchLocale 写入 app_locale 且状态即时更新', () async {
      final prefs = await _mockPrefs();
      final container = ProviderContainer(
        overrides: [
          preferencesProvider.overrideWithValue(Preferences(prefs: prefs)),
        ],
      );
      addTearDown(container.dispose);

      await container.read(localeProvider.notifier).switchLocale(
            AppLocale.enUs,
          );
      expect(container.read(localeProvider), AppLocale.enUs);
      expect(
        prefs.getString('app_locale'),
        'en-US',
        reason: '切换后应持久化 languageTag',
      );
    });

    test('重启后经 initI18n 恢复英文选择', () async {
      // 首次"运行"：切换到英文并持久化
      final prefs = await _mockPrefs();
      final first = ProviderContainer(
        overrides: [
          preferencesProvider.overrideWithValue(Preferences(prefs: prefs)),
        ],
      );
      addTearDown(first.dispose);
      await first.read(localeProvider.notifier).switchLocale(AppLocale.enUs);

      // 模拟重启：新容器 + initI18n 读同一持久化存储
      final second = ProviderContainer(
        overrides: [
          preferencesProvider.overrideWithValue(Preferences(prefs: prefs)),
        ],
      );
      addTearDown(second.dispose);
      await initI18n(savedLocaleTag: prefs.getString('app_locale'));
      expect(LocaleSettings.currentLocale, AppLocale.enUs);
      expect(second.read(localeProvider), AppLocale.enUs);
    });

    test('中英文可重复切换', () async {
      final prefs = await _mockPrefs();
      final container = ProviderContainer(
        overrides: [
          preferencesProvider.overrideWithValue(Preferences(prefs: prefs)),
        ],
      );
      addTearDown(container.dispose);
      final notifier = container.read(localeProvider.notifier);

      await notifier.switchLocale(AppLocale.enUs);
      expect(container.read(localeProvider), AppLocale.enUs);
      await notifier.switchLocale(AppLocale.zhCn);
      expect(container.read(localeProvider), AppLocale.zhCn);
      await notifier.switchLocale(AppLocale.enUs);
      expect(container.read(localeProvider), AppLocale.enUs);
      expect(prefs.getString('app_locale'), 'en-US');
    });
  });
}

Future<SharedPreferences> _mockPrefs() async {
  SharedPreferences.setMockInitialValues(const {});
  return SharedPreferences.getInstance();
}
