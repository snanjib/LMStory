import 'package:lmstory/features/memory/domain/entities/facts_change_record.dart';
import 'package:lmstory/features/memory/domain/entities/facts_delta.dart';
import 'package:lmstory/features/memory/domain/entities/factual_attribute.dart';
import 'package:lmstory/features/memory/domain/entities/factual_entity.dart';
import 'package:lmstory/features/memory/domain/services/attribute_schema.dart';

/// 实际生效的事实及其写入效果。持久化使用，模型只能提供 [FactsDelta]。
class AppliedFact {
  const AppliedFact({
    required this.action,
    required this.entityId,
    required this.attrKey,
    required this.value,
    required this.reason,
    required this.beforeHash,
    required this.afterHash,
  });

  factory AppliedFact.fromJson(Map<String, Object?> json) {
    if (json
        case {
          'action': final String action,
          'entityId': final String entityId,
          'attrKey': final String? attrKey,
          'value': final String? value,
          'reason': final String? reason,
          'beforeHash': final String? beforeHash,
          'afterHash': final String afterHash,
        }
        when entityId.isNotEmpty &&
            _effectHashPattern.hasMatch(afterHash) &&
            (beforeHash == null || _effectHashPattern.hasMatch(beforeHash))) {
      final factAction = _storedAction(action);
      if (factAction != null) {
        return AppliedFact(
          action: factAction,
          entityId: entityId,
          attrKey: attrKey,
          value: value,
          reason: reason,
          beforeHash: beforeHash,
          afterHash: afterHash,
        );
      }
    }
    throw const FormatException('Invalid stored fact effect');
  }

  /// 存储在每条原始提议上。键存在且值为 null 表示该条未生效。
  static const field = 'applied';
  static final _effectHashPattern = RegExp(r'^[0-9a-f]{64}$');

  final FactAction action;
  final String entityId;
  final String? attrKey;
  final String? value;
  final String? reason;
  final String? beforeHash;
  final String afterHash;

  Map<String, Object?> toJson() => {
        'action': action.toJsonString(),
        'entityId': entityId,
        'attrKey': attrKey,
        'value': value,
        'reason': reason,
        'beforeHash': beforeHash,
        'afterHash': afterHash,
      };

  bool matches(AppliedFact replayed) =>
      action == replayed.action &&
      attrKey == replayed.attrKey &&
      value == replayed.value &&
      reason == replayed.reason &&
      beforeHash == replayed.beforeHash &&
      afterHash == replayed.afterHash;

  FactsDelta replayDelta(FactsDelta proposal, String targetId) => FactsDelta(
        action: action,
        entityId: action == FactAction.createEntity ? null : targetId,
        entityType: proposal.entityType,
        primaryName: proposal.primaryName,
        attrKey: attrKey,
        value: action == FactAction.createEntity
            ? (attrKey == null ? null : proposal.value)
            : value,
        reason: reason,
        confidence: proposal.confidence,
        importance: proposal.importance ??
            (action == FactAction.setImportance
                ? int.tryParse(value ?? '')
                : null),
        isCuration:
            proposal.isCuration && proposal.action != FactAction.createEntity,
        skipFrequencyGuard: proposal.skipFrequencyGuard,
      );
}

/// 早期格式保存的是原始提议。只有与同一稿件的成功记录逐条吻合，
/// 明确指定对象的提议才可交给会话归属校验和事务重放。
class LegacyFactReplay {
  const LegacyFactReplay(this.proposal, this.change, this.entityId);

  static const createdIdField = 'replayCreatedId';

  /// 复制可信旧稿时，保留供比对的原展示 ID。实际写入使用独立的本地 ID。
  static const displayIdField = 'legacyDisplayEntityId';

  final FactsDelta proposal;
  final FactsChangeRecord change;
  final String entityId;

  bool matches(FactsChangeRecord replayed, AppliedFact effect) {
    final key = effect.attrKey;
    // 旧展示只有原提议的键，无法证明按关系对象名称归一后写的是哪一条。
    if (key != null && AttributeSchema.relationshipObjectOf(key) != null) {
      return false;
    }
    return (proposal.action == FactAction.createEntity ||
            key == proposal.attrKey) &&
        change.action == replayed.action &&
        change.attrKey == replayed.attrKey &&
        change.oldValue == replayed.oldValue &&
        change.newValue == replayed.newValue &&
        change.reason == replayed.reason;
  }

