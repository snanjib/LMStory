import 'package:flutter/material.dart';
import 'package:lmstory/core/theme/api/lm_component_kit.dart';
import 'package:lmstory/core/theme/intermediate/intermediate_spacing.dart';
import 'package:lmstory/core/theme/intermediate/intermediate_text_styles.dart';
import 'package:lmstory/core/theme/system/lm_overlays.dart';
import 'package:lmstory/core/theme/system/lm_radius.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';
import 'package:lmstory/features/advanced/domain/services/director_core_blocks.dart';
import 'package:lmstory/features/chat/domain/entities/story_anchor.dart';
import 'package:lmstory/features/memory/domain/entities/factual_source.dart';
import 'package:lmstory/i18n/strings.g.dart';

/// 场记板视图——「AI 眼中的现在」
///
/// 只读面板，展示下一轮将注入的 core blocks 素材（关键实体/剧情主线/
/// 叙事时间/剧情锚）。数据经 [loader] 现算，与 runner 注入面共用
/// [assembleDirectorCoreBlocks]——同一份装配，可互验。历史轮快照未随轮
/// 存档，当前只做「现在的」视图（历史轮记为后续增强）。
class DirectorScriptBoardSheet extends StatefulWidget {
  const DirectorScriptBoardSheet({required this.loader, super.key});

  final Future<DirectorCoreBlocksData?> Function() loader;

  static Future<void> show(
    BuildContext context, {
    required Future<DirectorCoreBlocksData?> Function() loader,
  }) {
    return showLmSheet<void>(
      context: context,
      isScrollControlled: true,
      // 内容自绘把手；shape 仅经典组合消费（琉璃形状由工厂锁定）。
      glassHandle: false,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(LmRadius.rXl),
        ),
      ),
      builder: (_) => DirectorScriptBoardSheet(loader: loader),
    );
  }

  @override
  State<DirectorScriptBoardSheet> createState() =>
      _DirectorScriptBoardSheetState();
}

class _DirectorScriptBoardSheetState extends State<DirectorScriptBoardSheet> {
  late final Future<DirectorCoreBlocksData?> _future;

  @override
  void initState() {
    super.initState();
    _future = widget.loader();
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.lm.palette;
    final t = Translations.of(context);

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
              t.advanced.scriptBoard.title,
              style: IntermediateTextStyles.title.copyWith(
                color: colors.ink,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: IntermediateSpacing.s2xs),
            Text(
              t.advanced.scriptBoard.hint,
              style: IntermediateTextStyles.caption.copyWith(
                color: colors.faint,
              ),
            ),
            const SizedBox(height: IntermediateSpacing.sMd),
            Flexible(
              child: FutureBuilder<DirectorCoreBlocksData?>(
                future: _future,
                builder: (context, snapshot) {
                  if (snapshot.connectionState != ConnectionState.done) {
                    return const Padding(
                      padding: EdgeInsets.symmetric(
                        vertical: IntermediateSpacing.sLg,
                      ),
                      child: Center(child: CircularProgressIndicator()),
                    );
                  }
                  final data = snapshot.data;
                  if (data == null) {
                    return Text(
                      t.advanced.scriptBoard.unavailable,
                      style: IntermediateTextStyles.bodyUi.copyWith(
                        color: colors.muted,
                      ),
                    );
                  }
                  return SingleChildScrollView(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _entities(data, colors, t),
                        _macros(data, colors, t),
                        if (data.narrativeTime != null &&
                            data.narrativeTime!.isNotEmpty)
                          _section(
                            t.advanced.scriptBoard.narrativeTime,
                            ['${data.narrativeTime}'],
                            colors,
                          ),
                        _anchor(data.anchor, colors, t),
                      ],
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _sectionTitle(String text, LmPalette colors) {
    return Padding(
      padding: const EdgeInsets.only(bottom: IntermediateSpacing.s2xs),
      child: Text(
        text,
        style: IntermediateTextStyles.caption.copyWith(color: colors.faint),
      ),
    );
  }

  /// 段落：标题 + 行列表
  Widget _section(
    String title,
    List<String> lines,
    LmPalette colors, {
    bool muted = false,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: IntermediateSpacing.sMd),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _sectionTitle(title, colors),
          for (final line in lines)
            Padding(
              padding: const EdgeInsets.only(
                left: IntermediateSpacing.sSm,
                bottom: IntermediateSpacing.s2xs,
              ),
              child: Text(
                line,
                style: IntermediateTextStyles.bodyUi.copyWith(
                  color: muted ? colors.faint : colors.muted,
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// 关键实体：截断口径与注入面一致（take(10)、属性 importance≥3 take(4)）
  Widget _entities(
    DirectorCoreBlocksData data,
    LmPalette colors,
    Translations t,
  ) {
    if (data.keyEntities.isEmpty) {
      return _section(
        t.advanced.scriptBoard.entities,
        [
          t.advanced.scriptBoard.empty,
        ],
        colors,
      );
    }
    return _section(
      t.advanced.scriptBoard.entities,
      [
        for (final entity in data.keyEntities.take(10))
          () {
            // 来源后缀分键——此前透传枚举名裸显
            // 「来源 worldbook」「来源 card」（同族）。
            final sourceSuffix = switch (entity.source) {
              FactualSource.auto => '',
              FactualSource.worldbook =>
                '｜${t.advanced.scriptBoard.sourceWorldbook}',
              FactualSource.card => '｜${t.advanced.scriptBoard.sourceCard}',
            };
            final attrs = (data.attributesByEntity[entity.entityId] ?? const [])
                .where((a) => a.importance >= 3)
                .take(4)
                .map((a) => '${a.attrKey}=${a.value}')
                .join('；');
            return attrs.isEmpty
                ? '· ${entity.primaryName}$sourceSuffix'
                : '· ${entity.primaryName}$sourceSuffix：$attrs';
          }(),
      ],
      colors,
    );
  }

  Widget _macros(
    DirectorCoreBlocksData data,
    LmPalette colors,
    Translations t,
  ) {
    if (data.latestMacros.isEmpty) return const SizedBox.shrink();
    return _section(
      t.advanced.scriptBoard.macros,
      [
        for (final macro in data.latestMacros.take(2))
          '· ${macro.summary ?? ''}',
      ],
      colors,
    );
  }

  Widget _anchor(
    StoryAnchor? anchor,
    LmPalette colors,
    Translations t,
  ) {
    if (anchor == null || anchor.isEmpty) return const SizedBox.shrink();
    final lines = <String>[
      if (anchor.arc != null && anchor.arc!.isNotEmpty)
        '· ${t.advanced.recap.arc}：${anchor.arc}',
      for (final f in anchor.openForeshadows.take(8)) '· ${f.text}',
      if (anchor.foreshadows.any((f) => f.resolved))
        '· ${t.advanced.recap.foreshadowsResolved}：${anchor.foreshadows.where((f) => f.resolved).length}',
    ];
    if (lines.isEmpty) return const SizedBox.shrink();
    return _section(t.advanced.scriptBoard.anchor, lines, colors);
  }
}
