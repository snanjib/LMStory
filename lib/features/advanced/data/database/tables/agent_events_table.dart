import 'package:drift/drift.dart';

/// agent_events 表定义（v0.3 ，schemaVersion 38）
///
/// Agent 会话事件日志：append-only，唯一真相源（设计报告 §7.3）。
/// 信封对齐 dsh `SessionEvent`：`{seq, type, time, data, surfaceOp,
/// sourceEventSeqs}`。
///
/// - **surface 事件**（带 `surfaceOp`）：`user/message`、`assistant/message`、
///   `tool/result`、`system/core`——投影为模型可见消息（deriveAgentMessages）。
///   `surfaceOp` = `append` 或 `replace`（replace 时用 `replaceStart`/`replaceEnd`
///   指向投影坐标区间，左闭右开）。
/// - **log-only 事件**（`surfaceOp` 为 null）：`turn/begin`、`turn/end`、
///   `step/begin`、`step/end`、`outline/update`、`doom/loop` 等。
///
/// 铁律 "model-visible means logged"：进模型的内容必须能从本表重建。
/// 压缩/裁剪只对 surface 做 replace，本表记录永不改写；
/// 唯一允许的删除是用户显式回滚轮次（随故事数据一起删，见
/// deleteFromSeq）。
class AgentEventsTable extends Table {
  @override
  String get tableName => 'agent_events';

  @override
  List<Set<Column>> get uniqueKeys => [
        {sessionId, seq},
      ];

  IntColumn get id => integer().autoIncrement()();

  /// 所属会话（chat_sessions.sessionId）
  TextColumn get sessionId => text()();

  /// 会话内单调递增序号（事件顺序 = 日志顺序）
  IntColumn get seq => integer()();

  /// 事件类型（`user/message` / `assistant/message` / `tool/result` /
  /// `system/core` / `turn/begin` / `turn/end` / `step/begin` / `step/end` /
  /// `outline/update` / `doom/loop`）
  TextColumn get type => text()();

  DateTimeColumn get time => dateTime()();

  /// 事件负载（JSON 字符串）
  TextColumn get data => text()();

  /// surface 操作：`append` / `replace`；log-only 事件为 null
  TextColumn get surfaceOp => text().nullable()();

  /// replace 时的投影坐标区间起点（左闭）；append 为 null
  IntColumn get replaceStart => integer().nullable()();

  /// replace 时的投影坐标区间终点（右开）；append 为 null
  IntColumn get replaceEnd => integer().nullable()();

  /// 溯源事件 seq 列表（JSON 数组字符串；assistant/message → 构成它的
  /// chunk/step 事件，replace → 被替换的事件）
  TextColumn get sourceEventSeqs => text().nullable()();
}
