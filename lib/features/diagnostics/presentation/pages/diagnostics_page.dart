import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lmstory/core/meta/app_meta.dart';
import 'package:lmstory/core/theme/api/lm_component_kit.dart';
import 'package:lmstory/core/theme/shared/components/labeled_value.dart';
import 'package:lmstory/core/theme/shared/components/section_heading.dart';
import 'package:lmstory/core/theme/simple/simple_spacing.dart';
import 'package:lmstory/core/theme/simple/simple_text_styles.dart';
import 'package:lmstory/core/theme/system/lm_layout.dart';
import 'package:lmstory/core/theme/system/lm_overlays.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';
import 'package:lmstory/core/utils/debug_log_options.dart';
import 'package:lmstory/core/utils/file_share.dart'
    if (dart.library.html) 'package:lmstory/core/utils/file_share_web.dart';
import 'package:lmstory/core/utils/log_file_ops.dart'
    if (dart.library.html) 'package:lmstory/core/utils/log_file_ops_web.dart';
import 'package:lmstory/core/utils/logger.dart';
import 'package:lmstory/core/widgets/file_saved_dialog.dart';
import 'package:lmstory/features/advanced/presentation/pages/agent_loop_diagnostics_page.dart';
import 'package:lmstory/features/advanced/presentation/pages/agent_round_trace_entry_page.dart';
import 'package:lmstory/features/diagnostics/presentation/controllers/diagnostics_controller.dart';
import 'package:lmstory/features/diagnostics/presentation/widgets/failure_history_widget.dart';
import 'package:lmstory/features/diagnostics/presentation/widgets/log_viewer_widget.dart';
import 'package:lmstory/i18n/strings.g.dart';
import 'package:share_plus/share_plus.dart';

/// 诊断信息页面
///
/// 集中展示运行日志 + 失败历史 + 日志级别控制 + 调试日志开关，便于真机测试时排查问题。
///
/// 6 个分组（参考 data_management_page 的卡片风格，含 Agent Loop 自检入口卡）：
/// 1. 状态概览：失败记录数 + 当前日志级别 + 快速操作（分享/清空）
/// 2. 日志级别切换：4 个 ChoiceChip，存 Preferences 立即生效
/// 3. 调试日志开关：5 个 CheckboxListTile（Stage 5），控制中级模式详细字段记录
/// 4. 运行日志：FileLogSink 文件 tail 500 行，等宽字体着色渲染
/// 5. 失败历史：failure_logs 表最近 50 条，可展开查看技术详情
///
/// 主题：跟随 Simple 主题。视觉规范遵循 impeccable shape brief。
class DiagnosticsPage extends ConsumerStatefulWidget {
  const DiagnosticsPage({super.key});

  @override
  ConsumerState<DiagnosticsPage> createState() => _DiagnosticsPageState();
}

class _DiagnosticsPageState extends ConsumerState<DiagnosticsPage> {
  // 开发者暗门门禁 + 版本行连点计数（2s 窗口，见 DevGateTapCounter）
  bool _devGateUnlocked = false;
  final DevGateTapCounter _gateTaps = DevGateTapCounter();

