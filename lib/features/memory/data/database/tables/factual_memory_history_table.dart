import 'package:drift/drift.dart';

/// factual_memory_history 表定义（DOC-11 §3.3）
///
/// 事实层审计日志表：记录所有 UPDATE/APPEND/REMOVE/CREATE/ARCHIVE 操作的
/// 历史版本，用于审计、回滚和更新频率限制。
///
/// 写入时机：每次 FactApplier.apply 成功应用一个 FactsDelta 后，
/// 在同一事务内追加一条历史记录。
/// 读取时机：
/// - 更新频率限制（DOC-11 §7.4.5）：查询某实体最近 N 轮的更新次数。
/// - 审计 UI（v0.3 HUD）：展示实体修改历史。
///
/// 不读取时机：retrieving 阶段不读取本表（只读 entities + attributes）。
///
/// Schema 依据：DOC-11 §3.3、DOC-02 §6（v22 新增）。
class FactualMemoryHistoryTable extends Table {
  @override
  String get tableName => 'factual_memory_history';

  /// 自增主键
  IntColumn get id => integer().autoIncrement()();

  /// 实体 ID（指向 FactualEntity.entityId）
  ///
  /// CREATE_ENTITY 时已有 entityId（系统先生成再创建）。
  TextColumn get entityId => text()();

  /// 属性 ID（nullable：CREATE_ENTITY / ADD_ALIAS / ARCHIVE_ENTITY 时无）
  TextColumn get attributeId => text().nullable()();

  /// 动作类型（与 FactAction 枚举对齐）
  ///
  /// `CREATE_ENTITY` / `UPDATE_ATTR` / `APPEND_LIST` / `REMOVE_FROM_LIST`
  /// / `ADD_ALIAS` / `ARCHIVE_ENTITY`
  TextColumn get action => text()();

  /// 旧值（CREATE 时为 NULL）
  TextColumn get oldValue => text().nullable()();

  /// 新值（ARCHIVE_ENTITY 时可为 NULL）
  TextColumn get newValue => text().nullable()();

  /// 修改原因（审计用，UPDATE_ATTR 必填）
  TextColumn get reason => text().nullable()();

  /// LLM 置信度 1-5（nullable：系统自动操作时无）
  ///
  /// 用于审计低置信度修改被拒绝的情况。
  IntColumn get confidence => integer().nullable()();

  /// 触发轮次（用于更新频率限制查询）
  IntColumn get turnNumber => integer()();

  /// 时间戳
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
}
