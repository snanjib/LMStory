import 'dart:convert';

import 'package:lmstory/core/agent/agent_tool_pipeline.dart';
import 'package:lmstory/core/config/intermediate_config.dart';
import 'package:lmstory/features/advanced/domain/entities/agent_work_step.dart';
import 'package:lmstory/features/chat/domain/entities/story_anchor.dart';
import 'package:lmstory/features/memory/domain/entities/event_summary.dart';
import 'package:lmstory/features/memory/domain/entities/facts_delta.dart';
import 'package:lmstory/features/memory/domain/entities/factual_attribute.dart';
import 'package:lmstory/features/memory/domain/entities/factual_entity.dart';
import 'package:lmstory/features/memory/domain/repositories/factual_repository.dart';
import 'package:lmstory/features/memory/domain/services/attribute_schema.dart';
import 'package:lmstory/features/memory/domain/services/facts_delta_projection.dart';
import 'package:lmstory/i18n/strings.g.dart';

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
    required this.t,
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

  final Translations t;

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
    final raw = request.arguments['deltas'];
    List<dynamic>? decoded;
    if (raw is List) {
      decoded = raw;
    } else if (raw is String && raw.trim().isNotEmpty) {
      try {
        final parsed = jsonDecode(raw);
        if (parsed is List) decoded = parsed;
      } on FormatException {
        decoded = null;
      }
    }
    if (decoded == null || decoded.isEmpty) return const [];

    final changes = <AgentApprovalChange>[];
    for (final item in decoded) {
      if (item is! Map<String, dynamic>) continue;
      final FactsDelta delta;
      try {
        delta = FactsDelta.fromJson(item);
      } catch (_) {
        continue; // 解析失败的条目由工具回执报错，明细区不猜
      }
      final change = await _projectDelta(delta);
      if (change != null) changes.add(change);
    }
    return changes;
  }

  /// 单条 delta 的干跑投影（转写循环至终态，深度上限 3 防环）
  Future<AgentApprovalChange?> _projectDelta(FactsDelta delta) async {
    var current = delta;
    final conversionNotes = <String>[];
    for (var depth = 0; depth < 3; depth++) {
      final entity = await _resolveEntity(current);
      final attrRows = await _attrRowsFor(current, entity);
      final recentUpdates = current.isCuration || current.entityId == null
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
      };

      if (verdict.outcome != FactsProjectionOutcome.converted) {
        final change = _toChange(verdict);
        if (conversionNotes.isEmpty) return change;
        // 保留整条转写链的说明（如 create 撞名→update→别名上限）：用户
        // 看到的应是「请求的是什么 + 实际会发生什么」两段信息
        final fullNote = [
          ...conversionNotes,
          if (change.note != null) change.note!,
        ].join('\n');
        return AgentApprovalChange(
          entityName: change.entityName,
          kind: change.kind,
          attrKey: change.attrKey,
          before: change.before,
          after: change.after,
          note: fullNote,
          reason: change.reason,
          confidence: change.confidence,
          effective: change.effective,
        );
      }
      final rewritten = verdict.rewrittenDelta;
      if (rewritten == null) return _toChange(verdict);
      final noteText = _noteText(verdict);
      if (noteText != null) conversionNotes.add(noteText);
      current = rewritten;
    }
    return null; // 环保护（现有转写链最深 2 层，理论不可达）
  }

  /// 实体定位（模拟 FactApplier._resolveDeltaEntityId 的按名兜底语义）
  Future<FactualEntity?> _resolveEntity(FactsDelta delta) async {
    if (delta.entityId != null) {
      return _repository.getEntityById(delta.entityId!);
    }
    if (delta.primaryName == null || delta.action == FactAction.createEntity) {
      return null;
    }
    final name = delta.primaryName!.trim();
    if (name.isEmpty) return null;
    final matches = await _repository.findByName(sessionId, [name]);
    return matches.length == 1 ? matches.first : null;
  }

  /// 归一化键查属性行（entity 缺失或无 attrKey 时为空）
  Future<List<FactualAttribute>> _attrRowsFor(
    FactsDelta delta,
    FactualEntity? entity,
  ) async {
    if (entity == null || delta.entityId == null || delta.attrKey == null) {
      return const [];
    }
    final attrKey =
        AttributeSchema.normalizeAttrKey(entity.type, delta.attrKey!);
    return _repository.getAttributesByKey(delta.entityId!, attrKey);
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

  AgentApprovalChange _toChange(FactsDeltaProjection verdict) {
    // 投影器契约：applied/converted 的 effectiveAction = 实际生效动作；
    // skipped 的 effectiveAction = 源意图动作（UI 灰显展示「想做但不会生效」）
    return AgentApprovalChange(
      entityName: verdict.entityLabel,
      kind: _kindOf(verdict.effectiveAction),
      attrKey: verdict.normalizedAttrKey,
      before: verdict.before,
      after: verdict.after,
      note: _noteText(verdict),
      reason: verdict.reason,
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
      };

  String? _noteText(FactsDeltaProjection verdict) {
    final note = verdict.note;
    if (note == null) return null;
    final s = t.advanced.approval;
    return switch (note) {
      FactsProjectionNote.missingFields => s.noteMissingFields,
      FactsProjectionNote.unknownEntityType => s.noteMissingFields,
      FactsProjectionNote.entityMissing => s.noteEntityMissing,
      FactsProjectionNote.nameIsIdentity => s.noteNameIsIdentity,
      FactsProjectionNote.attrKeyNotWhitelisted => s.noteWhitelist,
      FactsProjectionNote.valueTooLong => s.noteTooLong,
      FactsProjectionNote.tooFrequent => s.noteTooFrequent,
      FactsProjectionNote.valueUnchangedBaseline => s.noteUnchanged,
      FactsProjectionNote.valueUnchanged => s.noteUnchanged,
      FactsProjectionNote.confidenceGate => s.noteConfidenceGate,
      FactsProjectionNote.listRejectsUpdate => s.noteListRejects,
      FactsProjectionNote.baselineSingleRedirect => s.noteBaselineRedirect,
      FactsProjectionNote.appendOnSingleConvertsUpdate =>
        s.noteBaselineRedirect,
      FactsProjectionNote.duplicateExact => s.noteDuplicate,
      FactsProjectionNote.duplicateSimilar => s.noteDuplicate,
      FactsProjectionNote.noMutableList => s.noteNoMutableList,
      FactsProjectionNote.valueNotInList => s.noteValueNotInList,
      FactsProjectionNote.aliasEmpty => s.noteMissingFields,
      FactsProjectionNote.aliasTooLong => s.noteTooLong,
      FactsProjectionNote.aliasSameAsPrimary => s.noteAliasSameAsPrimary,
      FactsProjectionNote.aliasExists => s.noteDuplicate,
      FactsProjectionNote.aliasLimit => s.noteAliasLimit,
      FactsProjectionNote.alreadyArchived => s.noteAlreadyArchived,
      FactsProjectionNote.sameNameConvertsUpdate => s.noteSameNameUpdate,
      FactsProjectionNote.sameNameConvertsAlias => s.noteSameNameAlias,
      FactsProjectionNote.createsAttrRow => s.noteCreatesAttrRow,
    };
  }

  // ==================== update_story_anchor ====================

  Future<List<AgentApprovalChange>> _composeAnchor(
    ToolExecutionRequest request,
  ) async {
    final args = request.arguments;
    final before = draftAnchor ?? currentAnchor;
    final s = t.advanced.approval;
    final changes = <AgentApprovalChange>[];

    void field(
      String key,
      String labelKey,
      String? Function(StoryAnchor a) get,
      String? after,
    ) {
      if (after == null) return;
      changes.add(
        AgentApprovalChange(
          entityName: s.anchorEntityName,
          kind: ApprovalChangeKind.anchor,
          attrKey: labelKey,
          before: before == null ? null : get(before),
          after: after,
        ),
      );
    }

    field(
      'arc',
      s.anchorFieldArc,
      (a) => a.arc,
      args['arc']?.toString(),
    );
    field(
      'one_liner',
      s.anchorFieldMainline,
      (a) => a.oneLiner,
      args['one_liner']?.toString(),
    );
    field(
      'narrative_time',
      s.anchorFieldTime,
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
          entityName: s.anchorEntityName,
          kind: ApprovalChangeKind.anchor,
          attrKey: s.anchorFieldForeshadow,
          before: oldList.isEmpty ? null : oldTexts.join(' / '),
          after: newList.isEmpty ? null : newTexts.join(' / '),
          note: added == 0 && removed == 0
              ? s.noteUnchanged
              : s.foreshadowDiff(
                  added: added,
                  removed: removed,
                ),
          effective: added != 0 || removed != 0,
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
    final what = args['what']?.toString() ?? '';
    final s = t.advanced.approval;
    final detail = [
      if (args['who'] != null) '${s.eventFieldWho}：${args['who']}',
      if (args['when'] != null) '${s.eventFieldWhen}：${args['when']}',
      if (args['where'] != null) '${s.eventFieldWhere}：${args['where']}',
      if (args['significance'] != null)
        '${s.eventFieldSignificance}：${args['significance']}',
    ].join('；');

    final noteParts = [
      if (detail.isNotEmpty) detail,
      if (draftEventSummary != null) s.noteEventReplace,
    ];
    return [
      AgentApprovalChange(
        entityName: s.eventEntityName,
        kind: ApprovalChangeKind.eventMemory,
        before: draftEventSummary?.displayText,
        after: what,
        note: noteParts.isEmpty ? null : noteParts.join('\n'),
        reason: args['significance']?.toString(),
      ),
    ];
  }

  // ==================== merge_entities（P3 一期口径） ====================

  /// 完整拆解明细二期；一期 = 意图白话行 + 目标实体关键属性快照参考
  Future<List<AgentApprovalChange>> _composeMerge(
    ToolExecutionRequest request,
  ) async {
    final args = request.arguments;
    final s = t.advanced.approval;
    final source = await _resolveMergeEndpoint(
      args['source_entity_id']?.toString(),
      args['source_name']?.toString(),
    );
    final target = await _resolveMergeEndpoint(
      args['target_entity_id']?.toString(),
      args['target_name']?.toString(),
    );

    final changes = <AgentApprovalChange>[
      AgentApprovalChange(
        entityName: s.mergePair(
          source: source?.primaryName ?? args['source_name']?.toString() ?? '?',
          target: target?.primaryName ?? args['target_name']?.toString() ?? '?',
        ),
        kind: ApprovalChangeKind.mergeNote,
        after: s.mergeIntentPlain(
          source: source?.primaryName ?? args['source_name']?.toString() ?? '?',
          target: target?.primaryName ?? args['target_name']?.toString() ?? '?',
        ),
        note: s.noteMergeDetail,
        reason: args['reason']?.toString(),
        confidence: _readConfidence(args['confidence']),
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
              kind: ApprovalChangeKind.entitySnapshot,
              attrKey: row.attrKey,
              after: row.displayText,
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
