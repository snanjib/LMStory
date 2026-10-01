import 'package:lmstory/core/exceptions/app_exceptions.dart';
import 'package:lmstory/features/chat/domain/entities/chat_message.dart';
import 'package:lmstory/features/chat/domain/entities/chat_mode.dart';
import 'package:lmstory/features/chat/domain/entities/chat_session.dart';
import 'package:lmstory/features/chat/domain/entities/fork_anchor.dart';
import 'package:lmstory/features/chat/domain/entities/search_result.dart';
import 'package:lmstory/features/settings/domain/entities/data_management_models.dart';

/// 聊天数据仓库接口
///
/// 定义会话和消息的数据访问操作。
abstract class ChatRepository {
  // ==================== 会话操作 ====================

  /// 创建新会话
  Future<ChatSession> createSession({
    required String title,
    String mode = ChatMode.chat,
    String? modelId,
    String? presetId,
  });

  /// 获取所有会话列表（按最后活跃时间降序）
  Future<List<ChatSession>> getAllSessions();

  /// 获取单个会话
  Future<ChatSession> getSession(String sessionId);

  /// 更新会话
  Future<ChatSession> updateSession(ChatSession session);

  /// 删除会话（级联删除相关消息和压缩点）
  Future<void> deleteSession(String sessionId);

  /// 删除所有会话（级联删除所有消息、压缩点和分支）
  ///
  /// 仅 DELETE 数据，不 DROP 表。无法修复 v16 新增表（如
  /// intermediate_round_artifacts）在旧数据库升级时缺失的问题。
  /// 修复场景请用 [recreateConversationTables]。
  Future<void> deleteAllSessions();

  /// 重建会话和消息相关的所有表（DROP + CREATE）
  ///
  /// 用于「清除会话和消息」功能：DROP 所有会话/消息/故事模式相关表后
  /// 重新创建，确保表结构同步至最新 schema。保留供应商配置和模板表。
  /// 与 [deleteAllSessions] 不同，本方法可修复表缺失问题。
  Future<void> recreateConversationTables();

  /// 修复数据库表结构（纯增量，不删除数据）
  ///
  /// 用于 dev 阶段 schemaVersion 升级后，旧版调试设备的数据库表结构
  /// 与新 schema 不一致时的增量修复。创建缺失的表 + 补齐缺失的列 +
  /// 重建索引 + 更新 schemaVersion。不修改已有列，不删除任何数据。
  ///
  /// 与 [recreateConversationTables] 的区别：
  /// - recreateConversationTables：DROP + CREATE，**会丢数据**
  /// - repairSchema：ALTER TABLE ADD COLUMN，**不丢数据**
  ///
  /// 返回 [SchemaRepairResult] 包含详细变更信息（新建表、新增列）。
  Future<SchemaRepairResult> repairSchema();

  /// 更新会话最后活跃时间
  Future<void> updateSessionLastActive(String sessionId);

  /// 更新会话消息计数
  Future<void> updateSessionMessageCount(String sessionId, int count);

  /// 复制会话（创建新会话并复制所有消息）
  ///
  /// [copySuffix] 追加到副本标题后的后缀（展示层注入本地化文案；
  /// 默认 '(Copy)' 兼容无上下文调用方与既有测试）。
  Future<ChatSession> copySession(
    String sourceSessionId, {
    String copySuffix = '(Copy)',
  });

  /// 更新会话标题
  Future<void> updateSessionTitle(String sessionId, String title);

  /// 批量更新会话排序顺序
  ///
  /// [sortOrders] 为 sessionId -> sortOrder 的映射。
  Future<void> updateSessionSortOrders(Map<String, double> sortOrders);

  // ==================== 消息操作 ====================

  /// 添加消息
  Future<ChatMessage> addMessage(ChatMessage message);

  /// 获取会话的所有消息（按创建时间升序）
  Future<List<ChatMessage>> getMessages(String sessionId);

  /// 获取会话的消息数量
  Future<int> getMessageCount(String sessionId);

  /// 更新消息内容
  Future<void> updateMessageContent(String messageId, String content);

  /// 续写段并入被续写消息：原子拼接内容并置「已中断·续写」
  /// 标记（is_continued=1）——「继续生成」的新内容追加进原消息，单气泡。
  ///
  /// CH-7：[tokensUsed] 为本轮续写的 usage 总量，非 null 时
  /// 一并写入 tokens_used（重进会话后上下文用量显示不回退）；为 null 时
  /// （如停止的半截续写无 usage）保留旧值。
  Future<void> appendContinuation(
    String messageId,
    String continuation, {
    int? tokensUsed,
  });

  /// 更新消息错误信息（持久化到消息，切换分支时保留）
  ///
  /// 返回受影响行数：前台流式消息完成前从不 INSERT（完成才落库），
  /// 该 UPDATE 可能 0 行命中——调用方（MessageManager）据此走 INSERT
  /// 兜底，否则断流的半截内容与错误痕迹刷新即丢。
  Future<int> updateMessageError(String messageId, String? error);

