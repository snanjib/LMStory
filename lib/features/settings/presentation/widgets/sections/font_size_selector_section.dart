import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lmstory/core/theme/api/lm_component_kit.dart';
import 'package:lmstory/core/theme/simple/simple_spacing.dart';
import 'package:lmstory/core/theme/simple/simple_text_styles.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';
import 'package:lmstory/core/widgets/commit_slider.dart';
import 'package:lmstory/features/settings/presentation/controllers/settings_controller.dart';
import 'package:lmstory/i18n/strings.g.dart';

/// 字体大小基准字号（与 [SimpleTextStyles.body] 的 fontSize 一致）。
///
/// fontScale = fontSize / kFontSizeBaseSize。
/// 例如 fontSize=15 → fontScale=1.0；fontSize=22 → fontScale≈1.47。
const double kFontSizeBaseSize = 15;

/// 字体大小范围常量（对标 ChatBox `LazySlider` min/max/step）。
const int kFontSizeMin = 12;
const int kFontSizeMax = 22;
const int kFontSizeDefault = 15;

/// 字体大小选择区块（连续 Slider + 默认值标记尺 + 实时预览）。
///
/// 设计参考 ChatBox `LazySlider`：
/// - min=12, max=22, step=1, divisions=10
/// - 默认值 15 处显示彩色标记 + "默认" label
/// - 实际生效字号数值显示（如"15 px"）
///
/// 与原 3 档胶囊按钮相比，连续 Slider 提供更细粒度的字号控制，
/// 默认值标记让用户一眼看到"推荐起点"，预览卡片让所见即所得。
class FontSizeSelectorSection extends ConsumerWidget {
  const FontSizeSelectorSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.lm.palette;
    final fontSize = ref.watch(
      settingsNotifierProvider.select((s) => s.fontSize),
    );
    final t = Translations.of(context);

    // 钳制到合法范围（防御脏数据）
    final clampedSize = fontSize.clamp(kFontSizeMin, kFontSizeMax);
    final isDefault = clampedSize == kFontSizeDefault;
    final fontScale = clampedSize / kFontSizeBaseSize;

    return Container(
      decoration: BoxDecoration(
        color: colors.surfaceVariant,
        borderRadius: BorderRadius.circular(context.lmUi.radius(LmCorner.lg)),
      ),
      padding: const EdgeInsets.fromLTRB(
        SimpleSpacing.sLg,
        SimpleSpacing.sMd,
        SimpleSpacing.sLg,
        SimpleSpacing.sLg,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // 顶部行：当前字号 + 默认标记（仅当等于默认值时显示）
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Flexible(
                child: Text(
                  t.settings.general.fontSizeActualPx(value: '$clampedSize'),
                  style: SimpleTextStyles.bodySm.copyWith(
                    color: colors.primary,
                    fontWeight: FontWeight.w600,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (isDefault) ...[
                const SizedBox(width: SimpleSpacing.sXs),
                _DefaultBadge(
                  colors: colors,
                  label: t.settings.general.fontSizeDefaultLabel,
                ),
              ],
            ],
          ),
          // Slider（连续整数 10 档）
          SliderTheme(
            data: SliderTheme.of(context).copyWith(
              trackHeight: 4,
              activeTrackColor: colors.primary,
              inactiveTrackColor: colors.divider,
              thumbColor: colors.primary,
              overlayColor: colors.primaryDim,
              // 拖动时显示数值气泡
              valueIndicatorColor: colors.primary,
              valueIndicatorTextStyle: SimpleTextStyles.overline.copyWith(
                color: colors.surface,
                fontWeight: FontWeight.w600,
              ),
              // 离散档位 tick mark：在整数位置显示小圆点
              tickMarkShape: _TickMarkShape(color: colors.surface),
            ),
            child: CommitSlider(
              value: clampedSize.toDouble(),
              min: kFontSizeMin.toDouble(),
              max: kFontSizeMax.toDouble(),
              divisions: kFontSizeMax - kFontSizeMin,
              labelBuilder: (value) => '${value.round()}',
              onCommit: (value) => ref
                  .read(settingsNotifierProvider.notifier)
                  .setFontSize(value.round()),
            ),
          ),
          // 默认值标记尺：在 Slider 下方画出 min/max 端点 + 默认值位置的特殊标记
          _DefaultValueRuler(colors: colors, t: t),
          const SizedBox(height: SimpleSpacing.sMd),
          // 预览卡片：模拟消息气泡，用当前 fontScale 渲染示例文本
          _FontSizePreview(
            fontScale: fontScale,
            colors: colors,
            previewText: t.settings.general.fontSizePreviewText,
          ),
        ],
      ),
    );
  }
}

/// "默认" 徽章（字号等于默认值时显示在字号数值旁）。
class _DefaultBadge extends StatelessWidget {
  const _DefaultBadge({required this.colors, required this.label});

