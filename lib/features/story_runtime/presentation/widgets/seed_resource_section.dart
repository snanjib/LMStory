import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lmstory/core/di/providers.dart';
import 'package:lmstory/core/exceptions/app_exceptions.dart';
import 'package:lmstory/core/theme/api/lm_component_kit.dart';
import 'package:lmstory/core/theme/intermediate/intermediate_spacing.dart';
import 'package:lmstory/core/theme/simple/simple_spacing.dart';
import 'package:lmstory/core/theme/simple/simple_text_styles.dart';
import 'package:lmstory/core/theme/system/lm_overlays.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';
import 'package:lmstory/features/memory/domain/entities/factual_entity.dart';
import 'package:lmstory/features/memory/domain/entities/factual_source.dart';
import 'package:lmstory/features/resource_library/domain/services/resource_apply_service.dart';
import 'package:lmstory/features/resource_library/domain/services/resource_projection_service.dart';
import 'package:lmstory/i18n/strings.g.dart';

/// 种子资源应用区段（DOC-15 §9.3， 自故事模式抽取共享）。
///
/// 会话级参数化、无模式依赖：故事/导演会话设置面板同款挂载。三张卡：
/// 应用角色卡 / 应用世界书 / 取消应用资源。占用名预检与投影
/// 均在 [ResourceApplyService]/[ResourceProjectionService] 领域层，
/// 随本组件天然共享，语义不变。
///
/// [enabled] 为 false（生成中）时三卡置灰。
class SeedResourceSection extends ConsumerStatefulWidget {
  const SeedResourceSection({
    required this.sessionId,
    required this.enabled,
    super.key,
  });

  final String sessionId;
  final bool enabled;

  @override
  ConsumerState<SeedResourceSection> createState() =>
      _SeedResourceSectionState();
}

