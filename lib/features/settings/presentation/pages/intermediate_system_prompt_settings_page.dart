import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lmstory/core/config/config_level.dart';
import 'package:lmstory/core/config/config_visibility.dart';
import 'package:lmstory/core/di/providers.dart';
import 'package:lmstory/core/theme/api/lm_component_kit.dart';
import 'package:lmstory/core/theme/intermediate/intermediate_spacing.dart';
import 'package:lmstory/core/theme/intermediate/intermediate_text_styles.dart';
import 'package:lmstory/core/theme/system/lm_layout.dart';
import 'package:lmstory/core/theme/system/lm_overlays.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';
import 'package:lmstory/features/settings/presentation/pages/intermediate_settings_page.dart'
    show IntermediateSettingsPage;
import 'package:lmstory/features/settings/presentation/widgets/intermediate_system_prompt_section.dart';
import 'package:lmstory/i18n/strings.g.dart';

/// 故事模式设置 — 系统提示词子页（2026-07-19 子页化重构）。
///
/// 从 [IntermediateSettingsPage] 抽出。承载系统提示词编辑器：
/// - TextField + 字数 + 保存/恢复按钮
/// - dirty check + PopScope 放弃修改确认
/// - 即时持久化到 `intermediate.system_prompt`
///
/// 优先级（DOC-09B §10.2）：
/// 会话级 > 全局 systemPrompt > kDefaultRolePrompt。
///
/// 状态由本页持有（与原 [IntermediateSettingsPage] 一致），未做状态上提
/// 是因为：(1) 仅本页需要 dirty check；(2) 草稿未保存时离开需要弹确认。
class IntermediateSystemPromptSettingsPage extends ConsumerStatefulWidget {
  const IntermediateSystemPromptSettingsPage({super.key});

  @override
  ConsumerState<IntermediateSystemPromptSettingsPage> createState() =>
      _IntermediateSystemPromptSettingsPageState();
}

class _IntermediateSystemPromptSettingsPageState
    extends ConsumerState<IntermediateSystemPromptSettingsPage> {
  final TextEditingController _controller = TextEditingController();
  bool _initialized = false;
  String _loadedValue = '';
  bool _isSaving = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// 配置加载后初始化 TextField（仅一次，避免覆盖用户输入）
  ///
  /// 必须等 [AsyncValue.hasValue] 为 true 才初始化——否则 FutureProvider
  /// 首次构建时 valueOrNull 为 null，会把空串当作已加载值，导致配置值无法回显。
  void _ensureInit(bool hasValue, String configValue) {
    if (_initialized || !hasValue) return;
    _loadedValue = configValue;
    _controller.text = _loadedValue;
    _initialized = true;
  }

  bool _isDirty() => _controller.text != _loadedValue;

  Future<void> _save() async {
    if (!_isDirty() || _isSaving) return;
    setState(() => _isSaving = true);
    try {
      final repo = ref.read(settingsRepositoryProvider);
      final text = _controller.text.trim();
      if (text.isEmpty) {
        // 空串等价于恢复默认：移除覆盖
        await repo.removeUserOverride('intermediate.system_prompt');
      } else {
        await repo.setUserOverride('intermediate.system_prompt', text);
      }
      // 刷新 provider 让后续对话立即生效
      ref.invalidate(intermediateConfigProvider);
      _loadedValue = text;
      if (mounted) {
        final t = Translations.of(context);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            behavior: SnackBarBehavior.floating,
            content: Text(
              t.settings.intermediate.saved,
              maxLines: 2,
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
          t.settings.intermediate.reset,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        content: Text(
          t.settings.intermediate.resetConfirm,
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
              t.settings.intermediate.reset,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    final repo = ref.read(settingsRepositoryProvider);
    await repo.removeUserOverride('intermediate.system_prompt');
    ref.invalidate(intermediateConfigProvider);
    _controller.clear();
    _loadedValue = '';
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          behavior: SnackBarBehavior.floating,
          content: Text(
            t.settings.intermediate.resetDone,
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
    _ensureInit(
      configAsync.hasValue,
      configAsync.valueOrNull?.systemPrompt ?? '',
    );

    return _buildScaffold(context, configAsync.isLoading);
  }

  Widget _buildScaffold(BuildContext context, bool isLoading) {
    final colors = context.lm.palette;
    final t = Translations.of(context);

    return Scaffold(
      backgroundColor:
          context.scaffoldBgOf(Theme.of(context).scaffoldBackgroundColor),
      appBar: AppBar(
        title: FittedBox(
          fit: BoxFit.scaleDown,
          child: Text(
            t.settings.intermediate.categories.systemPrompt.title,
            style: IntermediateTextStyles.title.copyWith(color: colors.ink),
          ),
        ),
        backgroundColor:
            context.scaffoldBgOf(Theme.of(context).scaffoldBackgroundColor),
        foregroundColor: colors.ink,
        elevation: 0,
        scrolledUnderElevation: 0,
        surfaceTintColor: Colors.transparent,
      ),
      body: PopScope(
        canPop: !_isDirty(),
        onPopInvokedWithResult: (didPop, _) async {
          if (didPop) return;
          final shouldPop = await _confirmDiscard();
          if (!mounted) return;
          if (shouldPop) Navigator.pop(this.context);
        },
        child: LmMeasure(
          child: ListView(
            padding: const EdgeInsets.all(IntermediateSpacing.sLg),
            children: [
              // 结构无变化面（配置双模式）：simple 声明键，双模式恒显，
              // 过滤门仅作表↔代码对账锚点。
              if (ConfigVisibility.of(
                ConfigVisibilityKeys.storySystemPromptSection,
                ref.watch(configLevelProvider),
              ))
                IntermediateSystemPromptSection(
                  controller: _controller,
                  loadedValue: _loadedValue,
                  isLoading: isLoading,
                  isSaving: _isSaving,
                  onSave: _save,
                  onReset: _reset,
                ),
            ],
          ),
        ),
      ),
    );
  }

  Future<bool> _confirmDiscard() async {
    if (!_isDirty()) return true;
    final t = Translations.of(context);
    final confirmed = await showLmDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(
          t.settings.intermediate.confirmDiscardTitle,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        content: Text(
          t.settings.intermediate.confirmDiscardContent,
          maxLines: 4,
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(
              t.settings.intermediate.keepEditing,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(
              t.settings.intermediate.discard,
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
