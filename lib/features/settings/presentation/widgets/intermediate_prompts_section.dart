import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lmstory/core/config/intermediate_config.dart';
import 'package:lmstory/core/di/providers.dart';
import 'package:lmstory/core/theme/api/lm_component_kit.dart';
import 'package:lmstory/core/theme/intermediate/intermediate_spacing.dart';
import 'package:lmstory/core/theme/intermediate/intermediate_text_styles.dart';
import 'package:lmstory/core/theme/system/lm_motion.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';
import 'package:lmstory/features/settings/presentation/pages/intermediate_prompt_editor_page.dart';
import 'package:lmstory/features/settings/presentation/pages/intermediate_prompt_preview_page.dart';
import 'package:lmstory/features/settings/presentation/widgets/intermediate_prompt_metadata.dart';
import 'package:lmstory/i18n/strings.g.dart';

/// 故事模式设置 — 提示词模板区块。
///
/// 渲染 10 段可编辑提示词的 tile 列表。每个 tile 显示：
/// - 标题（Inter label）
/// - 描述（Inter caption，muted，1 行截断）
/// - 字数 + 状态标签（Inter caption，faint/primary）
/// - 已自定义提示词左侧显示 primary 色圆点
///
/// 交互：点击 tile → [IntermediatePromptEditorPage] 全屏编辑器。
///
/// 数据来源：[intermediateConfigProvider] 提供当前生效的 PromptsConfig，
/// 与各字段的内置默认值（[PromptFieldMeta.defaultValue]）比较判断是否已自定义。
///
/// 持久化：不在本组件内完成，由编辑器页面负责 Save/Reset。
/// 本组件只读展示当前配置状态。
class IntermediatePromptsSection extends ConsumerWidget {
  const IntermediatePromptsSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.lm.palette;
    final t = Translations.of(context);
    final configAsync = ref.watch(intermediateConfigProvider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          t.settings.intermediate.prompts.sectionTitle,
          style: IntermediateTextStyles.title.copyWith(color: colors.ink),
        ),
        const SizedBox(height: IntermediateSpacing.s2xs),
        Text(
          t.settings.intermediate.prompts.sectionDesc,
          style: IntermediateTextStyles.caption.copyWith(color: colors.muted),
        ),
        const SizedBox(height: IntermediateSpacing.sMd),
        // 高级配置提醒
        Container(
          padding: const EdgeInsets.symmetric(
            horizontal: IntermediateSpacing.sMd,
            vertical: IntermediateSpacing.sSm,
          ),
          decoration: BoxDecoration(
            color: colors.accentDim,
            borderRadius:
                BorderRadius.circular(context.lmUi.radius(LmCorner.sm)),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                Icons.info_outline,
                size: 16,
                color: colors.accent,
              ),
              const SizedBox(width: IntermediateSpacing.sSm),
              Expanded(
                child: Text(
                  t.settings.intermediate.prompts.sectionNote,
                  style: IntermediateTextStyles.caption
                      .copyWith(color: colors.muted, height: 1.5),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: IntermediateSpacing.sMd),
        // tile 列表
        Container(
          decoration: BoxDecoration(
            color: colors.surface,
            borderRadius:
                BorderRadius.circular(context.lmUi.radius(LmCorner.lg)),
          ),
          child: configAsync.when(
            data: (config) => _buildTileList(context, config.prompts),
            loading: () => _buildLoadingList(colors),
            error: (e, _) => _buildErrorList(colors, e.toString()),
          ),
        ),
        const SizedBox(height: IntermediateSpacing.sMd),
        // 预览拼接效果按钮（全屏只读展示四步生成中四个 LLM 请求的完整 messages）
        _PreviewButton(),
      ],
    );
  }

  Widget _buildTileList(
    BuildContext context,
    PromptsConfig prompts,
  ) {
    final colors = context.lm.palette;
    return Column(
      children: [
        for (var i = 0; i < promptFieldMetas.length; i++) ...[
          if (i > 0) Divider(height: 1, thickness: 1, color: colors.divider),
          _PromptTile(
            meta: promptFieldMetas[i],
            currentValue: promptFieldMetas[i].currentValue(prompts),
          ),
        ],
      ],
    );
  }

  Widget _buildLoadingList(LmPalette colors) => Padding(
        padding: const EdgeInsets.all(IntermediateSpacing.sLg),
        child: Center(
          child: SizedBox(
            width: 20,
            height: 20,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: colors.muted,
            ),
          ),
        ),
      );

  Widget _buildErrorList(LmPalette colors, String error) => Padding(
        padding: const EdgeInsets.all(IntermediateSpacing.sLg),
        child: Text(
          error,
          style: IntermediateTextStyles.caption.copyWith(color: colors.error),
          maxLines: 4,
          overflow: TextOverflow.ellipsis,
        ),
      );
}

