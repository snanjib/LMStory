import 'package:lmstory/core/agent/agent_tool_pipeline.dart';
import 'package:lmstory/core/config/intermediate_config.dart';
import 'package:lmstory/features/advanced/domain/entities/agent_work_step.dart';
import 'package:lmstory/features/advanced/domain/services/agent_session_tools.dart'
    show AgentFactsDeltaInput;
import 'package:lmstory/features/chat/domain/entities/story_anchor.dart';
import 'package:lmstory/features/memory/domain/entities/event_summary.dart';
import 'package:lmstory/features/memory/domain/entities/facts_delta.dart';
import 'package:lmstory/features/memory/domain/entities/factual_attribute.dart';
import 'package:lmstory/features/memory/domain/entities/factual_entity.dart';
import 'package:lmstory/features/memory/domain/repositories/factual_repository.dart';
import 'package:lmstory/features/memory/domain/services/attribute_schema.dart';
import 'package:lmstory/features/memory/domain/services/facts_delta_projection.dart';
import 'package:lmstory/features/memory/domain/services/facts_delta_target.dart';

/// 审批变更明细组装器（2026-10-15 批 B）
///
/// 审批 seam 弹横幅前调用：以「工具参数 + repository 现查旧值」干跑合成
/// 结构化前后对比（[AgentApprovalChange]），转写判定委托
/// [FactsDeltaProjectionEvaluator]（与 FactApplier 落库同源——看到的
/// diff = 落库判定）。
///
/// **降级契约**：任一步异常由调用方捕获并置空 changes（审批照常，横幅
/// 退化为现状纯摘要）；本类内部不抛出阻断审批的异常（解析失败返回
/// 空明细）。
class AgentApprovalComposer {
  AgentApprovalComposer({
    required FactualRepository repository,
    required this.sessionId,
    required this.draftTurnNumber,
    required this.currentAnchor,
    required this.draftAnchor,
    required this.draftEventSummary,
  }) : _repository = repository;

  final FactualRepository _repository;
  final String sessionId;
  final int draftTurnNumber;

  /// 会话当前锚（update_story_anchor 的 before 基线：参数未提供的字段
  /// 保留旧值 = 部分更新语义）
  final StoryAnchor? currentAnchor;

  /// 本轮草稿锚（已批准暂存的锚更新，优先于会话当前锚）
  final StoryAnchor? draftAnchor;

  /// 本轮草稿事件记忆（同轮二次 record_event_memory 的「将替换」提示）
  final EventSummary? draftEventSummary;

  /// 组装入口：按工具分派；未知写工具返回空明细（横幅退化为摘要）
  Future<List<AgentApprovalChange>> compose(
    ToolExecutionRequest request,
  ) async {
    switch (request.toolName) {
      case 'update_facts':
        return _composeFacts(request);
      case 'update_story_anchor':
        return _composeAnchor(request);
      case 'record_event_memory':
        return _composeEvent(request);
      case 'merge_entities':
        return _composeMerge(request);
      default:
        return const [];
    }
  }

  // ==================== update_facts ====================

  Future<List<AgentApprovalChange>> _composeFacts(
    ToolExecutionRequest request,
  ) async {
    final arguments = request.arguments;
    if (arguments['clear_pending'] == true &&
        arguments['replace_pending'] != true) {
      return const [];
    }
    final decoded = AgentFactsDeltaInput.decodeList(arguments['deltas']);
    if (decoded == null || decoded.length > AgentFactsDeltaInput.maxBatchSize) {
      return const [];
    }

    final changes = <AgentApprovalChange>[];
    for (final item in decoded) {
      final input = AgentFactsDeltaInput.fromRaw(item).input;
      final delta = input?.toFactsDelta();
      if (input == null || delta == null) continue;
      final change = await _projectDelta(delta, input.originalReason);
      if (change != null) changes.add(change);
    }
    return changes;
  }

