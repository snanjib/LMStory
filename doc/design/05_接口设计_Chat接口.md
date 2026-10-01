# LMStory 接口设计（3）：Chat 接口

> **状态：历史接口快照。** 当前 Chat 契约以 Repository 源码为准；备份属于 `BackupRepository`，模式包含 `intermediate`，不得按下文旧提案扩展接口。

| 属性 | 值 |
|------|-----|
| 文档编号 | LMStory-DOC-05-3 |
| 版本 | v1.0 |
| 日期 | 2026-06-30 |
| 状态 | 审定（拆分自 DOC-05 v2.2） |
| 前置文档 | LMStory-DOC-01 ~ 04 |
| 配套文档 | LMStory-DOC-05-1 ~ 05-8（其他子文档） |

---

## 0. 文档定位

本文档是接口设计的第 3 部分，覆盖 §3.1-3.3（ChatRepository 接口定义 + SSE 事件类型 + 使用示例）。

> **拆分说明**：本文档原属 DOC-05 v2.2，因 05 行数严重超限（2841 行 > 500 行限制）拆分为 DOC-05-1 ~ DOC-05-8 共 8 个子文档。本文档保留原节号以保持交叉引用稳定。原 DOC-05 文件替换为索引页（指向各子文档）。

---

## 3. ChatRepository（会话与消息管理）

**所属模块**: Chat
**版本**: v0.1
**职责**: 会话与消息的数据存取（纯数据操作，不含业务编排逻辑）
**接口定义位置**: `features/chat/domain/repositories/chat_repository.dart`

### 3.1 接口定义

> **v0.1 实际实现说明**：以下为 v0.1 实际实现的 ChatRepository 接口，与原始设计存在显著差异。主要差异：
> 1. `mode` 参数类型从 `ChatMode` 枚举改为 `String`（'chat'/'advanced'）
> 2. 会话级设置直接作为 `ChatSession` 的扁平字段，无独立 `ChatSessionSettings` 实体
> 3. 无 `ChatSessionInfo` 轻量视图，`getAllSessions()` 直接返回 `List<ChatSession>`
> 4. 无 `streamChat()` 方法——SSE 流式请求由 Controller 直接通过 HttpClient + SseParser 管理
> 5. 分支操作简化为 `forkFromMessage()` + `getBranchMessages()`，无 `BranchInfo` 实体
> 6. 压缩点操作使用 `Map<String, dynamic>` 而非 `CompactionPoint` 实体
> 7. 新增 `updateMessageContent`、`deleteMessages`、`updateSessionLastActive`、`updateSessionMessageCount`、`getMessageCount` 等方法
> 8. `streamChat`、`duplicateSession`、`exportSession`、`importSession`、`clearMessages` 标记为 v0.2 待实现

