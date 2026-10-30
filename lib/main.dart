import 'dart:async';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lmstory/core/config/advanced_overrides_migrator.dart';
import 'package:lmstory/core/config/config_level.dart';
import 'package:lmstory/core/di/providers.dart';
import 'package:lmstory/core/storage/preferences.dart';
import 'package:lmstory/core/theme/api/lm_component_kit.dart';
import 'package:lmstory/core/theme/appearance_controller.dart';
import 'package:lmstory/core/theme/system/lm_layout.dart';
import 'package:lmstory/core/theme/theme_controller.dart';
import 'package:lmstory/core/utils/file_log_sink.dart';
import 'package:lmstory/core/utils/logger.dart';
import 'package:lmstory/features/advanced/presentation/advanced_mode_flag.dart';
import 'package:lmstory/features/chat/presentation/pages/main_layout.dart';
import 'package:lmstory/features/diagnostics/presentation/controllers/diagnostics_controller.dart';
import 'package:lmstory/features/intermediate/presentation/intermediate_mode_flag.dart';
import 'package:lmstory/features/settings/presentation/controllers/settings_controller.dart';
import 'package:lmstory/i18n/i18n.dart';
import 'package:lmstory/i18n/strings.g.dart';
import 'package:path_provider/path_provider.dart';

void main() async {
  await runZonedGuarded<Future<void>>(
    () async {
      WidgetsFlutterBinding.ensureInitialized();

      // 捕获 Flutter 框架错误（Widget 构建异常、布局异常等）
      FlutterError.onError = (FlutterErrorDetails details) {
        FlutterError.presentError(details);
        const Logger(
          'FlutterError',
        ).error('Framework error', detail: details.exceptionAsString());
      };

      // 兜底：捕获 FlutterError.onError 和 runZonedGuarded 都未拦住的错误
      // （如 Isolate 间的未处理异常、引擎层错误）
      // 用 WidgetsBinding.instance.platformDispatcher 避免显式 import dart:ui
      WidgetsBinding.instance.platformDispatcher.onError =
          (Object error, StackTrace stack) {
        const Logger(
          'Platform',
        ).error('Uncaught platform error', error: error, stackTrace: stack);
        return true; // true = 已处理，防止二次抛出
      };

      final prefs = Preferences();
      final savedLocaleTag = await prefs.getString(localePrefKey);
      await initI18n(savedLocaleTag: savedLocaleTag);

      // 主题/导演开关/故事开关/配置显示模式启动预读（对齐 locale 预读范式）
      // ——保存值≠系统值时首帧不再闪烁（false/system → 保存值）。
      final savedThemeMode = await ThemeModeNotifier.readInitial(prefs);
      final savedAppearance = await AppearanceNotifier.readInitial(prefs);
      final savedAdvancedFlag = await AdvancedModeFlagNotifier.readInitial(
        prefs,
      );
      final savedIntermediateFlag =
          await IntermediateModeFlagNotifier.readInitial(prefs);
      final savedConfigLevel = await ConfigLevelNotifier.readInitial(prefs);

      // 初始化日志文件落盘（诊断包基础设施）
      await _initFileLogging(prefs);

      // 导演设置分家一次性迁移：intermediate.* overrides 复制为 advanced.*
      //（设计文档 §8.1）。必须在 runApp 之前完成，早于任何
      // getResolvedConfig() 读取；失败仅日志不阻塞启动。
      try {
        final migrator = AdvancedOverridesMigrator(prefs);
        await migrator.runIfNeeded();
        // 上下文配置收敛：清除全局 override 存储中的
        // stale 上下文预算键（组装侧定死后无消费点）；独立标记，
        // 已迁移过的老安装也补清
        await migrator.cleanupStaleContextBudgetKeys();
      } catch (e) {
        const Logger(
          'App',
        ).error('advanced overrides migration failed', detail: '$e');
      }

      runApp(
        ProviderScope(
          // 预读值经 override 注入（notifier 首帧即持保存值）
          overrides: [
            appearanceProvider.overrideWith(
              (ref) => AppearanceNotifier(
                ref.read(preferencesProvider),
                initialValue: savedAppearance,
              ),
            ),
            themeModeProvider.overrideWith(
              (ref) => ThemeModeNotifier(
                ref.read(preferencesProvider),
                initialValue: savedThemeMode,
              ),
            ),
            advancedModeFlagProvider.overrideWith(
              (ref) => AdvancedModeFlagNotifier(
                ref.watch(preferencesProvider),
                initialValue: savedAdvancedFlag,
              ),
            ),
            intermediateModeFlagProvider.overrideWith(
              (ref) => IntermediateModeFlagNotifier(
                ref.watch(preferencesProvider),
                initialValue: savedIntermediateFlag,
              ),
            ),
            configLevelProvider.overrideWith(
              (ref) => ConfigLevelNotifier(
                ref.read(preferencesProvider),
                initialValue: savedConfigLevel,
              ),
            ),
          ],
          child: const MyApp(),
        ),
      );
    },
    (Object error, StackTrace stack) {
      // 捕获 Dart 异步错误（未 await 的 Future 异常、Isolate 异常等）
      const Logger(
        'Zone',
      ).error('Uncaught async error', detail: '$error\n$stack');
    },
  );
}