  final LmPalette colors;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: SimpleSpacing.sXs,
        vertical: 1,
      ),
      decoration: BoxDecoration(
        color: colors.primaryDim,
        borderRadius: BorderRadius.circular(context.lmUi.radius(LmCorner.full)),
      ),
      child: Text(
        label,
        style: SimpleTextStyles.overline.copyWith(
          color: colors.primary,
          fontSize: 10,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.04,
        ),
      ),
    );
  }
}

/// 默认值标记尺：在 Slider 下方画出 min/max 端点 + 默认值位置的特殊标记。
///
/// 用 LayoutBuilder 计算默认值在 Slider 轨道上的实际像素位置，
/// 在该位置画一条彩色短竖线 + "默认" label。
/// Flutter Slider 的 track 实际宽度 = parentWidth - 2 * trackHorizontalPadding，
/// trackHorizontalPadding = overlayShape radius / 2，默认 overlay 半径 24px。
const double _sliderTrackPadding = 12;

class _DefaultValueRuler extends StatelessWidget {
  const _DefaultValueRuler({required this.colors, required this.t});

  final LmPalette colors;
  final Translations t;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final trackWidth = constraints.maxWidth - _sliderTrackPadding * 2;
        final defaultX = (kFontSizeDefault - kFontSizeMin) /
                (kFontSizeMax - kFontSizeMin) *
                trackWidth +
            _sliderTrackPadding;

        return SizedBox(
          height: 28,
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              // 顶部刻度线（连接 Slider 与标记尺的视觉锚点）
              Positioned(
                top: 0,
                left: _sliderTrackPadding,
                right: _sliderTrackPadding,
                child: Container(
                  height: 1,
                  color: colors.divider,
                ),
              ),
              // 默认值竖线（彩色，比端点 tick mark 更粗）
              Positioned(
                top: -4,
                left: defaultX - 1,
                child: Container(
                  width: 2,
                  height: 10,
                  color: colors.primary,
                ),
              ),
              // 默认值 label
              Positioned(
                top: 8,
                left: defaultX - 14,
                child: Text(
                  t.settings.general.fontSizeDefaultLabel,
                  style: SimpleTextStyles.overline.copyWith(
                    color: colors.primary,
                    fontSize: 10,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              // min 端点 label
              Positioned(
                top: 8,
                left: 0,
                child: Text(
                  '$kFontSizeMin',
                  style: SimpleTextStyles.overline.copyWith(
                    color: colors.faint,
                    fontSize: 10,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ),
              // max 端点 label
              Positioned(
                top: 8,
                right: 0,
                child: Text(
                  '$kFontSizeMax',
                  style: SimpleTextStyles.overline.copyWith(
                    color: colors.faint,
                    fontSize: 10,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// 字号预览卡片：模拟助手消息气泡渲染示例文本。
///
/// 用 SimpleTextStyles.body 的基准字号 × fontScale 渲染，
/// 与聊天页助手消息渲染逻辑保持一致，让用户在设置页
/// 看到的预览就是聊天页实际的字号效果。
class _FontSizePreview extends StatelessWidget {
  const _FontSizePreview({
    required this.fontScale,
    required this.colors,
    required this.previewText,
  });

  final double fontScale;
  final LmPalette colors;
  final String previewText;

  @override
  Widget build(BuildContext context) {
    final baseSize = SimpleTextStyles.body.fontSize ?? kFontSizeBaseSize;
    final scaledSize = baseSize * fontScale;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(
        horizontal: SimpleSpacing.sMd,
        vertical: SimpleSpacing.sSm,
      ),
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(context.lmUi.radius(LmCorner.md)),
        border: Border.all(color: colors.divider),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            previewText,
            style: SimpleTextStyles.body.copyWith(
              color: colors.ink,
              fontSize: scaledSize,
              height: 1.6,
            ),
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: SimpleSpacing.s2xs),
          Text(
            Translations.of(context).settings.general.fontSizePreviewCaption,
            style: SimpleTextStyles.overline.copyWith(
              color: colors.faint,
              fontWeight: FontWeight.w400,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }
}

/// 自定义 Slider tick mark：在整数档位渲染小圆点（替代 Material 默认竖线）。
class _TickMarkShape extends SliderTickMarkShape {
  const _TickMarkShape({required this.color});

  final Color color;
  static const double _radius = 2.5;

  @override
  Size getPreferredSize({
    required SliderThemeData sliderTheme,
    bool isEnabled = false,
  }) =>
      const Size.square(_radius * 2);

  @override
  void paint(
    PaintingContext context,
    Offset center, {
    required RenderBox parentBox,
    required SliderThemeData sliderTheme,
    required Animation<double> enableAnimation,
    required TextDirection textDirection,
    required Offset thumbCenter,
    bool isEnabled = false,
  }) {
    final canvas = context.canvas;
    final paint = Paint()..color = color;
    canvas.drawCircle(center, _radius, paint);
  }
}
