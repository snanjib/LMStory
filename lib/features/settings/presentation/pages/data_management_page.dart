import 'dart:convert';
import 'dart:io' show File, Platform;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, kIsWeb, visibleForTesting;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lmstory/core/config/config_level.dart';
import 'package:lmstory/core/config/config_visibility.dart';
import 'package:lmstory/core/di/providers.dart';
import 'package:lmstory/core/theme/api/lm_component_kit.dart';
import 'package:lmstory/core/theme/shared/components/labeled_value.dart';
import 'package:lmstory/core/theme/shared/components/section_heading.dart';
import 'package:lmstory/core/theme/simple/simple_spacing.dart';
import 'package:lmstory/core/theme/simple/simple_text_styles.dart';
import 'package:lmstory/core/theme/system/lm_layout.dart';
import 'package:lmstory/core/theme/system/lm_narrative_text_styles.dart';
import 'package:lmstory/core/theme/system/lm_overlays.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';
import 'package:lmstory/core/utils/db_storage_info.dart'
    if (dart.library.html) 'package:lmstory/core/utils/db_storage_info_web.dart';
import 'package:lmstory/core/utils/file_reader.dart'
    if (dart.library.html) 'package:lmstory/core/utils/file_reader_web.dart';
import 'package:lmstory/core/utils/file_share.dart'
    if (dart.library.html) 'package:lmstory/core/utils/file_share_web.dart';
import 'package:lmstory/core/utils/json_depth_guard.dart';
import 'package:lmstory/core/widgets/file_saved_dialog.dart';
import 'package:lmstory/features/settings/data/auto_backup_manager.dart';
import 'package:lmstory/features/settings/domain/entities/data_management_models.dart';
import 'package:lmstory/features/settings/domain/services/data_management_service.dart';
import 'package:lmstory/features/settings/presentation/pages/provider_list_page.dart';
import 'package:lmstory/features/settings/presentation/widgets/data_management_sheets.dart';
import 'package:lmstory/i18n/strings.g.dart';
import 'package:url_launcher/url_launcher.dart';

/// 检测备份是否携带 API Key。
///
/// 两层口径（与 DataManagementService 导出门控配套）：
/// 1. v3 备份用 `contains_secrets: true` 显式标记（仅布尔 true 命中）；
/// 2. 手裁/第三方变体兜底扫描 presets 内 `api_key`（v3）/`apiKey`（v1）
///    字段——非空字符串才算带 Key。
///
/// 原为 `_importData` 内联逻辑、零测试，提取为
/// 可测函数，误报/漏报边界由 data_management_secrets_detection_test.dart
/// 锁定。previewMap 为 null（非法 JSON / v1 列表顶层）返回 false。
@visibleForTesting
bool detectBackupContainsSecrets(Map<String, dynamic>? previewMap) {
  if (previewMap == null) return false;
  if (previewMap['contains_secrets'] == true) return true;
  final presets = previewMap['presets'];
  if (presets is List) {
    return presets.any(
      (p) =>
          p is Map &&
          ((p['api_key'] != null && p['api_key'] != '') ||
              (p['apiKey'] != null && p['apiKey'] != '')),
    );
  }
  return false;
}

/// 数据管理页面
///
/// 提供数据导出（多选内容 + API Key 独立选项）、导入（追加 / 覆盖两种模式）、
/// 数据恢复（扫描孤立消息）、清除会话和消息、存储信息展示。
///
/// 业务逻辑统一由 [DataManagementService] 处理，本页面只负责 UI 交互和文件 IO。
class DataManagementPage extends ConsumerStatefulWidget {
  const DataManagementPage({super.key, this.initialImportContent});

  /// 外部"打开方式/分享"进入的备份 JSON 内容：进页即走导入主链
  /// （版本守卫/模式选择/前置快照/二次确认全继承）。
  /// 仅当入口监听器判定为应用备份格式时才会传入。
  final String? initialImportContent;

  @override
  ConsumerState<DataManagementPage> createState() => _DataManagementPageState();
}

class _DataManagementPageState extends ConsumerState<DataManagementPage> {
  Future<StorageStats>? _statsFuture;

  /// 撤除导入进度弹层的回调（弹层 builder 建立时登记）
  void Function()? _dismissImportProgress;

  /// 迟到关闭标志：弹层 builder 晚于撤除调用执行时的兜底
  /// （导入在首帧前同步失败/完成的窄窗口）。
  bool _importProgressDismissed = false;