```dart
abstract class ChatRepository {
  // ─── 会话操作 ───

  /// 创建新会话
  /// [mode] 会话模式：'chat' / 'advanced'（String，非 ChatMode 枚举）
  /// [title] 会话标题
  /// [modelId] 可选，会话级模型覆盖
  /// [presetId] 可选，会话级预设覆盖
  /// 返回创建后的完整 ChatSession
  /// 异常: QueryException (E301)
  Future<ChatSession> createSession({
    required String title,
    String mode = 'chat',
    String? modelId,
    String? presetId,
  });

  /// 获取所有会话列表（按最后活跃时间降序）
  /// 返回完整 ChatSession 列表（含 lastMessagePreview）
  /// 注：v0.1 不使用 ChatSessionInfo 轻量视图，直接返回 ChatSession
  Future<List<ChatSession>> getAllSessions();

  /// 获取单个会话
  /// 异常: SessionNotFoundException (E001)
  Future<ChatSession> getSession(String sessionId);

  /// 更新会话（整体替换）
  /// [session] 修改后的 ChatSession 对象
  /// 异常: SessionNotFoundException (E001), QueryException (E301)
  Future<ChatSession> updateSession(ChatSession session);

  /// 删除会话（级联删除相关消息和压缩点）
  /// 异常: QueryException (E301)
  Future<void> deleteSession(String sessionId);

  /// 复制会话（创建新会话含相同消息，v0.1 实际实现新增）
  /// [sessionId] 源会话 ID
  /// 返回新创建的 ChatSession
  /// 异常: SessionNotFoundException (E001), QueryException (E301)
  Future<ChatSession> copySession(String sessionId);

  /// 删除所有会话（级联删除所有消息和压缩点，v0.1 实际实现新增）
  /// 仅 DELETE 数据，不 DROP 表。无法修复 v16 新增表缺失问题。
  /// 异常: QueryException (E301)
  Future<void> deleteAllSessions();

  /// 重建会话和消息相关的所有表（DROP + CREATE，v0.2 新增）
  ///
  /// 用于「清除会话和消息」功能：DROP 所有会话/消息/故事模式相关表后
  /// 重新创建，确保表结构同步至最新 schema。同时修复 v15 → v16 升级时
  /// onUpgrade 未创建新表（intermediate_round_artifacts 等）导致的表缺失
  /// 问题。保留 api_presets 和 templates 表。
  /// 异常: QueryException (E301)
  Future<void> recreateConversationTables();

  /// 更新会话排序权重（v0.1 实际实现新增，拖拽排序后调用）
  /// [sortOrders] sessionId → sortOrder 的映射
  /// 异常: QueryException (E301)
  Future<void> updateSessionSortOrders(Map<String, double> sortOrders);

  /// 跨会话搜索消息（v0.1 实际实现新增，全局搜索）
  /// [query] 搜索关键词
  /// 返回匹配的 SearchResult 列表（含会话标题和匹配位置）
  /// 异常: QueryException (E301)
  Future<List<SearchResult>> searchMessages(String query);

  /// 更新会话最后活跃时间
  /// 异常: QueryException (E301)
  Future<void> updateSessionLastActive(String sessionId);

  /// 更新会话消息计数
  /// 异常: QueryException (E301)
  Future<void> updateSessionMessageCount(String sessionId, int count);

  // ─── 消息操作 ───

  /// 添加消息
  /// 返回插入后的 ChatMessage（含回填的 messageId）
  /// 异常: QueryException (E301)
  Future<ChatMessage> addMessage(ChatMessage message);

  /// 获取会话的所有消息（按创建时间升序）
  Future<List<ChatMessage>> getMessages(String sessionId);

  /// 获取会话的消息数量
  Future<int> getMessageCount(String sessionId);

  /// 更新消息内容
  /// [messageId] 消息业务 ID
  /// [content] 新内容
  /// 异常: QueryException (E301)
  Future<void> updateMessageContent(String messageId, String content);

  /// 更新消息错误信息（持久化到消息，切换分支时保留）
  /// [messageId] 消息业务 ID
  /// [error] 错误信息（null 表示清除错误）
  /// 异常: QueryException (E301)
  Future<void> updateMessageError(String messageId, String? error);

  /// 更新消息的 token 用量（持久化到消息，用于上下文用量显示）
  /// [messageId] 消息业务 ID
  /// [tokensUsed] LLM 返回的 usage.total_tokens（null 表示清除）
  /// 用途：流式压缩摘要写入 tokensUsed 后，UI 顶部 token 用量立即刷新，
  /// 无需等下一条助手消息（v0.1 实际实现新增）
  /// 异常: QueryException (E301)
  Future<void> updateMessageTokensUsed(String messageId, int? tokensUsed);

  /// 删除单条消息
  /// 异常: QueryException (E301)
  Future<void> deleteMessage(String messageId);

  /// 删除会话的所有消息
  /// 异常: QueryException (E301)
  Future<void> deleteMessages(String sessionId);

  // ─── 分支操作（快照模型） ───

  /// 获取会话的所有分支锚点
  /// 返回 List<ForkAnchor>，每个锚点对应 chat_session_branches 表一行
  /// 异常: QueryException (E301)
  Future<List<ForkAnchor>> getForkAnchors(String sessionId);

  /// 创建新助手分支并保存当前尾部消息为快照
  /// [anchorUserMsgId] 锚点用户消息 ID
  /// [tailMessages] 锚点之后的所有消息（将被序列化为快照并从 DB 删除）
  /// 返回新分支索引
  /// 异常: QueryException (E301)
  Future<int> addAssistantBranchAndSnapshot({
    required String sessionId,
    required String anchorUserMsgId,
    required List<ChatMessage> tailMessages,
  });

  /// 切换分支（快照交换）
  /// [newActiveIndex] 目标分支索引
  /// [currentTailMessages] 当前尾部消息（将存入当前分支快照）
  /// 返回目标分支的消息列表（已写入 DB）
  /// 异常: QueryException (E301)
  Future<List<ChatMessage>> switchForkBranchWithSnapshot({
    required String sessionId,
    required String anchorUserMsgId,
    required int newActiveIndex,
    required List<ChatMessage> currentTailMessages,
  });

  /// 删除分支（快照模型）
  /// [removedBranchIndex] 要删除的分支索引
  /// [currentTailMessages] 当前尾部消息（仅删除活跃分支时需要）
  /// 返回切换后的消息列表（删除非活跃分支返回 null；删除活跃分支返回恢复的消息列表）
  /// 异常: QueryException (E301)
  Future<List<ChatMessage>?> removeForkBranchWithSnapshot({
    required String sessionId,
    required String anchorUserMsgId,
    required int removedBranchIndex,
    required List<ChatMessage> currentTailMessages,
  });

  // ─── 压缩点操作 ───

  /// 添加压缩点
  /// 注：v0.1 使用 Map<String, dynamic> 而非 CompactionPoint 实体
  /// 异常: QueryException (E301)
  Future<void> addCompactionPoint({
    required String sessionId,
    required String summaryMessageId,
    required String boundaryMessageId,
    required DateTime createdAt,
  });

  /// 获取会话的压缩点列表
  /// 返回 List<Map<String, dynamic>>（含 summaryMessageId、boundaryMessageId、createdAt）
  Future<List<Map<String, dynamic>>> getCompactionPoints(String sessionId);

  /// 删除压缩点
  /// [createdAt] 压缩点创建时间（作为标识）
  Future<void> deleteCompactionPoint(String sessionId, DateTime createdAt);

  /// 删除指定摘要消息对应的压缩点（对标 ChatBox removeMessage 删除摘要时清理 CompactionPoint）
  ///
  /// 删除摘要消息时调用，同时删除关联的 CompactionPoint，
  /// 使原始消息恢复到上下文中（无 boundary 限制）。
  Future<void> deleteCompactionPointBySummaryId(
    String sessionId,
    String summaryMessageId,
  );

  // ─── 数据管理操作 ───

  /// 扫描孤立消息（消息表的 sessionId 在 chat_sessions 表中已不存在）
  ///
  /// 用于数据恢复功能。返回按 sessionId 分组的孤立消息列表，
  /// 每组的消息按时间升序排列。
  Future<List<List<ChatMessage>>> scanOrphanMessages();

  /// 获取所有消息总数（跨会话）
  Future<int> getTotalMessageCount();

  // ─── v0.2 待实现 ───

  // /// 发起流式聊天请求（v0.2 待实现）
  // /// v0.1 中 SSE 流式请求由 Controller 直接管理（HttpClient + SseParser）
  // Stream<SseEvent> streamChat({
  //   required List<ChatMessage> messages,
  //   required ChatSessionSettings settings,
  // });

  // /// 导出会话为 JSON（v0.2 待实现）
  // Future<String> exportSession(String sessionId);

  // /// 从 JSON 导入会话（v0.2 待实现）
  // Future<ChatSession> importSession(String jsonStr);

  // /// 清空会话消息（v0.2 待实现）
  // /// v0.1 使用 deleteMessages(sessionId) 替代
  // Future<void> clearMessages(String sessionId);
}
```

