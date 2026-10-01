import 'package:flutter/material.dart';
import 'package:lmstory/core/theme/system/lm_layout.dart';
import 'package:lmstory/core/theme/system/lm_narrative_text_styles.dart';
import 'package:lmstory/core/theme/system/lm_overlays.dart';
import 'package:lmstory/core/theme/system/lm_radius.dart';
import 'package:lmstory/core/theme/system/lm_spacing.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';
import 'package:lmstory/features/memory/domain/entities/event_summary.dart';
import 'package:lmstory/features/memory/domain/entities/experiential_memory.dart';
import 'package:lmstory/i18n/strings.g.dart';

/// 5W1E 记忆详情临时小窗（v0.2 Phase C 方案二，2026-07-19 新增）。
///
/// 触发场景：
/// - 用户点击 SummarizePanel 展开态的事件摘要文本 → 显示 [EventSummary] 详情
/// - 用户点击 RetrievalPanel 展开态的记忆条目 → 显示 [ExperientialMemory] 详情
///
/// 临时性：通过 [showDialog] 实现，用户点击小窗
/// 外区域或右上角关闭按钮即可关闭，不修改任何状态。
///
/// 视觉规范（DOC-06B §6.3C）：
/// - 背景：surfaceElevated（主题 dialogTheme 已配）
/// - 圆角：rXl（20px，主题 dialogTheme 已配）
/// - 标题行：title 字体 + ink 色 + 右上角 muted 关闭按钮
/// - 5W1E 字段：每字段独立成块（label + value 两行），label 用 caption + muted，
///   value 用 narrativeBody + ink（衬线字体保持叙事感）
/// - 空字段不展示（与 EventSummary.displayText / ExperientialMemory.displayText
///   的 `isNotEmpty` 判断保持一致）
/// - 元数据底栏：caption + faint 色，显示轮次/记忆层级/生成时间
///
/// impeccable product register：用标准 Dialog，不重新发明 affordance；
/// 危险操作通过 error 色按钮强化，无装饰性图标。
class MemoryDetailDialog {
  MemoryDetailDialog._();

  /// 显示事件摘要详情（来自 SummarizePanel）
  static Future<void> showEventSummary(
    BuildContext context, {
    required EventSummary summary,
  }) {
    return showLmDialog<void>(
      context: context,
      builder: (context) => _MemoryDetailDialog(
        source: _EventSummarySource(summary),
      ),
    );
  }

  /// 显示记忆条目详情（来自 RetrievalPanel，可为 micro 或 macro）
  static Future<void> showExperientialMemory(
    BuildContext context, {
    required ExperientialMemory memory,
  }) {
    return showLmDialog<void>(
      context: context,
      builder: (context) => _MemoryDetailDialog(
        source: _ExperientialMemorySource(memory),
      ),
    );
  }
}

/// 详情数据源的统一抽象（内部 sealed class 模拟）
///
/// 用抽象类 + 两个子类实现，避免引入 freezed 等代码生成依赖。
/// 子类负责从原始实体提取展示字段，UI 层只依赖此抽象。
abstract class _MemoryDetailSource {
  String title(Translations t);
  List<String> tags();
  int importance();
  int? turnNumber();
  String? summaryText();
  String? whenText();
  String? whereText();
  String? whoText();
  String? whatText();
  String? significanceText();
  String? extraText();

  /// 绝对叙事时间（v0.2 叙事时间机制，2026-07-25 新增）
  ///
  /// 与 [whenText] 区别：when 是事件相对时间描述（"次日清晨"），
  /// narrativeTime 是绝对故事内时间锚点（"来公寓第三天"）。
  /// 返回 null 表示未输出，UI 不展示该字段行。
  String? narrativeTimeText();

  /// 元数据底栏额外信息（记忆层级、触发原因等）
  /// 返回 null 表示不展示底栏
  List<String>? footerMetadata(Translations t);
}

class _EventSummarySource implements _MemoryDetailSource {
  _EventSummarySource(this.summary);

  final EventSummary summary;

  @override
  String title(Translations t) => t.intermediate.chat.memoryDetail.eventTitle;

  @override
  List<String> tags() => summary.tags;

  @override
  int importance() => summary.importance;

  @override
  int? turnNumber() => summary.turnNumber;

  @override
  String? summaryText() => summary.summary;

  @override
  String? whenText() => summary.when;

  @override
  String? whereText() => summary.where;

  @override
  String? whoText() => summary.who;

  @override
  String? whatText() => summary.what;

  @override
  String? significanceText() => summary.significance;

  @override
  String? extraText() => summary.extra;

  @override
  String? narrativeTimeText() => summary.narrativeTime;

  @override
  List<String>? footerMetadata(Translations t) {
    // EventSummary 仅展示轮次
    final turn = summary.turnNumber;
    return [t.intermediate.chat.memoryDetail.turn(n: turn)];
  }
}