class _SeedResourceSectionState extends ConsumerState<SeedResourceSection> {
  @override
  Widget build(BuildContext context) {
    final t = Translations.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        context.lmUi.settingCard(
          context,
          narrative: true,
          icon: Icons.badge_outlined,
          title: t.common.seedResource.applyCard,
          subtitle: '',
          onTap: _applyResourceCard,
          enabled: widget.enabled,
        ),
        const SizedBox(height: IntermediateSpacing.sMd),
        context.lmUi.settingCard(
          context,
          narrative: true,
          icon: Icons.auto_stories_outlined,
          title: t.common.seedResource.applyBook,
          subtitle: '',
          onTap: _applyResourceBook,
          enabled: widget.enabled,
        ),
        const SizedBox(height: IntermediateSpacing.sMd),
        context.lmUi.settingCard(
          context, narrative: true,
          // F1 修复：兑现「可随时取消应用」承诺
          icon: Icons.remove_circle_outline,
          title: t.common.seedResource.unapplyResource,
          subtitle: '',
          onTap: _unapplyResource,
          enabled: widget.enabled,
        ),
      ],
    );
  }

  /// 取消应用：列出会话内已投影的种子（按来源分组）供选择移除
  Future<void> _unapplyResource() async {
    final t = Translations.of(context);
    try {
      final repository = ref.read(factualRepositoryProvider);
      final entities = await repository.getEntities(
        widget.sessionId,
        includeArchived: true,
      );

      // 分组名用资源名（书名/卡名）。sourceRef 即
      // bookId/cardId，反查资源表一次取全量建索引——此前用首个实体
      // 主名，世界书组显示的是词条名，用户认不出是哪本书。
      final resourceRepository = ref.read(resourceLibraryRepositoryProvider);
      final cards = await resourceRepository.getAllCharacterCards();
      final books = await resourceRepository.getAllWorldbooks();
      if (!mounted) return;
      final groups = groupProjectedSeedEntities(
        entities,
        cardNamesById: {for (final c in cards) c.cardId: c.name},
        bookNamesById: {for (final b in books) b.bookId: b.name},
      );
      if (groups.isEmpty) {
        _showResourceSnack(t.common.seedResource.unapplyEmpty);
        return;
      }

      final selected = await _pickResource(
        groups.values
            .map(
              (g) => (
                id: g.sourceRef,
                name: t.common.seedResource.unapplyItemLabel(
                  name: g.name,
                  count: g.count,
                ),
              ),
            )
            .toList(),
      );
      if (selected == null || !mounted) return;

      final group = groups[selected]!;
      final confirmed = await showLmDialog<bool>(
        context: context,
        // 破坏性确认弹窗不可点屏障/ESC 关闭——
        // 与资源删除弹窗同款，防止「关了但没做」静默空间
        barrierDismissible: false,
        builder: (ctx) => AlertDialog(
          title: Text(t.common.seedResource.unapplyResource),
          content: Text(
            t.common.seedResource.unapplyConfirm(
              name: group.name,
              count: group.count,
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: Text(t.common.cancel),
            ),
            // 取消应用同样删数据（移除 N 个实体及其
            // AI 演变值），确认键改破坏性红样式——此前中性「确认」按钮
            // 承载破坏性操作反而最弱化风险（三套弹窗词汇统一的一部分）。
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              style: FilledButton.styleFrom(
                backgroundColor: Theme.of(ctx).colorScheme.error,
                foregroundColor: Theme.of(ctx).colorScheme.onError,
              ),
              child: Text(t.common.confirm),
            ),
          ],
        ),
      );
      if (confirmed != true || !mounted) return;

      final removed = await _resourceApplyService().unapplyResource(
        sessionId: widget.sessionId,
        sourceRef: selected,
      );
      if (!mounted) return;
      _showResourceSnack(
        t.common.seedResource.unapplyDone(count: removed),
      );
    } catch (e) {
      if (mounted) {
        // 取消应用失败不再复用「应用失败」文案
        _showResourceSnack(
          '${t.common.seedResource.resourceUnapplyFailed}: $e',
        );
      }
    }
  }

  /// 批 J-b：应用前预览对话框。（只读语义 2.0）重组为三段式：
  /// 只读基线样例行（锁形前缀）/ 注入方式（常驻量级 + 按关键词触发量级）/
  /// 尾部说明。非阻断说明式确认（应用非破坏性，随时可取消应用）。
  Future<bool?> _showApplyPreviewDialog(SeedApplyPreview preview) {
    final t = Translations.of(context);
    final colors = context.lm.palette;
    // 按关键词触发条数 = 启用总数 - 常驻数（同源口径，M<=0 不显示）
    final keywordCount =
        (preview.enabledEntryCount ?? 0) - preview.constantCount;
    return showLmDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(t.common.seedResource.previewTitle),
        content: SizedBox(
          width: double.maxFinite,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                preview.title,
                style: SimpleTextStyles.title2.copyWith(color: colors.ink),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: SimpleSpacing.sSm),
              // 段一：将导入为只读基线——样例行统一加锁形前缀（含卡路径的
              // 内置词条行：同为导入只读内容）
              if (preview.lines.isNotEmpty) ...[
                _previewSectionHeader(
                  t.common.seedResource.previewBaselineSection,
                  colors,
                ),
                const SizedBox(height: SimpleSpacing.sXs),
                for (final line in preview.lines)
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      vertical: SimpleSpacing.s2xs,
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (line.kind != SeedPreviewLineKind.moreCount) ...[
                          Icon(
                            Icons.lock_outline,
                            size: 12,
                            color: colors.muted,
                          ),
                          const SizedBox(width: SimpleSpacing.s2xs),
                        ] else
                          // 截断尾行与锁形行文本对齐（12 图标 + 4 间距）
                          const SizedBox(width: 16),
                        Expanded(
                          child: Text(
                            _previewLineText(line),
                            style: SimpleTextStyles.caption
                                .copyWith(color: colors.ink),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                  ),
                const SizedBox(height: SimpleSpacing.sMd),
              ],
              // 段二：注入方式——常驻 N 条每轮必进 + 其余 M 条按关键词触发
              if (preview.constantCount > 0 || keywordCount > 0) ...[
                _previewSectionHeader(
                  t.common.seedResource.previewInjectionSection,
                  colors,
                ),
                const SizedBox(height: SimpleSpacing.sXs),
                if (preview.constantCount > 0)
                  Padding(
                    padding: const EdgeInsets.only(bottom: SimpleSpacing.s2xs),
                    child: Text(
                      t.common.seedResource.previewConstantCount(
                        count: preview.constantCount,
                      ),
                      style: SimpleTextStyles.caption.copyWith(
                        color: colors.primary,
                      ),
                    ),
                  ),
                if (keywordCount > 0)
                  Text(
                    t.common.seedResource.previewKeywordCount(
                      count: keywordCount,
                    ),
                    style: SimpleTextStyles.caption.copyWith(color: colors.ink),
                  ),
                const SizedBox(height: SimpleSpacing.sMd),
              ],
              // 尾部说明：只读基线 + 演变并存语义
              Text(
                t.common.seedResource.previewHint,
                style: SimpleTextStyles.caption.copyWith(color: colors.muted),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(t.common.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(t.common.seedResource.previewApply),
          ),
        ],
      ),
    );
  }

  /// 预览弹窗分段标题：沿用现有 Container 分区风格
  /// （surfaceVariant 底 + 圆角），不引入新组件。
  Widget _previewSectionHeader(String label, LmPalette colors) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(
        horizontal: SimpleSpacing.sSm,
        vertical: SimpleSpacing.s2xs,
      ),
      decoration: BoxDecoration(
        color: colors.surfaceVariant,
        borderRadius: BorderRadius.circular(context.lmUi.radius(LmCorner.sm)),
      ),
      child: Text(
        label,
        style: SimpleTextStyles.caption.copyWith(
          color: colors.muted,
          fontWeight: FontWeight.w600,
        ),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
    );
  }

  /// 预览域服务只产出语义键，用户可见文案统一在
  /// presentation 按 slang 映射——域层不再拼接「background/内置词条」等
  /// 界面标签（绕过中文门禁且与对话框其余中文不一致）。
  String _previewLineText(SeedApplyPreviewLine line) {
    final t = Translations.of(context);
    switch (line.kind) {
      case SeedPreviewLineKind.cardBackground:
        return '${t.common.seedResource.previewLabelBackground}：${line.text}';
      case SeedPreviewLineKind.cardPersonality:
        return '${t.common.seedResource.previewLabelPersonality}：${line.text}';
      case SeedPreviewLineKind.cardEmbeddedEntry:
        return '${t.common.seedResource.previewLabelEmbeddedEntry}：${line.text}';
      case SeedPreviewLineKind.worldbookEntry:
        return line.isConstant
            ? '${t.common.seedResource.previewConstantMark}${line.text}'
            : line.text;
      case SeedPreviewLineKind.moreCount:
        return t.common.seedResource.previewMoreCount(count: line.count ?? 0);
    }
  }

  ResourceApplyService _resourceApplyService() {
    return ResourceApplyService(
      resourceRepository: ref.read(resourceLibraryRepositoryProvider),
      projectionService: ResourceProjectionService(
        repository: ref.read(factualRepositoryProvider),
      ),
    );
  }

  Future<void> _applyResourceCard() async {
    final t = Translations.of(context);
    try {
      final cards = await ref
          .read(resourceLibraryRepositoryProvider)
          .getAllCharacterCards();
      if (!mounted) return;
      if (cards.isEmpty) {
        _showResourceSnack(t.common.seedResource.resourceEmpty);
        return;
      }
      final selected = await _pickResource(
        cards.map((c) => (id: c.cardId, name: c.name)).toList(),
      );
      if (selected == null || !mounted) return;
      // 批 J-b：应用前预览——确认前先看会带来什么
      final preview = await _resourceApplyService().previewCharacterCard(
        cardId: selected,
        defaultCharacterName: t.settings.resourceLibrary.unnamedCharacter,
      );
      if (!mounted) return;
      final confirmed = await _showApplyPreviewDialog(preview);
      if (confirmed != true || !mounted) return;
      final count = await _resourceApplyService().applyCharacterCard(
        sessionId: widget.sessionId,
        cardId: selected,
        defaultCharacterName: t.settings.resourceLibrary.unnamedCharacter,
        defaultSettingName: t.settings.resourceLibrary.unnamedSetting,
        duplicateErrorMessage:
            t.common.seedResource.duplicateCharacter(name: preview.title),
      );
      if (!mounted) return;
      _showResourceSnack(
        t.common.seedResource.resourceApplied(count: count),
      );
    } on ResourceApplyException catch (e) {
      if (mounted) _showResourceSnack(e.message);
    } catch (e) {
      if (mounted) {
        _showResourceSnack(
          '${t.common.seedResource.resourceApplyFailed}: $e',
        );
      }
    }
  }

  Future<void> _applyResourceBook() async {
    final t = Translations.of(context);
    try {
      final books =
          await ref.read(resourceLibraryRepositoryProvider).getAllWorldbooks();
      if (!mounted) return;
      if (books.isEmpty) {
        _showResourceSnack(t.common.seedResource.resourceEmpty);
        return;
      }
      final selected = await _pickResource(
        books.map((b) => (id: b.bookId, name: b.name)).toList(),
      );
      if (selected == null || !mounted) return;
      // 批 J-b：应用前预览（词条样例+常驻量级）
      final preview = await _resourceApplyService().previewWorldbook(
        bookId: selected,
        defaultSettingName: t.settings.resourceLibrary.unnamedSetting,
      );
      if (!mounted) return;
      final confirmed = await _showApplyPreviewDialog(preview);
      if (confirmed != true || !mounted) return;
      final count = await _resourceApplyService().applyWorldbook(
        sessionId: widget.sessionId,
        bookId: selected,
        defaultSettingName: t.settings.resourceLibrary.unnamedSetting,
      );
      if (!mounted) return;
      _showResourceSnack(
        t.common.seedResource.resourceApplied(count: count),
      );
    } on ResourceApplyException catch (e) {
      if (mounted) _showResourceSnack(e.message);
    } catch (e) {
      if (mounted) {
        _showResourceSnack(
          '${t.common.seedResource.resourceApplyFailed}: $e',
        );
      }
    }
  }

  Future<String?> _pickResource(List<({String id, String name})> resources) {
    return showLmSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            for (final r in resources)
              ListTile(
                title: Text(r.name),
                onTap: () => Navigator.pop(ctx, r.id),
              ),
          ],
        ),
      ),
    );
  }

  void _showResourceSnack(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        behavior: SnackBarBehavior.floating,
        content: Text(message),
      ),
    );
  }
}