  @override
  void initState() {
    super.initState();
    // 帧后加载，避免 initState 中触发 provider 状态重建
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(diagnosticsControllerProvider.notifier).load();
      // 读持久化解锁态（解锁过免再点）
      ref
          .read(diagnosticsControllerProvider.notifier)
          .isDevGateUnlocked()
          .then((unlocked) {
        if (mounted) setState(() => _devGateUnlocked = unlocked);
      });
    });
  }

  /// 版本行连点 7 次解锁开发者暗门（两卡条件渲染）；2s 窗口外计数作废
  void _onVersionTap() {
    if (_devGateUnlocked) return;
    if (!_gateTaps.registerTap(DateTime.now())) return;
    ref.read(diagnosticsControllerProvider.notifier).unlockDevGate();
    setState(() => _devGateUnlocked = true);
    final t = Translations.of(context);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        behavior: SnackBarBehavior.floating,
        content: Text(t.settings.diagnostics.devGateUnlockedToast),
      ),
    );
  }

  /// 重新上锁：收回两张开发者卡（与连点解锁对称）
  void _onRelockTap() {
    ref.read(diagnosticsControllerProvider.notifier).lockDevGate();
    setState(() {
      _devGateUnlocked = false;
      _gateTaps.reset();
    });
    final t = Translations.of(context);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        behavior: SnackBarBehavior.floating,
        content: Text(t.settings.diagnostics.devGateLockedToast),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = Translations.of(context);
    final state = ref.watch(diagnosticsControllerProvider);
    final colors = context.lm.palette;

    return Scaffold(
      backgroundColor: context.scaffoldBgOf(colors.bg),
      appBar: context.lmUi.appBar(context, title: t.settings.diagnostics.title),
      body: state.isLoading
          ? const Center(child: CircularProgressIndicator())
          : LmMeasure(
              maxWidth: LmLayout.listMeasure,
              child: ListView(
                padding: const EdgeInsets.all(SimpleSpacing.sLg),
                children: [
                  _OverviewCard(
                    failureCount: state.failureTotal,
                    logLevel: state.logLevel,
                    onShare: () => _shareLog(context),
                    onClear: () => _confirmClear(context),
                  ),
                  const SizedBox(height: SimpleSpacing.sMd),
                  _LogLevelCard(
                    current: state.logLevel,
                    onSelected: (level) => ref
                        .read(diagnosticsControllerProvider.notifier)
                        .setLogLevel(level),
                  ),
                  const SizedBox(height: SimpleSpacing.sMd),
                  _DebugLogOptionsCard(
                    options: state.debugLogOptions,
                    onToggle: (field, value) => ref
                        .read(diagnosticsControllerProvider.notifier)
                        .setDebugLogOption(field, value),
                  ),
                  const SizedBox(height: SimpleSpacing.sMd),
                  // 开发者暗门收门禁（版本行连点 7 次解锁）
                  if (_devGateUnlocked) ...[
                    _AgentLoopEntryCard(
                      onTap: () => _navigateTo(
                        context,
                        const AgentLoopDiagnosticsPage(),
                      ),
                      // 消耗警示：自检真实调用 LLM，耗用户配额
                      subtitleOverride:
                          t.settings.diagnostics.agentLoop.costWarning,
                    ),
                    const SizedBox(height: SimpleSpacing.sMd),
                    // 轮轨迹入口（开发者暗门；原长按入口因并行改动改道于此）
                    _AgentLoopEntryCard(
                      onTap: () => _navigateTo(
                        context,
                        const AgentRoundTraceEntryPage(),
                      ),
                      titleOverride: 'Director Round Trace',
                      iconOverride: Icons.timeline_outlined,
                    ),
                    const SizedBox(height: SimpleSpacing.sMd),
                    _DevGateLockAction(onTap: _onRelockTap),
                  ],
                  SizedBox(
                    height: 320,
                    child: LogViewer(
                      lines: state.logLines,
                      onShare: () => _shareLog(context),
                    ),
                  ),
                  const SizedBox(height: SimpleSpacing.sMd),
                  FailureHistory(failures: state.failures),
                  // 页尾小字版本行（连点 7 次解锁开发者暗门）
                  Padding(
                    padding: const EdgeInsets.only(top: SimpleSpacing.sMd),
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: _onVersionTap,
                      child: Center(
                        child: Text(
                          'LMStory v$kAppVersion',
                          style: SimpleTextStyles.caption.copyWith(
                            color: colors.muted,
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: SimpleSpacing.sXl),
                ],
              ),
            ),
    );
  }

  // ==================== 分享日志 ====================

  Future<void> _shareLog(BuildContext context) async {
    final t = Translations.of(context);
    if (Logger.currentLogFilePath == null) {
      _showInfo(context, t.settings.diagnostics.logs.empty);
      return;
    }

    // 桌面端此前走 share_plus 的 Windows 分享浮层，
    // 真机上浮层不可见时抢占输入导致整页卡死（复现 2 次），改走系统
    // 保存对话框直接落盘（轮转文件一并合并导出）。
    if (switch (defaultTargetPlatform) {
      TargetPlatform.linux ||
      TargetPlatform.macOS ||
      TargetPlatform.windows =>
        true,
      _ => false,
    }) {
      await _saveLogToFile(context);
      return;
    }

    // 脱敏后的日志仍可能含用户主动记录的会话内容与提示词。
    {
      final colors = context.lm.palette;
      final confirmed = await showLmDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(
            t.settings.diagnostics.logs.shareConfirmTitle,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          content: Text(
            t.settings.diagnostics.logs.shareConfirmBody,
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: Text(t.common.cancel),
            ),
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              style: TextButton.styleFrom(foregroundColor: colors.error),
              child: Text(t.settings.diagnostics.logs.shareConfirmAction),
            ),
          ],
        ),
      );
      if (confirmed != true || !context.mounted) return;
    }

    try {
      await withTemporaryLogExport((path) async {
        if (!context.mounted) return;
        await Share.shareXFiles(
          [XFile(path, mimeType: 'text/plain')],
          subject: t.settings.diagnostics.logs.shareSubject,
          sharePositionOrigin: shareOriginFrom(context),
        );
      });
    } catch (_) {
      if (context.mounted) {
        _showInfo(
          context,
          Translations.of(context).settings.diagnostics.logs.shareFailed,
        );
      }
    }
  }

  /// 桌面端日志导出：系统保存对话框选位置 → Isolate 合并落盘 → 成功确认框
  Future<void> _saveLogToFile(BuildContext context) async {
    final timestamp = DateTime.now().toIso8601String().replaceAll(':', '-');
    try {
      final savedPath = await FilePicker.platform.saveFile(
        fileName: 'lmstory_log_$timestamp.log',
        type: FileType.custom,
        allowedExtensions: const ['log'],
      );
      if (savedPath == null || savedPath.isEmpty || !context.mounted) return;
      await saveLogFilesTo(targetPath: savedPath);
      if (context.mounted) await showFileSavedDialog(context, savedPath);
    } catch (e) {
      if (!context.mounted) return;
      _showInfo(
        context,
        Translations.of(context).settings.diagnostics.logs.saveFailed(
              error: e.toString(),
            ),
      );
    }
  }

  // ==================== 清空确认 ====================

  Future<void> _confirmClear(BuildContext context) async {
    final t = Translations.of(context);
    final colors = context.lm.palette;

    final confirmed = await showLmDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(
          t.settings.diagnostics.clear.title,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        content: Text(
          t.settings.diagnostics.clear.confirm,
          maxLines: 5,
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(t.common.cancel),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: TextButton.styleFrom(foregroundColor: colors.error),
            child: Text(t.common.confirm),
          ),
        ],
      ),
    );

    if (confirmed != true || !context.mounted) return;

    try {
      await ref.read(diagnosticsControllerProvider.notifier).clearAll();
      if (!context.mounted) return;
      _showInfo(context, t.settings.diagnostics.clear.success);
    } catch (_) {
      if (!context.mounted) return;
      _showInfo(context, t.settings.diagnostics.clear.failed);
    }
  }

  void _showInfo(BuildContext context, String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 2),
      ),
    );
  }
}

