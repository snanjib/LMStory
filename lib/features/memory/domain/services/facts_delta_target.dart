import 'package:lmstory/features/memory/domain/entities/facts_delta.dart';
import 'package:lmstory/features/memory/domain/repositories/factual_repository.dart';

/// 非创建动作缺 entityId 时的按名定位兜底
///
/// 导演模式没有故事模式的 {{known_entities}} 通道，模型常拿 primary_name
/// 定位既有实体发起 update_attr 等修改。原实现硬性要求 entityId，这类
/// delta 全部被静默跳过。现按主名（含别名）查找：唯一命中回填 entityId，
/// 未命中或歧义命中返回 null 跳过该条（findByName 的匹配含只读实体，
/// 后续各动作按属性级只读基线语义处理写入）。
///
/// 精确名未命中时补一层主表子串兜底（≥2 字
/// 才启用，避免"剑"这类单字误配），且仅在**唯一命中**时采用——多命中
/// 仍判歧义跳过，不猜。
Future<FactsDelta?> resolveDeltaEntityId(
  FactualRepository repository,
  String sessionId,
  FactsDelta delta, {
  void Function(int matches)? onUnresolved,
}) async {
  if (delta.entityId != null || delta.primaryName == null) return delta;
  if (delta.action == FactAction.createEntity) return delta;

  final name = delta.primaryName!.trim();
  if (name.isEmpty) return null;
  var matches = await repository.findByName(sessionId, [name]);
  if (matches.isEmpty && name.runes.length >= 2) {
    final textMatches = await repository.searchEntitiesByText(
      sessionId,
      [name],
      limit: 5,
    );
    if (textMatches.length == 1) matches = textMatches;
  }
  if (matches.length == 1) {
    return FactsDelta(
      action: delta.action,
      confidence: delta.confidence,
      entityId: matches.first.entityId,
      entityType: delta.entityType,
      primaryName: delta.primaryName,
      attrKey: delta.attrKey,
      value: delta.value,
      reason: delta.reason,
      importance: delta.importance,
      isCuration: delta.isCuration,
      skipFrequencyGuard: delta.skipFrequencyGuard,
    );
  }
  onUnresolved?.call(matches.length);
  return null;
}
