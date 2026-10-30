import 'package:flutter/material.dart';
import 'package:lmstory/core/theme/api/lm_component_kit.dart';
import 'package:lmstory/core/theme/intermediate/intermediate_spacing.dart';
import 'package:lmstory/core/theme/intermediate/intermediate_text_styles.dart';
import 'package:lmstory/core/theme/shared/components/panel_heading.dart';
import 'package:lmstory/core/theme/system/lm_overlays.dart';
import 'package:lmstory/core/theme/system/lm_radius.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';
import 'package:lmstory/features/chat/domain/entities/story_anchor.dart';
import 'package:lmstory/i18n/strings.g.dart';

/// 剧情锚编辑 sheet
///
/// 编辑当前剧情锚的弧线/叙事时间/伏笔清单（增删改+兑现状态）。保存走与
/// AI `update_story_anchor` 相同的数据源（chat_sessions.story_anchor 列，
/// 由调用方经 controller 写入）；oneLiner 与 updatedTurn 保留原值。
/// 伏笔行按「全量清单整体替换」语义提交（与工具协议一致）。
class DirectorAnchorEditSheet extends StatefulWidget {
  const DirectorAnchorEditSheet({required this.anchor, super.key});

  final StoryAnchor anchor;

  /// 弹出编辑 sheet；保存返回新锚，取消返回 null。
  static Future<StoryAnchor?> show(BuildContext context, StoryAnchor anchor) {
    return showLmSheet<StoryAnchor>(
      context: context,
      isScrollControlled: true,
      // 内容自绘把手；shape 仅经典组合消费（琉璃形状由工厂锁定）。
      glassHandle: false,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(LmRadius.rXl),
        ),
      ),
      builder: (_) => DirectorAnchorEditSheet(anchor: anchor),
    );
  }

  @override
  State<DirectorAnchorEditSheet> createState() =>
      _DirectorAnchorEditSheetState();
}

class _DirectorAnchorEditSheetState extends State<DirectorAnchorEditSheet> {
  late final TextEditingController _arcController;
  late final TextEditingController _timeController;
  late final List<_ForeshadowDraft> _foreshadows;

  @override
  void initState() {
    super.initState();
    _arcController = TextEditingController(text: widget.anchor.arc ?? '');
    _timeController = TextEditingController(
      text: widget.anchor.narrativeTime ?? '',
    );
    _foreshadows = [
      for (final f in widget.anchor.foreshadows)
        _ForeshadowDraft(text: f.text, resolved: f.resolved),
    ];
  }

