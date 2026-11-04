import 'package:flutter/material.dart';
import 'package:lmstory/core/theme/api/lm_component_kit.dart';
import 'package:lmstory/core/theme/intermediate/intermediate_spacing.dart';
import 'package:lmstory/core/theme/intermediate/intermediate_text_styles.dart';
import 'package:lmstory/core/theme/shared/components/panel_heading.dart';
import 'package:lmstory/core/theme/system/lm_overlays.dart';
import 'package:lmstory/core/theme/system/lm_radius.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';
import 'package:lmstory/core/utils/file_share.dart'
    if (dart.library.html) 'package:lmstory/core/utils/file_share_web.dart';
import 'package:lmstory/core/widgets/file_saved_dialog.dart';
import 'package:lmstory/features/advanced/domain/entities/advanced_chat_state.dart';
import 'package:lmstory/features/advanced/presentation/widgets/director_manuscript_exporter.dart';
import 'package:lmstory/features/story_runtime/domain/services/round_history_utils.dart';
import 'package:lmstory/i18n/strings.g.dart';

/// 导演会话稿件导出
///
/// 范围（全部/当前幕）× 内容（纯稿件/含幕后过程）四选后产出 Markdown：
/// 桌面端弹系统保存对话框（同源 [shareTextAsFile]）、
/// 移动端调分享面板、Web 直接下载。数据取页面 state（messages +
/// artifactsByTurnNumber 已由 loadHistory 装配），构建为纯内存字符串。
class DirectorExportSheet extends StatefulWidget {
  const DirectorExportSheet({required this.state, super.key});

  final AdvancedChatState state;

  /// 弹出导出选项 sheet 并完成导出流程；取消返回 false。
  static Future<bool> show(BuildContext context, AdvancedChatState state) {
    return showLmSheet<bool>(
      context: context,
      isScrollControlled: true,
      // 内容自绘把手；shape 仅经典组合消费（琉璃形状由工厂锁定）。
      glassHandle: false,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(LmRadius.rXl),
        ),
      ),
      builder: (_) => DirectorExportSheet(state: state),
    ).then((v) => v ?? false);
  }

  @override
  State<DirectorExportSheet> createState() => _DirectorExportSheetState();
}

class _DirectorExportSheetState extends State<DirectorExportSheet> {
  DirectorExportScope _scope = DirectorExportScope.all;
  bool _includeBackstage = false;