/// 初始化文件日志 sink：注册到 Logger，加载保存的日志级别。
///
/// 日志目录约定：`getApplicationDocumentsDirectory()/logs/app.log`
/// 诊断页用相同路径约定访问日志文件，无需持有 sink 实例。
/// 日志级别存 Preferences key `log_level`，诊断页可调。
///
/// **Web 平台跳过文件日志**：浏览器无文件系统访问权限，仅保留控制台输出。
/// 日志级别仍从 Preferences 加载（Preferences 在 web 上使用 localStorage）。
Future<void> _initFileLogging(Preferences prefs) async {
  // 缺省级别单源 kDefaultLogLevel（release 收敛 info——安全评测），
  // 与诊断页显示共用，防止两端缺省漂移
  Logger.globalMinLevel = kDefaultLogLevel;

  // 加载保存的日志级别（诊断页可调）——所有平台共用；用户显式
  // 设置过则尊重用户值（含无效值回退，回退也按模式取默认）
  final savedLevel = await prefs.getString('log_level');
  if (savedLevel != null) {
    Logger.globalMinLevel = LogLevel.values.firstWhere(
      (l) => l.name == savedLevel,
      orElse: () => kDefaultLogLevel,
    );
  }

  // DM-4：启动即恢复调试日志五开关到 Logger.debugOptions——
  // 此前仅诊断页 load() 时装配，重启后「UI 勾选但运行时全关」。
  // 与诊断页共用同一加载函数（键名单一事实源），所有平台共用
  //（开关同样作用于 Web 的控制台输出）。
  Logger.debugOptions = await DiagnosticsController.loadDebugLogOptions(prefs);

  // Web 平台无文件系统，跳过文件 sink 初始化
  if (kIsWeb) {
    const Logger('App').info('Web platform: file logging skipped');
    return;
  }

  // 初始化文件 sink（原生平台）
  final docsDir = await getApplicationDocumentsDirectory();
  final logDir = '${docsDir.path}/logs';
  final sink = FileLogSink(directoryPath: logDir);
  await sink.init();
  Logger.addSink(sink);

  const Logger('App').info('File logging initialized', detail: 'dir: $logDir');
}

class MyApp extends ConsumerWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final locale = ref.watch(flutterLocaleProvider);
    final themeMode = ref.watch(themeModeProvider);
    final themes = ref.watch(appearanceThemesProvider);
    final contentWidthMode = ref.watch(
      settingsNotifierProvider.select((s) => s.contentWidthMode),
    );

    return TranslationProvider(
      child: MaterialApp(
        title: 'LMStory',
        theme: themes.light,
        darkTheme: themes.dark,
        themeMode: themeMode,
        locale: locale,
        // 全局场地：琉璃结构下所有路由共享的根渐变幕布——经根导航推入的
        // 页面（设置树/供应商页等）scaffoldBgOf 取透明底，无此地时透出
        // 黑底（日间尤其不可读）。首页/壳层的内层 venue 与此同色叠加无观感差。
        // 内容宽度模式经作用域下发全树（版心消费面 context 读取，
        // 切换即时生效）
        builder: (context, child) => LmContentWidthScope(
          mode: contentWidthMode,
          child: _GlassVenueShell(child: child),
        ),
        supportedLocales: AppLocale.values.map((e) => e.flutterLocale),
        localizationsDelegates: const [
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        home: const MainLayout(),
      ),
    );
  }
}

/// 全局场地壳：琉璃结构下在导航器底下铺根渐变幕布（GlassBackdrop），
/// 场地由当前结构的组件实现提供；经典结构原样透传。
///
/// 读 tokens 放在自身 build（此处已位于 Theme 之下），builder 回调的
/// context 不依赖。
class _GlassVenueShell extends StatelessWidget {
  const _GlassVenueShell({this.child});

  final Widget? child;

  @override
  Widget build(BuildContext context) {
    return context.lmVenue(child ?? const SizedBox.shrink());
  }
}
