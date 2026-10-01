import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lmstory/core/theme/api/lm_component_kit.dart';
import 'package:lmstory/core/theme/simple/components/simple_chat_input.dart';
import 'package:lmstory/core/theme/simple/components/simple_selection_option.dart';
import 'package:lmstory/core/theme/simple/simple_spacing.dart';
import 'package:lmstory/core/theme/simple/simple_text_styles.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';
import 'package:lmstory/features/settings/presentation/controllers/settings_controller.dart';
import 'package:lmstory/i18n/strings.g.dart';

/// 发送键/换行键选择区块。
///
/// 桌面端显示"发送键"和"换行键"两个独立配置区块，冲突选项自动禁用。
/// 移动端显示"回车发送"和"回车换行"两个选项。
class SendKeySelectorSection extends ConsumerWidget {
  const SendKeySelectorSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.lm.palette;
    final sendKey = ref.watch(
      settingsNotifierProvider.select((s) => s.sendKey),
    );
    final newlineKey = ref.watch(
      settingsNotifierProvider.select((s) => s.newlineKey),
    );
    final t = Translations.of(context);
    final notifier = ref.read(settingsNotifierProvider.notifier);

    final isMobile = Theme.of(context).platform == TargetPlatform.android ||
        Theme.of(context).platform == TargetPlatform.iOS;

    if (isMobile) {
      return _buildMobile(context, colors, t, notifier, sendKey);
    }
    return _buildDesktop(context, colors, t, notifier, sendKey, newlineKey);
  }

  // 移动端：回车发送 / 回车换行
  Widget _buildMobile(
    BuildContext context,
    LmPalette colors,
    Translations t,
    SettingsNotifier notifier,
    SendKey sendKey,
  ) {
    return Container(
      decoration: BoxDecoration(
        color: colors.surfaceVariant,
        borderRadius: BorderRadius.circular(context.lmUi.radius(LmCorner.lg)),
      ),
      child: Column(
        children: [
          SimpleSelectionOption(
            label: t.settings.general.mobileSendKeyOptions.enter,
            isSelected: sendKey == SendKey.enter,
            onTap: () => notifier.setSendKey(SendKey.enter),
          ),
          SimpleSelectionOption(
            label: t.settings.general.mobileSendKeyOptions.button,
            isSelected: sendKey == SendKey.button,
            onTap: () => notifier.setSendKey(SendKey.button),
          ),
          if (sendKey == SendKey.enter)
            _buildHint(colors, t.settings.general.sendKeyEnterHint),
          _buildHint(colors, t.settings.general.sendButtonNewlineHint),
        ],
      ),
    );
  }

  // 桌面端：发送键（3 选项）+ 换行键（4 选项，冲突禁用）
  Widget _buildDesktop(
    BuildContext context,
    LmPalette colors,
    Translations t,
    SettingsNotifier notifier,
    SendKey sendKey,
    NewlineKey newlineKey,
  ) {
    return Container(
      decoration: BoxDecoration(
        color: colors.surfaceVariant,
        borderRadius: BorderRadius.circular(context.lmUi.radius(LmCorner.lg)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildSectionTitle(colors, t.settings.general.sendKey),
          SimpleSelectionOption(
            label: t.settings.general.sendKeyOptions.enter,
            isSelected: sendKey == SendKey.enter,
            onTap: () => notifier.setSendKey(SendKey.enter),
          ),
          SimpleSelectionOption(
            label: t.settings.general.sendKeyOptions.shiftEnter,
            isSelected: sendKey == SendKey.shiftEnter,
            onTap: () => notifier.setSendKey(SendKey.shiftEnter),
          ),
          SimpleSelectionOption(
            label: t.settings.general.sendKeyOptions.ctrlEnter,
            isSelected: sendKey == SendKey.ctrlEnter,
            onTap: () => notifier.setSendKey(SendKey.ctrlEnter),
          ),
          Divider(height: 1, color: colors.divider),
          _buildSectionTitle(colors, t.settings.general.newlineKey),
          SimpleSelectionOption(
            label: t.settings.general.newlineKeyOptions.enter,
            isSelected: newlineKey == NewlineKey.enter,
            isEnabled: sendKey != SendKey.enter,
            onTap: () => notifier.setNewlineKey(NewlineKey.enter),
          ),
          SimpleSelectionOption(
            label: t.settings.general.newlineKeyOptions.shiftEnter,
            isSelected: newlineKey == NewlineKey.shiftEnter,
            isEnabled: sendKey != SendKey.shiftEnter,
            onTap: () => notifier.setNewlineKey(NewlineKey.shiftEnter),
          ),
          SimpleSelectionOption(
            label: t.settings.general.newlineKeyOptions.ctrlEnter,
            isSelected: newlineKey == NewlineKey.ctrlEnter,
            isEnabled: sendKey != SendKey.ctrlEnter,
            onTap: () => notifier.setNewlineKey(NewlineKey.ctrlEnter),
          ),
          SimpleSelectionOption(
            label: t.settings.general.newlineKeyOptions.altEnter,
            isSelected: newlineKey == NewlineKey.altEnter,
            onTap: () => notifier.setNewlineKey(NewlineKey.altEnter),
          ),
          _buildHint(colors, t.settings.general.sendButtonNewlineHint),
        ],
      ),
    );
  }

  Widget _buildSectionTitle(LmPalette colors, String title) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        SimpleSpacing.sLg,
        SimpleSpacing.sMd,
        SimpleSpacing.sLg,
        0,
      ),
      child: Text(
        title,
        style: SimpleTextStyles.bodySm.copyWith(
          color: colors.muted,
          fontWeight: FontWeight.w600,
        ),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
    );
  }

  Widget _buildHint(LmPalette colors, String text) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        SimpleSpacing.sMd,
        0,
        SimpleSpacing.sMd,
        SimpleSpacing.sSm,
      ),
      child: Align(
        alignment: Alignment.centerLeft,
        child: Text(
          text,
          style: SimpleTextStyles.overline.copyWith(
            color: colors.muted,
          ),
        ),
      ),
    );
  }
}
