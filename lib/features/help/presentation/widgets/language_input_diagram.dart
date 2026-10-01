import 'package:flutter/material.dart';
import 'package:lmstory/core/theme/api/lm_component_kit.dart';
import 'package:lmstory/core/theme/simple/simple_spacing.dart';
import 'package:lmstory/core/theme/simple/simple_text_styles.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';
import 'package:lmstory/i18n/strings.g.dart';

/// 语言与输入示意图（2026-07-27 新增）。
///
/// 用于「语言与输入」wiki 页顶部主视觉。
///
/// 设计：
/// - 上段：3 种语言选项（中文可用 / English 预告 / 跟随系统预告）
/// - 下段：4 种发送快捷键（Enter / Shift+Enter / Ctrl+Enter / 回车换行）
class LanguageInputDiagram extends StatelessWidget {
  const LanguageInputDiagram({super.key});

  @override
  Widget build(BuildContext context) {
    final colors = context.lm.palette;
    final t = Translations.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 上段：3 种语言选项
        Container(
          padding: const EdgeInsets.all(SimpleSpacing.sMd),
          decoration: BoxDecoration(
            color: colors.surfaceVariant,
            borderRadius:
                BorderRadius.circular(context.lmUi.radius(LmCorner.lg)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                t.help.languageInput.diagramLangTitle,
                style: SimpleTextStyles.bodySm.copyWith(
                  color: colors.muted,
                  fontWeight: FontWeight.w600,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: SimpleSpacing.sSm),
              Row(
                children: [
                  Expanded(
                    child: _LangCard(
                      icon: Icons.check_circle,
                      label: t.help.languageInput.langZh,
                      desc: t.help.languageInput.langZhDesc,
                      highlight: true,
                    ),
                  ),
                  const SizedBox(width: SimpleSpacing.sXs),
                  Expanded(
                    child: _LangCard(
                      icon: Icons.schedule_outlined,
                      label: t.help.languageInput.langEn,
                      desc: t.help.languageInput.langEnDesc,
                      highlight: false,
                      disabled: true,
                    ),
                  ),
                  const SizedBox(width: SimpleSpacing.sXs),
                  Expanded(
                    child: _LangCard(
                      icon: Icons.schedule_outlined,
                      label: t.help.languageInput.langSystem,
                      desc: t.help.languageInput.langSystemDesc,
                      highlight: false,
                      disabled: true,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: SimpleSpacing.sMd),

        // 下段：发送键 + 换行键概览（2x2 网格）
        Container(
          padding: const EdgeInsets.all(SimpleSpacing.sMd),
          decoration: BoxDecoration(
            color: colors.surface,
            borderRadius:
                BorderRadius.circular(context.lmUi.radius(LmCorner.lg)),
            border: Border.all(color: colors.divider),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                t.help.languageInput.diagramSendKeyTitle,
                style: SimpleTextStyles.bodySm.copyWith(
                  color: colors.muted,
                  fontWeight: FontWeight.w600,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: SimpleSpacing.sSm),
              Row(
                children: [
                  Expanded(
                    child: _SendKeyCard(
                      icon: Icons.keyboard_return,
                      label: t.help.languageInput.sendKeyEnter,
                      desc: t.help.languageInput.sendKeyEnterDesc,
                      highlight: true,
                    ),
                  ),
                  const SizedBox(width: SimpleSpacing.sXs),
                  Expanded(
                    child: _SendKeyCard(
                      icon: Icons.arrow_upward,
                      label: t.help.languageInput.sendKeyShiftEnter,
                      desc: t.help.languageInput.sendKeyShiftEnterDesc,
                      highlight: false,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: SimpleSpacing.sXs),
              Row(
                children: [
                  Expanded(
                    child: _SendKeyCard(
                      icon: Icons.keyboard_command_key,
                      label: t.help.languageInput.sendKeyCtrlEnter,
                      desc: t.help.languageInput.sendKeyCtrlEnterDesc,
                      highlight: false,
                    ),
                  ),
                  const SizedBox(width: SimpleSpacing.sXs),
                  Expanded(
                    child: _SendKeyCard(
                      icon: Icons.send,
                      label: t.help.languageInput.sendKeyButton,
                      desc: t.help.languageInput.sendKeyButtonDesc,
                      highlight: false,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: SimpleSpacing.sXs),
              Text(
                '${t.help.languageInput.newlineKeyEnter} · ${t.help.languageInput.newlineKeyShiftEnter} · ${t.help.languageInput.newlineKeyCtrlEnter} · ${t.help.languageInput.newlineKeyAltEnter}',
                style: SimpleTextStyles.caption.copyWith(
                  color: colors.faint,
                  fontSize: 10,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _LangCard extends StatelessWidget {
  const _LangCard({
    required this.icon,
    required this.label,
    required this.desc,
    required this.highlight,
    this.disabled = false,
  });

  final IconData icon;
  final String label;
  final String desc;
  final bool highlight;
  final bool disabled;

  @override
  Widget build(BuildContext context) {
    final colors = context.lm.palette;

    return Container(
      padding: const EdgeInsets.all(SimpleSpacing.sSm),
      decoration: BoxDecoration(
        color: highlight
            ? colors.primaryDim
            : (disabled ? colors.surfaceVariant : colors.surface),
        borderRadius: BorderRadius.circular(context.lmUi.radius(LmCorner.md)),
        border: Border.all(
          color: highlight ? colors.primary : colors.divider,
        ),
      ),
      child: Column(
        children: [
          Icon(
            icon,
            color: highlight
                ? colors.primary
                : (disabled ? colors.faint : colors.muted),
            size: 20,
          ),
          const SizedBox(height: SimpleSpacing.s2xs),
          Text(
            label,
            style: SimpleTextStyles.caption.copyWith(
              color: highlight
                  ? colors.primary
                  : (disabled ? colors.faint : colors.ink),
              fontWeight: FontWeight.w600,
            ),
            textAlign: TextAlign.center,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: SimpleSpacing.s2xs),
          Text(
            desc,
            style: SimpleTextStyles.caption.copyWith(
              color: colors.faint,
              fontSize: 10,
              height: 1.3,
            ),
            textAlign: TextAlign.center,
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }
}

class _SendKeyCard extends StatelessWidget {
  const _SendKeyCard({
    required this.icon,
    required this.label,
    required this.desc,
    required this.highlight,
  });

  final IconData icon;
  final String label;
  final String desc;
  final bool highlight;

  @override
  Widget build(BuildContext context) {
    final colors = context.lm.palette;

    return Container(
      padding: const EdgeInsets.all(SimpleSpacing.sSm),
      decoration: BoxDecoration(
        color: highlight ? colors.primaryDim : colors.surfaceVariant,
        borderRadius: BorderRadius.circular(context.lmUi.radius(LmCorner.md)),
        border: Border.all(color: highlight ? colors.primary : colors.divider),
      ),
      child: Row(
        children: [
          Icon(
            icon,
            color: highlight ? colors.primary : colors.muted,
            size: 18,
          ),
          const SizedBox(width: SimpleSpacing.sXs),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: SimpleTextStyles.caption.copyWith(
                    color: highlight ? colors.primary : colors.ink,
                    fontWeight: FontWeight.w600,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                Text(
                  desc,
                  style: SimpleTextStyles.caption.copyWith(
                    color: colors.muted,
                    fontSize: 10,
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