  /// 更新消息的 tokens 使用量
  ///
  /// 用于压缩摘要消息写入 usage.total_tokens，使 UI 顶部 token 用量
  /// 在压缩完成后立即刷新（无需等下一条助手消息）。
  Future<void> updateMessageTokensUsed(String messageId, int? tokensUsed);

  /// 删除消息
  Future<void> deleteMessage(String messageId);

  /// 删除会话的所有消息
  Future<void> deleteMessages(String sessionId);

  // ==================== 分支操作 ====================
  //
  // 快照模型（对标 ChatBox messageForksHash）：
  // - 锚点 = 触发助手回复的用户消息（parentUserMsgId）
  // - chat_messages 表仅存储当前活跃分支的消息（无需过滤）
  // - 非活跃分支的消息以 JSON 快照存储在 chat_session_branches.branch_snapshots
  // - 切换分支 = 在 DB 与快照之间交换消息
  // - "尾部消息" = 锚点处的助手消息 + 之后所有消息

  /// 获取会话的所有 Fork 锚点信息
  ///
  /// 仅返回 branchCount > 1 的锚点（即存在分支的用户消息）。
  Future<List<ForkAnchor>> getForkAnchors(String sessionId);

  /// 为指定锚点添加新分支（重新生成场景）
  ///
  /// 1. 若锚点不存在，创建锚点（branchCount=1, activeBranchIndex=0）
  /// 2. 将 [tailMessages] 保存为当前活跃分支的快照
  /// 3. 从 chat_messages 表删除 [tailMessages] 对应的消息
  /// 4. branchCount+1，activeBranchIndex 指向新分支
  /// 5. 返回新分支索引（调用方据此生成新助手消息）
  Future<int> addAssistantBranchAndSnapshot({
    required String sessionId,
    required String anchorUserMsgId,
    required List<ChatMessage> tailMessages,
  });

  /// 切换指定锚点的活跃分支
  ///
  /// 1. 将 [currentTailMessages] 保存为当前活跃分支的快照
  /// 2. 从 chat_messages 表删除 [currentTailMessages] 对应的消息
  /// 3. 从快照中加载 [newActiveIndex] 分支的消息，插入 chat_messages 表
  /// 4. 从快照中移除 [newActiveIndex] 分支
  /// 5. 更新 activeBranchIndex = [newActiveIndex]
  /// 6. 返回新分支的消息列表（调用方用于更新 UI 状态）
  Future<List<ChatMessage>> switchForkBranchWithSnapshot({
    required String sessionId,
    required String anchorUserMsgId,
    required int newActiveIndex,
    required List<ChatMessage> currentTailMessages,
  });

  /// 删除指定锚点的一个分支
  ///
  /// [removedBranchIndex] 为要删除的分支索引。
  /// [currentTailMessages] 为当前活跃分支的尾部消息（仅当删除活跃分支时用于从 DB 删除）。
  ///
  /// - 若删除的是活跃分支：从快照中加载另一个分支替换当前消息，返回新分支消息列表
  /// - 若删除的是非活跃分支：仅从快照中移除，返回 null
  /// - branchCount-1；若降为 1，删除锚点记录
  Future<List<ChatMessage>?> removeForkBranchWithSnapshot({
    required String sessionId,
    required String anchorUserMsgId,
    required int removedBranchIndex,
    required List<ChatMessage> currentTailMessages,
  });

  /// 删除锚点的整条分支记录（含全部非活跃分支快照）。
  ///
  /// 删除作为 Fork 锚点的用户消息
  /// （连同其后全部消息）时调用——分支快照行不随消息删除而消失，会
  /// 残留不可达的历史分支内容（隐私残留），此后无任何 UI 途径可达。
  Future<void> deleteForkBranchesByAnchor(
    String sessionId,
    String anchorUserMsgId,
  );

  /// 向非活跃分支的快照追加一条消息
  ///
  /// 后台分支生成（流式中切看其他分支）完成/失败/停止时，产物消息属于
  /// 生成分支，而该分支此刻以快照形式存在——直接 addMessage 会把它写进
  /// 当前查看分支的表尾，被后续切分支/删除误并入当前分支快照（跨分支
  /// 污染）。本方法把消息追加到 [branchIndex] 对应的快照尾部。
  ///
  /// 返回 false 表示无法安全追加（锚点不存在 / 该分支即当前活跃分支 /
  /// 快照缺失——嵌套锚点等边缘形态），调用方应回退 addMessage 保数据。
  Future<bool> appendMessageToBranchSnapshot({
    required String sessionId,
    required String anchorUserMsgId,
    required int branchIndex,
    required ChatMessage message,
  });

