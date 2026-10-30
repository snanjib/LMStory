/// 草稿可读预览内容（resource_ai）：结构化渲染卡/书草稿。
///
/// 卡=分字段区块；书=书级元信息 + 词条卡片（标题/关键词/内容/常驻·触发
/// 标记）。任何组件不渲染 rawJson 原文（用户看的是字段不是 JSON）。
/// 长文本字段走 SimpleMarkdownBody（模型产出常含 markdown 列表/粗体）。
/// 本组件不自持滚动——嵌入会话设置面板的滚动视图使用。
library;

import 'package:flutter/material.dart';
import 'package:lmstory/core/theme/api/lm_component_kit.dart';
import 'package:lmstory/core/theme/simple/simple_spacing.dart';
import 'package:lmstory/core/theme/simple/simple_text_styles.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';
import 'package:lmstory/features/resource_ai/domain/entities/draft_entities.dart';
import 'package:lmstory/features/resource_ai/presentation/widgets/draft_change_labels.dart';
import 'package:lmstory/i18n/strings.g.dart';

class DraftPreviewContent extends StatelessWidget {
  const DraftPreviewContent({required this.draft, super.key});

  final DraftState? draft;

  /// 长文本字段（渲染 markdown）。
  static const _markdownFields = {
    CardField.description,
    CardField.personality,
    CardField.scenario,
    CardField.firstMes,
    CardField.mesExample,
    CardField.creatorNotes,
  };

  @override
  Widget build(BuildContext context) {
    final t = Translations.of(context);
    if (draft == null || !draft!.isDirty) {
      return Center(child: Text(t.resourceAi.previewEmpty));
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (draft!.kind == DraftKind.characterCard)
          ..._cardSections(context, draft!.card!)
        else
          ..._bookSections(context, draft!.book!),
      ],
    );
  }

  List<Widget> _cardSections(BuildContext context, CardDraft card) {
    final t = Translations.of(context);
    return [
      _SectionLabel(t.resourceAi.previewCardSection),
      for (final f in CardField.values)
        if (card.value(f).isNotEmpty)
          _FieldBlock(
            label: cardFieldLabel(t, f),
            body: card.value(f),
            markdown: _markdownFields.contains(f),
          ),
      if (card.tags.isNotEmpty)
        _FieldBlock(label: cardTagsLabel(t), body: card.tags.join('、')),
    ];
  }

  List<Widget> _bookSections(BuildContext context, WorldbookDraft book) {
    final t = Translations.of(context);
    return [
      _SectionLabel(
        '${t.resourceAi.previewBookSection}（${book.entries.length}）',
      ),
      if (book.name.isNotEmpty)
        _FieldBlock(label: t.resourceAi.bookNameLabel, body: book.name),
      if (book.description.isNotEmpty)
        _FieldBlock(
          label: t.resourceAi.bookDescriptionLabel,
          body: book.description,
          markdown: true,
        ),
      for (final e in book.entries) _EntryCard(entry: e),
    ];
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(
        bottom: SimpleSpacing.sMd,
        top: SimpleSpacing.s2xs,
      ),
      child: Text(text, style: SimpleTextStyles.title3),
    );
  }
}

/// 字段区块：caption 标题 + surfaceElevated 正文容器。
class _FieldBlock extends StatelessWidget {
  const _FieldBlock({
    required this.label,
    required this.body,
    this.markdown = false,
  });

  final String label;
  final String body;

  /// true 时正文用 markdown 渲染（长文本字段）。
  final bool markdown;

  @override
  Widget build(BuildContext context) {
    final colors = context.lm.palette;
    return Padding(
      padding: const EdgeInsets.only(bottom: SimpleSpacing.sMd),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: SimpleTextStyles.caption.copyWith(color: colors.muted),
          ),
          const SizedBox(height: SimpleSpacing.s3xs + 2),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(SimpleSpacing.sMd),
            decoration: BoxDecoration(
              color: colors.surfaceElevated,
              borderRadius:
                  BorderRadius.circular(context.lmUi.radius(LmCorner.md)),
            ),
            child: markdown
                ? context.lmUi.markdownBody(context, data: body)
                : Text(body, style: SimpleTextStyles.body),
          ),
        ],
      ),
    );
  }
}

/// 词条卡片：标题（comment 优先）+ 常驻/触发/停用标记 + 关键词行 + 内容。
class _EntryCard extends StatelessWidget {
  const _EntryCard({required this.entry});

  final WorldEntry entry;

  @override
  Widget build(BuildContext context) {
    final t = Translations.of(context);
    final colors = context.lm.palette;
    return Padding(
      padding: const EdgeInsets.only(bottom: SimpleSpacing.sMd),
      child: Container(
        padding: const EdgeInsets.all(SimpleSpacing.sMd),
        decoration: BoxDecoration(
          color: colors.surfaceElevated,
          borderRadius: BorderRadius.circular(context.lmUi.radius(LmCorner.md)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    entry.comment.isNotEmpty
                        ? entry.comment
                        : entry.keys.join('、'),
                    style: SimpleTextStyles.title3,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (entry.constant)
                  _Tag(text: t.resourceAi.entryConstant, color: colors.accent)
                else
                  _Tag(
                    text: t.resourceAi.entryTriggered,
                    color: colors.primary,
                  ),
                if (!entry.enabled)
                  _Tag(text: t.resourceAi.entryDisabled, color: colors.muted),
              ],
            ),
            if (entry.keys.isNotEmpty) ...[
              const SizedBox(height: SimpleSpacing.s2xs),
              Text(
                entry.keys.join('、'),
                style: SimpleTextStyles.caption.copyWith(color: colors.muted),
              ),
            ],
            const SizedBox(height: SimpleSpacing.s2xs),
            context.lmUi.markdownBody(context, data: entry.content),
          ],
        ),
      ),
    );
  }
}

class _Tag extends StatelessWidget {
  const _Tag({required this.text, required this.color});

  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(left: SimpleSpacing.s2xs),
      padding: const EdgeInsets.symmetric(
        horizontal: SimpleSpacing.s2xs + 2,
        vertical: SimpleSpacing.s3xs + 1,
      ),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(context.lmUi.radius(LmCorner.full)),
      ),
      child: Text(
        text,
        style: SimpleTextStyles.caption.copyWith(color: color),
      ),
    );
  }
}