  @override
  Widget build(BuildContext context) {
    final colors = context.lm.palette;
    final t = Translations.of(context);
    final state = widget.state;
    final lastAct = _lastCompletedAct(state);

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          IntermediateSpacing.sLg,
          IntermediateSpacing.sMd,
          IntermediateSpacing.sLg,
          IntermediateSpacing.sLg,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: colors.divider,
                  borderRadius: BorderRadius.circular(
                    context.lmUi.radius(LmCorner.full),
                  ),
                ),
              ),
            ),
            const SizedBox(height: IntermediateSpacing.sMd),
            PanelHeading(title: t.advanced.export.sheetTitle),
            const SizedBox(height: IntermediateSpacing.sMd),
            Text(
              t.advanced.export.scopeTitle,
              style: IntermediateTextStyles.caption.copyWith(
                color: colors.faint,
              ),
            ),
            _OptionTile(
              tileKey: const ValueKey('export-scope-all'),
              selected: _scope == DirectorExportScope.all,
              label: t.advanced.export.scopeAll(
                count: _completedActCount(state),
              ),
              onTap: () => setState(() => _scope = DirectorExportScope.all),
            ),
            _OptionTile(
              tileKey: const ValueKey('export-scope-current'),
              selected: _scope == DirectorExportScope.currentAct,
              // 无已完成幕时禁选（空导出无意义）
              enabled: lastAct != null,
              label: lastAct == null
                  ? t.advanced.export.scopeCurrentNone
                  : t.advanced.export.scopeCurrent(act: lastAct),
              onTap: () =>
                  setState(() => _scope = DirectorExportScope.currentAct),
            ),
            const SizedBox(height: IntermediateSpacing.sSm),
            Text(
              t.advanced.export.contentTitle,
              style: IntermediateTextStyles.caption.copyWith(
                color: colors.faint,
              ),
            ),
            _OptionTile(
              tileKey: const ValueKey('export-content-manuscript'),
              selected: !_includeBackstage,
              label: t.advanced.export.contentManuscriptOnly,
              description: t.advanced.export.contentManuscriptOnlyDesc,
              onTap: () => setState(() => _includeBackstage = false),
            ),
            _OptionTile(
              tileKey: const ValueKey('export-content-backstage'),
              selected: _includeBackstage,
              label: t.advanced.export.contentWithBackstage,
              description: t.advanced.export.contentWithBackstageDesc,
              onTap: () => setState(() => _includeBackstage = true),
            ),
            const SizedBox(height: IntermediateSpacing.sMd),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: _export,
                child: Text(t.advanced.export.confirm),
              ),
            ),
            const SizedBox(height: IntermediateSpacing.sXs),
            SizedBox(
              width: double.infinity,
              child: TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                style: TextButton.styleFrom(foregroundColor: colors.muted),
                child: Text(t.common.cancel),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _export() async {
    final state = widget.state;
    final t = Translations.of(context);
    final content = DirectorManuscriptExporter.toMarkdown(
      session: state.session,
      messages: state.messages,
      artifactsByTurnNumber: state.artifactsByTurnNumber,
      compactedTurnBase: state.compactedTurnBase,
      scope: _scope,
      includeBackstage: _includeBackstage,
    );

    final timestamp = DateTime.now().toIso8601String().replaceAll(':', '-');
    final safeTitle =
        state.session.title.replaceAll(RegExp(r'[\/:*?"<>|]'), '').trim();
    final fileName = safeTitle.isEmpty
        ? 'manuscript_$timestamp.md'
        : '${safeTitle}_$timestamp.md';

    try {
      final savedPath = await shareTextAsFile(
        content: content,
        fileName: fileName,
        sharePositionOrigin: shareOriginFrom(context),
      );
      if (!mounted) return;
      Navigator.of(context).pop(true);
      if (savedPath != null) {
        await showFileSavedDialog(context, savedPath);
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            behavior: SnackBarBehavior.floating,
            content: Text(t.advanced.export.shared),
          ),
        );
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          behavior: SnackBarBehavior.floating,
          content: Text(
            '${t.advanced.export.failed}\n$e',
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      );
    }
  }

  /// 已完成幕数（user→assistant 配对计数，与导出器同口径的轻量重算）
  static int _completedActCount(AdvancedChatState state) {
    var count = 0;
    final messages = state.messages;
    for (var i = 1; i < messages.length; i++) {
      if (messages[i].role != 'assistant' || messages[i].isSummary) continue;
      final prev = messages[i - 1];
      if (prev.role != 'user' || prev.isSummary) continue;
      count++;
    }
    return count;
  }

  /// 最后一幕的幕号（无已完成幕返回 null；轮号走共享公式）
  static int? _lastCompletedAct(AdvancedChatState state) {
    final messages = state.messages;
    int? lastTurn;
    for (var i = 1; i < messages.length; i++) {
      final assistant = messages[i];
      if (assistant.role != 'assistant' || assistant.isSummary) continue;
      final user = messages[i - 1];
      if (user.role != 'user' || user.isSummary) continue;
      lastTurn = turnNumberForMessage(
            message: assistant,
            messages: messages,
            compactedTurnBase: state.compactedTurnBase,
          ) ??
          lastTurn;
    }
    return lastTurn;
  }
}

class _OptionTile extends StatelessWidget {
  const _OptionTile({
    required this.selected,
    required this.label,
    required this.onTap,
    this.description,
    this.enabled = true,
    this.tileKey,
  });

  final bool selected;
  final String label;
  final String? description;
  final bool enabled;
  final VoidCallback onTap;

  /// 测试锚点（选项行稳定键）
  final Key? tileKey;

  @override
  Widget build(BuildContext context) {
    final colors = context.lm.palette;
    final ink = enabled ? colors.ink : colors.faint;
    return InkWell(
      key: tileKey,
      onTap: enabled ? onTap : null,
      borderRadius: BorderRadius.circular(context.lmUi.radius(LmCorner.md)),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: IntermediateSpacing.sSm),
        child: Row(
          children: [
            Icon(
              selected ? Icons.radio_button_checked : Icons.radio_button_off,
              size: 18,
              color: selected && enabled ? colors.primary : colors.faint,
            ),
            const SizedBox(width: IntermediateSpacing.sSm),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    style: IntermediateTextStyles.bodyUi.copyWith(color: ink),
                  ),
                  if (description != null) ...[
                    const SizedBox(height: IntermediateSpacing.s2xs),
                    Text(
                      description!,
                      style: IntermediateTextStyles.caption.copyWith(
                        color: colors.faint,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
