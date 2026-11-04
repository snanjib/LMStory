import 'package:lmstory/core/config/intermediate_config.dart';
import 'package:lmstory/core/utils/logger.dart';
import 'package:lmstory/features/advanced/domain/services/agent_system_prompt.dart';
import 'package:lmstory/features/chat/domain/entities/story_anchor.dart';
import 'package:lmstory/features/memory/domain/entities/experiential_memory.dart';
import 'package:lmstory/features/memory/domain/entities/factual_attribute.dart';
import 'package:lmstory/features/memory/domain/entities/factual_entity.dart';
import 'package:lmstory/features/memory/domain/repositories/experience_repository.dart';
import 'package:lmstory/features/memory/domain/repositories/factual_repository.dart';

/// 导演模式 core blocks 装配数据（场记板的同源投影）
///
/// 关键实体/属性/宏摘要/叙事时间/剧情锚是「AI 眼中的现在」的结构化素材；
/// [text] 经 [AgentSystemPromptBuilder.buildCoreBlocks] 产出注入文本（截断
/// 口径见其实现：实体 take(10)、属性 importance≥3 take(4)、宏摘要 take(2)）。
/// runner（注入面）与场记板视图（用户面）共用同一份装配，保证互验一致。
class DirectorCoreBlocksData {
  const DirectorCoreBlocksData({
    required this.keyEntities,
    required this.attributesByEntity,
    required this.latestMacros,
    required this.narrativeTime,
    required this.anchor,
  });

  final List<FactualEntity> keyEntities;
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
      );

  /// 是否含世界书/角色卡导入实体（来源标注面）
  bool get hasImported => keyEntities.any((e) => e.source.name != 'auto');
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
  Logger? logger,
}) async {
  try {
    final keyEntities = await factual.getKeyEntities(
      sessionId,
      factualConfig.keyEntityImportanceThreshold,
      includeForceInject: true,
      excludeInjectionDisabled: true,
    );
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
    // 宏摘要口径与 runner.loadLatestMacros 一致：最近 20 条里取前 3 条 macro
    final recent = await experienceRepository.getRecentExperiences(
      sessionId,
      limit: 20,
    );
    final latestMacros = recent.where((m) => m.isMacro).take(3).toList();
    return DirectorCoreBlocksData(
      keyEntities: keyEntities,
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
