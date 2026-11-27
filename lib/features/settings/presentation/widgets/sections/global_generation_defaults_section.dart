import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lmstory/core/theme/api/lm_component_kit.dart';
import 'package:lmstory/core/theme/simple/simple_spacing.dart';
import 'package:lmstory/core/theme/simple/simple_text_styles.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';
import 'package:lmstory/core/widgets/commit_slider.dart';
import 'package:lmstory/features/settings/presentation/controllers/settings_controller.dart';
import 'package:lmstory/features/settings/presentation/utils/model_sampling_controls.dart';
import 'package:lmstory/i18n/strings.g.dart';

/// 全局新对话默认生成参数区块（对标 ChatBox Default Settings for New Conversation）。
///
/// 这些值是会话级字段在物化时的"快照源"——会话级字段在物化时读取当前全局值
/// 并写入 chat_sessions 对应字段。修改全局参数不影响已物化的会话（快照语义）。
///
/// 持久化：
/// - `broadcast_chat.temperature`（0.0-2.0）
/// - `broadcast_chat.top_p`（0.0-1.0）
/// - `broadcast_chat.max_tokens`（int? null=由模型决定）
/// - `broadcast_chat.stream_enabled`（bool）
class GlobalGenerationDefaultsSection extends ConsumerStatefulWidget {
  const GlobalGenerationDefaultsSection({super.key});

  @override
  ConsumerState<GlobalGenerationDefaultsSection> createState() =>
      _GlobalGenerationDefaultsSectionState();
}