/// 按 sourceRef（cardId/bookId）聚合会话内已投影的种子实体。
///
/// 分组显示名取**资源名**（书名/卡名，由调用方
/// 反查资源表传入），资源已删除或反查不到时回退首个实体主名——
/// 此前一律用首个实体主名，世界书组显示的是第一个词条名，用户
/// 认不出是哪本书，与 unapplyConfirm(name:...) 联动误导。
/// auto 来源与空 sourceRef 的实体不参与分组。
Map<String, ({String sourceRef, int count, String name})>
    groupProjectedSeedEntities(
  Iterable<FactualEntity> entities, {
  Map<String, String> cardNamesById = const {},
  Map<String, String> bookNamesById = const {},
}) {
  final groups = <String, ({String sourceRef, int count, String name})>{};
  for (final e in entities) {
    final ref = e.sourceRef;
    if ((e.source == FactualSource.card ||
            e.source == FactualSource.worldbook) &&
        ref != null &&
        ref.isNotEmpty) {
      final existing = groups[ref];
      final resourceName = e.source == FactualSource.card
          ? cardNamesById[ref]
          : bookNamesById[ref];
      groups[ref] = (
        sourceRef: ref,
        count: (existing?.count ?? 0) + 1,
        name: existing?.name ?? (resourceName ?? e.primaryName),
      );
    }
  }
  return groups;
}