> **v0.1 实际实现 vs 原始设计差异汇总**：
>
> | 原始设计方法 | v0.1 实际实现 | 说明 |
> |------------|-------------|------|
> | `createSession({ChatMode mode, String? title})` | `createSession({String title, String mode, String? modelId, String? presetId})` | mode 改为 String；新增 modelId/presetId 参数 |
> | `getSessionInfoList({ChatMode? mode})` | `getAllSessions()` | 返回完整 ChatSession，无轻量视图 |
> | `updateSession(id, updater)` | `updateSession(session)` | 改为整体替换，无 updater 回调 |
> | `insertMessage(sessionId, msg, {previousMessageId})` | `addMessage(msg)` | 简化参数，消息自带 sessionId |
> | `insertMessages(sessionId, messages)` | — | v0.1 未实现批量插入 |
> | `updateMessage(sessionId, id, updater)` | `updateMessageContent(messageId, content)` | 简化为仅更新内容 |
> | `deleteMessage(sessionId, messageId)` | `deleteMessage(messageId)` | 移除 sessionId 参数 |
> | `getMessages(sessionId, {branchIndex})` | `getMessages(sessionId)` | 移除 branchIndex 参数 |
> | `streamChat(...)` | — | v0.1 由 Controller 直接管理 SSE |
> | `createForkBranch(...)` | `forkFromMessage(messageId)` | 简化 |
> | `switchActiveBranch(...)` | — | v0.1 由 Controller 层 ForkAnchor 管理 |
> | `deleteActiveBranch(...)` | — | v0.1 由 Controller 层 ForkAnchor 管理 |
> | `expandBranch(...)` | — | v0.1 未实现 |
> | `getBranchInfoList(...)` | `getBranchMessages(sessionId, branchIndex)` | 简化 |
> | `getCompactionPoints(sessionId)` → `List<CompactionPoint>` | → `List<Map<String, dynamic>>` | 返回类型简化 |
> | `createCompactionPoint(sessionId, cp)` | `addCompactionPoint({...})` | 参数展开 |
> | `deleteCompactionPoint(sessionId, summaryMessageId)` | `deleteCompactionPoint(sessionId, createdAt)` | 改用 createdAt 标识 |
> | `updateSessionSettings(...)` | — | v0.1 设置为 ChatSession 扁平字段，通过 updateSession 更新 |
> | `getSessionSettings(...)` | — | v0.1 无独立设置实体 |
> | — | `updateSessionLastActive(sessionId)` | v0.1 新增 |
> | — | `updateSessionMessageCount(sessionId, count)` | v0.1 新增 |
> | — | `getMessageCount(sessionId)` | v0.1 新增 |
> | — | `deleteMessages(sessionId)` | v0.1 新增（删除会话所有消息） |
> | — | `copySession(sessionId)` | v0.1 实际实现新增（会话复制） |
> | — | `deleteAllSessions()` | v0.1 实际实现新增（清空所有数据，仅 DELETE） |
> | — | `recreateConversationTables()` | v0.2 新增（DROP + CREATE 重建表，修复 v16 表缺失） |
> | — | `updateSessionSortOrders(sortOrders)` | v0.1 实际实现新增（会话拖拽排序） |
> | — | `searchMessages(query)` | v0.1 实际实现新增（全局搜索） |
> | `duplicateSession(...)` | `copySession(sessionId)` | v0.1 实际实现新增 |
> | `exportSession(...)` | — | v0.2 待实现 |
> | `importSession(...)` | — | v0.2 待实现 |
> | `clearMessages(...)` | `deleteMessages(sessionId)` | v0.1 使用不同方法名 |
> | — | `scanOrphanMessages()` | v0.1 实际实现新增（Phase 数据管理扩展：孤立消息扫描） |
> | — | `getTotalMessageCount()` | v0.1 实际实现新增（Phase 数据管理扩展：存储统计） |
>
> **v1.2 变更说明（原始设计）**：`compactContext`、`needsCompaction`、`buildSimpleContext` 从 ChatRepository 移至 Chat 内部组件（CompactionDetector、CompactionExecutor、ContextBuilder），因为它们包含业务逻辑（LLM 调用、阈值判断、上下文截断），不属于纯数据存取。ChatRepository 新增 `createCompactionPoint` 纯数据方法供 CompactionExecutor 调用。