  static List<LegacyFactReplay> read(
    List<Map<String, Object?>> rows,
    List<Map<String, Object?>> changes,
  ) {
    if (rows.length != changes.length) {
      throw const FormatException('Missing stored fact effects');
    }
    final replays = <LegacyFactReplay>[];
    final createdHere = <String>{};
    for (final (index, row) in rows.indexed) {
      final proposal = readStoredFactProposal(row);
      final display = changes[index];
      _checkStoredFactFields(display, const ['oldValue', 'newValue']);
      final change = FactsChangeRecord.fromJson(display);
      final displayId = change.entityId;
      final creating = proposal.action == FactAction.createEntity;
      final entityId =
          creating ? row[createdIdField] ?? displayId : proposal.entityId;
      final expectedDisplayId = row[displayIdField] ?? entityId;
      final expectedValue = switch (proposal.action) {
        FactAction.createEntity => proposal.primaryName,
        FactAction.addAlias => proposal.value?.trim(),
        FactAction.archiveEntity => null,
        _ => proposal.value,
      };
      if (entityId is! String ||
          entityId.isEmpty ||
          displayId == null ||
          displayId.isEmpty ||
          displayId != expectedDisplayId ||
          proposal.action != change.action ||
          proposal.attrKey != change.attrKey ||
          proposal.primaryName != change.primaryName ||
          proposal.entityType != change.entityType ||
          proposal.reason != change.reason ||
          proposal.confidence != change.confidence ||
          expectedValue != change.newValue ||
          !_legacyAttributeIsUnambiguous(proposal) ||
          (creating &&
              (proposal.entityId != null ||
                  change.oldValue != null ||
                  !createdHere.add(entityId)))) {
        throw const FormatException('Unverified legacy fact proposal');
      }
      replays.add(LegacyFactReplay(proposal, change, entityId));
    }
    return replays;
  }

  static bool _legacyAttributeIsUnambiguous(FactsDelta proposal) {
    final attrKey = proposal.attrKey;
    if (attrKey == null) return true;
    if (AttributeSchema.relationshipObjectOf(attrKey) != null) return false;
    // 创建记录的实体类型由创建动作本身确定。其他动作的旧展示只带提议
    // 中填写的类型，无法排除实际对象当时是另一个类型。
    if (proposal.action == FactAction.createEntity) return true;
    final candidates = <({String key, AttributeValueType valueType})>{};
    for (final type in FactualEntityType.values) {
      final key = AttributeSchema.normalizeAttrKey(type, attrKey);
      if (proposal.isCuration || AttributeSchema.isAttrKeyAllowed(type, key)) {
        candidates.add(
          (
            key: key,
            valueType: AttributeSchema.valueTypeOf(type, key),
          ),
        );
      }
    }
    return candidates.length == 1 && candidates.single.key == attrKey;
  }
}

FactsDelta readStoredFactProposal(Map<String, Object?> json) {
  _checkStoredFactFields(json, const ['value']);
  if ((json['importance'] != null && json['importance'] is! int) ||
      (json['isCuration'] != null && json['isCuration'] is! bool) ||
      (json['skipFrequencyGuard'] != null &&
          json['skipFrequencyGuard'] is! bool)) {
    throw const FormatException('Invalid stored fact proposal');
  }
  return FactsDelta.fromJson(json);
}

void _checkStoredFactFields(
  Map<String, Object?> json,
  List<String> valueFields,
) {
  final confidence = json['confidence'];
  if (_storedAction(json['action']) == null ||
      confidence is! num ||
      !confidence.isFinite) {
    throw const FormatException('Invalid stored fact action or confidence');
  }
  for (final field in [
    'entityId',
    'entityType',
    'primaryName',
    'attrKey',
    'reason',
    ...valueFields,
  ]) {
    final value = json[field];
    if (value != null && value is! String) {
      throw const FormatException('Invalid stored fact text field');
    }
  }
}

FactAction? _storedAction(Object? action) {
  for (final candidate in FactAction.values) {
    if (action == candidate.toJsonString()) return candidate;
  }
  return null;
}