  /// 单条 delta 的干跑投影（转写循环至终态，深度上限 3 防环）
  Future<AgentApprovalChange?> _projectDelta(
    FactsDelta delta,
    String? originalReason,
  ) async {
    var current = await resolveDeltaEntityId(
          _repository,
          sessionId,
          delta,
        ) ??
        delta;
    final conversionNotes = <FactsProjectionNote>[];
    for (var depth = 0; depth < 3; depth++) {
      final entityId = current.entityId;
      final entity =
          entityId == null ? null : await _repository.getEntityById(entityId);
      final attrRows = await _attrRowsFor(current, entity);
      final recentUpdates = current.isCuration ||
              current.skipFrequencyGuard ||
              current.entityId == null
          ? 0
          : await _countRecentUpdates(current.entityId!);

      final verdict = switch (current.action) {
        FactAction.updateAttr =>
          FactsDeltaProjectionEvaluator.evaluateUpdateAttr(
            delta: current,
            config: const FactualConfig(),
            entity: entity,
            attrRows: attrRows,
            recentUpdates: recentUpdates,
          ),
        FactAction.appendList =>
          FactsDeltaProjectionEvaluator.evaluateAppendList(
            delta: current,
            config: const FactualConfig(),
            entity: entity,
            attrRows: attrRows,
          ),
        FactAction.removeFromList =>
          FactsDeltaProjectionEvaluator.evaluateRemoveFromList(
            delta: current,
            entity: entity,
            attrRows: attrRows,
          ),
        FactAction.addAlias => FactsDeltaProjectionEvaluator.evaluateAddAlias(
            delta: current,
            config: const FactualConfig(),
            entity: entity,
          ),
        FactAction.archiveEntity =>
          FactsDeltaProjectionEvaluator.evaluateArchiveEntity(
            delta: current,
            entity: entity,
          ),
        FactAction.createEntity =>
          FactsDeltaProjectionEvaluator.evaluateCreateEntity(
            delta: current,
            config: const FactualConfig(),
            sameNameEntity: current.primaryName == null
                ? null
                : await _findByName(current.primaryName!),
          ),
        FactAction.setImportance =>
          FactsDeltaProjectionEvaluator.evaluateSetImportance(
            delta: current,
            entity: entity,
          ),
      };

      final rewritten = verdict.rewrittenDelta;
      final note = verdict.note;
      if (note != null) conversionNotes.add(note);
      if (verdict.outcome != FactsProjectionOutcome.converted ||
          rewritten == null) {
        return _toChange(
          verdict,
          entity?.type ?? FactualEntityType.tryFromString(current.entityType),
          conversionNotes,
          originalReason ?? delta.reason,
        );
      }
      current = rewritten;
    }
    return null; // 环保护（现有转写链最深 2 层，理论不可达）
  }

  /// 归一化键查属性行（entity 缺失或无 attrKey 时为空）
  ///
  /// 按对象关系键的对象名规范化与 FactApplier 落库同款（别名唯一命中
  /// 归一到主名），保证审批横幅看到的行 = 提交时落库判定的行。
  Future<List<FactualAttribute>> _attrRowsFor(
    FactsDelta delta,
    FactualEntity? entity,
  ) async {
    if (entity == null || delta.entityId == null || delta.attrKey == null) {
      return const [];
    }
    var attrKey = AttributeSchema.normalizeAttrKey(entity.type, delta.attrKey!);
    final relationshipObject =
        AttributeSchema.relationshipObjectOf(delta.attrKey!);
    if (relationshipObject != null) {
      attrKey = await _canonicalizeRelationshipKey(relationshipObject);
    }
    return _repository.getAttributesByKey(delta.entityId!, attrKey);
  }

  /// 按对象关系键对象名规范化（与 FactApplier._canonicalizeRelationshipKey
  /// 同语义：唯一命中归一，未命中/歧义保留原键）
  Future<String> _canonicalizeRelationshipKey(String relationshipObject) async {
    try {
      final matches = await _repository.findByName(
        sessionId,
        [relationshipObject],
      );
      if (matches.length == 1) {
        return AttributeSchema.buildRelationshipAttrKey(
          matches.first.primaryName,
        );
      }
    } catch (_) {
      // 名字解析失败保留原键，与落库侧一致
    }
    return AttributeSchema.buildRelationshipAttrKey(relationshipObject);
  }

  Future<int> _countRecentUpdates(String entityId) async {
    try {
      return await _repository.countRecentUpdates(
        entityId,
        fromTurn: draftTurnNumber - 2,
      );
    } catch (_) {
      return 0;
    }
  }

  Future<FactualEntity?> _findByName(String name) async {
    final matches = await _repository.findByName(sessionId, [name]);
    return matches.isEmpty ? null : matches.first;
  }

  AgentApprovalChange _toChange(
    FactsDeltaProjection verdict,
    FactualEntityType? entityType,
    List<FactsProjectionNote> notes,
    String? reason,
  ) {
    return AgentApprovalChange(
      entityName: verdict.entityLabel,
      kind: _kindOf(verdict.effectiveAction),
      entityType: entityType,
      attrKey: verdict.effectiveAction == FactAction.setImportance
          ? 'importance'
          : verdict.normalizedAttrKey,
      before: verdict.before,
      after: verdict.after,
      details: notes.isEmpty ? null : ApprovalFactNotes(notes),
      reason: reason,
      confidence: verdict.confidence,
      effective: verdict.outcome != FactsProjectionOutcome.skipped,
    );
  }

  ApprovalChangeKind _kindOf(FactAction action) => switch (action) {
        FactAction.createEntity => ApprovalChangeKind.createEntity,
        FactAction.updateAttr => ApprovalChangeKind.updateAttr,
        FactAction.appendList => ApprovalChangeKind.appendList,
        FactAction.removeFromList => ApprovalChangeKind.removeFromList,
        FactAction.addAlias => ApprovalChangeKind.addAlias,
        FactAction.archiveEntity => ApprovalChangeKind.archiveEntity,
        FactAction.setImportance => ApprovalChangeKind.updateAttr,
      };

  // ==================== update_story_anchor ====================

