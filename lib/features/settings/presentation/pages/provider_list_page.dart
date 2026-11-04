import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lmstory/core/theme/api/lm_component_kit.dart';
import 'package:lmstory/core/theme/simple/simple_spacing.dart';
import 'package:lmstory/core/theme/simple/simple_text_styles.dart';
import 'package:lmstory/core/theme/system/lm_layout.dart';
import 'package:lmstory/core/theme/system/lm_narrative_text_styles.dart';
import 'package:lmstory/core/theme/system/lm_overlays.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';
import 'package:lmstory/core/utils/api_url_resolver.dart';
import 'package:lmstory/features/settings/domain/entities/api_preset.dart';
import 'package:lmstory/features/settings/domain/entities/llm_protocol.dart';
import 'package:lmstory/features/settings/presentation/controllers/settings_controller.dart';
import 'package:lmstory/features/settings/presentation/pages/provider_detail_page.dart';
import 'package:lmstory/features/settings/presentation/widgets/create_preset_sheet.dart';
import 'package:lmstory/i18n/strings.g.dart';

/// 模型提供商列表页
///
/// 对标 ChatBox 的 ProviderList：一个供应商列表，每项是一个完整的配置单元
/// （API Key + Host + 模型列表）。点击进入 [ProviderDetailPage] 编辑详情。
///
/// 与旧设计的区别：去掉了"激活预设"概念，供应商只是配置容器，不区分
/// "当前使用哪个"。真正选择模型是在每个对话中，默认模型由"默认模型"页设置。
class ProviderListPage extends ConsumerStatefulWidget {
  const ProviderListPage({super.key});

  @override
  ConsumerState<ProviderListPage> createState() => _ProviderListPageState();
}

class _ProviderListPageState extends ConsumerState<ProviderListPage> {
  @override
  void initState() {
    super.initState();
    Future.microtask(
      () {
        // 已有数据时静默刷新（不闪全屏 spinner）。
        final hasData = ref.read(settingsNotifierProvider).presets.isNotEmpty;
        return ref
            .read(settingsNotifierProvider.notifier)
            .refresh(silent: hasData);
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = Translations.of(context);
    // 仅订阅本页消费的字段切片：其它设置字段的变更不再触发本页重建
    final presets = ref.watch(
      settingsNotifierProvider.select((s) => s.presets),
    );
    final isLoading = ref.watch(
      settingsNotifierProvider.select((s) => s.isLoading),
    );
    final apiKeyStatus = ref.watch(
      settingsNotifierProvider.select((s) => s.apiKeyStatus),
    );

    // 监听 state.error：弹 SnackBar 提示用户，避免错误被静默吞掉
    // （修复前 SettingsController.try/catch 吞掉异常后无 UI 反馈）
    ref.listen<String?>(
      settingsNotifierProvider.select((s) => s.error),
      (String? prev, String? error) {
        if (error == null) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            behavior: SnackBarBehavior.floating,
            content: Text(
              error,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        );
        ref.read(settingsNotifierProvider.notifier).clearError();
      },
    );

    return Scaffold(
      backgroundColor:
          context.scaffoldBgOf(Theme.of(context).scaffoldBackgroundColor),
      appBar: context.lmUi.appBar(
        context,
        title: t.settings.provider.title,
        actions: [
          IconButton(
            icon: const Icon(Icons.add),
            tooltip: t.settings.provider.add,
            onPressed: () => _showCreateDialog(context),
          ),
        ],
      ),
      body: _buildBody(
        context,
        isLoading: isLoading,
        presets: presets,
        apiKeyStatus: apiKeyStatus,
      ),
    );
  }

  Widget _buildBody(
    BuildContext context, {
    required bool isLoading,
    required List<ApiPreset> presets,
    required Map<String, bool> apiKeyStatus,
  }) {
    final t = Translations.of(context);
    if (isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (presets.isEmpty) {
      return context.lmUi.emptyState(
        context,
        title: t.settings.provider.emptyList,
        actionLabel: t.settings.provider.add,
        onAction: () => _showCreateDialog(context),
      );
    }

    return LmMeasure(
      child: ListView.builder(
        padding: const EdgeInsets.all(SimpleSpacing.sLg),
        itemCount: presets.length,
        itemBuilder: (context, index) {
          final preset = presets[index];
          final hasApiKey = apiKeyStatus[preset.presetId] ?? false;
          return _ProviderCard(
            preset: preset,
            hasApiKey: hasApiKey,
            onTap: () => _navigateToDetail(context, preset),
          );
        },
      ),
    );
  }

  void _navigateToDetail(BuildContext context, ApiPreset preset) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ProviderDetailPage(presetId: preset.presetId),
      ),
    );
  }

