import 'package:flutter/material.dart';
import 'package:lmstory/core/theme/api/lm_component_kit.dart';
import 'package:lmstory/core/theme/shared/components/narrative_identity.dart';
import 'package:lmstory/core/theme/shared/components/panel_heading.dart';
import 'package:lmstory/core/theme/shared/components/section_heading.dart';
import 'package:lmstory/core/theme/simple/simple_spacing.dart';
import 'package:lmstory/core/theme/simple/simple_text_styles.dart';
import 'package:lmstory/core/theme/system/lm_motion.dart';
import 'package:lmstory/core/theme/system/lm_overlays.dart';
import 'package:lmstory/core/theme/system/lm_radius.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';
import 'package:lmstory/features/resource_library/domain/entities/normalized_world_entry.dart';
import 'package:lmstory/features/resource_library/domain/entities/parsed_character_card.dart';
import 'package:lmstory/features/resource_library/domain/services/character_card_parser.dart';
import 'package:lmstory/features/resource_library/domain/services/worldbook_parser.dart';
import 'package:lmstory/i18n/strings.g.dart';

/// WA13U-1：资源内容查看——人类可读性第一。
///
/// 卡/书 tile 点开详情弹窗：字段中文名、长文折叠、大书限流
///（「更多 N 条」）；数据复用两 Parser 的结构化产出（现场解析 rawJson，
/// 与应用/预览同源）。不做原始 JSON 直出。

/// 词条首屏渲染上限——数百词条大书一次全开会卡列表，超出部分折叠为
///「更多 N 条」按钮。
const int _kMaxInitialEntries = 20;

Future<void> showCardContentSheet(
  BuildContext context, {
  required String name,
  required String rawJson,
}) {
  return _showSheet(
    context,
    title: name,
    builder: (context, t, colors) {
      // 现场解析（与导入/应用同源）；解析失败给出原始 JSON 的兜底视图
      try {
        final card = CharacterCardParser.parse(rawJson);
        return [CharacterCardViewer(card: card, colors: colors)];
      } catch (_) {
        return [
          _sectionHeader(
            context,
            t.settings.resourceLibrary.viewer.rawJson,
            colors,
          ),
          _FoldableText(text: rawJson, colors: colors),
        ];
      }
    },
  );
}

Future<void> showBookContentSheet(
  BuildContext context, {
  required String name,
  required String rawJson,
}) {
  return _showSheet(
    context,
    title: name,
    builder: (context, t, colors) {
      try {
        final book = WorldbookParser.parseBook(rawJson);
        return [
          _sectionHeader(
            context,
            t.settings.resourceLibrary.viewer
                .entries(count: book.entries.length),
            colors,
          ),
          if (book.entries.isEmpty)
            _bodyText(t.settings.resourceLibrary.viewer.noEntries, colors)
          else
            ..._entryList(book.entries, t, colors),
        ];
      } catch (_) {
        return [
          _sectionHeader(
            context,
            t.settings.resourceLibrary.viewer.rawJson,
            colors,
          ),
          _FoldableText(text: rawJson, colors: colors),
        ];
      }
    },
  );
}

Future<void> _showSheet(
  BuildContext context, {
  required String title,
  required List<Widget> Function(BuildContext, Translations, LmPalette) builder,
}) {
  return showLmSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(LmRadius.rLg)),
    ),
    builder: (ctx) {
      final t = Translations.of(ctx);
      final inner = ctx.lm.palette;
      return DraggableScrollableSheet(
        initialChildSize: 0.85,
        minChildSize: 0.4,
        maxChildSize: 0.95,
        expand: false,
        builder: (ctx, scrollController) => Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(SimpleSpacing.sMd),
              child: PanelHeading(
                title: title,
                actions: [
                  IconButton(
                    //  语义缺口：复用 common.close（不新增 i18n key）。
                    tooltip: t.common.close,
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.of(ctx).pop(),
                  ),
                ],
              ),
            ),
            Expanded(
              child: ListView(
                controller: scrollController,
                padding: const EdgeInsets.symmetric(
                  horizontal: SimpleSpacing.sLg,
                ),
                children: builder(ctx, t, inner),
              ),
            ),
          ],
        ),
      );
    },
  );
}

Widget _sectionHeader(BuildContext context, String label, LmPalette colors) {
  return Padding(
    padding: const EdgeInsets.only(
      top: SimpleSpacing.sMd,
      bottom: SimpleSpacing.s2xs,
    ),
    child: SectionHeading(title: label),
  );
}

Widget _bodyText(String text, LmPalette colors) {
  return Text(
    text,
    style: SimpleTextStyles.bodySm.copyWith(color: colors.ink),
  );
}