class _ExperientialMemorySource implements _MemoryDetailSource {
  _ExperientialMemorySource(this.memory);

  final ExperientialMemory memory;

  @override
  String title(Translations t) => t.intermediate.chat.memoryDetail.memoryTitle;

  @override
  List<String> tags() => memory.tags;

  @override
  int importance() => memory.importance;

  @override
  int? turnNumber() => memory.turnNumber;

  @override
  String? summaryText() => memory.summary;

  @override
  String? whenText() => memory.when;

  @override
  String? whereText() => memory.where;

  @override
  String? whoText() => memory.who;

  @override
  String? whatText() => memory.what;

  @override
  String? significanceText() => memory.significance;

  @override
  String? extraText() => memory.extra;

  @override
  String? narrativeTimeText() => memory.narrativeTime;

  @override
  List<String>? footerMetadata(Translations t) {
    final parts = <String>[
      // 轮次
      t.intermediate.chat.memoryDetail.turn(n: memory.turnNumber),
      // 记忆层级
      if (memory.isMacro)
        t.intermediate.chat.memoryDetail.macroMemory
      else
        t.intermediate.chat.memoryDetail.microMemory,
    ];

    // 宏摘要特有：聚合微摘要数 + 触发原因
    if (memory.isMacro) {
      final parentCount = memory.parentEventIds?.length ?? 0;
      if (parentCount > 0) {
        parts
            .add(t.intermediate.chat.memoryDetail.parentEvents(n: parentCount));
      }
      switch (memory.macroTriggerReason) {
        case MacroTriggerReason.eventEnd:
          parts.add(
            '${t.intermediate.chat.memoryDetail.triggerReason}：'
            '${t.intermediate.chat.memoryDetail.triggerEventEnd}',
          );
        case MacroTriggerReason.roundLimit:
          parts.add(
            '${t.intermediate.chat.memoryDetail.triggerReason}：'
            '${t.intermediate.chat.memoryDetail.triggerRoundLimit}',
          );
        case MacroTriggerReason.compaction:
          // CompactionPoint 压缩触发的宏摘要
          parts.add(
            '${t.intermediate.chat.memoryDetail.triggerReason}：'
            '${t.intermediate.chat.memoryDetail.triggerCompaction}',
          );
        case null:
          break;
      }
    }

    // 生成时间（简洁格式 yyyy-MM-dd HH:mm）
    final dt = memory.createdAt;
    final dtStr = '${dt.year.toString().padLeft(4, '0')}-'
        '${dt.month.toString().padLeft(2, '0')}-'
        '${dt.day.toString().padLeft(2, '0')} '
        '${dt.hour.toString().padLeft(2, '0')}:'
        '${dt.minute.toString().padLeft(2, '0')}';
    parts.add('${t.intermediate.chat.memoryDetail.createdAt}：$dtStr');

    return parts;
  }
}

class _MemoryDetailDialog extends StatelessWidget {
  const _MemoryDetailDialog({required this.source});

  final _MemoryDetailSource source;