### 3.2 SSE 事件类型

```dart
/// SSE 解析器输出的事件类型
sealed class SseEvent {
  const SseEvent();
}

/// 文本增量
class TextDeltaEvent extends SseEvent {
  final String delta;
  const TextDeltaEvent(this.delta);
}

/// 思考/推理内容增量（DeepSeek-R1 的 reasoning_content）
class ThinkingDeltaEvent extends SseEvent {
  final String content;
  const ThinkingDeltaEvent(this.content);
}

/// Tool Call 完成
class ToolCallCompleteEvent extends SseEvent {
  final ToolCall toolCall;
  const ToolCallCompleteEvent(this.toolCall);
}

/// 流结束
class StreamEndEvent extends SseEvent {
  final String? finishReason;
  final SseUsage? usage;  // v0.1 后期：从 MessageUsage? 改为 SseUsage?（字段均可空）
  const StreamEndEvent({this.finishReason, this.usage});
}

/// 流错误
class StreamErrorEvent extends SseEvent {
  final AppError error;
  const StreamErrorEvent(this.error);
}
```

### 3.3 使用示例

> **v0.1 实际实现差异**：以下示例为原始设计。v0.1 实际实现中：
> - SSE 流由 Controller 直接通过 `HttpClient.streamPost()` + `SseParser.parse()` 管理，不通过 `ChatRepository.streamChat()`
> - 设置解析由 `ConfigurationResolver.resolveSettings()` 完成（v0.1.1 重构后从 `ChatModeController._resolveSettings()` 抽离为独立服务类）
> - 消息实体为 `ChatMessage`（role 为 String），非 `Message`（role 为 MessageRole 枚举）