List<Widget> _entryList(
  List<NormalizedWorldEntry> entries,
  Translations t,
  LmPalette colors,
) {
  final shown = entries.take(_kMaxInitialEntries).toList();
  final hidden = entries.length - shown.length;
  return [
    for (final e in shown) _EntryCard(entry: e, t: t, colors: colors),
    if (hidden > 0)
      Padding(
        padding: const EdgeInsets.only(top: SimpleSpacing.sSm),
        child: Center(
          child: Text(
            t.settings.resourceLibrary.viewer.moreEntries(count: hidden),
            style: SimpleTextStyles.caption.copyWith(color: colors.muted),
          ),
        ),
      ),
  ];
}

class _EntryCard extends StatefulWidget {
  const _EntryCard({
    required this.entry,
    required this.t,
    required this.colors,
  });

  final NormalizedWorldEntry entry;
  final Translations t;
  final LmPalette colors;

  @override
  State<_EntryCard> createState() => _EntryCardState();
}

class _EntryCardState extends State<_EntryCard> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final e = widget.entry;
    final t = widget.t;
    final colors = widget.colors;
    final title = e.comment.isNotEmpty
        ? e.comment
        : (e.keys.isNotEmpty ? e.keys.join(' / ') : '');
    return Container(
      margin: const EdgeInsets.only(top: SimpleSpacing.sSm),
      padding: const EdgeInsets.all(SimpleSpacing.sMd),
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(context.lmUi.radius(LmCorner.md)),
        border: Border.all(color: colors.divider),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  title.isEmpty
                      ? t.settings.resourceLibrary.viewer.unnamedEntry
                      : title,
                  style: SimpleTextStyles.body.copyWith(
                    color: colors.ink,
                    fontWeight: FontWeight.w600,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (e.constant)
                Padding(
                  padding: const EdgeInsets.only(left: SimpleSpacing.s2xs),
                  child: Icon(Icons.push_pin, size: 14, color: colors.primary),
                ),
              if (!e.enabled)
                Padding(
                  padding: const EdgeInsets.only(left: SimpleSpacing.s2xs),
                  child: Icon(
                    Icons.visibility_off_outlined,
                    size: 14,
                    color: colors.faint,
                  ),
                ),
            ],
          ),
          if (e.keys.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: SimpleSpacing.s2xs),
              child: Text(
                e.keys.join('、'),
                style: SimpleTextStyles.caption.copyWith(color: colors.muted),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          const SizedBox(height: SimpleSpacing.sXs),
          AnimatedCrossFade(
            duration: LmMotion.fast,
            crossFadeState: _expanded
                ? CrossFadeState.showSecond
                : CrossFadeState.showFirst,
            firstChild: GestureDetector(
              onTap: () => setState(() => _expanded = true),
              child: Text(
                e.content,
                style: SimpleTextStyles.bodySm.copyWith(color: colors.ink),
                maxLines: 4,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            secondChild: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  e.content,
                  style: SimpleTextStyles.bodySm.copyWith(color: colors.ink),
                ),
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton(
                    onPressed: () => setState(() => _expanded = false),
                    child: Text(t.settings.resourceLibrary.viewer.collapse),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 长文折叠（默认 6 行 + 展开按钮）
class _FoldableText extends StatefulWidget {
  const _FoldableText({required this.text, required this.colors});

  final String text;
  final LmPalette colors;

  @override
  State<_FoldableText> createState() => _FoldableTextState();
}

class _FoldableTextState extends State<_FoldableText> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final t = Translations.of(context);
    final style = SimpleTextStyles.bodySm.copyWith(color: widget.colors.ink);
    return LayoutBuilder(
      builder: (context, constraints) {
        // 短文（未超 6 行）不显示「展开」——此前恒显按钮点击无视觉变化
        final painter = TextPainter(
          text: TextSpan(text: widget.text, style: style),
          textDirection: TextDirection.ltr,
          maxLines: 6,
        )..layout(maxWidth: constraints.maxWidth);
        final didOverflow = painter.didExceedMaxLines;
        painter.dispose();
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AnimatedCrossFade(
              duration: LmMotion.fast,
              crossFadeState: _expanded
                  ? CrossFadeState.showSecond
                  : CrossFadeState.showFirst,
              firstChild: GestureDetector(
                onTap:
                    didOverflow ? () => setState(() => _expanded = true) : null,
                child: Text(
                  widget.text,
                  style: style,
                  maxLines: 6,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              secondChild: Text(widget.text, style: style),
            ),
            if (didOverflow && !_expanded)
              TextButton(
                onPressed: () => setState(() => _expanded = true),
                child: Text(t.settings.resourceLibrary.viewer.expand),
              ),
          ],
        );
      },
    );
  }
}

/// 角色卡图形化查看器（人类可读性第一，不出原始 JSON）。
///
/// V2/V3 富字段分区展示：身份/标签 chip 流/场景/开场白/替代开场白/
/// 描述/性格/对话示例/作者注/系统提示（长文折叠）+ 内嵌世界书词条 +
/// 未消费简单字段的「其他字段」折叠组（复杂结构不展示）。空字段不渲染。
class CharacterCardViewer extends StatelessWidget {
  const CharacterCardViewer({
    required this.card,
    required this.colors,
    super.key,
  });

  final ParsedCharacterCard card;
  final LmPalette colors;

  @override
  Widget build(BuildContext context) {
    final t = Translations.of(context);
    final v = t.settings.resourceLibrary.viewer;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // 身份区：名字/昵称/年龄/作者（键值行；全空则整区不渲染）
        if (card.name.isNotEmpty ||
            card.nickname.isNotEmpty ||
            card.age.isNotEmpty ||
            card.creator.isNotEmpty) ...[
          NarrativeIdentity(
            name: card.name,
            label: v.identity,
            details: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (card.nickname.isNotEmpty) _kvRow(v.nickname, card.nickname),
                if (card.age.isNotEmpty) _kvRow(v.age, card.age),
                if (card.creator.isNotEmpty) _kvRow(v.creator, card.creator),
              ],
            ),
          ),
        ],
        // 标签 chip 流
        if (card.tags.isNotEmpty) ...[
          _sectionHeader(context, v.tags, colors),
          Wrap(
            spacing: SimpleSpacing.sXs,
            runSpacing: SimpleSpacing.s2xs,
            children: [
              for (final tag in card.tags)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: SimpleSpacing.sSm,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: colors.surfaceVariant,
                    borderRadius: BorderRadius.circular(
                      context.lmUi.radius(LmCorner.xs),
                    ),
                  ),
                  child: Text(
                    tag,
                    style: SimpleTextStyles.caption.copyWith(
                      color: colors.muted,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
            ],
          ),
        ],
        _kvRow(v.version, card.specVersion),
        if (card.scenario.isNotEmpty)
          _foldSection(context, v.scenario, card.scenario),
        if (card.firstMes.isNotEmpty)
          _foldSection(context, v.firstMes, card.firstMes),
        if (card.alternateGreetings.isNotEmpty) ...[
          _sectionHeader(
            context,
            v.alternateGreetings(count: card.alternateGreetings.length),
            colors,
          ),
          for (var i = 0; i < card.alternateGreetings.length; i++)
            _FoldableText(
              text: '${i + 1}. ${card.alternateGreetings[i]}',
              colors: colors,
            ),
        ],
        if (card.description.isNotEmpty)
          _foldSection(context, v.description, card.description),
        if (card.personality.isNotEmpty)
          _foldSection(context, v.personality, card.personality),
        if (card.mesExample.isNotEmpty)
          _foldSection(context, v.mesExample, card.mesExample),
        if (card.creatorNotes.isNotEmpty)
          _foldSection(context, v.creatorNotes, card.creatorNotes),
        if (card.systemPrompt.isNotEmpty)
          _foldSection(context, v.systemPrompt, card.systemPrompt),
        if (card.embeddedEntries.isNotEmpty) ...[
          _sectionHeader(
            context,
            v.embeddedEntries(count: card.embeddedEntries.length),
            colors,
          ),
          ..._entryList(card.embeddedEntries, t, colors),
        ],
        if (card.extraFields.isNotEmpty)
          Theme(
            // 折叠组默认收起：未知字段属低频信息
            data: Theme.of(
              context,
            ).copyWith(dividerColor: Colors.transparent),
            child: ExpansionTile(
              tilePadding: EdgeInsets.zero,
              childrenPadding: EdgeInsets.zero,
              title: Text(
                v.otherFields(count: card.extraFields.length),
                style: SimpleTextStyles.caption.copyWith(
                  color: colors.muted,
                  fontWeight: FontWeight.w600,
                ),
              ),
              children: [
                for (final f in card.extraFields)
                  Padding(
                    padding: const EdgeInsets.only(bottom: SimpleSpacing.s2xs),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          f.key,
                          style: SimpleTextStyles.caption.copyWith(
                            color: colors.muted,
                          ),
                        ),
                        Text(
                          f.value,
                          style: SimpleTextStyles.bodySm.copyWith(
                            color: colors.ink,
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _kvRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: SimpleSpacing.s2xs),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 72,
            child: Text(
              label,
              style: SimpleTextStyles.caption.copyWith(color: colors.muted),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: SimpleTextStyles.bodySm.copyWith(color: colors.ink),
            ),
          ),
        ],
      ),
    );
  }

  Widget _foldSection(BuildContext context, String label, String text) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _sectionHeader(context, label, colors),
        _FoldableText(text: text, colors: colors),
      ],
    );
  }
}