class _GlobalGenerationDefaultsSectionState
    extends ConsumerState<GlobalGenerationDefaultsSection> {
  late final TextEditingController _maxTokensController;
  late final FocusNode _maxTokensFocusNode;

  @override
  void initState() {
    super.initState();
    final current = ref.read(
      settingsNotifierProvider.select((s) => s.globalMaxTokens),
    );
    _maxTokensController = TextEditingController(
      text: current?.toString() ?? '',
    );
    _maxTokensFocusNode = FocusNode();
    // 失焦即提交（与回车同语义），此前仅回车提交——
    // 点别处失焦时输入静默丢失且界面仍显示未生效值。
    _maxTokensFocusNode.addListener(_onMaxTokensFocusChanged);
  }

  @override
  void dispose() {
    _maxTokensFocusNode
      ..removeListener(_onMaxTokensFocusChanged)
      ..dispose();
    _maxTokensController.dispose();
    super.dispose();
  }

  void _onMaxTokensFocusChanged() {
    if (_maxTokensFocusNode.hasFocus) return;
    _commitMaxTokens(_maxTokensController.text);
  }

  /// 提交当前输入（回车与失焦共用）：可解析则持久化（空=清除），
  /// 与持久值一致时 no-op。
  void _commitMaxTokens(String value) {
    final parsed = int.tryParse(value.trim());
    final current = ref.read(
      settingsNotifierProvider.select((s) => s.globalMaxTokens),
    );
    if (parsed == current) return;
    ref.read(settingsNotifierProvider.notifier).setGlobalMaxTokens(parsed);
  }

  /// 同步 TextEditingController 与当前 state 值。
  ///
  /// 仅在文本不一致时更新，避免覆盖用户正在输入的光标位置。
  /// 在 build 中直接调用是安全的——只是设置 controller 的 value，
  /// 不会触发 widget rebuild 循环。
  void _syncController(int? maxTokens) {
    final expected = maxTokens?.toString() ?? '';
    if (_maxTokensController.text != expected) {
      _maxTokensController.value = TextEditingValue(
        text: expected,
        selection: TextSelection.collapsed(offset: expected.length),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.lm.palette;
    final t = Translations.of(context);
    final tt = t.settings.chatSettings.generationDefaults;
    final showSampling = ref.watch(
      settingsNotifierProvider.select(
        (s) => samplingControlsForModel(
          s.presets,
          (s.defaultPresetId, s.defaultModelId),
          reasoningEffort: s.defaultReasoningEffort,
        ).showsTemperatureAndTopP,
      ),
    );

    final temperature = ref.watch(
      settingsNotifierProvider.select((s) => s.globalTemperature),
    );
    final topP = ref.watch(
      settingsNotifierProvider.select((s) => s.globalTopP),
    );
    final maxTokens = ref.watch(
      settingsNotifierProvider.select((s) => s.globalMaxTokens),
    );
    final streamEnabled = ref.watch(
      settingsNotifierProvider.select((s) => s.globalStreamEnabled),
    );

    // 同步 maxTokens 控制器（外部变化时，如初始化加载完成后）。
    // 使用 ref.listen 注册回调，在 state 变化时同步 controller。
    // 首次 build 时如果 controller 文本与 state 不一致（如 initState 后 state 才加载完成），
    // 也需要同步——这里用 _syncController 处理。
    ref.listen<int?>(
      settingsNotifierProvider.select((s) => s.globalMaxTokens),
      (previous, next) {
        _syncController(next);
      },
    );
    // 首次 build 同步（initState 时 state 可能还未加载完成）
    _syncController(maxTokens);

    return Container(
      decoration: BoxDecoration(
        color: colors.surfaceVariant,
        borderRadius: BorderRadius.circular(context.lmUi.radius(LmCorner.lg)),
      ),
      padding: const EdgeInsets.all(SimpleSpacing.sLg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 标题与说明
          Text(
            tt.title,
            style: SimpleTextStyles.body.copyWith(fontWeight: FontWeight.w600),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 2),
          Text(
            tt.desc,
            style: SimpleTextStyles.caption,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: SimpleSpacing.sMd),
          Divider(height: 1, color: colors.divider),
          const SizedBox(height: SimpleSpacing.sMd),

          if (showSampling) ...[
            _buildSliderRow(
              colors: colors,
              label: tt.temperature,
              desc: tt.temperatureDesc,
              value: temperature,
              max: 2,
              divisions: 200,
              valueFormatter: (v) => v.toStringAsFixed(2),
              onChanged: ref
                  .read(settingsNotifierProvider.notifier)
                  .setGlobalTemperature,
            ),
            const SizedBox(height: SimpleSpacing.sMd),
            _buildSliderRow(
              colors: colors,
              label: tt.topP,
              desc: tt.topPDesc,
              value: topP,
              max: 1,
              divisions: 100,
              valueFormatter: (v) => v.toStringAsFixed(2),
              onChanged:
                  ref.read(settingsNotifierProvider.notifier).setGlobalTopP,
            ),
            const SizedBox(height: SimpleSpacing.sMd),
          ],

          // 最大 Token 数输入框
          _buildMaxTokensRow(
            colors: colors,
            label: tt.maxTokens,
            desc: tt.maxTokensDesc,
            clearedLabel: tt.maxTokensCleared,
            maxTokens: maxTokens,
          ),
          const SizedBox(height: SimpleSpacing.sMd),
          Divider(height: 1, color: colors.divider),
          const SizedBox(height: SimpleSpacing.sMd),

          // 流式输出开关
          _buildSwitchRow(
            colors: colors,
            label: tt.streamEnabled,
            desc: tt.streamEnabledDesc,
            value: streamEnabled,
            onChanged: ref
                .read(settingsNotifierProvider.notifier)
                .setGlobalStreamEnabled,
          ),
        ],
      ),
    );
  }

  Widget _buildSliderRow({
    required LmPalette colors,
    required String label,
    required String desc,
    required double value,
    required double max,
    required int divisions,
    required String Function(double) valueFormatter,
    required ValueChanged<double> onChanged,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    style: SimpleTextStyles.body.copyWith(
                      fontWeight: FontWeight.w500,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    desc,
                    style: SimpleTextStyles.caption,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            const SizedBox(width: SimpleSpacing.sSm),
            Text(
              valueFormatter(value),
              style: SimpleTextStyles.caption.copyWith(
                color: colors.primary,
                fontWeight: FontWeight.w600,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
        const SizedBox(height: SimpleSpacing.sXs),
        CommitSlider(
          value: value,
          min: 0,
          max: max,
          divisions: divisions,
          activeColor: colors.primary,
          inactiveColor: colors.primaryDim,
          labelBuilder: valueFormatter,
          onCommit: onChanged,
        ),
      ],
    );
  }

  Widget _buildMaxTokensRow({
    required LmPalette colors,
    required String label,
    required String desc,
    required String clearedLabel,
    required int? maxTokens,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    style: SimpleTextStyles.body.copyWith(
                      fontWeight: FontWeight.w500,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    desc,
                    style: SimpleTextStyles.caption,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            const SizedBox(width: SimpleSpacing.sSm),
            if (maxTokens == null)
              Text(
                clearedLabel,
                style: SimpleTextStyles.caption.copyWith(color: colors.faint),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
          ],
        ),
        const SizedBox(height: SimpleSpacing.sXs),
        TextField(
          controller: _maxTokensController,
          focusNode: _maxTokensFocusNode,
          keyboardType: TextInputType.number,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          style: SimpleTextStyles.bodySm.copyWith(color: colors.ink),
          decoration: InputDecoration(
            filled: true,
            fillColor: colors.surfaceElevated,
            border: OutlineInputBorder(
              borderRadius:
                  BorderRadius.circular(context.lmUi.radius(LmCorner.xs)),
              borderSide: BorderSide.none,
            ),
            hintText: desc,
            contentPadding: const EdgeInsets.symmetric(
              horizontal: SimpleSpacing.sMd,
              vertical: SimpleSpacing.sSm,
            ),
          ),
          onSubmitted: _commitMaxTokens,
        ),
      ],
    );
  }

  Widget _buildSwitchRow({
    required LmPalette colors,
    required String label,
    required String desc,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) {
    return MergeSemantics(
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: SimpleTextStyles.body.copyWith(
                    fontWeight: FontWeight.w500,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 2),
                Text(
                  desc,
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
    );
  }
}
