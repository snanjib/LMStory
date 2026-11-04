import 'package:drift/drift.dart';
import 'package:lmstory/features/memory/data/database/tables/factual_attributes_table.dart'
    show FactualAttributesTable;

/// factual_entities 表定义（DOC-11 §3.1）
///
/// 事实层实体表：每个"东西"（角色/地点/物品/设定/组织/杂项）一条记录。
/// 与 [FactualAttributesTable] 配合实现"实体 + 属性"双表结构，避免扁平
/// key 存储导致的多实例串台问题（如两只狗的 skills 归属混乱）。
///
/// v0.2 事实层中间方案（DOC-11）：在不引入 v0.3 Agent Loop 的前提下，
/// 通过 summarizing 阶段并行调用 extract_facts 工具写入事实数据，
/// 解决长对话后设定漂移问题。
///
/// 写入时机：summarizing 阶段 LLM 产出 CREATE_ENTITY/ADD_ALIAS/ARCHIVE_ENTITY
/// 动作时，由 FactApplier 在 persisting 事务内写入。
/// 读取时机：retrieving 阶段 FactContextBuilder 加载关键实体 + 本轮 keywords
/// 命中实体，注入 reviewing prompt 的【世界设定】区块。
///
/// Schema 依据：DOC-11 §3.1、DOC-02 §6（v22 新增）。
class FactualEntitiesTable extends Table {
  @override
  String get tableName => 'factual_entities';

  /// 自增主键（内部使用，Repository 不暴露，B-4 硬约束）
  IntColumn get id => integer().autoIncrement()();

  /// 业务主键（如 `ent_001`），UUID 或自定义格式
  TextColumn get entityId => text().customConstraint('NOT NULL UNIQUE')();

  /// 所属会话
  TextColumn get sessionId => text()();

  /// 实体类型：`character` / `location` / `item` / `lore` / `organization` / `misc`
  ///
  /// 与 FactAction.createEntity 的 entityType 字段对齐。
  /// 每种类型有预定义的属性 schema 白名单（DOC-11 §7.4.2）。
  /// 旧值 pet/npc/rule 由 FactualEntityType.fromString 自动映射到新类型。
  TextColumn get type => text()();

  /// 主名（用于检索和展示）
  ///
  /// 例：「旺财」「李逍遥」「青云门后山」
  /// 唯一性约束：同一会话内【活跃】实体 primaryName 唯一
  ///（idx_factual_entities_session_name， 起 partial：WHERE is_archived=0，
  /// 归档让名）。用户改名时通过 UPDATE_ATTR 修改此字段（attrKey='name'）。
  TextColumn get primaryName => text()();

  /// 别名 JSON 数组字符串（默认 '[]'）
  ///
  /// 用户换称呼时通过 ADD_ALIAS 动作追加。检索时按 primaryName 或
  /// aliases 匹配（DOC-11 §10.1）。
  /// 例：'["小金毛", "财财"]'
  TextColumn get aliases => text().withDefault(const Constant('[]'))();

  /// 分类标签（可选，如"主角宠物"）
  ///
  /// 用户自定义分类，用于 UI 分组展示。不影响检索逻辑。
  TextColumn get category => text().nullable()();

  /// 重要性 1-5（默认 3）
  ///
  /// 关键实体（>= keyEntityImportanceThreshold，默认 5）在 retrieving
  /// 阶段强制注入 prompt，无需 keywords 命中。
  /// 路人/一次性物品 importance=1，几乎不注入。
  IntColumn get importance => integer().withDefault(const Constant(3))();

  /// 是否归档（角色死亡/物品销毁）
  ///
  /// 归档后不再注入 prompt，但保留记录供历史回顾。
  /// 通过 ARCHIVE_ENTITY 动作触发。
  BoolColumn get isArchived => boolean().withDefault(const Constant(false))();

  /// 来源（DOC-15 §3.1）：`auto` / `worldbook` / `card`，默认 `auto`
  ///
  /// 世界书导入实体为 `worldbook`（完全冻结，不可改/删）；角色卡导入实体为
  /// `card`（基线属性只读、实体本身可演化）；AI 自动提取为 `auto`。
  TextColumn get source => text().withDefault(const Constant('auto'))();

  /// 来源资源引用（DOC-15 §8.3）：指向资源表 `cardId`/`bookId`
  ///
  /// 仅 `worldbook`/`card` 来源实体有值；`auto` 为 null。用于详情展示与导出溯源。
  TextColumn get sourceRef => text().nullable()();

  /// 实体强制注入开关（v0.2.3）：`none` / `world` / `directive`，默认 `none`
  ///
  /// 与 importance 评分解耦的注入偏好，仅检索层消费。
  TextColumn get forceInject => text().withDefault(const Constant('none'))();

  /// 批 J-b：注入停用——词条级临时关闭，不参与任何
  /// 注入（世界设定/常驻指令/known_entities），但保留在记忆库浏览、
  /// 检索与关键词命中中（与 isArchived 的「归档让名+隐藏」语义不同）。
  /// 默认 false；种子投影与 AI 建档天然 false。
  BoolColumn get injectionDisabled =>
      boolean().withDefault(const Constant(false))();

  /// 创建时间
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();

  /// 出现轮次（对应当前对话轮次）
  ///
  /// 用于 UI 展示"第 N 轮登场"，以及更新频率限制（DOC-11 §7.4.5）。
  IntColumn get createdTurn => integer()();

  /// 最后修改时间（nullable：从未修改过的实体为 NULL）
  DateTimeColumn get updatedAt => dateTime().nullable()();

  /// 最后修改轮次（nullable：从未修改过的实体为 NULL）
  IntColumn get updatedTurn => integer().nullable()();
}
