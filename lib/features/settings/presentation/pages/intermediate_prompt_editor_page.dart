import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lmstory/core/config/intermediate_config.dart';
import 'package:lmstory/core/di/providers.dart';
import 'package:lmstory/core/theme/api/lm_component_kit.dart';
import 'package:lmstory/core/theme/intermediate/intermediate_spacing.dart';
import 'package:lmstory/core/theme/intermediate/intermediate_text_styles.dart';
import 'package:lmstory/core/theme/shared/components/panel_heading.dart';
import 'package:lmstory/core/theme/system/lm_layout.dart';
import 'package:lmstory/core/theme/system/lm_overlays.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';
import 'package:lmstory/features/settings/presentation/widgets/intermediate_prompt_metadata.dart';
import 'package:lmstory/i18n/strings.g.dart';

/// 故事模式提示词全屏编辑器。
///
/// 从 IntermediatePromptsSection 的 tile 点击进入。
/// 提供：
/// - 自适应高度 TextField（maxLines: null + expands: true，撑满页面剩余空间）
/// - 实时字数统计
/// - 保存按钮（持久化到 SettingsRepository.user_overrides）
/// - 恢复默认按钮（移除覆盖）
/// - 使用场景说明
/// - PopScope dirty check（未保存离开时确认）
///
/// 持久化 key：`intermediate.prompts.{fieldKey}`
/// （如 `intermediate.prompts.generating_suffix_v2`）。
/// 空保存被校验拦截（每项必有值）；恢复默认
/// 走显式按钮。
///
/// 视觉：夜航主题，与 IntermediateSettingsPage 一致。
class IntermediatePromptEditorPage extends ConsumerStatefulWidget {
  const IntermediatePromptEditorPage({required this.meta, super.key});

  /// 目标提示词字段元数据
  final PromptFieldMeta meta;

  @override
  ConsumerState<IntermediatePromptEditorPage> createState() =>
      _IntermediatePromptEditorPageState();
}