/// 单个提示词 tile（标题 + 描述 + 状态 + 导航箭头）。
class _PromptTile extends StatelessWidget {
  const _PromptTile({
    required this.meta,
    required this.currentValue,
  });

  final PromptFieldMeta meta;
  final String currentValue;

  @override
  Widget build(BuildContext context) {
    final colors = context.lm.palette;
    final t = Translations.of(context);
    final isCustomized = currentValue != meta.defaultValue;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () => Navigator.push<void>(
          context,
          MaterialPageRoute<void>(
            builder: (_) => IntermediatePromptEditorPage(meta: meta),
          ),
        ),
        borderRadius: BorderRadius.circular(context.lmUi.radius(LmCorner.lg)),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: IntermediateSpacing.sMd,
            vertical: IntermediateSpacing.sMd,
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 已自定义圆点（左侧视觉标记）
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: _CustomizedDot(visible: isCustomized),
              ),
              const SizedBox(width: IntermediateSpacing.sSm),
              // 标题 + 描述 + 状态行
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      meta.title(t),
                      style: IntermediateTextStyles.label
                          .copyWith(color: colors.ink),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: IntermediateSpacing.s2xs),
                    Text(
                      meta.desc(t),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: IntermediateTextStyles.caption
                          .copyWith(color: colors.muted),
                    ),
                    const SizedBox(height: IntermediateSpacing.s2xs),
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            t.settings.intermediate.prompts.charCount(
                              count: currentValue.length,
                            ),
                            style: IntermediateTextStyles.caption
                                .copyWith(color: colors.faint),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        const SizedBox(width: IntermediateSpacing.sSm),
                        Text(
                          '·',
                          style: IntermediateTextStyles.caption
                              .copyWith(color: colors.faint),
                        ),
                        const SizedBox(width: IntermediateSpacing.sSm),
                        Flexible(
                          child: Text(
                            isCustomized
                                ? t.settings.intermediate.prompts.customized
                                : t.settings.intermediate.prompts.defaultStatus,
                            style: IntermediateTextStyles.caption.copyWith(
                              color:
                                  isCustomized ? colors.primary : colors.faint,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(width: IntermediateSpacing.sSm),
              // 导航箭头
              Icon(
                Icons.chevron_right,
                size: 20,
                color: colors.faint,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 已自定义圆点（primary 色，仅 isCustomized 时可见）。
class _CustomizedDot extends StatelessWidget {
  const _CustomizedDot({required this.visible});

  final bool visible;

  @override
  Widget build(BuildContext context) {
    final colors = context.lm.palette;
    return AnimatedOpacity(
      opacity: visible ? 1.0 : 0.0,
      duration: LmMotion.fast,
      child: Container(
        width: 6,
        height: 6,
        decoration: BoxDecoration(
          color: colors.primary,
          shape: BoxShape.circle,
        ),
      ),
    );
  }
}

/// 预览拼接效果按钮。
///
/// 全宽次级按钮：surface 底 + primary 文字 + 右侧箭头，点击进入
/// [IntermediatePromptPreviewPage] 全屏只读预览。置于 tile 列表下方，
/// 与列表视觉同区，作为调参辅助工具的统一入口。
///
/// 视觉决策（impeccable / Restrained）：
/// - 不用 primary 实心（避免与主操作混淆，预览是辅助查看非保存类动作）
/// - 用 surface 底 + primary 文字 + 1px primaryDim 边框，弱化但可识别
/// - 触感反馈 InkWell + rLg 圆角，与 tile 列表容器一致
class _PreviewButton extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final colors = context.lm.palette;
    final t = Translations.of(context);

    return Material(
      color: colors.surface,
      borderRadius: BorderRadius.circular(context.lmUi.radius(LmCorner.lg)),
      child: InkWell(
        onTap: () => Navigator.push<void>(
          context,
          MaterialPageRoute<void>(
            builder: (_) => const IntermediatePromptPreviewPage(),
          ),
        ),
        borderRadius: BorderRadius.circular(context.lmUi.radius(LmCorner.lg)),
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(
            horizontal: IntermediateSpacing.sMd,
            vertical: IntermediateSpacing.sMd,
          ),
          decoration: BoxDecoration(
            borderRadius:
                BorderRadius.circular(context.lmUi.radius(LmCorner.lg)),
            border: Border.all(color: colors.primaryDim),
          ),
          child: Row(
            children: [
              Icon(Icons.visibility_outlined, size: 18, color: colors.primary),
              const SizedBox(width: IntermediateSpacing.sSm),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      t.settings.intermediate.prompts.previewButton,
                      style: IntermediateTextStyles.label
                          .copyWith(color: colors.primary),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      t.settings.intermediate.prompts.previewButtonDesc,
                      style: IntermediateTextStyles.caption
                          .copyWith(color: colors.muted),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              Icon(Icons.chevron_right, size: 20, color: colors.primary),
            ],
          ),
        ),
      ),
    );
  }
}