  @override
  void initState() {
    super.initState();
    _reloadStats();
    final initial = widget.initialImportContent;
    if (initial != null) {
      // 等首帧布局完成再起导入链：_importContent 依赖 context 弹层
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _importContent(context, initial);
      });
    }
  }

  void _reloadStats() {
    _statsFuture = _computeStats();
  }

  Future<StorageStats> _computeStats() async {
    final service = ref.read(dataManagementServiceProvider);
    final templateRepo = ref.read(templateRepositoryProvider);

    // 数据库文件大小：原生平台读取实际文件，Web 平台返回 0（条件导入）
    final dbSize = await getDatabaseFileSize();

    final templates = await templateRepo.getAllTemplates();

    return service.getStorageStats(
      dbSizeBytes: dbSize,
      // 与 presetCount 同口径——内置模板不计入"我的配置资产"
      templateCount: templates.where((t) => !t.isBuiltIn).length,
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = Translations.of(context);

    return Scaffold(
      backgroundColor:
          context.scaffoldBgOf(Theme.of(context).scaffoldBackgroundColor),
      appBar: context.lmUi.appBar(context, title: t.settings.data.title),
      body: LmMeasure(
        child: ListView(
          padding: const EdgeInsets.all(SimpleSpacing.sLg),
          children: [
            _DataCard(
              icon: Icons.upload_file_outlined,
              title: t.settings.data.export,
              subtitle: t.settings.data.exportDesc,
              onTap: () => _exportData(context),
            ),
            const SizedBox(height: SimpleSpacing.sMd),
            _DataCard(
              icon: Icons.download_outlined,
              title: t.settings.data.import,
              subtitle: t.settings.data.importDesc,
              onTap: () => _importData(context),
            ),
            const SizedBox(height: SimpleSpacing.sMd),
            //  备份完整性立项：自动备份区段（开关 + 立即备份 + 打开目录）。
            // 结构无变化面（配置双模式）：simple 声明键，双模式恒显，
            // 过滤门仅作表↔代码对账锚点（动作卡片非配置项不过滤）。
            if (!kIsWeb &&
                ConfigVisibility.of(
                  ConfigVisibilityKeys.dataAutoBackup,
                  ref.watch(configLevelProvider),
                ))
              _AutoBackupSection(
                onRestore: (content) => _importContent(context, content),
              ),
            const SizedBox(height: SimpleSpacing.sMd),
            _DataCard(
              icon: Icons.restore_outlined,
              title: t.settings.data.recovery.title,
              subtitle: t.settings.data.recovery.desc,
              onTap: () => _recoverData(context),
            ),
            const SizedBox(height: SimpleSpacing.sMd),
            _DataCard(
              icon: Icons.build_outlined,
              title: t.settings.data.repairSchema.title,
              subtitle: t.settings.data.repairSchema.desc,
              onTap: () => _confirmRepairSchema(context),
            ),
            const SizedBox(height: SimpleSpacing.sMd),
            _DataCard(
              icon: Icons.delete_forever_outlined,
              title: t.settings.data.clearAll,
              subtitle: t.settings.data.clearAllDesc,
              titleColor: context.lm.palette.error,
              onTap: () => _confirmClearAll(context),
            ),
            const SizedBox(height: SimpleSpacing.sXl),
            _StorageInfoSection(statsFuture: _statsFuture),
          ],
        ),
      ),
    );
  }

  // ==================== 导出 ====================

  Future<void> _exportData(BuildContext context) async {
    // 分享锚点需在首个 await 前取（iPad/iPhone 分享浮层必需）
    final shareOrigin = shareOriginFrom(context);
    final options = await ExportOptionsSheet.show(context);
    if (options == null || !context.mounted) return;

    final service = ref.read(dataManagementServiceProvider);
    try {
      final jsonStr = await service.exportFullBackup(options);
      final timestamp = DateTime.now().toIso8601String().replaceAll(':', '-');
      final fileName = 'lmstory_backup_$timestamp.json';

      // 桌面端返回保存路径（弹成功确认框明示位置）；
      // null = 移动端分享面板已调起，反馈由面板自管
      final savedPath = await shareTextAsFile(
        content: jsonStr,
        fileName: fileName,
        subject: 'LMStory Data Export',
        sharePositionOrigin: shareOrigin,
      );
      if (savedPath != null && context.mounted) {
        await showFileSavedDialog(context, savedPath);
      }
    } catch (e) {
      if (context.mounted) {
        _showError(
          context,
          Translations.of(context).settings.data.exportFailed(
                error: e.toString(),
              ),
        );
      }
    }
  }

  // ==================== 导入 ====================

  Future<void> _importData(BuildContext context) async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['json'],
      );
      if (result == null || result.files.isEmpty) return;

      final picked = result.files.single;
      // Web 平台 picked.path 为 null，使用 bytes 读取；
      // 原生平台优先使用 path 读取文件。
      String content;
      if (kIsWeb) {
        final bytes = picked.bytes;
        if (bytes == null) return;
        //  修复：必须按 UTF-8 解码。此前
        // String.fromCharCodes 把 UTF-8 字节当码点，中文内容在 Web 端
        // 导入必然乱码（同库 log_tail_reader 已修过同类 bug）。
        content = utf8.decode(bytes, allowMalformed: true);
      } else {
        final filePath = picked.path;
        if (filePath == null) return;
        content = await _readFileContent(filePath);
      }

      if (!context.mounted) return;
      await _importContent(context, content);
    } catch (e) {
      if (context.mounted) {
        _showError(
          context,
          Translations.of(context).settings.data.importFailed(
                error: e.toString(),
              ),
        );
      }
    }
  }

  /// 导入主链（内容串驱动）——文件选择与
  /// 「从备份恢复」（listBackups/listPreImportSnapshots 读本地文件）
  /// 两条入口共用； 快照/ 二次确认/ 版本守卫全继承。
  Future<void> _importContent(BuildContext context, String content) async {
    final t = Translations.of(context);

    // 快照失败标志提到 try 外（catch 分支需要区分失败原因）
    var snapshotFailed = false;
    try {
      // 深度粗检先于预检 jsonDecode（与导入主链同口径）：极深内容若先走
      // 预检解码会栈溢出成晦涩的 Stack Overflow 文案，提前以主链同句拒绝。
      final previewSource =
          content.startsWith('\uFEFF') ? content.substring(1) : content;
      if (exceedsMaxDepth(previewSource)) {
        if (!context.mounted) return;
        _showError(
          context,
          t.settings.data.importFailed(
            error: DataManagementService.depthLimitMessage,
          ),
        );
        return;
      }
      //  修复：版本守卫 + 备份规模预检。
      // 此前只判 ==2，未来版本的备份会被当 v1 静默解析成空会话；
      // 单会话备份选覆盖会清空全库再灌 1 个会话，需二次确认。
      Map<String, dynamic>? previewMap;
      var backupSessionCount = 0;
      try {
        final decoded = jsonDecode(previewSource);
        if (decoded is Map<String, dynamic>) {
          previewMap = decoded;
          final sessions = decoded['sessions'];
          if (sessions is List) backupSessionCount = sessions.length;
        } else if (decoded is List) {
          backupSessionCount = decoded.length;
        }
      } on FormatException {
        // 非法 JSON 交给 importBackup 走既有错误路径
      }
      if (previewMap != null && previewMap.containsKey('version')) {
        final version = previewMap['version'];
        if (version is int && version > DataManagementService.backupVersion) {
          if (!context.mounted) return;
          _showError(
            context,
            t.settings.data.repairSchema.importVersionTooNew(version: version),
          );
          return;
        }
      }

      // 检测备份是否携带 API Key——口径见
      // [detectBackupContainsSecrets]（v3 contains_secrets 标记 +
      // api_key/apiKey 兜底扫描）
      final backupContainsSecrets = detectBackupContainsSecrets(previewMap);

      if (!context.mounted) return;
      final sheetResult = await ImportModeSheet.show(
        context,
        backupSessionCount: backupSessionCount,
        backupContainsSecrets: backupContainsSecrets,
      );
      if (sheetResult == null || !context.mounted) return;
      final mode = sheetResult.mode;

      //  修复：单会话（或空）备份 + 覆盖模式 = 清空全库再灌入极少数据，
      // 泛化警告不足以拦截，追加一次明确的二次确认。
      // 不含会话键的纯配置备份（count=0）
      // 覆盖时 _importV2 不触碰会话——对最无害的覆盖不再给最吓人的确认。
      if (mode == ImportMode.overwrite &&
          backupSessionCount > 0 &&
          backupSessionCount <= 1) {
        final confirmed = await _confirmOverwriteSingleBackup(
          context,
          backupSessionCount,
        );
        if (!confirmed || !context.mounted) return;
      }

      final service = ref.read(dataManagementServiceProvider);
      // 覆盖导入前置自动快照——服务层保证快照先于
      // 任何删除、失败即中止（fail-closed）；空库返回 null（无物可保护）。
      // web 无本地备份目录（与自动备份区段隐藏一致），跳过快照。
      String? preImportSnapshotName;
      // 导入进度反馈：大备份/慢存储时导入耗时可观，无反馈会让用户
      // 以为无状态导入而离开页面（用户实测反馈）。弹层不可关闭，
      // 同时挡住返回键——导入期间不会误退。
      if (!context.mounted) return;
      _showImportProgress(t.settings.data.importing);
      final importResult = await _runWithProgress(
        () => service.importBackup(
          content,
          mode,
          importApiKeys: sheetResult.importApiKeys,
          preImportSnapshot: mode == ImportMode.overwrite && !kIsWeb
              ? () async {
                  try {
                    final snapshot = await ref
                        .read(autoBackupManagerProvider)
                        .createPreImportSnapshot();
                    preImportSnapshotName = snapshot?.uri.pathSegments.last;
                  } catch (e) {
                    snapshotFailed = true;
                    rethrow;
                  }
                }
              : null,
        ),
      );

      if (!context.mounted) return;
      _showImportSummary(
        importResult,
        preImportSnapshotName: preImportSnapshotName,
        backupContainsSecrets: backupContainsSecrets,
        importApiKeys: sheetResult.importApiKeys,
      );

      setState(_reloadStats);
    } catch (e) {
      if (context.mounted) {
        _showError(
          context,
          snapshotFailed
              ? t.settings.data.importMode.snapshotFailed(error: e.toString())
              : t.settings.data.importFailed(error: e.toString()),
        );
      }
    }
  }

  /// 执行导入并在结束（含失败）时撤除进度弹层
  Future<T> _runWithProgress<T>(Future<T> Function() run) async {
    try {
      return await run();
    } finally {
      _hideImportProgress();
    }
  }

  /// 导入进度弹层：不可关闭（点遮罩/返回键均不退），导入期间挡住页面
  void _showImportProgress(String message) {
    _importProgressDismissed = false;
    showLmDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) {
        _dismissImportProgress = () {
          if (dialogContext.mounted) Navigator.of(dialogContext).pop();
        };
        // 弹层 builder 在下一帧才执行；若导入在首帧前就同步失败/完成，
        // _hideImportProgress 已先跑过（此时回调还是 null），补一道迟到
        // 关闭——否则不可关闭弹层构建后永久滞留，只能重启应用。
        if (_importProgressDismissed) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (dialogContext.mounted) Navigator.of(dialogContext).pop();
          });
        }
        return PopScope(
          canPop: false,
          child: AlertDialog(
            content: Row(
              children: [
                const SizedBox(
                  width: 24,
                  height: 24,
                  child: CircularProgressIndicator(strokeWidth: 3),
                ),
                const SizedBox(width: SimpleSpacing.sMd),
                Expanded(child: Text(message)),
              ],
            ),
          ),
        );
      },
    );
  }

  void _hideImportProgress() {
    _importProgressDismissed = true;
    _dismissImportProgress?.call();
    _dismissImportProgress = null;
  }

  /// 读取文件内容（原生平台）
  ///
  /// 使用条件导入避免 web 平台引入 dart:io。
  Future<String> _readFileContent(String path) {
    return readFileContentNative(path);
  }

  ///  修复：单会话备份 + 覆盖模式的二次确认
  Future<bool> _confirmOverwriteSingleBackup(
    BuildContext context,
    int sessionCount,
  ) async {
    final t = Translations.of(context);
    final confirmed = await showLmDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(t.settings.data.repairSchema.importOverwriteSingleTitle),
        content: Text(
          t.settings.data.repairSchema.importOverwriteSingleBody(
            n: sessionCount,
            count: sessionCount,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(t.common.cancel),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: ctx.lm.palette.error,
            ),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(t.common.confirm),
          ),
        ],
      ),
    );
    return confirmed ?? false;
  }

  /// 导入摘要弹窗。
  ///
  /// Key 提示按实际选择切换三档口径，不再无条件说
  /// 「API Key 不随备份保存」（与  含 Key 备份语义矛盾）——
  /// - 勾选导入且备份含 Key：确认已覆盖本机密钥（success，无「去填写」）
  /// - 备份含 Key 但未勾选：告知本机密钥未变 + 重新导入路径
  /// - 备份不含 Key：维持原「需重新填写」提醒
  void _showImportSummary(
    ImportResult result, {
    required bool backupContainsSecrets,
    required bool importApiKeys,
    String? preImportSnapshotName,
  }) {
    final t = Translations.of(context);
    final colors = context.lm.palette;
    // 实际写入为准（追加模式下供应商全部已存在被跳过时不写 Key，
    // 此前按勾选宣称「已导入并覆盖」误导排查）
    final keysImported = result.importedApiKeys > 0;

    showLmDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(
          t.settings.data.importSuccess,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (result.importedPresets > 0 || result.skippedPresets > 0)
                Text(
                  t.settings.data.importSummary.presets(
                    imported: result.importedPresets,
                    skipped: result.skippedPresets,
                  ),
                  style: SimpleTextStyles.bodySm,
                ),
              if (result.importedPresets > 0 || result.skippedPresets > 0)
                const SizedBox(height: 4),
              if (result.importedSessions > 0 ||
                  result.skippedSessions > 0) ...[
                Text(
                  t.settings.data.importSummary.sessions(
                    imported: result.importedSessions,
                    skipped: result.skippedSessions,
                  ),
                  style: SimpleTextStyles.bodySm,
                ),
                const SizedBox(height: 4),
              ],
              if (result.importedMessages > 0)
                Text(
                  t.settings.data.importSummary.messages(
                    imported: result.importedMessages,
                  ),
                  style: SimpleTextStyles.bodySm,
                ),
              if (result.importedPreferences > 0 ||
                  result.skippedPreferences > 0) ...[
                const SizedBox(height: 4),
                Text(
                  t.settings.data.importSummary.preferences(
                    imported: result.importedPreferences,
                    skipped: result.skippedPreferences,
                  ),
                  style: SimpleTextStyles.bodySm,
                ),
              ],
              // v3 全局资产行（角色卡/世界书/自建模板/事件日志）
              if (result.importedAssets > 0) ...[
                const SizedBox(height: 4),
                Text(
                  t.settings.data.importSummary.assets(
                    imported: result.importedAssets,
                  ),
                  style: SimpleTextStyles.bodySm,
                ),
              ],
              // 导入前快照行——告知回滚路径
              if (preImportSnapshotName != null) ...[
                const SizedBox(height: 8),
                Row(
                  children: [
                    Icon(
                      Icons.history_outlined,
                      size: 14,
                      color: colors.success,
                    ),
                    const SizedBox(width: SimpleSpacing.s2xs),
                    Expanded(
                      child: Text(
                        t.settings.data.importMode.snapshotCreated(
                          fileName: preImportSnapshotName,
                        ),
                        style: SimpleTextStyles.bodySm.copyWith(
                          color: colors.success,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
              // 供应商已恢复提示 + 直达链接； 起按
              // 备份是否含 Key / 是否勾选导入切换三档文案
              if (result.importedPresets > 0) ...[
                const SizedBox(height: 8),
                Row(
                  children: [
                    Icon(
                      keysImported
                          ? Icons.key_outlined
                          : Icons.key_off_outlined,
                      size: 14,
                      color: keysImported ? colors.success : colors.warning,
                    ),
                    const SizedBox(width: SimpleSpacing.s2xs),
                    Expanded(
                      child: Text(
                        keysImported
                            ? t.settings.data.importSummary.apiKeyImportedNotice
                            : backupContainsSecrets
                                ? t.settings.data.importSummary
                                    .apiKeyNotImportedNotice
                                : t.settings.data.importSummary.apiKeyReminder,
                        style: SimpleTextStyles.bodySm.copyWith(
                          color: keysImported ? colors.success : colors.warning,
                        ),
                      ),
                    ),
                    // 已导入 Key 无须再填写，不给误导性的「去填写」入口
                    if (!keysImported)
                      TextButton(
                        onPressed: () {
                          Navigator.of(ctx).pop();
                          Navigator.of(context).push(
                            MaterialPageRoute<void>(
                              builder: (_) => const ProviderListPage(),
                            ),
                          );
                        },
                        child: Text(t.settings.data.importSummary.goProviders),
                      ),
                  ],
                ),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text(
              t.common.confirm,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }

  // ==================== 数据恢复 ====================

  Future<void> _recoverData(BuildContext context) async {
    final t = Translations.of(context);
    final service = ref.read(dataManagementServiceProvider);

    // 1. 扫描
    List<OrphanMessageGroup> groups;
    try {
      groups = await service.scanOrphanMessages();
    } catch (e) {
      if (context.mounted) {
        _showError(
          context,
          t.settings.data.recovery.scanFailed(error: e.toString()),
        );
      }
      return;
    }

    if (!context.mounted) return;

    if (groups.isEmpty) {
      _showInfo(context, t.settings.data.recovery.noOrphan);
      return;
    }

    // 2. 展示结果并询问是否恢复
    final totalMessages = groups.fold<int>(0, (s, g) => s + g.messageCount);
    final confirmed = await showLmDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(
          t.settings.data.recovery.title,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        content: Text(
          t.settings.data.recovery.foundOrphan(
            groups: groups.length,
            messages: totalMessages,
          ),
          maxLines: 5,
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(
              t.common.cancel,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(
              t.settings.data.recovery.recover,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );

    if (confirmed != true || !context.mounted) return;

    // 3. 执行恢复
    try {
      final recovered = await service.recoverOrphanMessages(groups);
      if (!context.mounted) return;
      _showInfo(
        context,
        t.settings.data.recovery.recovered(
          n: recovered.length,
          count: recovered.length,
        ),
      );
      setState(_reloadStats);
    } catch (e) {
      if (context.mounted) {
        _showError(
          context,
          t.settings.data.recovery.failed(error: e.toString()),
        );
      }
    }
  }

  // ==================== 修复表结构 ====================

  Future<void> _confirmRepairSchema(BuildContext context) async {
    final t = Translations.of(context);

    // 二次确认：提示用户先备份
    final confirmed = await showLmDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(
          t.settings.data.repairSchema.title,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        content: Text(
          t.settings.data.repairSchema.confirm,
          maxLines: 5,
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(
              t.common.cancel,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(
              t.common.confirm,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );

    if (confirmed != true || !context.mounted) return;

    try {
      final service = ref.read(dataManagementServiceProvider);
      final result = await service.repairDatabaseSchema();
      if (!context.mounted) return;

      // 展示修复结果
      _showRepairResult(context, result);
      setState(_reloadStats);
    } catch (e) {
      if (context.mounted) {
        _showError(
          context,
          t.settings.data.repairSchema.failed(error: e.toString()),
        );
      }
    }
  }

  /// 展示修复结果详情
  void _showRepairResult(BuildContext context, SchemaRepairResult result) {
    final t = Translations.of(context);

    if (result.isNoOp) {
      _showInfo(context, t.settings.data.repairSchema.noChange);
      return;
    }

    // 构建详细报告
    final parts = <String>[];

    if (result.createdTables.isNotEmpty) {
      parts.add(
        t.settings.data.repairSchema
            .createdTables(count: result.createdTables.length),
      );
      for (final table in result.createdTables) {
        parts.add('  • $table');
      }
    }

    if (result.addedColumns.isNotEmpty) {
      parts.add(
        t.settings.data.repairSchema
            .addedColumns(count: result.addedColumns.length),
      );
      for (final col in result.addedColumns) {
        parts.add('  • $col');
      }
    }

    //  修复：ALTER 失败不再静默——向用户暴露半迁移状态
    if (result.failedColumns.isNotEmpty) {
      parts.add(
        t.settings.data.repairSchema
            .failedColumns(count: result.failedColumns.length),
      );
      for (final col in result.failedColumns) {
        parts.add('  • $col');
      }
    }

    parts.add(
      t.settings.data.repairSchema
          .versionUpdated(version: result.updatedSchemaVersion),
    );

    showLmDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(
          t.settings.data.repairSchema.successTitle,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        content: SingleChildScrollView(
          child: Text(parts.join('\n')),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text(
              t.common.confirm,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }

  // ==================== 清除 ====================

  Future<void> _confirmClearAll(BuildContext context) async {
    final t = Translations.of(context);
    final colors = context.lm.palette;

    final confirmed = await showLmDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(
          t.settings.data.clearAll,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        content: Text(
          t.settings.data.clearConfirm,
          maxLines: 5,
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(
              t.common.cancel,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: TextButton.styleFrom(foregroundColor: colors.error),
            child: Text(
              t.common.confirm,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );

    if (confirmed != true || !context.mounted) return;

    try {
      final service = ref.read(dataManagementServiceProvider);
      await service.clearAllConversations();
      if (!context.mounted) return;
      _showInfo(context, t.settings.data.clearSuccess);
      setState(_reloadStats);
    } catch (e) {
      if (context.mounted) _showError(context, t.settings.data.clearFailed);
    }
  }

  // ==================== 反馈 ====================

  void _showInfo(BuildContext context, String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        behavior: SnackBarBehavior.floating,
        content: Text(
          message,
          maxLines: 3,
          overflow: TextOverflow.ellipsis,
        ),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  void _showError(BuildContext context, String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        behavior: SnackBarBehavior.floating,
        content: Text(
          message,
          maxLines: 3,
          overflow: TextOverflow.ellipsis,
        ),
      ),
    );
  }
}

// ==================== 自动备份区段 ====================

/// 自动备份开关 + 立即备份 / 打开备份目录入口。
///
/// 开关状态存用户偏好（缺省开启）；备份文件在应用文档目录 backups/，
/// 滚动保留最近 3 份，默认不含 API Key。仅原生平台渲染（Web 无
/// path_provider）。
class _AutoBackupSection extends ConsumerStatefulWidget {
  const _AutoBackupSection({required this.onRestore});

  /// 「从备份恢复」选中的文件内容交给页面导入主链
  ///（快照/ 二次确认/ 版本守卫全继承）。
  final Future<void> Function(String content) onRestore;

  @override
  ConsumerState<_AutoBackupSection> createState() => _AutoBackupSectionState();
}

class _AutoBackupSectionState extends ConsumerState<_AutoBackupSection> {
  /// null = 读取中（开关禁用态）
  bool? _enabled;
  bool _backing = false;

  /// 状态行数据——最近成功（首备份文件 mtime）与
  /// 最近失败（lastFailureKey）。
  DateTime? _lastSuccessAt;
  String? _lastFailure;

  @override
  void initState() {
    super.initState();
    _loadEnabled();
    _loadStatus();
  }

  Future<void> _loadEnabled() async {
    final enabled = await ref.read(autoBackupManagerProvider).isEnabled();
    if (mounted) setState(() => _enabled = enabled);
  }

  Future<void> _loadStatus() async {
    try {
      final manager = ref.read(autoBackupManagerProvider);
      final backups = await manager.listBackups();
      DateTime? successAt;
      if (backups.isNotEmpty) {
        successAt = backups.first.lastModifiedSync();
      }
      String? failure;
      try {
        final overrides =
            await ref.read(settingsRepositoryProvider).getUserOverrides();
        failure = overrides[AutoBackupManager.lastFailureKey] as String?;
      } catch (_) {}
      if (mounted) {
        setState(() {
          _lastSuccessAt = successAt;
          _lastFailure = failure;
        });
      }
    } catch (_) {
      // 状态行是辅助信息，读取失败静默
    }
  }

  Future<void> _toggle(bool value) async {
    setState(() => _enabled = value);
    await ref.read(autoBackupManagerProvider).setEnabled(enabled: value);
  }

  Future<void> _backupNow() async {
    if (_backing) return;
    setState(() => _backing = true);
    try {
      final file =
          await ref.read(autoBackupManagerProvider).runIfNeeded(force: true);
      // 手动备份也写成功/失败偏好键——立即刷新状态行（时间戳/失败行），
      // 此前须重进页面才见真值
      await _loadStatus();
      if (!mounted) return;
      final t = Translations.of(context);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          behavior: SnackBarBehavior.floating,
          content: Text(
            file != null
                ? t.settings.data.autoBackup.done
                : t.settings.data.autoBackup.failed,
          ),
        ),
      );
    } finally {
      if (mounted) setState(() => _backing = false);
    }
  }

  String _formatBackupTime(DateTime time) {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${time.year}-'
        '${two(time.month)}-'
        '${two(time.day)} '
        '${two(time.hour)}:'
        '${two(time.minute)}';
  }

  /// 备份/快照列表 sheet → 宽容读 → 页面导入
  /// 主链（版本守卫/ 快照/二次确认全继承）。
  Future<void> _restoreFromBackup() async {
    final t = Translations.of(context);
    final manager = ref.read(autoBackupManagerProvider);
    try {
      final backups = await manager.listBackups();
      final snapshots = await manager.listPreImportSnapshots();
      if (!mounted) return;
      if (backups.isEmpty && snapshots.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            behavior: SnackBarBehavior.floating,
            content: Text(t.settings.data.autoBackup.nothingToRestore),
          ),
        );
        return;
      }
      final picked = await showLmSheet<File>(
        context: context,
        builder: (ctx) => SafeArea(
          child: ListView(
            children: [
              Padding(
                padding: const EdgeInsets.all(SimpleSpacing.sMd),
                child: Text(
                  t.settings.data.autoBackup.restoreSheetTitle,
                  style: SimpleTextStyles.title3,
                ),
              ),
              if (backups.isNotEmpty) ...[
                _restoreSectionHeader(
                  t.settings.data.autoBackup.restoreSectionBackups,
                ),
                for (final file in backups)
                  _restoreTile(ctx, file, subtitle: _fileSubtitle(file)),
              ],
              if (snapshots.isNotEmpty) ...[
                _restoreSectionHeader(
                  t.settings.data.autoBackup.restoreSectionSnapshots,
                ),
                for (final file in snapshots)
                  _restoreTile(ctx, file, subtitle: _fileSubtitle(file)),
              ],
              const SizedBox(height: SimpleSpacing.sMd),
            ],
          ),
        ),
      );
      if (picked == null || !mounted) return;
      final content = await readFileTextLenientNative(picked.path);
      if (content.isEmpty) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            behavior: SnackBarBehavior.floating,
            content: Text(t.settings.data.autoBackup.restoreReadFailed),
          ),
        );
        return;
      }
      await widget.onRestore(content);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            behavior: SnackBarBehavior.floating,
            content: Text(t.settings.data.autoBackup.restoreReadFailed),
          ),
        );
      }
    }
  }

  String _fileSubtitle(File file) {
    final kb = (file.lengthSync() / 1024).round();
    return '${_formatBackupTime(file.lastModifiedSync())} · ${kb}KB';
  }

  Widget _restoreSectionHeader(String title) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        SimpleSpacing.sMd,
        SimpleSpacing.sXs,
        SimpleSpacing.sMd,
        0,
      ),
      child: Text(title, style: SimpleTextStyles.bodySm),
    );
  }

  Widget _restoreTile(BuildContext ctx, File file, {required String subtitle}) {
    final name = file.path.split(Platform.pathSeparator).last;
    return ListTile(
      leading: const Icon(Icons.description_outlined, size: 20),
      title: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(subtitle, maxLines: 1, overflow: TextOverflow.ellipsis),
      onTap: () => Navigator.of(ctx).pop(file),
    );
  }

  Future<void> _openFolder() async {
    final t = Translations.of(context);
    final manager = ref.read(autoBackupManagerProvider);
    var path = '';
    try {
      path = (await manager.backupsDirectory()).path;
    } on Exception catch (_) {
      // 目录不可用（极端文件系统异常）：路径留空走弹窗占位
    }
    var opened = false;
    if (path.isNotEmpty) {
      try {
        opened = await launchUrl(Uri.file(path));
      } on Exception catch (_) {
        // 移动端文件管理器普遍不收 file:// 目录：回退弹窗展示路径
      }
    }
    if (opened || !mounted) return;
    // 回退：复制路径 + 弹窗展示（桌面资源管理器打不开时同样兜底）。
    // 移动端该目录几乎必然打不开（file:// 目录 URI 不被文件管理器接受），
    // 弹窗必须说明「看不到是正常现象」并指路导出/导入，否则用户会在
    // 文件管理器里徒劳地找这个路径。
    await Clipboard.setData(ClipboardData(text: path));
    if (!mounted) return;
    await showLmDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(t.settings.data.autoBackup.pathLabel),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SelectableText(path.isEmpty ? '-' : path),
            const SizedBox(height: SimpleSpacing.sMd),
            Text(
              t.settings.data.autoBackup.pathSandboxNote,
              style: SimpleTextStyles.bodySm,
            ),
            const SizedBox(height: SimpleSpacing.sXs),
            Text(
              t.settings.data.autoBackup.pathMigrationTip,
              style: SimpleTextStyles.bodySm,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text(t.common.close),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = Translations.of(context);
    final colors = context.lm.palette;

    return Container(
      decoration: BoxDecoration(
        color: colors.surfaceVariant,
        borderRadius: BorderRadius.circular(context.lmUi.radius(LmCorner.md)),
      ),
      padding: const EdgeInsets.symmetric(
        horizontal: SimpleSpacing.sMd,
        vertical: SimpleSpacing.sXs,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Material 包裹：Container 背景色会遮住 ListTile 的墨水涟漪
          // （debug 断言 ListTile background color may be invisible），
          // 透明 Material 让 SwitchListTile 自带绘制层（测试接线时修复）。
          Material(
            type: MaterialType.transparency,
            child: SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: _enabled ?? false,
              onChanged: _enabled == null ? null : _toggle,
              title: Text(
                t.settings.data.autoBackup.title,
                style: SimpleTextStyles.title3,
              ),
              subtitle: Text(
                t.settings.data.autoBackup.desc,
                style: SimpleTextStyles.bodySm,
              ),
            ),
          ),
          // 行为说明——口径与 AutoBackupManager
          // 实际行为一致（启动检查 / >24h / 有会话数据 / backups/ / 无 Key / 3 份）
          Padding(
            padding: const EdgeInsets.only(bottom: SimpleSpacing.sXs),
            child: Text(
              t.settings.data.autoBackup.hint,
              style: SimpleTextStyles.caption.copyWith(
                color: colors.muted,
              ),
            ),
          ),
          // 醒目提示：备份目录在应用私有存储内、文件管理器不可见，
          // 迁移数据走「导出数据」——用户反馈在此徒劳找目录的高频困惑点
          Padding(
            padding: const EdgeInsets.only(bottom: SimpleSpacing.sXs),
            child: Text(
              // 桌面备份目录在「文档」根（可见），移动端在应用私有存储
              //（不可见）——同一句提示在桌面与用户所见直接矛盾
              switch (defaultTargetPlatform) {
                // macOS 沙盒容器路径与「文档」目录不同，单独口径
                TargetPlatform.macOS =>
                  t.settings.data.autoBackup.sandboxNoticeMacos,
                TargetPlatform.windows ||
                TargetPlatform.linux =>
                  t.settings.data.autoBackup.sandboxNoticeDesktop,
                _ => t.settings.data.autoBackup.sandboxNotice,
              },
              style: SimpleTextStyles.caption.copyWith(
                color: colors.warning,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          // 状态行——失败优先（warning 色），否则显示
          // 上次成功时间（listBackups 首文件 mtime 即事实源）。
          if (_lastFailure != null)
            Padding(
              padding: const EdgeInsets.only(bottom: SimpleSpacing.sXs),
              child: Text(
                t.settings.data.autoBackup.lastFailedAt(
                  // 失败键值=「ISO|runtimeType」——时间与成功行同款格式化
                  time: _formatBackupTime(
                    DateTime.parse(_lastFailure!.split('|').first),
                  ),
                ),
                style: SimpleTextStyles.caption.copyWith(
                  color: colors.warning,
                ),
              ),
            )
          else if (_lastSuccessAt != null)
            Padding(
              padding: const EdgeInsets.only(bottom: SimpleSpacing.sXs),
              child: Text(
                t.settings.data.autoBackup.lastSuccessAt(
                  time: _formatBackupTime(_lastSuccessAt!),
                ),
                style: SimpleTextStyles.caption.copyWith(
                  color: colors.muted,
                ),
              ),
            ),
          // Wrap 而非 Row：窄屏（手机竖屏）三个按钮放不下会溢出，
          // 放不下时自动换行（Row 会 RenderFlex overflow）
          Wrap(
            spacing: SimpleSpacing.sXs,
            runSpacing: SimpleSpacing.sXs,
            children: [
              TextButton.icon(
                onPressed: _backing ? null : _backupNow,
                icon: _backing
                    ? const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.backup_outlined, size: 18),
                label: Text(t.settings.data.autoBackup.backupNow),
              ),
              TextButton.icon(
                onPressed: _openFolder,
                icon: const Icon(Icons.folder_open_outlined, size: 18),
                label: Text(t.settings.data.autoBackup.openFolder),
              ),
              // 从备份恢复入口
              TextButton.icon(
                onPressed: _restoreFromBackup,
                icon: const Icon(Icons.restore, size: 18),
                label: Text(t.settings.data.autoBackup.restoreFromBackup),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// ==================== 数据操作卡片 ====================

class _DataCard extends StatelessWidget {
  const _DataCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.titleColor,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  final Color? titleColor;

  @override
  Widget build(BuildContext context) {
    final colors = context.lm.palette;
    final effectiveTitleColor = titleColor ?? colors.primary;

    return context.lmUi.card(
      context,
      onTap: onTap,
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: titleColor == null
                  ? colors.surface
                  : effectiveTitleColor.withValues(alpha: 0.12),
              borderRadius:
                  BorderRadius.circular(context.lmUi.radius(LmCorner.md)),
            ),
            child: Icon(
              icon,
              color: effectiveTitleColor,
              size: 22,
            ),
          ),
          const SizedBox(width: SimpleSpacing.sMd),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: LmNarrativeTextStyles.narrativeDisplay.copyWith(
                    fontSize: 20,
                    height: 1.35,
                    color: titleColor ?? colors.ink,
                    fontWeight: FontWeight.w500,
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  style: SimpleTextStyles.caption.copyWith(
                    color: colors.muted,
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          Icon(
            Icons.chevron_right,
            color: colors.faint,
            size: 20,
          ),
        ],
      ),
    );
  }
}

// ==================== 存储信息 ====================

class _StorageInfoSection extends StatelessWidget {
  const _StorageInfoSection({required this.statsFuture});

  final Future<StorageStats>? statsFuture;

  @override
  Widget build(BuildContext context) {
    final t = Translations.of(context);

    return context.lmUi.card(
      context,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SectionHeading(title: t.settings.data.storageInfo.title),
          const SizedBox(height: SimpleSpacing.sMd),
          FutureBuilder<StorageStats>(
            future: statsFuture,
            builder: (context, snapshot) {
              if (snapshot.connectionState != ConnectionState.done) {
                return const Padding(
                  padding: EdgeInsets.symmetric(vertical: SimpleSpacing.sMd),
                  child: Center(
                    child: SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  ),
                );
              }
              if (snapshot.hasError || snapshot.data == null) {
                return _StorageInfoRow(
                  label: t.settings.data.storageInfo.dbSize,
                  value: t.settings.data.storageInfo.placeholder,
                );
              }
              final stats = snapshot.data!;
              return Column(
                children: [
                  _StorageInfoRow(
                    label: t.settings.data.storageInfo.dbSize,
                    value: stats.dbSizeFormatted,
                    prominent: true,
                  ),
                  const SizedBox(height: SimpleSpacing.sSm),
                  _StorageInfoRow(
                    label: t.settings.data.storageInfo.sessionCount,
                    value: '${stats.sessionCount}',
                  ),
                  const SizedBox(height: SimpleSpacing.sSm),
                  _StorageInfoRow(
                    label: t.settings.data.storageInfo.messageCount,
                    value: '${stats.messageCount}',
                  ),
                  const SizedBox(height: SimpleSpacing.sSm),
                  _StorageInfoRow(
                    label: t.settings.data.storageInfo.presetCount,
                    value: '${stats.presetCount}',
                  ),
                  const SizedBox(height: SimpleSpacing.sSm),
                  _StorageInfoRow(
                    label: t.settings.data.storageInfo.templateCount,
                    value: '${stats.templateCount}',
                  ),
                  const SizedBox(height: SimpleSpacing.sSm),
                  _StorageInfoRow(
                    label: t.settings.data.storageInfo.preferenceCount,
                    value: '${stats.preferenceCount}',
                  ),
                  const SizedBox(height: SimpleSpacing.sSm),
                  // 稿件变体膨胀可见（变体含正文/
                  // 思考/锚快照；与  删除链修复配合）
                  if (stats.variantCount > 0) ...[
                    _StorageInfoRow(
                      label: t.settings.data.storageInfo.variantCount,
                      value: '${stats.variantCount}',
                    ),
                    const SizedBox(height: SimpleSpacing.sSm),
                  ],
                  // 批 I：事件日志膨胀可见——滚动保留
                  // 上限（advanced.harness.event_log_retention_turns）约束
                  _StorageInfoRow(
                    label: t.settings.data.storageInfo.agentEvents,
                    value: stats.agentEventCount > 0
                        ? t.settings.data.storageInfo.agentEventsValue(
                            count: stats.agentEventCount,
                            size: stats.agentEventSizeFormatted,
                          )
                        : '--',
                  ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }
}

class _StorageInfoRow extends StatelessWidget {
  const _StorageInfoRow({
    required this.label,
    required this.value,
    this.prominent = false,
  });
  final String label;
  final String value;
  final bool prominent;

  @override
  Widget build(BuildContext context) =>
      LabeledValue(label: label, value: value, prominent: prominent);
}