```dart
// 发送消息（原始设计示例）
final settings = await settingsResolver.resolve(sessionId);
final context = await contextBuilder.buildSimpleContext(sessionId);
final userMsg = Message(role: MessageRole.user, content: userInput, ...);
await chatRepo.insertMessage(sessionId, userMsg);
final messages = [...context, userMsg];

final stream = chatRepo.streamChat(messages: messages, settings: settings);
await for (final event in stream) {
  switch (event) {
    case TextDeltaEvent(:final delta):
      state = state.copyWith(streamingContent: state.streamingContent + delta);
    case ToolCallCompleteEvent(:final toolCall):
      // v0.2: 交给 UpdateWorldUseCase
      break;
    case StreamEndEvent():
      await _persistAssistantMessage();
    case StreamErrorEvent(:final error):
      state = state.copyWith(error: error);
  }
}
```

```dart
// 发送消息（v0.1 实际实现示例）
final settings = await _resolveSettings();  // Controller 内联方法
final requestBody = json.encode({
  'model': settings.modelId,
  'messages': _buildMessagesForApi(settings.systemPrompt),
  'temperature': settings.temperature,
  'top_p': settings.topP,
  'max_tokens': settings.maxTokens,
  'stream': settings.streamEnabled,
});
final preset = await _presetRepository.getPreset(settings.presetId);
final stream = _httpClient.streamPost(
  ApiUrlResolver.resolve(preset.baseUrl, '/v1/chat/completions'),
  {'Authorization': 'Bearer $_cachedApiKey'},
  body: requestBody,
  cancelToken: _currentCancelToken,
);
_currentSubscription = _sseParser.parse(stream).listen((event) {
  _handleSseEvent(event, userMessage);
});
```



---

## 变更记录

| 版本 | 日期 | 变更 |
|------|------|------|
| v1.0 | 2026-06-30 | 从原 DOC-05 v2.2 拆分（05 因 2841 行严重超限拆为 05-1 ~ 05-8），本文档包含原 §3.1-3.3。原节号保持不变 |