  @override
  void dispose() {
    _arcController.dispose();
    _timeController.dispose();
    for (final f in _foreshadows) {
      f.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.lm.palette;
    final t = Translations.of(context);

    // 内容区包 SingleChildScrollView——伏笔清单由 AI
    // 维护、恰是  处理的「>8 条长线悬疑剧本」场景，此前 min Column
    // 无滚动包装，行数 ×（56px+间距）+ 两输入框 + 标题区超屏高即
    // RenderFlex overflow，键盘弹开时可用高度进一步压缩（6 条左右即可
    // 触发）。isScrollControlled 只放开高度上限，不提供滚动。
    return Padding(
      padding: EdgeInsets.only(
        left: IntermediateSpacing.sLg,
        right: IntermediateSpacing.sLg,
        top: IntermediateSpacing.sMd,
        // 键盘弹出不遮挡输入（随内容一起滚动）
        bottom:
            MediaQuery.viewInsetsOf(context).bottom + IntermediateSpacing.sLg,
      ),
      child: SingleChildScrollView(
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
                  borderRadius:
                      BorderRadius.circular(context.lmUi.radius(LmCorner.full)),
                ),
              ),
            ),
            const SizedBox(height: IntermediateSpacing.sMd),
            PanelHeading(title: t.advanced.anchorEdit.sheetTitle),
            const SizedBox(height: IntermediateSpacing.sSm),
            Text(
              t.advanced.anchorEdit.sheetHint,
              style: IntermediateTextStyles.caption.copyWith(
                color: colors.faint,
              ),
            ),
            const SizedBox(height: IntermediateSpacing.sMd),
            _fieldLabel(t.advanced.recap.arc, colors),
            TextField(
              key: const ValueKey('anchor-edit-arc'),
              controller: _arcController,
              maxLines: 2,
              style: IntermediateTextStyles.bodyUi.copyWith(color: colors.ink),
            ),
            const SizedBox(height: IntermediateSpacing.sSm),
            _fieldLabel(t.advanced.anchorEdit.narrativeTime, colors),
            TextField(
              key: const ValueKey('anchor-edit-time'),
              controller: _timeController,
              style: IntermediateTextStyles.bodyUi.copyWith(color: colors.ink),
            ),
            const SizedBox(height: IntermediateSpacing.sMd),
            Row(
              children: [
                Expanded(
                  child: _fieldLabel(t.advanced.recap.foreshadowsOpen, colors),
                ),
                // 新增伏笔行
                IconButton(
                  key: const ValueKey('anchor-edit-add'),
                  tooltip: t.advanced.anchorEdit.addForeshadow,
                  icon: Icon(Icons.add, size: 18, color: colors.primary),
                  onPressed: () => setState(
                    () => _foreshadows.add(_ForeshadowDraft(text: '')),
                  ),
                ),
              ],
            ),
            // 伏笔行：文本 + 兑现开关 + 删除
            for (var i = 0; i < _foreshadows.length; i++)
              _foreshadowRow(i, colors, t),
            const SizedBox(height: IntermediateSpacing.sMd),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                key: const ValueKey('anchor-edit-save'),
                onPressed: _save,
                child: Text(t.common.save),
              ),
            ),
            const SizedBox(height: IntermediateSpacing.sXs),
            SizedBox(
              width: double.infinity,
              child: TextButton(
                onPressed: () => Navigator.of(context).pop(),
                style: TextButton.styleFrom(foregroundColor: colors.muted),
                child: Text(t.common.cancel),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _fieldLabel(String text, LmPalette colors) {
    return Padding(
      padding: const EdgeInsets.only(bottom: IntermediateSpacing.s2xs),
      child: Text(
        text,
        style: IntermediateTextStyles.caption.copyWith(color: colors.faint),
      ),
    );
  }

  Widget _foreshadowRow(
    int index,
    LmPalette colors,
    Translations t,
  ) {
    final draft = _foreshadows[index];
    return Padding(
      padding: const EdgeInsets.only(bottom: IntermediateSpacing.sXs),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              key: ValueKey('anchor-edit-foreshadow-$index'),
              controller: draft.controller,
              style: IntermediateTextStyles.bodyUi.copyWith(
                color: draft.resolved ? colors.faint : colors.ink,
              ),
              decoration: InputDecoration(
                hintText: t.advanced.anchorEdit.foreshadowHint,
              ),
            ),
          ),
          // 兑现状态切换（已兑现=划线弱化）。
          // 纯图标可点控件：补 button 角色 + 按当前状态给可读名
          // （语义补完——此前两个方向是同一个无名节点）。
          Semantics(
            button: true,
            label: draft.resolved
                ? t.common.unmarkResolved
                : t.common.markResolved,
            child: InkWell(
              key: ValueKey('anchor-edit-resolved-$index'),
              onTap: () => setState(() => draft.resolved = !draft.resolved),
              borderRadius:
                  BorderRadius.circular(context.lmUi.radius(LmCorner.full)),
              child: Padding(
                padding: const EdgeInsets.all(IntermediateSpacing.sXs),
                child: Icon(
                  draft.resolved
                      ? Icons.check_circle
                      : Icons.check_circle_outline,
                  size: 18,
                  color: draft.resolved ? colors.success : colors.faint,
                ),
              ),
            ),
          ),
          IconButton(
            key: ValueKey('anchor-edit-remove-$index'),
            tooltip: t.advanced.anchorEdit.removeForeshadow,
            icon: Icon(Icons.close, size: 16, color: colors.faint),
            onPressed: () => setState(() => _foreshadows.removeAt(index)),
          ),
        ],
      ),
    );
  }

  void _save() {
    final foreshadows = [
      for (final draft in _foreshadows)
        if (draft.controller.text.trim().isNotEmpty)
          AnchorForeshadow(
            text: draft.controller.text.trim(),
            resolved: draft.resolved,
          ),
    ];
    final arc = _arcController.text.trim();
    final time = _timeController.text.trim();
    // 直接构造而非 copyWith：copyWith 的 null 语义是「保留」，无法清空字段
    Navigator.of(context).pop(
      StoryAnchor(
        updatedTurn: widget.anchor.updatedTurn,
        arc: arc.isEmpty ? null : arc,
        narrativeTime: time.isEmpty ? null : time,
        foreshadows: foreshadows,
        oneLiner: widget.anchor.oneLiner,
      ),
    );
  }
}

/// 伏笔编辑行草稿（controller 生命周期随 sheet）
class _ForeshadowDraft {
  _ForeshadowDraft({required String text, this.resolved = false})
      : controller = TextEditingController(text: text);

  final TextEditingController controller;
  bool resolved;

  void dispose() => controller.dispose();
}
