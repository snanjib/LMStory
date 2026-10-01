import 'package:drift/drift.dart';
import 'package:lmstory/features/memory/data/database/tables/factual_entities_table.dart'
    show FactualEntitiesTable;

/// factual_attributes 表定义（DOC-11 §3.2）
///
/// 事实层属性表：实体的各项属性，每个属性一条记录。
/// 与 [FactualEntitiesTable] 配合实现"实体 + 属性"双表结构。
///
/// 设计动机：用 entityId 隔离不同实体的同名属性，杜绝串台。
/// 例：ent_001 (旺财) / skills / '["接飞盘"]' 与 ent_002 (小白) /
/// skills / '[]' 完全独立，更新一方不影响另一方。
///
/// 属性 schema 白名单（DOC-11 §7.4.2）：每种实体类型预定义固定的 attrKey
/// 集合，LLM 只能使用预定义的 attrKey，不能发明新的。描述性属性
/// （personality/description/background）强制 single 类型，只能 update
/// 不能 append，避免"温顺"+"乖巧"近义词堆积。
///
/// 写入时机：summarizing 阶段 LLM 产出 UPDATE_ATTR/APPEND_LIST 动作时，
/// 由 FactApplier 在 persisting 事务内写入。
/// 读取时机：retrieving 阶段 FactContextBuilder 批量加载命中实体的所有属性。
///
/// Schema 依据：DOC-11 §3.2、DOC-02 §6（v22 新增）。
class FactualAttributesTable extends Table {
  @override
  String get tableName => 'factual_attributes';

  /// 自增主键（内部使用，Repository 不暴露，B-4 硬约束）
  IntColumn get id => integer().autoIncrement()();

  /// 业务主键 UUID
  TextColumn get attributeId => text().customConstraint('NOT NULL UNIQUE')();

  /// 指向 FactualEntity.entityId
  TextColumn get entityId => text()();

  /// 所属会话（冗余，加速查询，避免 JOIN）
  TextColumn get sessionId => text()();

  /// 属性名（如 `species` / `age` / `skills` / `personality`）
  ///
  /// 必须在实体类型的属性 schema 白名单内（DOC-11 §7.4.2）。
  /// 不在白名单内的 attrKey 被 FactApplier 拒绝入库。
  TextColumn get attrKey => text()();

  /// 属性值
  ///
  /// 单值属性存字符串（如 "金毛"）。
  /// 列表属性存 JSON 数组字符串（如 '["接飞盘", "握手"]'）。
  /// 字典属性存 JSON 对象字符串（如 '{"朋友": "李逍遥", "敌人": "魔王"}'）。
  ///
  /// 长度上限 500 字（DOC-11 §7.4.6），超出被 FactApplier 拒绝。
  TextColumn get value => text()();

  /// 值类型：`single` / `list` / `dict`（默认 'single'）
  ///
  /// 决定 value 字段的解析方式。single 类型只能 UPDATE_ATTR，
  /// list 类型只能 APPEND_LIST / REMOVE_FROM_LIST。
  TextColumn get valueType => text().withDefault(const Constant('single'))();

  /// 属性重要性 1-5（默认 3）
  ///
  /// 关键属性（>= 4）如角色名、种族等，修改需要高置信度（>= 4）
  /// （DOC-11 §7.2 三重防护）。
  IntColumn get importance => integer().withDefault(const Constant(3))();

  /// 来源（DOC-15 §8.1）：`auto` / `worldbook` / `card`，默认 `auto`
  ///
  /// `source != auto` 即只读基线（世界书实体属性 / 角色卡基线属性），
  /// 不可被 FactApplier 覆盖/删除。角色卡的可演化变化写入独立 `auto` 行。
  TextColumn get source => text().withDefault(const Constant('auto'))();

  /// 创建时间
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();

  /// 最后修改时间（nullable）
  DateTimeColumn get updatedAt => dateTime().nullable()();

  /// 最后修改轮次（nullable）
  IntColumn get updatedTurn => integer().nullable()();

  /// 修改原因（审计用，UPDATE_ATTR 必填）
  ///
  /// 例："用户在第8轮明确改名""剧情中角色死亡"。
  /// 由 LLM 在 FactsDelta.reason 中提供。
  TextColumn get updateReason => text().nullable()();
}
