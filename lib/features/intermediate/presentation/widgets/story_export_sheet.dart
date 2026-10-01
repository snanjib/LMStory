import 'package:flutter/material.dart';
import 'package:lmstory/core/theme/api/lm_component_kit.dart';
import 'package:lmstory/core/theme/intermediate/intermediate_spacing.dart';
import 'package:lmstory/core/theme/intermediate/intermediate_text_styles.dart';
import 'package:lmstory/core/theme/system/lm_overlays.dart';
import 'package:lmstory/core/theme/system/lm_radius.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';
import 'package:lmstory/core/utils/file_share.dart'
    if (dart.library.html) 'package:lmstory/core/utils/file_share_web.dart';
import 'package:lmstory/core/widgets/file_saved_dialog.dart';
import 'package:lmstory/features/intermediate/domain/entities/intermediate_chat_state.dart';
import 'package:lmstory/features/intermediate/presentation/widgets/story_manuscript_exporter.dart';
import 'package:lmstory/features/story_runtime/domain/services/round_history_utils.dart';
import 'package:lmstory/i18n/strings.g.dart';

/// 故事会话稿件导出 sheet
///
/// 骨架复用导演版（DirectorExportSheet）：范围（全部/仅最新轮）×
/// 内容（纯正文/含生成过程）四选后产出 Markdown；桌面端弹系统保存
/// 对话框、移动端调分享面板、Web 直接下载。「含生成过程」为故事四小窗
/// 数据（指令/检索/草稿/摘要），非 agent 时间线。
class StoryExportSheet extends StatefulWidget {
  const StoryExportSheet({required this.state, super.key});

  final IntermediateChatState state;

  /// 弹出导出选项 sheet 并完成导出流程；取消返回 false。
  static Future<bool> show(BuildContext context, IntermediateChatState state) {
    return showLmSheet<bool>(
      context: context,
      isScrollControlled: true,
      // 内容自绘把手（glassHandle:false 避免双把手）；shape 仅经典组合
      // 消费（琉璃形状由工厂锁定）。
      glassHandle: false,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(LmRadius.rXl),
        ),
      ),
      builder: (_) => StoryExportSheet(state: state),
    ).then((v) => v ?? false);
  }

  @override
  State<StoryExportSheet> createState() => _StoryExportSheetState();
}

class _StoryExportSheetState extends State<StoryExportSheet> {
  StoryExportScope _scope = StoryExportScope.all;
  bool _includeProcess = false;

  @override
  Widget build(BuildContext context) {
    final colors = context.lm.palette;
    final t = Translations.of(context);
    final state = widget.state;
    final lastRound = _lastCompletedRound(state);

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
            Text(
              t.intermediate.chat.export.sheetTitle,
              style: IntermediateTextStyles.title.copyWith(
                color: colors.ink,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: IntermediateSpacing.sMd),
            Text(
              t.intermediate.chat.export.scopeTitle,
              style: IntermediateTextStyles.caption.copyWith(
                color: colors.faint,
              ),
            ),
            _OptionTile(
              tileKey: const ValueKey('story-export-scope-all'),
              selected: _scope == StoryExportScope.all,
              label: t.intermediate.chat.export.scopeAll(
                count: _completedRoundCount(state),
              ),
              onTap: () => setState(() => _scope = StoryExportScope.all),
            ),
            _OptionTile(
              tileKey: const ValueKey('story-export-scope-last'),
              selected: _scope == StoryExportScope.lastRound,
              // 无已完成轮时禁选（空导出无意义）
              enabled: lastRound != null,
              label: lastRound == null
                  ? t.intermediate.chat.export.scopeLastNone
                  : t.intermediate.chat.export.scopeLast(round: lastRound),
              onTap: () => setState(() => _scope = StoryExportScope.lastRound),
            ),
            const SizedBox(height: IntermediateSpacing.sSm),
            Text(
              t.intermediate.chat.export.contentTitle,
              style: IntermediateTextStyles.caption.copyWith(
                color: colors.faint,
              ),
            ),
            _OptionTile(
              tileKey: const ValueKey('story-export-content-manuscript'),
              selected: !_includeProcess,
              label: t.intermediate.chat.export.contentManuscriptOnly,
              description: t.intermediate.chat.export.contentManuscriptOnlyDesc,
              onTap: () => setState(() => _includeProcess = false),
            ),
            _OptionTile(
              tileKey: const ValueKey('story-export-content-process'),
              selected: _includeProcess,
              label: t.intermediate.chat.export.contentWithProcess,
              description: t.intermediate.chat.export.contentWithProcessDesc,
              onTap: () => setState(() => _includeProcess = true),
            ),
            const SizedBox(height: IntermediateSpacing.sMd),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: _export,
                child: Text(t.intermediate.chat.export.confirm),
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
    final content = StoryManuscriptExporter.toMarkdown(
      session: state.session,
      messages: state.messages,
      artifactsByTurnNumber: state.artifactsByTurnNumber,
      compactedTurnBase: state.compactedTurnBase,
      scope: _scope,
      includeProcess: _includeProcess,
    );

    final timestamp = DateTime.now().toIso8601String().replaceAll(':', '-');
    final safeTitle =
        state.session.title.replaceAll(RegExp(r'[\/:*?"<>|]'), '').trim();
    final fileName = safeTitle.isEmpty
        ? 'story_$timestamp.md'
        : '${safeTitle}_$timestamp.md';

    try {
      final savedPath = await shareTextAsFile(
        content: content,
        fileName: fileName,
      );
      if (!mounted) return;
      Navigator.of(context).pop(true);
      if (savedPath != null) {
        await showFileSavedDialog(context, savedPath);
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            behavior: SnackBarBehavior.floating,
            content: Text(t.intermediate.chat.export.shared),
          ),
        );
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          behavior: SnackBarBehavior.floating,
          content: Text(
            '${t.intermediate.chat.export.failed}\n$e',
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      );
    }
  }

  /// 已完成轮数（user→assistant 配对计数，与导出器同口径的轻量重算）
  static int _completedRoundCount(IntermediateChatState state) {
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

  /// 最后一轮的轮号（无已完成轮返回 null；轮号走共享公式）
  static int? _lastCompletedRound(IntermediateChatState state) {
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
  final VoidCallback onTap;

  final String? description;
  final bool enabled;

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
