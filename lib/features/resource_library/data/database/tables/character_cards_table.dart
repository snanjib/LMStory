import 'package:drift/drift.dart';

/// character_cards 表定义（DOC-15 §9.1）
///
/// 角色卡资源库（全局、跨会话复用）：存 SillyTavern 角色卡的**完整原始 JSON**
/// （无损，服务详情展示 + 投影到会话事实层 source=card）。
class CharacterCardsTable extends Table {
  @override
  String get tableName => 'character_cards';

  /// 自增主键（内部使用，不暴露）
  IntColumn get id => integer().autoIncrement()();

  /// 业务主键（uuid）
  TextColumn get cardId => text().withLength(min: 1).unique()();

  /// 反规范化展示名（列表展示用，其余展示字段从 rawJson 解析）
  TextColumn get name => text().withLength(min: 1)();

  /// 完整原始卡 JSON（无损）
  TextColumn get rawJson => text()();

  /// 来源格式：`v1` / `v2` / `v3` / `json`
  TextColumn get sourceFormat => text().nullable()();

  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
  DateTimeColumn get updatedAt => dateTime().withDefault(currentDateAndTime)();
}
