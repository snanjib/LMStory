import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/config/config_level.dart';
import 'package:lmstory/core/di/providers.dart';
import 'package:lmstory/core/storage/preferences.dart';
import 'package:lmstory/core/theme/simple/simple_theme.dart';
import 'package:lmstory/features/chat/domain/entities/chat_session.dart';
import 'package:lmstory/features/chat/domain/repositories/chat_repository.dart';
import 'package:lmstory/features/settings/data/auto_backup_manager.dart';
import 'package:lmstory/features/settings/domain/entities/api_preset.dart';
import 'package:lmstory/features/settings/domain/entities/data_management_models.dart';
import 'package:lmstory/features/settings/domain/repositories/api_preset_repository.dart';
import 'package:lmstory/features/settings/domain/repositories/backup_repository.dart';
import 'package:lmstory/features/settings/domain/repositories/settings_repository.dart';
import 'package:lmstory/features/settings/domain/services/data_management_service.dart';
import 'package:lmstory/features/settings/presentation/pages/data_management_page.dart';
import 'package:lmstory/features/settings/presentation/widgets/data_management_sheets.dart';
import 'package:lmstory/features/templates/domain/repositories/template_repository.dart';
import 'package:lmstory/i18n/strings.g.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 数据管理页 Widget 测试
///
/// 自动备份区段必须展示说明文案——
/// 实际行为口径（AutoBackupManager）：启动时检查、距上次备份超过
/// 24 小时且有会话数据才备份；存于文档目录 backups/；不含 API Key；
/// 保留最近 3 份；关闭开关即可停用。
void main() {
  setUp(() {
    LocaleSettings.setLocale(AppLocale.zhCn);
  });

  Widget wrap(Widget child) => TranslationProvider(
        child: MaterialApp(theme: SimpleTheme.lightTheme, home: child),
      );

  testWidgets('自动备份区段展示行为说明文案（A7）', (tester) async {
    await tester.pumpWidget(
      wrap(
        ProviderScope(
          overrides: [
            templateRepositoryProvider.overrideWithValue(_StubTemplateRepo()),
            dataManagementServiceProvider.overrideWith(
              (ref) => DataManagementService(
                chatRepository: _StubChatRepo(),
                presetRepository: _StubPresetRepo(),
                settingsRepository: _StubSettingsRepo(),
                backupRepository: _StubBackupRepo(),
              ),
            ),
            autoBackupManagerProvider.overrideWith(
              (ref) => AutoBackupManager(
                dataManagementService: ref.read(dataManagementServiceProvider),
                settingsRepository: _StubSettingsRepo(),
                chatRepository: _StubChatRepo(),
              ),
            ),
          ],
          child: const DataManagementPage(),
        ),
      ),
    );
    // 页面含不确定进度指示器（统计加载），不用 pumpAndSettle（永不静止）
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    expect(
      find.textContaining('24 小时'),
      findsOneWidget,
      reason: '自动备份说明必须如实描述触发条件（>24h 且有会话数据）',
    );
    expect(
      find.text(t.settings.data.autoBackup.hint),
      findsOneWidget,
    );
    expect(
      find.text(t.settings.data.autoBackup.sandboxNotice),
      findsOneWidget,
      reason: '备份目录沙盒属性必须醒目提示（warning 色提示行）',
    );
  });
  testWidgets('配置双模式：简单模式自动备份区段与动作卡片全保留（无裁剪）', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = Preferences(prefs: await SharedPreferences.getInstance());
    await tester.pumpWidget(
      wrap(
        ProviderScope(
          overrides: [
            configLevelProvider.overrideWith(
              (ref) =>
                  ConfigLevelNotifier(prefs, initialValue: ConfigLevel.simple),
            ),
            templateRepositoryProvider.overrideWithValue(_StubTemplateRepo()),
            dataManagementServiceProvider.overrideWith(
              (ref) => DataManagementService(
                chatRepository: _StubChatRepo(),
                presetRepository: _StubPresetRepo(),
                settingsRepository: _StubSettingsRepo(),
                backupRepository: _StubBackupRepo(),
              ),
            ),
            autoBackupManagerProvider.overrideWith(
              (ref) => AutoBackupManager(
                dataManagementService: ref.read(dataManagementServiceProvider),
                settingsRepository: _StubSettingsRepo(),
                chatRepository: _StubChatRepo(),
              ),
            ),
          ],
          child: const DataManagementPage(),
        ),
      ),
    );
    // 页面含不确定进度指示器，不用 pumpAndSettle（永不静止）
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    // simple 声明键区段恒显（配置双模式结构无变化面）
    expect(find.text('导出数据'), findsOneWidget);
    expect(find.text('数据恢复'), findsOneWidget);
    expect(find.textContaining('24 小时'), findsOneWidget);
  });
  testWidgets('打开备份目录兜底弹窗说明沙盒不可见并指路导出/导入', (tester) async {
    // Clipboard.setData 走平台通道，测试环境必须 mock（弹窗前置步骤）
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async => null,
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null),
    );
    await tester.pumpWidget(
      wrap(
        ProviderScope(
          overrides: [
            templateRepositoryProvider.overrideWithValue(_StubTemplateRepo()),
            dataManagementServiceProvider.overrideWith(
              (ref) => DataManagementService(
                chatRepository: _StubChatRepo(),
                presetRepository: _StubPresetRepo(),
                settingsRepository: _StubSettingsRepo(),
                backupRepository: _StubBackupRepo(),
              ),
            ),
            autoBackupManagerProvider.overrideWith(
              (ref) => AutoBackupManager(
                dataManagementService: ref.read(dataManagementServiceProvider),
                settingsRepository: _StubSettingsRepo(),
                chatRepository: _StubChatRepo(),
                // 目录不可用 → path 留空走兜底弹窗（跳过 launchUrl，
                // 不依赖 url_launcher 在测试环境的行为；真实 path_provider
                // 通道在 widget test 里未 mock 会永久挂起）
                documentsDirectory: () async =>
                    throw const FileSystemException('测试环境无文档目录'),
              ),
            ),
          ],
          child: const DataManagementPage(),
        ),
      ),
    );
    // 页面含不确定进度指示器（统计加载），不用 pumpAndSettle（永不静止）
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    // 区块在页面下方视口外，必须先滚到可见，否则 tap 静默落空。
    await tester.ensureVisible(
      find.text(t.settings.data.autoBackup.openFolder),
    );
    await tester.pump();
    await tester.tap(find.text(t.settings.data.autoBackup.openFolder));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    expect(
      find.text(t.settings.data.autoBackup.pathSandboxNote),
      findsOneWidget,
      reason: '兜底弹窗必须说明目录在应用私有存储内、文件管理器不可见',
    );
    expect(
      find.text(t.settings.data.autoBackup.pathMigrationTip),
      findsOneWidget,
      reason: '兜底弹窗必须指路「导出数据/导入数据」完成数据迁移',
    );
    expect(find.text(t.common.close), findsOneWidget);

    // 收尾关弹窗：不留挂起的浮层，防 locale 微任务串入后续用例
    await tester.tap(find.text(t.common.close));
    await tester.pump();
  });
  testWidgets('窄屏：自动备份三按钮自动换行不溢出', (tester) async {
    // 手机竖屏典型窄宽度：此前 Row 并排三个按钮 → RenderFlex overflow
    // （用户真机截图，「从备份恢复」被切出屏外）
    tester.view.physicalSize = const Size(360, 780);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      wrap(
        ProviderScope(
          overrides: [
            templateRepositoryProvider.overrideWithValue(_StubTemplateRepo()),
            dataManagementServiceProvider.overrideWith(
              (ref) => DataManagementService(
                chatRepository: _StubChatRepo(),
                presetRepository: _StubPresetRepo(),
                settingsRepository: _StubSettingsRepo(),
                backupRepository: _StubBackupRepo(),
              ),
            ),
            autoBackupManagerProvider.overrideWith(
              (ref) => AutoBackupManager(
                dataManagementService: ref.read(dataManagementServiceProvider),
                settingsRepository: _StubSettingsRepo(),
                chatRepository: _StubChatRepo(),
              ),
            ),
          ],
          child: const DataManagementPage(),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    // RenderFlex overflow 会在布局期抛异常，此处必须干净
    expect(tester.takeException(), isNull);
    expect(
      find.text(t.settings.data.autoBackup.backupNow),
      findsOneWidget,
    );
    expect(
      find.text(t.settings.data.autoBackup.openFolder),
      findsOneWidget,
    );
    expect(
      find.text(t.settings.data.autoBackup.restoreFromBackup),
      findsOneWidget,
    );
  });
  testWidgets('initialImportContent：外部进入的备份内容直达导入模式选择', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = Preferences(prefs: await SharedPreferences.getInstance());
    final gatedService = _GatedImportService(
      chatRepository: _StubChatRepo(),
      presetRepository: _StubPresetRepo(),
      settingsRepository: _StubSettingsRepo(),
      backupRepository: _StubBackupRepo(),
    );
    await tester.pumpWidget(
      wrap(
        ProviderScope(
          overrides: [
            configLevelProvider.overrideWith(
              (ref) =>
                  ConfigLevelNotifier(prefs, initialValue: ConfigLevel.simple),
            ),
            templateRepositoryProvider.overrideWithValue(_StubTemplateRepo()),
            dataManagementServiceProvider.overrideWith((ref) => gatedService),
            autoBackupManagerProvider.overrideWith(
              (ref) => AutoBackupManager(
                dataManagementService: ref.read(dataManagementServiceProvider),
                settingsRepository: _StubSettingsRepo(),
                chatRepository: _StubChatRepo(),
              ),
            ),
          ],
          child: const DataManagementPage(
            // "打开方式"进入的备份内容：进页即走导入主链
            initialImportContent:
                '{"version":3,"exportedAt":"2026-09-25T00:00:00Z",'
                '"sessions":[]}',
          ),
        ),
      ),
    );
    // initState 的 post-frame 起导入链（解码→版本守卫→模式选择弹层），
    // 页面含不确定进度指示器，全程手动 pump
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pump(const Duration(milliseconds: 300));

    expect(
      find.byType(ImportModeSheet),
      findsOneWidget,
      reason: '备份内容应跳过文件选择直达导入模式选择（追加/覆盖）',
    );

    // 点确认（追加已是默认模式）→ 导入被闸门挂起 → 进度弹层出现且驻留
    await tester.tap(find.text(t.common.confirm));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 150));
    expect(
      find.text(t.settings.data.importing),
      findsOneWidget,
      reason: '导入执行期必须显示不可关闭的进度弹层（无反馈会被误判为无状态导入）',
    );
    // sheet 退场动画走完再断言其消失
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(ImportModeSheet), findsNothing);

    // 释放闸门 → 导入完成 → 进度弹层自动撤除
    gatedService.gate.complete(
      const ImportResult(
        importedPresets: 0,
        skippedPresets: 0,
        importedSessions: 0,
        skippedSessions: 0,
        importedMessages: 0,
        importedPreferences: 0,
        skippedPreferences: 0,
        mode: ImportMode.append,
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(
      find.text(t.settings.data.importing),
      findsNothing,
      reason: '导入结束后进度弹层必须自动撤除',
    );
  });

  testWidgets('导入同步失败（坏 JSON）→ 进度弹层不得滞留（迟到关闭兜底）', (
    tester,
  ) async {
    // importBackup 首句 jsonDecode 同步抛出：错误经微任务在弹层 builder
    // 首帧执行前送达，撤除回调尚未挂上——若无迟到关闭兜底，不可关闭
    // 弹层会构建后永久滞留（只能重启应用）。
    SharedPreferences.setMockInitialValues({});
    final prefs = Preferences(prefs: await SharedPreferences.getInstance());
    final failService = _SyncFailImportService(
      chatRepository: _StubChatRepo(),
      presetRepository: _StubPresetRepo(),
      settingsRepository: _StubSettingsRepo(),
      backupRepository: _StubBackupRepo(),
    );
    await tester.pumpWidget(
      wrap(
        ProviderScope(
          overrides: [
            configLevelProvider.overrideWith(
              (ref) =>
                  ConfigLevelNotifier(prefs, initialValue: ConfigLevel.simple),
            ),
            templateRepositoryProvider.overrideWithValue(_StubTemplateRepo()),
            dataManagementServiceProvider.overrideWith((ref) => failService),
            autoBackupManagerProvider.overrideWith(
              (ref) => AutoBackupManager(
                dataManagementService: ref.read(dataManagementServiceProvider),
                settingsRepository: _StubSettingsRepo(),
                chatRepository: _StubChatRepo(),
              ),
            ),
          ],
          child: const DataManagementPage(
            initialImportContent:
                '{"version":3,"exportedAt":"2026-09-25T00:00:00Z",'
                '"sessions":[]}',
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text(t.common.confirm));
    await tester.pump();
    // builder 帧 + 迟到 pop 的 postFrame 帧
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 300));

    expect(
      find.text(t.settings.data.importing),
      findsNothing,
      reason: '同步失败路径的进度弹层必须自动撤除，不可关闭弹层永挂=只能重启',
    );
  });
}

