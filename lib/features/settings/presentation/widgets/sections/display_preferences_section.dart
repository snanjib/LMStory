import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lmstory/core/theme/api/lm_component_kit.dart';
import 'package:lmstory/core/theme/simple/simple_spacing.dart';
import 'package:lmstory/core/theme/simple/simple_text_styles.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';
import 'package:lmstory/features/settings/domain/entities/display_preferences.dart';
import 'package:lmstory/features/settings/presentation/controllers/settings_controller.dart';
import 'package:lmstory/i18n/strings.g.dart';

/// 显示偏好区块：时间戳 / 模型名 / Token 用量 / 字数 / 首字延迟 / 头像
/// 开关 + 消息布局选择。
///
/// 所有开关持久化于 `DisplayPreferences`，布局选择通过
/// `setMessageLayoutMode` 持久化。
class DisplayPreferencesSection extends ConsumerWidget {
  const DisplayPreferencesSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.lm.palette;
    final displayPrefs = ref.watch(
      settingsNotifierProvider.select((s) => s.displayPreferences),
    );
    final t = Translations.of(context);

    final toggles = <(String, String, bool, ValueChanged<bool>)>[
      (
        t.settings.chatSettings.showTimestamp,
        t.settings.chatSettings.showTimestampDesc,
        displayPrefs.showTimestamp,
        (v) => ref.read(settingsNotifierProvider.notifier).setShowTimestamp(v),
      ),
      (
        t.settings.chatSettings.showModelName,
        t.settings.chatSettings.showModelNameDesc,
        displayPrefs.showModelName,
        (v) => ref.read(settingsNotifierProvider.notifier).setShowModelName(v),
      ),
      (
        t.settings.chatSettings.showTokenUsed,
        t.settings.chatSettings.showTokenUsedDesc,
        displayPrefs.showTokenUsed,
        (v) => ref.read(settingsNotifierProvider.notifier).setShowTokenUsed(v),
      ),
      (
        t.settings.chatSettings.showWordCount,
        t.settings.chatSettings.showWordCountDesc,
        displayPrefs.showWordCount,
        (v) => ref.read(settingsNotifierProvider.notifier).setShowWordCount(v),
      ),
      (
        t.settings.chatSettings.showFirstTokenLatency,
        t.settings.chatSettings.showFirstTokenLatencyDesc,
        displayPrefs.showFirstTokenLatency,
        (v) => ref
            .read(settingsNotifierProvider.notifier)
            .setShowFirstTokenLatency(v),
      ),
      (
        t.settings.chatSettings.showAvatar,
        t.settings.chatSettings.showAvatarDesc,
        displayPrefs.showAvatar,
        (v) => ref.read(settingsNotifierProvider.notifier).setShowAvatar(v),
      ),
    ];

    return Container(
      decoration: BoxDecoration(
        color: colors.surfaceVariant,
        borderRadius: BorderRadius.circular(context.lmUi.radius(LmCorner.lg)),
      ),
      child: Column(
        children: [
          for (var i = 0; i < toggles.length; i++) ...[
            if (i > 0)
              Divider(
                height: 1,
                color: colors.divider,
                indent: SimpleSpacing.sLg,
              ),
            _DisplayToggleItem(
              title: toggles[i].$1,
              subtitle: toggles[i].$2,
              value: toggles[i].$3,
              onChanged: toggles[i].$4,
              colors: colors,
            ),
          ],
          Divider(height: 1, color: colors.divider, indent: SimpleSpacing.sLg),
          _MessageLayoutSelector(currentMode: displayPrefs.messageLayoutMode),
        ],
      ),
    );
  }
}

/// 单个显示开关项：标题 + 副标题 + Switch。
class _DisplayToggleItem extends StatelessWidget {
  const _DisplayToggleItem({
    required this.title,
    required this.subtitle,
    required this.value,
    required this.onChanged,
    required this.colors,
  });

  final String title;
  final String subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;
  final LmPalette colors;

  @override
  Widget build(BuildContext context) {
    return MergeSemantics(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          SimpleSpacing.sLg,
          SimpleSpacing.sMd,
          SimpleSpacing.sLg,
          SimpleSpacing.sMd,
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: SimpleTextStyles.body.copyWith(
                      fontWeight: FontWeight.w500,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: SimpleTextStyles.caption,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            Switch(
              value: value,
              onChanged: onChanged,
              activeThumbColor: colors.primary,
              activeTrackColor: colors.primary.withValues(alpha: 0.5),
            ),
          ],
        ),
      ),
    );
  }
}

/// 消息布局选择器：气泡 / 标准，胶囊样式。
class _MessageLayoutSelector extends ConsumerWidget {
  const _MessageLayoutSelector({required this.currentMode});

  final MessageLayoutMode currentMode;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.lm.palette;
    final t = Translations.of(context);

    return Padding(
      padding: const EdgeInsets.fromLTRB(
        SimpleSpacing.sLg,
        SimpleSpacing.sMd,
        SimpleSpacing.sLg,
        SimpleSpacing.sMd,
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  t.settings.chatSettings.messageLayout,
                  style: SimpleTextStyles.body.copyWith(
                    fontWeight: FontWeight.w500,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 2),
                Text(
                  t.settings.chatSettings.messageLayoutDesc,
                  style: SimpleTextStyles.caption,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          const SizedBox(width: SimpleSpacing.sSm),
          Container(
            padding: const EdgeInsets.all(SimpleSpacing.s2xs),
            decoration: BoxDecoration(
              color: colors.bg,
              borderRadius:
                  BorderRadius.circular(context.lmUi.radius(LmCorner.full)),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _LayoutModeChip(
                  label: t.settings.chatSettings.messageLayoutOptions.bubble,
                  isSelected: currentMode == MessageLayoutMode.bubble,
                  onTap: () => ref
                      .read(settingsNotifierProvider.notifier)
                      .setMessageLayoutMode(MessageLayoutMode.bubble),
                  colors: colors,
                ),
                _LayoutModeChip(
                  label: t.settings.chatSettings.messageLayoutOptions.standard,
                  isSelected: currentMode == MessageLayoutMode.standard,
                  onTap: () => ref
                      .read(settingsNotifierProvider.notifier)
                      .setMessageLayoutMode(MessageLayoutMode.standard),
                  colors: colors,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 单个布局 chip（：Material+InkWell+Semantics，
/// 选中前景走 onPrimary 令牌——原为裸 GestureDetector+硬编码白）。
class _LayoutModeChip extends StatelessWidget {
  const _LayoutModeChip({
    required this.label,
    required this.isSelected,
    required this.onTap,
    required this.colors,
  });

  final String label;
  final bool isSelected;
  final VoidCallback onTap;
  final LmPalette colors;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      selected: isSelected,
      child: Material(
        color: isSelected ? colors.primary : Colors.transparent,
        borderRadius: BorderRadius.circular(context.lmUi.radius(LmCorner.full)),
        child: InkWell(
          onTap: onTap,
          borderRadius:
              BorderRadius.circular(context.lmUi.radius(LmCorner.full)),
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: SimpleSpacing.sSm,
              vertical: SimpleSpacing.s2xs,
            ),
            child: Text(
              label,
              style: SimpleTextStyles.caption.copyWith(
                color: isSelected ? colors.onPrimary : colors.muted,
                fontWeight: isSelected ? FontWeight.w600 : FontWeight.w400,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ),
      ),
    );
  }
}
