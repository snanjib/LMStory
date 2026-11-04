import 'package:drift/drift.dart';

/// chat_messages 表定义
/// 存储聊天消息，支持分支（Fork）和压缩摘要
class ChatMessagesTable extends Table {
  @override
  String get tableName => 'chat_messages';

  IntColumn get id => integer().autoIncrement()();
  TextColumn get messageId => text().withLength(min: 1).unique()();
  TextColumn get sessionId => text()();
  TextColumn get role => text()();
  TextColumn get content => text().nullable()();
  TextColumn get toolCalls => text().nullable()();
  TextColumn get toolCallId => text().nullable()();
  TextColumn get thinkingContent => text().nullable()();
  IntColumn get thinkingDuration => integer().nullable()();

  /// DeepSeek V4 原始 reasoning_content 字段（DOC-12 §5.4.2）
  ///
  /// 与 [thinkingContent] 的差异：
  /// - [thinkingContent]：从 `<think>` 标签提取的内容（用于 UI 显示）
  /// - reasoningContent：DeepSeek V4 API 响应的 `reasoning_content` 字段原文
  ///
  /// 用途：tool call 场景下，必须将此字段原样回传给 API，否则 400 错误。
  /// 非 tool call 场景可为 null（不影响兼容性）。
  TextColumn get reasoningContent => text().nullable()();
  TextColumn get parentUserMsgId => text().nullable()();
  IntColumn get branchIndex => integer().withDefault(const Constant(0))();
  BoolColumn get isSummary => boolean().withDefault(const Constant(false))();

  /// 「已中断·续写」标记：该消息被续写合并过（停止后
  /// 「继续生成」的新内容追加了进来，单气泡）。旧库经 repairSchema 补列
  /// （v47 窗口内，纯增量 nullable default false，无数据迁移）。
  BoolColumn get isContinued => boolean().withDefault(const Constant(false))();
  TextColumn get attachments => text().nullable()();
  TextColumn get error => text().nullable()();
  IntColumn get tokensUsed => integer().nullable()();
  IntColumn get firstTokenLatency => integer().nullable()();
  TextColumn get modelName => text().nullable()();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
}