/// 导入挂起服务：importBackup 在闸门上等待，测试据此断言进度弹层
/// 的出现与自动撤除（真实导入耗时不可控，挂起才能确定性断言）
class _GatedImportService extends DataManagementService {
  _GatedImportService({
    required super.chatRepository,
    required super.presetRepository,
    required super.settingsRepository,
    required super.backupRepository,
  });

  final Completer<ImportResult> gate = Completer<ImportResult>();

  @override
  Future<ImportResult> importBackup(
    String jsonContent,
    ImportMode mode, {
    Future<void> Function()? preImportSnapshot,
    bool importApiKeys = false,
  }) =>
      gate.future;
}

class _StubTemplateRepo implements TemplateRepository {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

class _StubSettingsRepo implements SettingsRepository {
  @override
  Future<Map<String, dynamic>> getUserOverrides() async => const {};

  @override
  Future<int> getUserOverrideCount() async => 0;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

/// 同步失败导入服务：模拟坏 JSON 在首个 await 前（jsonDecode）抛出，
/// 错误经微任务先于进度弹层首帧送达的窄窗口。
class _SyncFailImportService extends DataManagementService {
  _SyncFailImportService({
    required super.chatRepository,
    required super.presetRepository,
    required super.settingsRepository,
    required super.backupRepository,
  });

  @override
  Future<ImportResult> importBackup(
    String jsonContent,
    ImportMode mode, {
    Future<void> Function()? preImportSnapshot,
    bool importApiKeys = false,
  }) async {
    throw const FormatException('invalid backup json');
  }
}

class _StubPresetRepo implements ApiPresetRepository {
  @override
  Future<List<ApiPreset>> getAllPresets() async => const [];

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

class _StubBackupRepo implements BackupRepository {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

class _StubChatRepo implements ChatRepository {
  @override
  Future<List<ChatSession>> getAllSessions() async => const [];

  @override
  Future<int> getTotalMessageCount() async => 0;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}