  Future<List<AgentApprovalChange>> _composeAnchor(
    ToolExecutionRequest request,
  ) async {
    final args = request.arguments;
    final before = draftAnchor ?? currentAnchor;
    final changes = <AgentApprovalChange>[];

    void field(
      ApprovalAnchorField field,
      String? Function(StoryAnchor a) get,
      String? after,
    ) {
      if (after == null) return;
      changes.add(
        AgentApprovalChange(
          entityName: '',
          kind: ApprovalChangeKind.anchor,
          before: before == null ? null : get(before),
          after: after,
          details: ApprovalAnchorDetails(field),
        ),
      );
    }

    field(
      ApprovalAnchorField.arc,
      (a) => a.arc,
      args['arc']?.toString(),
    );
    field(
      ApprovalAnchorField.mainline,
      (a) => a.oneLiner,
      args['one_liner']?.toString(),
    );
    field(
      ApprovalAnchorField.time,
      (a) => a.narrativeTime,
      args['narrative_time']?.toString(),
    );

    final rawForeshadows = args['foreshadows'];
    if (rawForeshadows is List) {
      final newList = rawForeshadows
          .map(
            (e) => e is Map<String, dynamic>
                ? AnchorForeshadow.fromJson(e)
                : AnchorForeshadow(text: e.toString()),
          )
          .toList();
      final oldList = before?.foreshadows ?? const <AnchorForeshadow>[];
      final oldTexts = oldList.map((f) => f.text).toSet();
      final newTexts = newList.map((f) => f.text).toSet();
      final added = newTexts.difference(oldTexts).length;
      final removed = oldTexts.difference(newTexts).length;
      changes.add(
        AgentApprovalChange(
          entityName: '',
          kind: ApprovalChangeKind.anchor,
          before: oldList.isEmpty ? null : oldTexts.join(' / '),
          after: newList.isEmpty ? null : newTexts.join(' / '),
          effective: added != 0 || removed != 0,
          details: ApprovalAnchorDetails(
            ApprovalAnchorField.foreshadow,
            added: added,
            removed: removed,
          ),
        ),
      );
    }

    return changes;
  }

  // ==================== record_event_memory ====================

  Future<List<AgentApprovalChange>> _composeEvent(
    ToolExecutionRequest request,
  ) async {
    final args = request.arguments;
    return [
      AgentApprovalChange(
        entityName: '',
        kind: ApprovalChangeKind.eventMemory,
        after: args['what']?.toString() ?? '',
        reason: args['significance']?.toString(),
        details: ApprovalEventDetails(
          previous: draftEventSummary,
          who: args['who']?.toString(),
          when: args['when']?.toString(),
          where: args['where']?.toString(),
        ),
      ),
    ];
  }

  // ==================== merge_entities（P3 一期口径） ====================

  /// 完整拆解明细二期；一期 = 意图白话行 + 目标实体关键属性快照参考
  Future<List<AgentApprovalChange>> _composeMerge(
    ToolExecutionRequest request,
  ) async {
    final args = request.arguments;
    final source = await _resolveMergeEndpoint(
      args['source_entity_id']?.toString(),
      args['source_name']?.toString(),
    );
    final target = await _resolveMergeEndpoint(
      args['target_entity_id']?.toString(),
      args['target_name']?.toString(),
    );
    final sourceName =
        source?.primaryName ?? args['source_name']?.toString() ?? '?';
    final targetName =
        target?.primaryName ?? args['target_name']?.toString() ?? '?';
    final reason = args['reason']?.toString();
    final confidence = _readConfidence(args['confidence']);

    final changes = <AgentApprovalChange>[
      AgentApprovalChange(
        entityName: '',
        kind: ApprovalChangeKind.mergeNote,
        reason: reason,
        confidence: confidence,
        details: ApprovalMergeDetails(source: sourceName, target: targetName),
      ),
    ];

    // 目标实体关键属性快照（参考；非变更）
    if (target != null) {
      try {
        final attrs = await _repository.getAttributes(sessionId, [
          target.entityId,
        ]);
        final rows = attrs.where((a) => a.entityId == target.entityId).take(3);
        for (final row in rows) {
          changes.add(
            AgentApprovalChange(
              entityName: target.primaryName,
              entityType: target.type,
              kind: ApprovalChangeKind.entitySnapshot,
              attrKey: row.attrKey,
              details: ApprovalSnapshotDetails(row),
            ),
          );
        }
      } catch (_) {
        // 快照失败不影响意图行
      }
    }
    return changes;
  }

  Future<FactualEntity?> _resolveMergeEndpoint(
    String? id,
    String? name,
  ) async {
    if (id != null && id.isNotEmpty) {
      final byId = await _repository.getEntityById(id);
      if (byId != null) return byId;
    }
    if (name != null && name.trim().isNotEmpty) {
      return _findByName(name.trim());
    }
    return null;
  }

  static int? _readConfidence(Object? raw) {
    if (raw is int) return raw.clamp(1, 5);
    if (raw is num) return raw.toInt().clamp(1, 5);
    return null;
  }
}
