import 'package:meta/meta.dart';

/// 角色卡资源（DOC-15 §9.1）
///
/// 资源库中的全局角色卡资源，存完整原始 JSON（无损）。
/// 展示字段（tags/creator/scenario 等 B 类）从 [rawJson] 解析。
@immutable
class CharacterCard {
  const CharacterCard({
    required this.cardId,
    required this.name,
    required this.rawJson,
    required this.createdAt,
    required this.updatedAt,
    this.sourceFormat,
  });

  final String cardId;
  final String name;
  final String rawJson;

  /// 来源格式：`v1` / `v2` / `v3` / `json`
  final String? sourceFormat;

  final DateTime createdAt;
  final DateTime updatedAt;
}