// ==================== 状态概览卡 ====================

Future<void> _navigateTo(BuildContext context, Widget page) async {
  await Navigator.push<void>(
    context,
    MaterialPageRoute(builder: (_) => page),
  );
}

/// Agent Loop 自检入口（v0.3  开发者入口）
class _AgentLoopEntryCard extends StatelessWidget {
  const _AgentLoopEntryCard({
    required this.onTap,
    this.titleOverride,
    this.iconOverride,
    this.subtitleOverride,
  });

  final VoidCallback onTap;

  /// 覆盖标题（开发者入口复用视觉时用；非 null 时绕过 slang）
  final String? titleOverride;

  /// 覆盖图标
  final IconData? iconOverride;

  /// 副标题覆盖（消耗警示）
  final String? subtitleOverride;

  @override
  Widget build(BuildContext context) {
    final t = Translations.of(context);
    final colors = context.lm.palette;

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(context.lmUi.radius(LmCorner.lg)),
      child: Container(
        decoration: BoxDecoration(
          color: colors.surfaceVariant,
          borderRadius: BorderRadius.circular(context.lmUi.radius(LmCorner.lg)),
        ),
        padding: const EdgeInsets.all(SimpleSpacing.sLg),
        child: Row(
          children: [
            Icon(
              iconOverride ?? Icons.smart_toy_outlined,
              color: colors.primary,
            ),
            const SizedBox(width: SimpleSpacing.sMd),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    titleOverride ?? t.settings.diagnostics.agentLoop.title,
                    style: SimpleTextStyles.title3.copyWith(
                      color: colors.ink,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  if (subtitleOverride != null)
                    Text(
                      subtitleOverride!,
                      style: SimpleTextStyles.caption.copyWith(
                        color: colors.warning,
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                ],
              ),
            ),
            Icon(Icons.chevron_right, color: colors.muted),
          ],
        ),
      ),
    );
  }
}

