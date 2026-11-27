import 'dart:math' as math;

import 'package:lmstory/core/config/intermediate_config.dart';
import 'package:lmstory/core/utils/logger.dart';
import 'package:lmstory/features/advanced/domain/services/agent_system_prompt.dart';
import 'package:lmstory/features/chat/domain/entities/story_anchor.dart';
import 'package:lmstory/features/memory/domain/entities/experiential_memory.dart';
import 'package:lmstory/features/memory/domain/entities/factual_attribute.dart';
import 'package:lmstory/features/memory/domain/entities/factual_entity.dart';
import 'package:lmstory/features/memory/domain/entities/factual_source.dart';
import 'package:lmstory/features/memory/domain/repositories/experience_repository.dart';
import 'package:lmstory/features/memory/domain/repositories/factual_repository.dart';

/// 导演模式 core blocks 装配数据（场记板的同源投影）
///
/// 关键实体/近期活跃非核心动态实体/属性/宏摘要/叙事时间/剧情锚是
/// 「AI 眼中的现在」的结构化素材；[text] 经
/// [AgentSystemPromptBuilder.buildCoreBlocks] 产出注入文本。
/// runner（注入面）与场记板视图（用户面）共用同一份装配，保证互验一致。
class DirectorCoreBlocksData {
  const DirectorCoreBlocksData({
    required this.keyEntities,
    required this.attributesByEntity,
    required this.latestMacros,
    required this.narrativeTime,
    required this.anchor,
    this.recentActiveEntities = const [],
  });

  final List<FactualEntity> keyEntities;
  final List<FactualEntity> recentActiveEntities;
  final Map<String, List<FactualAttribute>> attributesByEntity;
  final List<ExperientialMemory> latestMacros;
  final String? narrativeTime;
  final StoryAnchor? anchor;

  /// 注入文本（无任何段落时 null）
  String? get text => const AgentSystemPromptBuilder().buildCoreBlocks(
        keyEntities: keyEntities,
        attributesByEntity: attributesByEntity,
        latestMacros: latestMacros,
        narrativeTime: narrativeTime,
        anchor: anchor,
        recentActiveEntities: recentActiveEntities,
      );

  /// 是否含世界书/角色卡导入实体（来源标注面）
  bool get hasImported => keyEntities.any((e) => e.source.name != 'auto');
}

int _latestActiveTurnOf(FactualEntity entity) {
  final updated = entity.updatedTurn;
  if (updated == null) return entity.createdTurn;
  return math.max(entity.createdTurn, updated);
}

/// 装配 core blocks 数据（runner 注入与  场记板共用）
///
/// 语义与 2026-09 前的 runner._buildDirectorCoreBlocks 完全一致：
/// - ：forceInject 非 none 的实体不达重要性阈值也入选
/// - ：停用词条不进任何注入桶（excludeInjectionDisabled）
/// - 失败不抛异常：返回 null，调用方各自降级（轮次不阻断/面板报不可用）
Future<DirectorCoreBlocksData?> assembleDirectorCoreBlocks({
  required FactualRepository factual,
  required ExperienceRepository experienceRepository,
  required String sessionId,
  required FactualConfig factualConfig,
  required String? narrativeTime,
  required StoryAnchor? anchor,
  int? currentTurn,
  int recentActiveEntitiesWindow = 15,
  int recentActiveEntitiesCap = 10,
  Logger? logger,
}) async {
  try {
    final keyEntitiesRaw = await factual.getKeyEntities(
      sessionId,
      factualConfig.keyEntityImportanceThreshold,
      includeForceInject: true,
      excludeInjectionDisabled: true,
    );
    // DEC-06：装配层取数与故事模式同一收口口径——统一稳定排序
    //（importance DESC → updatedAt/updatedTurn 新者在前 → entityId 兜底）
    // 后取 keyEntityAutoCap（默认 10，与展示层 buildCoreBlocks 的实体
    // take(10) 对齐），不叠加额外收缩。仓储查询层不感知此排序。
    final keyEntities = ([...keyEntitiesRaw]
          ..sort(FactualEntity.compareInjectionPriority))
        .take(factualConfig.keyEntityAutoCap)
        .toList();
    final attributesByEntity = <String, List<FactualAttribute>>{};
    if (keyEntities.isNotEmpty) {
      final attributes = await factual.getAttributes(
        sessionId,
        [for (final e in keyEntities) e.entityId],
      );
      for (final attr in attributes) {
        attributesByEntity.putIfAbsent(attr.entityId, () => []).add(attr);
      }
    }

    var recentActiveEntities = const <FactualEntity>[];
    if (recentActiveEntitiesWindow > 0 && recentActiveEntitiesCap > 0) {
      final keyEntityIds = {
        for (final e in keyEntities.take(10)) e.entityId,
      };
      final activeEntities = await factual.getEntities(sessionId);
      final effectiveTurn = currentTurn ??
          activeEntities.fold<int>(
            anchor?.updatedTurn ?? 0,
            (maxTurn, e) => math.max(maxTurn, _latestActiveTurnOf(e)),
          );
      final candidates = activeEntities.where((e) {
        if (e.isArchived || e.injectionDisabled) return false;
        if (keyEntityIds.contains(e.entityId)) return false;
        final isDynamicOrEvolved =
            e.source == FactualSource.auto || e.updatedTurn != null;
        if (!isDynamicOrEvolved) return false;
        final activeTurn = _latestActiveTurnOf(e);
        return effectiveTurn - activeTurn <= recentActiveEntitiesWindow;
      }).toList()
        ..sort((a, b) {
          final byTurn =
              _latestActiveTurnOf(b).compareTo(_latestActiveTurnOf(a));
          if (byTurn != 0) return byTurn;
          final byImportance = b.importance.compareTo(a.importance);
          if (byImportance != 0) return byImportance;
          return a.entityId.compareTo(b.entityId);
        });
      recentActiveEntities = candidates.take(recentActiveEntitiesCap).toList();
    }

    // 宏摘要口径与 runner.loadLatestMacros 一致：最近 20 条里取前 3 条 macro
    final recent = await experienceRepository.getRecentExperiences(
      sessionId,
      limit: 20,
    );
    final latestMacros = recent.where((m) => m.isMacro).take(3).toList();
    return DirectorCoreBlocksData(
      keyEntities: keyEntities,
      recentActiveEntities: recentActiveEntities,
      attributesByEntity: attributesByEntity,
      latestMacros: latestMacros,
      narrativeTime: narrativeTime,
      anchor: anchor,
    );
  } catch (e) {
    logger?.warn('Director core blocks skipped on failure', detail: '$e');
    return null;
  }
}
