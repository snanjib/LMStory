import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lmstory/core/config/config_level.dart';
import 'package:lmstory/core/config/config_visibility.dart';
import 'package:lmstory/core/di/providers.dart';
import 'package:lmstory/core/theme/api/lm_component_kit.dart';
import 'package:lmstory/core/theme/intermediate/intermediate_spacing.dart';
import 'package:lmstory/core/theme/intermediate/intermediate_text_styles.dart';
import 'package:lmstory/core/theme/system/lm_layout.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';
import 'package:lmstory/core/widgets/advanced_level_hint.dart';
import 'package:lmstory/features/advanced/presentation/advanced_mode_flag.dart';
import 'package:lmstory/features/intermediate/presentation/widgets/collapsed_sections_store.dart';
import 'package:lmstory/features/intermediate/presentation/widgets/collapsible_settings_section.dart';
import 'package:lmstory/features/settings/presentation/pages/settings_page.dart'
    show SettingsPage;
import 'package:lmstory/features/settings/presentation/widgets/sections/director_budget_section.dart';
import 'package:lmstory/features/settings/presentation/widgets/sections/director_context_section.dart';
import 'package:lmstory/features/settings/presentation/widgets/sections/director_memory_section.dart';
import 'package:lmstory/features/settings/presentation/widgets/sections/director_models_generation_section.dart';
import 'package:lmstory/features/settings/presentation/widgets/sections/director_setting_rows.dart';
import 'package:lmstory/features/settings/presentation/widgets/sections/director_tool_permissions_section.dart';
import 'package:lmstory/i18n/strings.g.dart';

/// 导演模式设置页（导演设置体系 P2，设计文档 §7）。
///
/// **单页折叠式**（导演 6 分区的量级不足以拆故事模式的分类子页）：
/// - 页首：导演模式入口开关（原设置主页 _AdvancedModeCard 迁入）
/// - 「模型与生成」常驻置顶，不参与折叠
/// - 其余 5 分区用 [CollapsibleSettingsSection] 折叠
/// - 标题栏一键折叠/一键展开；折叠状态全局记忆
///   （`ui.directorSettings.collapsedSections`）
/// - 默认态仅首次生效：展开 = 项目规则/工具权限，折叠 = 运行与预算/
///   上下文与压缩/检索与记忆（设计文档 §7）
///
/// 页面**自包含，不跳转故事模式设置**（"两个产品"原则）。
/// 夜航主题，与导演会话页同氛围。
///
/// 组装层按配置显示模式过滤：简单模式保留入口开关、项目规则区、
/// 「模型与生成」区内的 GM 模型/剧情节奏/思考档行与记忆区壳内的
/// 向量化模型行；工具权限/预算/上下文区、记忆区记忆管线技术行
/// 与推荐回复组尾、采样参数行仅进阶模式渲染。
/// 折叠批操作只作用于当前模式可见区，被隐藏区的折叠记录原样保留。
/// 过滤只动展示层，被隐藏区已有用户值继续生效。
class DirectorSettingsPage extends ConsumerStatefulWidget {
  const DirectorSettingsPage({super.key, this.focusSection});

  /// 进入时强制展开的分区 id（一次性，不写折叠记忆）。
  ///
  /// 导演会话「未配置向量化模型」横幅跳转时定位「检索与记忆」
  /// （memory）分区，避免用户在折叠页里找配置入口。
  final String? focusSection;

  @override
  ConsumerState<DirectorSettingsPage> createState() =>
      _DirectorSettingsPageState();
}

class _DirectorSettingsPageState extends ConsumerState<DirectorSettingsPage> {
  /// 可折叠分区 id（models 常驻置顶不在此列）。
  static const List<String> _collapsibleSectionIds = [
    'rules',
    'tools',
    'budget',
    'context',
    'memory',
  ];

  /// 默认折叠分区（仅首次打开生效；用户操作后按全局记忆）。
  static const Set<String> _defaultCollapsed = {'budget', 'context', 'memory'};

  late final CollapsedSectionsStore _collapseStore;
  // 必须拷贝为可变副本——直引用 const Set 会让首次打开
  // （无折叠记忆，_loadCollapsed 不替换引用）后的 _toggleSection 对
  // const set add/remove 抛 UnmodifiableSetError 且折叠失效。
  Set<String> _collapsed = _defaultCollapsed.toSet();

  @override
  void initState() {
    super.initState();
    _collapseStore = CollapsedSectionsStore(
      ref.read(settingsRepositoryProvider),
      storageKey: 'ui.directorSettings.collapsedSections',
    );
    _loadCollapsed();
  }

  Future<void> _loadCollapsed() async {
    final saved = await _collapseStore.loadOrNull();
    if (!mounted) return;
    if (saved != null) {
      setState(() => _collapsed = saved);
    }
    // saved == null：首次打开，保持默认态表，不落盘
    //（首次用户动作才写入记忆，此后不再重置——DOC-14 §3.4）
    // focusSection：一次性展开目标分区，不写折叠记忆（深链定位）
    if (widget.focusSection != null &&
        _collapsibleSectionIds.contains(widget.focusSection)) {
      setState(() => _collapsed.remove(widget.focusSection));
    }
  }