/// 重新上锁动作行（暗门解锁态显示）
///
/// 状态开关而非功能入口——刻意不用卡片容器（避免读作第三张功能卡），
/// 与页尾版本行同级的安静样式：lock 图标 + 说明文字，居中，muted 色，
/// 纵向内边距保证 ≥44dp 触达面积。
class _DevGateLockAction extends StatelessWidget {
  const _DevGateLockAction({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = Translations.of(context);
    final colors = context.lm.palette;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(context.lmUi.radius(LmCorner.md)),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: SimpleSpacing.sMd),
          child: Center(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.lock_outline, size: 16, color: colors.muted),
                const SizedBox(width: SimpleSpacing.sXs),
                Flexible(
                  child: Text(
                    t.settings.diagnostics.devGateRelock,
                    style: SimpleTextStyles.caption.copyWith(
                      color: colors.muted,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _OverviewCard extends StatelessWidget {
  const _OverviewCard({
    required this.failureCount,
    required this.logLevel,
    required this.onShare,
    required this.onClear,
  });

  final int failureCount;
  final LogLevel logLevel;
  final VoidCallback onShare;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    final t = Translations.of(context);
    final colors = context.lm.palette;

    return context.lmUi.card(
      context,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SectionHeading(title: t.settings.diagnostics.overview.title),
          const SizedBox(height: SimpleSpacing.sMd),
          _InfoRow(
            label: t.settings.diagnostics.failures.title,
            value: failureCount == 0
                ? t.settings.diagnostics.overview.noFailures
                : t.settings.diagnostics.overview.failureCount(
                    count: failureCount,
                  ),
            valueColor: failureCount > 0 ? colors.error : colors.ink,
          ),
          const SizedBox(height: SimpleSpacing.sSm),
          _InfoRow(
            label: t.settings.diagnostics.logLevel.title,
            value: _levelLabel(logLevel, t),
          ),
          const SizedBox(height: SimpleSpacing.sLg),
          Wrap(
            spacing: SimpleSpacing.sSm,
            runSpacing: SimpleSpacing.sSm,
            children: [
              _ActionButton(
                icon: Icons.ios_share,
                label: t.settings.diagnostics.logs.share,
                onTap: onShare,
                primary: true,
              ),
              _ActionButton(
                icon: Icons.delete_outline,
                label: t.settings.diagnostics.clear.title,
                onTap: onClear,
                danger: true,
              ),
            ],
          ),
        ],
      ),
    );
  }

  String _levelLabel(LogLevel level, Translations t) {
    final l = t.settings.diagnostics.logLevel;
    return switch (level) {
      LogLevel.debug => l.debug,
      LogLevel.info => l.info,
      LogLevel.warn => l.warn,
      LogLevel.error => l.error,
    };
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({required this.label, required this.value, this.valueColor});
  final String label;
  final String value;
  final Color? valueColor;

  @override
  Widget build(BuildContext context) =>
      LabeledValue(label: label, value: value, valueColor: valueColor);
}

class _ActionButton extends StatelessWidget {
  const _ActionButton({
    required this.icon,
    required this.label,
    required this.onTap,
    this.primary = false,
    this.danger = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool primary;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final colors = context.lm.palette;
    final color =
        danger ? colors.error : (primary ? colors.primary : colors.ink);

    return primary
        ? FilledButton.icon(
            onPressed: onTap,
            icon: Icon(icon, size: 18),
            label: Text(label, maxLines: 2, overflow: TextOverflow.ellipsis),
          )
        : OutlinedButton.icon(
            onPressed: onTap,
            icon: Icon(icon, size: 18),
            label: Text(label, maxLines: 2, overflow: TextOverflow.ellipsis),
            style: OutlinedButton.styleFrom(foregroundColor: color),
          );
  }
}

// ==================== 日志级别切换卡 ====================

class _LogLevelCard extends StatelessWidget {
  const _LogLevelCard({
    required this.current,
    required this.onSelected,
  });

  final LogLevel current;
  final void Function(LogLevel) onSelected;

  @override
  Widget build(BuildContext context) {
    final t = Translations.of(context);
    final colors = context.lm.palette;
    final l = t.settings.diagnostics.logLevel;

    return context.lmUi.card(
      context,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SectionHeading(title: l.title),
          const SizedBox(height: 2),
          Text(
            l.desc,
            style: SimpleTextStyles.caption.copyWith(color: colors.muted),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: SimpleSpacing.sMd),
          Wrap(
            spacing: SimpleSpacing.sSm,
            runSpacing: SimpleSpacing.sXs,
            children: [
              _LevelChip(
                label: l.debug,
                selected: current == LogLevel.debug,
                onSelected: () => onSelected(LogLevel.debug),
              ),
              _LevelChip(
                label: l.info,
                selected: current == LogLevel.info,
                onSelected: () => onSelected(LogLevel.info),
              ),
              _LevelChip(
                label: l.warn,
                selected: current == LogLevel.warn,
                onSelected: () => onSelected(LogLevel.warn),
              ),
              _LevelChip(
                label: l.error,
                selected: current == LogLevel.error,
                onSelected: () => onSelected(LogLevel.error),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _LevelChip extends StatelessWidget {
  const _LevelChip({
    required this.label,
    required this.selected,
    required this.onSelected,
  });

  final String label;
  final bool selected;
  final VoidCallback onSelected;

  @override
  Widget build(BuildContext context) {
    final colors = context.lm.palette;
    return ChoiceChip(
      label: Text(
        label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      selected: selected,
      onSelected: (_) => onSelected(),
      selectedColor: colors.primary.withValues(alpha: 0.15),
      labelStyle: SimpleTextStyles.bodySm.copyWith(
        color: selected ? colors.primary : colors.ink,
        fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
      ),
      backgroundColor: colors.surface,
      side: BorderSide(color: colors.divider),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(context.lmUi.radius(LmCorner.full)),
      ),
      showCheckmark: false,
      visualDensity: VisualDensity.compact,
    );
  }
}

// ==================== 调试日志开关卡（Stage 5）====================

/// 中级模式排障专用：5 个 CheckboxListTile 控制详细字段记录
///
/// 勾选后立即生效（持久化到 Preferences + 同步到 Logger.debugOptions），
/// 中级模式控制器在关键点检查对应开关，按需写入完整提示词/响应/记忆/关键词。
///
/// 默认全关避免日志膨胀；按需开启后下一轮生成即写入。
class _DebugLogOptionsCard extends StatelessWidget {
  const _DebugLogOptionsCard({
    required this.options,
    required this.onToggle,
  });

  final DebugLogOptions options;
  // ignore: avoid_positional_boolean_parameters — 与 setDebugLogOption 签名一致
  final void Function(DebugLogField field, bool value) onToggle;

  @override
  Widget build(BuildContext context) {
    final t = Translations.of(context);
    final colors = context.lm.palette;
    final l = t.settings.diagnostics.debugLog;

    return context.lmUi.card(
      context,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SectionHeading(title: l.title),
          const SizedBox(height: 2),
          Text(
            l.desc,
            style: SimpleTextStyles.caption.copyWith(color: colors.muted),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: SimpleSpacing.sSm),
          _DebugOptionTile(
            title: l.logPrompts,
            subtitle: l.logPromptsDesc,
            value: options.logPrompts,
            onChanged: (v) => onToggle(DebugLogField.prompts, v),
          ),
          _DebugOptionTile(
            title: l.logResponses,
            subtitle: l.logResponsesDesc,
            value: options.logResponses,
            onChanged: (v) => onToggle(DebugLogField.responses, v),
          ),
          _DebugOptionTile(
            title: l.logMemories,
            subtitle: l.logMemoriesDesc,
            value: options.logMemories,
            onChanged: (v) => onToggle(DebugLogField.memories, v),
          ),
          _DebugOptionTile(
            title: l.logKeywords,
            subtitle: l.logKeywordsDesc,
            value: options.logKeywords,
            onChanged: (v) => onToggle(DebugLogField.keywords, v),
          ),
          _DebugOptionTile(
            title: l.logPayloads,
            subtitle: l.logPayloadsDesc,
            value: options.logPayloads,
            onChanged: (v) => onToggle(DebugLogField.payloads, v),
          ),
        ],
      ),
    );
  }
}

class _DebugOptionTile extends StatelessWidget {
  const _DebugOptionTile({
    required this.title,
    required this.subtitle,
    required this.value,
    required this.onChanged,
  });

  final String title;
  final String subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final colors = context.lm.palette;
    // 用 Material 包裹：CheckboxListTile 的 ink splash 画在最近 Material 祖先上，
    // 外层 Container 的背景色会遮挡。透明 Material 让 ink splash 正常显示。
    return Material(
      color: Colors.transparent,
      child: CheckboxListTile(
        value: value,
        // CheckboxListTile.onChanged 期望 ValueChanged<bool?>（禁用/三态时为 null），
        // 这里非 tristate，v != null 时才回调。
        onChanged: (bool? v) {
          if (v != null) onChanged(v);
        },
        title: Text(
          title,
          style: SimpleTextStyles.bodySm.copyWith(
            color: colors.ink,
            fontWeight: FontWeight.w500,
          ),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: Text(
          subtitle,
          style: SimpleTextStyles.caption.copyWith(color: colors.muted),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        controlAffinity: ListTileControlAffinity.leading,
        contentPadding: EdgeInsets.zero,
        dense: true,
        visualDensity: VisualDensity.compact,
      ),
    );
  }
}