  Future<void> _showCreateDialog(BuildContext context) async {
    final t = Translations.of(context);
    // 使用 BottomSheet 替代 AlertDialog（移动端友好，符合 DOC-06A 规范）
    final result = await showLmSheet<CreatePresetResult>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      // CreatePresetSheet 自绘 _Grabber。
      glassHandle: false,
      builder: (sheetContext) => Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.of(sheetContext).viewInsets.bottom,
        ),
        child: const CreatePresetSheet(),
      ),
    );

    if (result == null || !mounted) return;

    // 根据用户选择创建 preset
    // - templateId 非空：基于模板创建（继承 protocol + baseUrl）
    // - templateId 为 null：自定义创建（使用用户选择的 protocol，baseUrl 留空）
    final ApiPreset? preset;
    if (result.templateId != null) {
      preset =
          await ref.read(settingsNotifierProvider.notifier).createFromTemplate(
                templateId: result.templateId!,
                name: result.name,
              );
    } else {
      preset = await ref.read(settingsNotifierProvider.notifier).createPreset(
            name: result.name,
            protocol: result.protocol ?? LlmProtocol.openaiCompatible,
          );
    }

    if (!mounted) return;
    if (preset == null) {
      // 创建失败：notifier 已将异常写入 state.error，显式弹 SnackBar 反馈
      if (!context.mounted) return;
      final error = ref.read(settingsNotifierProvider).error ?? t.common.error;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          behavior: SnackBarBehavior.floating,
          content: Text(
            '${t.common.error}: $error',
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      );
      ref.read(settingsNotifierProvider.notifier).clearError();
      return;
    }
    if (!context.mounted) return;

    // 创建成功后跳转详情页，引导用户补全 API Key + 模型列表
    _navigateToDetail(context, preset);
  }
}

/// 供应商卡片——点击进入详情页编辑 API Key / Host / 模型列表
class _ProviderCard extends StatelessWidget {
  const _ProviderCard({
    required this.preset,
    required this.hasApiKey,
    required this.onTap,
  });

  final ApiPreset preset;
  final bool hasApiKey;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = Translations.of(context);
    final colors = context.lm.palette;
    return Padding(
      padding: const EdgeInsets.only(bottom: SimpleSpacing.sMd),
      child: context.lmUi.card(
        context,
        onTap: onTap,
        child: Row(
          children: [
            // 供应商图标
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: colors.primaryDim,
                borderRadius:
                    BorderRadius.circular(context.lmUi.radius(LmCorner.md)),
              ),
              child: Icon(
                Icons.dns_outlined,
                color: colors.primary,
                size: 20,
              ),
            ),
            const SizedBox(width: SimpleSpacing.sMd),
            // 供应商信息
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    preset.name,
                    style: LmNarrativeTextStyles.narrativeDisplay.copyWith(
                      color: colors.ink,
                      fontSize: 24,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: SimpleSpacing.s2xs),
                  Text(
                    // raw 模式持久化值带 raw: 前缀，列表展示
                    /// 与详情页同法剥离（ApiUrlResolver.displayName）
                    ApiUrlResolver.displayName(preset.baseUrl),
                    style: SimpleTextStyles.caption,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: SimpleSpacing.s2xs),
                  Wrap(
                    spacing: SimpleSpacing.sMd,
                    runSpacing: SimpleSpacing.sSm,
                    children: [
                      // API Key 状态
                      _StatusDot(
                        ok: hasApiKey,
                        label: hasApiKey
                            ? t.settings.provider.apiKeyStatus.set
                            : t.settings.provider.apiKeyStatus.notSet,
                        color: hasApiKey ? colors.success : colors.warning,
                      ),
                      // 模型数量
                      _StatusDot(
                        ok: preset.cachedModels.isNotEmpty,
                        label: t.settings.provider.modelCount(
                          n: preset.cachedModels.length,
                          count: preset.cachedModels.length,
                        ),
                        color: preset.cachedModels.isNotEmpty
                            ? colors.success
                            : colors.faint,
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(width: SimpleSpacing.sSm),
            Icon(Icons.chevron_right, color: colors.faint, size: 20),
          ],
        ),
      ),
    );
  }
}

class _StatusDot extends StatelessWidget {
  const _StatusDot({
    required this.ok,
    required this.label,
    required this.color,
  });

  final bool ok;
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 6,
          height: 6,
          decoration: BoxDecoration(
            color: color,
            shape: BoxShape.circle,
          ),
        ),
        const SizedBox(width: SimpleSpacing.s2xs),
        Flexible(
          child: Text(
            label,
            style: SimpleTextStyles.overline,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }
}