class _IntermediatePromptEditorPageState
    extends ConsumerState<IntermediatePromptEditorPage> {
  final TextEditingController _controller = TextEditingController();
  bool _initialized = false;
  String _loadedValue = '';
  bool _isSaving = false;

  PromptFieldMeta get _meta => widget.meta;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// 配置加载后初始化 TextField（仅一次）
  ///
  /// 加载的值是「当前生效值」= 用户覆盖 OR 内置默认。
  void _ensureInit(bool hasValue, String currentValue) {
    if (_initialized || !hasValue) return;
    _loadedValue = currentValue;
    _controller.text = _loadedValue;
    _initialized = true;
  }

  bool _isDirty() => _controller.text != _loadedValue;

  Future<void> _save() async {
    if (!_isDirty() || _isSaving) return;
    final t = Translations.of(context);
    final text = _controller.text;
    // 空就是空、每项必有值——
    // 空保存直接校验拦截，不做「空=移除覆盖回默认」的隐义（隐义让
    // 「清空」与「恢复默认」混同，曾致系统提示词被静默清空）；恢复
    // 默认走显式的「恢复默认」按钮。
    if (text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          behavior: SnackBarBehavior.floating,
          content: Text(
            t.settings.intermediate.prompts.emptyBlocked,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      );
      return;
    }
    setState(() => _isSaving = true);
    try {
      final repo = ref.read(settingsRepositoryProvider);
      if (text == _meta.defaultValue) {
        // 与内置默认一致 → 移除冗余覆盖（运行时回落同一常量，等价快照）
        await repo.removeUserOverride(_meta.overrideKey);
      } else {
        await repo.setUserOverride(_meta.overrideKey, text);
      }
      ref.invalidate(intermediateConfigProvider);
      _loadedValue = text;
      if (mounted) {
        final t = Translations.of(context);
        // 默认值含占位符的段，删掉占位符保存后给非阻断警告——
        // {factInjectionTitle} 等占位符由设置页「注入标题」单独配置并
        // 在发送前插值，静默缺失会让对应区块标题失效且无从自察。
        final defaultPlaceholders = _placeholdersOf(_meta.defaultValue);
        final missing =
            defaultPlaceholders.where((p) => !text.contains(p)).toList();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            behavior: SnackBarBehavior.floating,
            content: Text(
              missing.isEmpty
                  ? t.settings.intermediate.prompts.saved
                  : t.settings.intermediate.prompts.placeholderMissingWarning(
                      names: missing.join('、'),
                    ),
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  Future<void> _reset() async {
    final t = Translations.of(context);
    final confirmed = await showLmDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(
          t.settings.intermediate.prompts.reset,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        content: Text(
          t.settings.intermediate.prompts.resetConfirm,
          maxLines: 4,
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(
              t.common.cancel,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(
              t.settings.intermediate.prompts.reset,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    final repo = ref.read(settingsRepositoryProvider);
    await repo.removeUserOverride(_meta.overrideKey);
    ref.invalidate(intermediateConfigProvider);
    _controller.text = _meta.defaultValue;
    _loadedValue = _meta.defaultValue;
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          behavior: SnackBarBehavior.floating,
          content: Text(
            t.settings.intermediate.prompts.resetDone,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final configAsync = ref.watch(intermediateConfigProvider);
    final currentValue = _extractCurrentValue(configAsync.valueOrNull);
    _ensureInit(configAsync.hasValue, currentValue);

    return _buildScaffold(context, configAsync.isLoading);
  }

  /// 从 IntermediateConfig 中提取目标字段的当前值
  String _extractCurrentValue(IntermediateConfig? config) {
    if (config == null) return _meta.defaultValue;
    return _meta.currentValue(config.prompts);
  }

  Widget _buildScaffold(BuildContext context, bool isLoading) {
    final colors = context.lm.palette;
    final t = Translations.of(context);

    return Scaffold(
      backgroundColor:
          context.scaffoldBgOf(Theme.of(context).scaffoldBackgroundColor),
      appBar: context.lmUi.appBar(context, title: _meta.title(t)),
      body: PopScope(
        // 恢复默认按钮在底部内容区（与系统提示词区块布局一致，
        // 遵循 earned familiarity 原则）。AppBar 仅保留标题。
        canPop: !_isDirty(),
        onPopInvokedWithResult: (didPop, _) async {
          if (didPop) return;
          final shouldPop = await _confirmDiscard();
          if (!mounted) return;
          if (shouldPop) Navigator.pop(this.context);
        },
        // 改用 ListView：所有内容可滚动，避免底部"使用场景+默认值预览"
        // 在长提示词（关键词提取/事件摘要/记忆提炼等默认值25-33行）时
        // 超出屏幕高度出现黄黑 overflow 条纹。
        // TextField 用 minLines: 8 保证最小编辑区域，不再用 expands 撑满。
        child: LmMeasure(
          child: ListView(
            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
            padding: EdgeInsets.zero,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  IntermediateSpacing.sLg,
                  IntermediateSpacing.sLg,
                  IntermediateSpacing.sLg,
                  IntermediateSpacing.sMd,
                ),
                child: _buildDescription(colors, t),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: IntermediateSpacing.sLg,
                ),
                child: _buildEditor(colors, t, isLoading),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  IntermediateSpacing.sLg,
                  IntermediateSpacing.sMd,
                  IntermediateSpacing.sLg,
                  IntermediateSpacing.sLg,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _buildCharCountAndSave(colors, t, isLoading),
                    const SizedBox(height: IntermediateSpacing.sXl),
                    _buildUsageSection(colors, t),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildDescription(LmPalette colors, Translations t) {
    return Text(
      _meta.desc(t),
      style: IntermediateTextStyles.bodyUi.copyWith(color: colors.muted),
    );
  }

  Widget _buildEditor(
    LmPalette colors,
    Translations t,
    bool isLoading,
  ) {
    return context.lmUi.card(
      context,
      padding: const EdgeInsets.all(IntermediateSpacing.sMd),
      child: TextField(
        controller: _controller,
        enabled: !isLoading && !_isSaving,
        // minLines: 8 保证最小编辑区域；maxLines: null 允许自动扩展。
        // 不用 expands: true（ListView 中无法撑满，会报错）。
        minLines: 8,
        maxLines: null,
        style: IntermediateTextStyles.input.copyWith(
          color: colors.ink,
          fontFamily: IntermediateTextStyles.sansFamily,
        ),
        decoration: InputDecoration(
          hintText:
              isLoading ? t.settings.intermediate.loading : _meta.defaultValue,
          hintStyle: IntermediateTextStyles.input.copyWith(
            color: colors.muted,
          ),
          filled: true,
          fillColor: colors.surfaceVariant,
          //  修复：圆角 rMd→rXs（4px 微圆角）
          // 对齐用户偏好"直角边缘"+ Death Stranding 风格
          border: OutlineInputBorder(
            borderRadius:
                BorderRadius.circular(context.lmUi.radius(LmCorner.xs)),
            borderSide: BorderSide.none,
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius:
                BorderRadius.circular(context.lmUi.radius(LmCorner.xs)),
            borderSide: BorderSide.none,
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius:
                BorderRadius.circular(context.lmUi.radius(LmCorner.xs)),
            borderSide: BorderSide(
              color: colors.primary,
              width: 1.5,
            ),
          ),
          contentPadding: const EdgeInsets.all(IntermediateSpacing.sMd),
        ),
      ),
    );
  }

  Widget _buildCharCountAndSave(
    LmPalette colors,
    Translations t,
    bool isLoading,
  ) {
    return ValueListenableBuilder<TextEditingValue>(
      valueListenable: _controller,
      builder: (context, value, _) {
        final dirty = value.text != _loadedValue;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              t.settings.intermediate.prompts
                  .charCount(count: value.text.length),
              style:
                  IntermediateTextStyles.caption.copyWith(color: colors.muted),
            ),
            const SizedBox(height: IntermediateSpacing.sSm),
            Wrap(
              alignment: WrapAlignment.end,
              spacing: IntermediateSpacing.sSm,
              runSpacing: IntermediateSpacing.sXs,
              children: [
                TextButton(
                  onPressed: (isLoading || _isSaving) ? null : _reset,
                  child: Text(t.settings.intermediate.prompts.reset),
                ),
                ElevatedButton(
                  onPressed: (_isSaving || !dirty) ? null : _save,
                  child: _isSaving
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Text(t.settings.intermediate.prompts.save),
                ),
              ],
            ),
          ],
        );
      },
    );
  }

  Widget _buildUsageSection(LmPalette colors, Translations t) {
    return context.lmUi.card(
      context,
      padding: const EdgeInsets.all(IntermediateSpacing.sMd),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          PanelHeading(title: t.settings.intermediate.prompts.usageTitle),
          const SizedBox(height: IntermediateSpacing.sSm),
          Text(
            _meta.usage(t),
            style: IntermediateTextStyles.caption.copyWith(
              color: colors.muted,
              height: 1.6,
            ),
          ),
          const SizedBox(height: IntermediateSpacing.sMd),
          Divider(height: 1, thickness: 1, color: colors.divider),
          const SizedBox(height: IntermediateSpacing.sMd),
          // 默认值含占位符的段恢复「可用变量」提示（R1-G7 注释
          // 失实纠正——并非所有段都是静态文本，review_suffix_v2 等段在
          // 发送前做占位符插值）
          _buildPlaceholderHint(colors, t),
          // 内置默认值预览（技术用户对比当前编辑内容与默认值的差异）
          _buildDefaultValuePreview(colors, t),
        ],
      ),
    );
  }

  /// 提取文本中的 `{identifier}` 占位符（去重保序）。
  static List<String> _placeholdersOf(String text) {
    final found = <String>[];
    for (final match
        in RegExp(r'\{[a-zA-Z_][a-zA-Z0-9_]*\}').allMatches(text)) {
      final token = match.group(0)!;
      if (!found.contains(token)) found.add(token);
    }
    return found;
  }

  /// 占位符提示块：默认值含 `{xxx}` 占位符的段渲染；纯静态段返回空。
  Widget _buildPlaceholderHint(LmPalette colors, Translations t) {
    final placeholders = _placeholdersOf(_meta.defaultValue);
    if (placeholders.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(Icons.code_outlined, size: 16, color: colors.accent),
            const SizedBox(width: IntermediateSpacing.sSm),
            Expanded(
              child: Text(
                t.settings.intermediate.prompts.placeholdersTitle,
                style: IntermediateTextStyles.label.copyWith(
                  color: colors.ink,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
        const SizedBox(height: IntermediateSpacing.s2xs),
        Padding(
          padding: const EdgeInsets.only(left: IntermediateSpacing.sSm),
          child: Text(
            t.settings.intermediate.prompts.placeholdersDesc(
              names: placeholders.join('、'),
            ),
            style: IntermediateTextStyles.caption.copyWith(
              color: colors.muted,
              height: 1.6,
            ),
          ),
        ),
        const SizedBox(height: IntermediateSpacing.sMd),
      ],
    );
  }

  /// 内置默认值预览：展示该提示词的内置默认内容，方便用户对比当前编辑内容。
  ///
  /// 历史注：该区块曾与"可用变量"区块二选一（当时的理由是多数段为静态
  /// 文本）； 起两块并存——含占位符的段先给变量提示（上方
  /// [_buildPlaceholderHint]），默认值预览对所有段保留。
  Widget _buildDefaultValuePreview(
    LmPalette colors,
    Translations t,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(Icons.history_outlined, size: 16, color: colors.accent),
            const SizedBox(width: IntermediateSpacing.sSm),
            Expanded(
              child: Text(
                t.settings.intermediate.prompts.defaultValuePreview,
                style: IntermediateTextStyles.label.copyWith(color: colors.ink),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
        const SizedBox(height: IntermediateSpacing.s2xs),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(IntermediateSpacing.sSm),
          decoration: BoxDecoration(
            color: colors.surfaceVariant,
            borderRadius:
                BorderRadius.circular(context.lmUi.radius(LmCorner.sm)),
          ),
          child: SelectableText(
            _meta.defaultValue,
            style: IntermediateTextStyles.caption.copyWith(
              color: colors.muted,
              height: 1.6,
              fontFamily: 'monospace',
              fontSize: 12,
            ),
          ),
        ),
      ],
    );
  }

  Future<bool> _confirmDiscard() async {
    if (!_isDirty()) return true;
    final t = Translations.of(context);
    final confirmed = await showLmDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(
          t.settings.intermediate.prompts.confirmDiscardTitle,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        content: Text(
          t.settings.intermediate.prompts.confirmDiscardContent,
          maxLines: 4,
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(
              t.settings.intermediate.prompts.keepEditing,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(
              t.settings.intermediate.prompts.discard,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
    return confirmed ?? false;
  }
}
