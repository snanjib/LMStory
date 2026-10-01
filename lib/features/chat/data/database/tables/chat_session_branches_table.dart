import 'package:drift/drift.dart';

/// chat_session_branches 表定义
/// 存储会话分支信息，每个分叉点一条记录
///
/// 采用 ChatBox 快照模型：
/// - chat_messages 表仅存储当前活跃分支的消息
/// - 非活跃分支的消息以 JSON 快照形式存储在 branchSnapshots 列
/// - 切换分支 = 在 DB 与快照之间交换消息
class ChatSessionBranchesTable extends Table {
  @override
  String get tableName => 'chat_session_branches';

  @override
  List<Set<Column>> get uniqueKeys => [
        {sessionId, anchorUserMsgId},
      ];

  IntColumn get id => integer().autoIncrement()();
  TextColumn get sessionId => text()();
  TextColumn get anchorUserMsgId => text()();
  IntColumn get activeBranchIndex => integer().withDefault(const Constant(0))();
  IntColumn get branchCount => integer().withDefault(const Constant(1))();

  /// 非活跃分支的消息快照（JSON 数组）
  /// 结构：[{"index": 0, "messages": [{...}, ...]}, ...]
  /// 仅存储非活跃分支；活跃分支的消息在 chat_messages 表中
  TextColumn get branchSnapshots => text().nullable()();

  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
}