  /// 把续写段并入非活跃分支快照中的被续写消息
  ///
  /// 续写在后台分支完成时（流式中切看其他分支），被续写的半截消息随生成
  /// 分支存在快照里（活跃表无此行，普通 [appendContinuation] 的 UPDATE
  /// 会 0 行命中）——本方法在 [branchIndex] 对应快照内按 [messageId]
  /// 定位该消息，原子拼接 [continuation]、置 is_continued 标记并写入
  /// [tokensUsed]（null 时保留旧值）。
  ///
  /// 返回 false 表示无法安全合并（锚点不存在 / 该分支即当前活跃分支 /
  /// 快照缺失 / 目标消息不在该快照中），调用方应回退保数据。
  Future<bool> appendContinuationToBranchSnapshot({
    required String sessionId,
    required String anchorUserMsgId,
    required int branchIndex,
    required String messageId,
    required String continuation,
    int? tokensUsed,
  });

  // ==================== 压缩点操作 ====================

  /// 添加压缩点
  Future<void> addCompactionPoint({
    required String sessionId,
    required String summaryMessageId,
    required String boundaryMessageId,
    required DateTime createdAt,
  });

  /// 获取会话的压缩点列表
  Future<List<Map<String, dynamic>>> getCompactionPoints(String sessionId);

  /// 删除压缩点
  Future<void> deleteCompactionPoint(String sessionId, DateTime createdAt);

  /// 删除指定摘要消息对应的压缩点（对标 ChatBox removeMessage 删除摘要时清理 CompactionPoint）
  ///
  /// 删除摘要消息时调用，同时删除关联的 CompactionPoint，
  /// 使原始消息恢复到上下文中（无 boundary 限制）。
  Future<void> deleteCompactionPointBySummaryId(
    String sessionId,
    String summaryMessageId,
  );

  /// 清理失效压缩点（boundary/summary 已不在消息表中的点）
  ///
  /// 消息级联删除路径此前不清理压缩点——
  /// 删除早于摘要的用户消息会留下孤儿压缩点，filterByCompactionPoint
  /// 失配后静默退回全量上下文，长会话直接超窗 400。幂等，可重复调用。
  Future<void> pruneInvalidCompactionPoints(String sessionId);

  // ==================== 搜索操作 ====================

  /// 跨会话搜索单次返回上限
  static const int globalSearchLimit = 100;

  /// 会话内搜索单次返回上限（同上； 后=DESC 取最近 N 条）
  static const int inSessionSearchLimit = 200;

  /// 跨会话搜索消息
  ///
  /// 返回匹配 [query] 的消息列表，按时间降序排列，
  /// 最多 [globalSearchLimit] 条（最近的优先）。
  Future<List<SearchResult>> searchMessages(String query);

  /// 会话内搜索消息
  ///
  /// 与 [searchMessages] 同口径（LIKE 转义/排除摘要/LIMIT），仅限
  /// [sessionId] 会话；升序返回（会话内导航按阅读方向 旧→新），
  /// 最多 [inSessionSearchLimit] 条（最近的优先）。
  Future<List<SearchResult>> searchMessagesInSession(
    String sessionId,
    String query,
  );

  // ==================== 数据管理操作 ====================

  /// 扫描孤立消息（消息表的 sessionId 在 chat_sessions 表中已不存在）
  ///
  /// 用于数据恢复功能。返回按 sessionId 分组的孤立消息列表，
  /// 每组的消息按时间升序排列。
  Future<List<List<ChatMessage>>> scanOrphanMessages();

  /// 获取所有消息总数（跨会话）
  Future<int> getTotalMessageCount();
}

/// 自动命名专用条件写标题（CAS 语义）。
///
/// 仅当会话当前标题仍属 allowedCurrentTitles（草稿标题集合，含空串）
/// 时才写入新标题，返回是否实际写入——消灭「命名 LLM 在途期间用户手动
/// 重命名被静默覆盖」的竞态（旧实现只在 LLM 调用前检查，TOCTOU 秒级~
/// 分钟级窗口；标题模型三级回落后窗口覆盖全部会话）。
///
/// 以扩展方法承载而非接口成员：不破坏测试侧约 25 个
/// `implements ChatRepository` 假件（fake 增生教训）；读-比-写
/// 之间仅剩毫秒级窗口，远小于原窗口。
extension ChatRepositoryTitleCas on ChatRepository {
  Future<bool> updateSessionTitleIfCurrentTitleIn(
    String sessionId,
    String newTitle,
    Set<String> allowedCurrentTitles,
  ) async {
    try {
      final current = await getSession(sessionId);
      if (!allowedCurrentTitles.contains(current.title)) return false;
      await updateSessionTitle(sessionId, newTitle);
      return true;
    } on ModelNotFoundException {
      // 命名在途期间会话被删除（如用户在另一入口删掉该会话）——
      // 视同 CAS 失败，静默放弃写回。
      return false;
    }
  }
}