  @override
  Widget build(BuildContext context) {
    final colors = context.lm.palette;
    final t = Translations.of(context);

    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(
          maxWidth: LmLayout.dialogNarrowWidth,
        ),
        child: Padding(
          padding: const EdgeInsets.all(LmSpacing.sLg),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _buildHeader(context, colors, t),
              const SizedBox(height: LmSpacing.sMd),
              _buildImportanceAndTags(colors, t),
              const SizedBox(height: LmSpacing.sMd),
              Flexible(
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: _build5W1EFields(colors, t),
                  ),
                ),
              ),
              if (source.footerMetadata(t) != null) ...[
                const SizedBox(height: LmSpacing.sMd),
                _buildFooter(colors, t),
              ],
            ],
          ),
        ),
      ),
    );
  }

  /// 标题行：左侧标题 + 右侧关闭按钮
  Widget _buildHeader(
    BuildContext context,
    LmPalette colors,
    Translations t,
  ) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Expanded(
          child: Text(
            source.title(t),
            style: LmNarrativeTextStyles.title.copyWith(color: colors.ink),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        IconButton(
          icon: const Icon(Icons.close, size: 20),
          color: colors.muted,
          tooltip: t.intermediate.chat.memoryDetail.close,
          onPressed: () => Navigator.of(context).pop(),
          visualDensity: VisualDensity.compact,
          constraints: const BoxConstraints(
            minWidth: 32,
            minHeight: 32,
          ),
          padding: EdgeInsets.zero,
        ),
      ],
    );
  }

  /// 重要性 + 标签行
  Widget _buildImportanceAndTags(LmPalette colors, Translations t) {
    final importance = source.importance();
    final tags = source.tags();
    return Row(
      children: [
        // 重要性星级（1-5 琥珀金）
        for (var i = 0; i < 5; i++)
          Icon(
            i < importance ? Icons.star : Icons.star_border,
            size: 14,
            color: i < importance ? colors.primary : colors.faint,
          ),
        const SizedBox(width: LmSpacing.sSm),
        Text(
          '${t.intermediate.chat.memoryDetail.importance} $importance',
          style: LmNarrativeTextStyles.caption.copyWith(color: colors.muted),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        if (tags.isNotEmpty) ...[
          const SizedBox(width: LmSpacing.sMd),
          Expanded(
            child: Wrap(
              spacing: LmSpacing.sXs,
              runSpacing: LmSpacing.sXs,
              children: [
                for (final tag in tags)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: LmSpacing.sSm,
                      vertical: LmSpacing.s2xs,
                    ),
                    decoration: BoxDecoration(
                      color: colors.primaryDim,
                      borderRadius: BorderRadius.circular(
                        LmRadius.rXs,
                      ),
                    ),
                    child: Text(
                      tag,
                      style: LmNarrativeTextStyles.caption.copyWith(
                        color: colors.primary,
                        fontWeight: FontWeight.w500,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
              ],
            ),
          ),
        ],
      ],
    );
  }

  /// 5W1E 字段列表（空字段不展示）
  ///
  /// 字段顺序：what → narrativeTime → when → where → who → significance → extra → summary
  /// 排序理由：what 是核心事件描述，应置顶；narrativeTime 是绝对时间锚点，
  /// 紧随其后；when 是相对时间描述，与 narrativeTime 相邻便于对照；
  /// 其余按叙事结构顺序；summary 是向后兼容字段，放最后作为补充
  /// （仅当 summary 与 what 不同时展示）。
  List<Widget> _build5W1EFields(LmPalette colors, Translations t) {
    final fields = <Widget>[];

    void addField(String label, String? value) {
      if (value == null || value.isEmpty) return;
      fields.add(
        Padding(
          padding: const EdgeInsets.only(bottom: LmSpacing.sSm),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                label,
                style: LmNarrativeTextStyles.caption.copyWith(
                  color: colors.muted,
                  fontWeight: FontWeight.w500,
                ),
              ),
              const SizedBox(height: LmSpacing.s2xs),
              Text(
                value,
                style: LmNarrativeTextStyles.narrativeBody.copyWith(
                  color: colors.ink,
                ),
              ),
            ],
          ),
        ),
      );
    }

    addField(t.intermediate.chat.memoryDetail.what, source.whatText());
    // 绝对叙事时间（narrativeTime 非空才展示，置于 when 之前作为时间锚点）
    addField(
      t.intermediate.chat.memoryDetail.narrativeTime,
      source.narrativeTimeText(),
    );
    addField(t.intermediate.chat.memoryDetail.when, source.whenText());
    addField(t.intermediate.chat.memoryDetail.where, source.whereText());
    addField(t.intermediate.chat.memoryDetail.who, source.whoText());
    addField(
      t.intermediate.chat.memoryDetail.significance,
      source.significanceText(),
    );
    addField(t.intermediate.chat.memoryDetail.extra, source.extraText());

    // 原始摘要：仅当 summary 与 what 不同时展示，避免重复
    final summaryValue = source.summaryText();
    final whatValue = source.whatText();
    if (summaryValue != null &&
        summaryValue.isNotEmpty &&
        summaryValue != whatValue) {
      addField(
        t.intermediate.chat.memoryDetail.originalSummary,
        summaryValue,
      );
    }

    // 全部字段为空时展示空事件占位
    if (fields.isEmpty) {
      fields.add(
        Padding(
          padding: const EdgeInsets.symmetric(vertical: LmSpacing.sMd),
          child: Text(
            t.intermediate.chat.memoryDetail.empty,
            style: LmNarrativeTextStyles.narrativeBody.copyWith(
              color: colors.faint,
              fontStyle: FontStyle.italic,
            ),
          ),
        ),
      );
    }

    return fields;
  }

  /// 元数据底栏
  Widget _buildFooter(LmPalette colors, Translations t) {
    final metadata = source.footerMetadata(t) ?? const <String>[];
    if (metadata.isEmpty) return const SizedBox.shrink();

    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: LmSpacing.sSm,
        vertical: LmSpacing.sXs,
      ),
      decoration: BoxDecoration(
        color: colors.surfaceVariant,
        borderRadius: BorderRadius.circular(LmRadius.rXs),
      ),
      child: Text(
        metadata.join(' · '),
        style: LmNarrativeTextStyles.caption.copyWith(color: colors.faint),
        maxLines: 3,
        overflow: TextOverflow.ellipsis,
      ),
    );
  }
}