  bool _isSectionExpanded(String id) => !_collapsed.contains(id);

  /// 区级可见性键；除 memory 外全部折叠区都有键（未知 id 走 fail-open
  /// 视为可见）。memory 区壳恒显（行级拆分后该区承载 simple 的
  /// 向量化模型行），行过滤在 DirectorMemorySection 内做。
  String? _sectionVisibilityKey(String id) => switch (id) {
        'rules' => ConfigVisibilityKeys.directorRules,
        'tools' => ConfigVisibilityKeys.directorToolPermissions,
        'budget' => ConfigVisibilityKeys.directorBudget,
        'context' => ConfigVisibilityKeys.directorContext,
        _ => null,
      };

  /// 该区在当前配置显示模式下是否渲染。
  bool _isSectionRendered(String id, ConfigLevel level) {
    // memory 区壳恒显，会话「未配置嵌入模型」横幅的「去配置」
    // 深链天然落地；focusSection 只承担展开定位（见 _loadCollapsed）。
    final key = _sectionVisibilityKey(id);
    return key == null || ConfigVisibility.of(key, level);
  }

  /// 当前模式下实际渲染的可折叠区 id——折叠批操作只作用于可见区，
  /// 被隐藏区的折叠记录原样保留，切回进阶模式恢复原折叠状态。
  Iterable<String> _renderedCollapsibleIds() {
    final level = ref.read(configLevelProvider);
    return _collapsibleSectionIds.where((id) => _isSectionRendered(id, level));
  }

  Future<void> _toggleSection(String id) async {
    setState(() {
      if (_collapsed.contains(id)) {
        _collapsed.remove(id);
      } else {
        _collapsed.add(id);
      }
    });
    await _collapseStore.save(_collapsed);
  }

  Future<void> _collapseAllSections() async {
    setState(() => _collapsed.addAll(_renderedCollapsibleIds()));
    await _collapseStore.save(_collapsed);
  }

  Future<void> _expandAllSections() async {
    setState(() => _collapsed.removeAll(_renderedCollapsibleIds()));
    await _collapseStore.save(_collapsed);
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.lm.palette;
    final t = Translations.of(context);
    final level = ref.watch(configLevelProvider);
    // 简单模式剩规则/记忆 2 个可折叠区，批操作对象仍偏少，维持进阶专属
    //（展示层裁量，非配置项不走键）。
    final showCollapseBatchActions = level == ConfigLevel.advanced;

    // 设置树撤除入场转场（穿越动画只保留在模式会话页）。
    return Scaffold(
      backgroundColor:
          context.scaffoldBgOf(Theme.of(context).scaffoldBackgroundColor),
      appBar: AppBar(
        title: FittedBox(
          fit: BoxFit.scaleDown,
          child: Text(
            t.settings.director.title,
            style: IntermediateTextStyles.title.copyWith(color: colors.ink),
          ),
        ),
        backgroundColor:
            context.scaffoldBgOf(Theme.of(context).scaffoldBackgroundColor),
        foregroundColor: colors.ink,
        elevation: 0,
        scrolledUnderElevation: 0,
        surfaceTintColor: Colors.transparent,
        actions: [
          if (showCollapseBatchActions) ...[
            TextButton(
              onPressed: _collapseAllSections,
              child: Text(t.settings.director.collapseAll),
            ),
            TextButton(
              onPressed: _expandAllSections,
              child: Text(t.settings.director.expandAll),
            ),
          ],
          const SizedBox(width: IntermediateSpacing.sXs),
        ],
      ),
      body: LmMeasure(
        child: ListView(
          padding: const EdgeInsets.all(IntermediateSpacing.sLg),
          children: [
            // ── 入口开关（原设置主页卡片迁入，夜航主题化）──────────
            const _DirectorModeToggleCard(),
            const SizedBox(height: IntermediateSpacing.sMd),

            // ── 模型与生成：常驻置顶，不参与折叠 ──────────────────
            _PinnedSectionCard(
              title: t.settings.director.sections.models,
              child: const DirectorModelsGenerationSection(),
            ),
            const SizedBox(height: IntermediateSpacing.sMd),

            for (final id in _collapsibleSectionIds)
              if (_isSectionRendered(id, level))
                _collapsibleSection(
                  id: id,
                  title: switch (id) {
                    'rules' => t.settings.director.sections.rules,
                    'tools' => t.settings.director.sections.tools,
                    'budget' => t.settings.director.sections.budget,
                    'context' => t.settings.director.sections.context,
                    'memory' => t.settings.director.sections.memory,
                    _ => id,
                  },
                  child: switch (id) {
                    'rules' => const _DirectorRulesSection(),
                    'tools' => const DirectorToolPermissionsSection(),
                    'budget' => const DirectorBudgetSection(),
                    'context' => const DirectorContextSection(),
                    'memory' => const DirectorMemorySection(),
                    _ => null,
                  },
                ),
            const AdvancedLevelHint(
              surfaceId: ConfigVisibilitySurfaces.director,
            ),
          ],
        ),
      ),
    );
  }

  /// 构造一个可折叠分区（顶部间距；child 为空时显示占位，后续任务填充）。
  Widget _collapsibleSection({
    required String id,
    required String title,
    Widget? child,
  }) {
    final colors = context.lm.palette;
    final t = Translations.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: IntermediateSpacing.sMd),
      child: CollapsibleSettingsSection(
        title: title,
        isExpanded: _isSectionExpanded(id),
        onToggle: () => _toggleSection(id),
        child: child ??
            Padding(
              padding:
                  const EdgeInsets.symmetric(vertical: IntermediateSpacing.sMd),
              child: Text(
                t.settings.director.sectionPending,
                style: IntermediateTextStyles.caption
                    .copyWith(color: colors.muted),
              ),
            ),
      ),
    );
  }
}

/// 项目规则默认分区（导演设置）：多行 TextField，
/// 500ms 节流写 `advanced.system_prompt`（空串 = 移除覆写回退内置规则）。
class _DirectorRulesSection extends ConsumerStatefulWidget {
  const _DirectorRulesSection();

  @override
  ConsumerState<_DirectorRulesSection> createState() =>
      _DirectorRulesSectionState();
}

class _DirectorRulesSectionState extends ConsumerState<_DirectorRulesSection> {
  late final TextEditingController _controller;
  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(
      text: ref.read(advancedConfigProvider).valueOrNull?.systemPrompt ?? '',
    );
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    super.dispose();
  }

  void _onChanged(String text) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 500), () {
      // lm-motion-exempt: 输入去抖（交互节流，非过渡动效）
      final trimmed = text.trim();
      writeDirectorOverride(
        ref,
        'advanced.system_prompt',
        trimmed.isEmpty ? null : trimmed,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.lm.palette;
    final t = Translations.of(context);

    return SettingsTile(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: _controller,
            onChanged: _onChanged,
            minLines: 4,
            maxLines: 8,
            style: IntermediateTextStyles.bodyUi.copyWith(color: colors.ink),
            decoration: InputDecoration(
              hintText: t.settings.director.rules.hint,
              hintStyle:
                  IntermediateTextStyles.caption.copyWith(color: colors.faint),
              isDense: true,
              border: OutlineInputBorder(
                borderRadius:
                    BorderRadius.circular(context.lmUi.radius(LmCorner.sm)),
                borderSide: BorderSide(color: colors.divider),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 常驻置顶分区卡（不参与折叠；与折叠分区同视觉层次——分区强边界）。
class _PinnedSectionCard extends StatelessWidget {
  const _PinnedSectionCard({required this.title, required this.child});

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final colors = context.lm.palette;
    return Material(
      color: colors.surface,
      borderRadius: BorderRadius.circular(context.lmUi.radius(LmCorner.lg)),
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.all(IntermediateSpacing.sMd),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: IntermediateSpacing.sMd,
              ),
              child: Text(
                title,
                style: IntermediateTextStyles.label.copyWith(
                  color: colors.primary,
                ),
              ),
            ),
            const SizedBox(height: IntermediateSpacing.sSm),
            child,
          ],
        ),
      ),
    );
  }
}

/// 导演模式入口开关卡片（自 [SettingsPage] 迁入，主题从 Simple 换夜航）。
class _DirectorModeToggleCard extends ConsumerWidget {
  const _DirectorModeToggleCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Translations.of(context);
    final enabled = ref.watch(advancedModeFlagProvider);
    final colors = context.lm.palette;

    return Material(
      color: colors.surfaceVariant,
      borderRadius: BorderRadius.circular(context.lmUi.radius(LmCorner.lg)),
      child: Padding(
        padding: const EdgeInsets.all(IntermediateSpacing.sLg),
        child: Row(
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: colors.warning.withValues(alpha: 0.15),
                borderRadius:
                    BorderRadius.circular(context.lmUi.radius(LmCorner.md)),
              ),
              child: Icon(
                Icons.theater_comedy,
                color: colors.warning,
                size: 22,
              ),
            ),
            const SizedBox(width: IntermediateSpacing.sMd),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    t.advanced.settings.title,
                    style: IntermediateTextStyles.bodyUi.copyWith(
                      color: colors.ink,
                      fontWeight: FontWeight.w600,
                      fontSize: 15,
                    ),
                  ),
                  Text(
                    t.advanced.settings.desc,
                    style: IntermediateTextStyles.caption
                        .copyWith(color: colors.muted),
                  ),
                ],
              ),
            ),
            Switch(
              value: enabled,
              onChanged: (value) => ref
                  .read(advancedModeFlagProvider.notifier)
                  .setEnabled(enabled: value),
            ),
          ],
        ),
      ),
    );
  }
}
