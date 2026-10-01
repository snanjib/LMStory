# LMStory 接口设计（7）：UseCase 接口

> **状态：历史/废弃提案集合。** `UpdateWorldUseCase`、`StatePatchParser`、旧 `PromptAssembler`、HUD 与旧 Consolidation 方案不是当前实现。现行能力以 LLM、记忆、持久化和故事阶段 Service 源码为准。

| 属性 | 值 |
|------|-----|
| 文档编号 | LMStory-DOC-05-7 |
| 版本 | v1.5 |
| 日期 | 2026-08-04 |
| 状态 | 审定（拆分自 DOC-05 v2.2） |
| 前置文档 | LMStory-DOC-01 ~ 04 |
| 配套文档 | LMStory-DOC-05-1 ~ 05-8（其他子文档） |

---

## 0. 文档定位

本文档是接口设计的第 7 部分，覆盖 §8（UseCase/Service 接口：DataManagementService/UpdateWorldUseCase/PromptAssembler/EmbeddingService/LlmService 等）。

> **拆分说明**：本文档原属 DOC-05 v2.2，因 05 行数严重超限（2841 行 > 500 行限制）拆分为 DOC-05-1 ~ DOC-05-8 共 8 个子文档。本文档保留原节号以保持交叉引用稳定。原 DOC-05 文件替换为索引页（指向各子文档）。

---

## 8. UseCase / Service 接口（Domain 层业务编排）

### 8.1 DataManagementService（v0.1）

**所属模块**: Settings（Domain 层服务）
**版本**: v0.1
**职责**: 统一封装数据导入/导出/统计/恢复的业务逻辑。文件 IO（读写文件、系统分享）由调用方（Presentation 层）负责，本服务只负责数据组装、解析、合并、去重等纯业务逻辑。
**接口定义位置**: `features/settings/domain/services/data_management_service.dart`

**设计参考**: ChatBox 的 ImportExportDataSection，但采用语义化分层 JSON 格式（version + exportedAt + 可选 presets/sessions/preferences）而非 ChatBox 的存储 key 平铺结构，便于跨版本兼容。

**依赖**:
- `ChatRepository`（会话与消息读写，v1 导入路径 + 统计 + 孤立消息恢复）
- `ApiPresetRepository`（供应商读写，v1 导入路径 + 统计）
- `SettingsRepository`（API Key 与偏好读写）
- `BackupRepository`（跨全部表的原始行级别批量数据读写，保留原始业务 ID；v2 导入/导出路径专用）

**接口定义**:

```dart
class DataManagementService {
  DataManagementService({
    required this.chatRepository,
    required this.presetRepository,
    required this.settingsRepository,
    required this.backupRepository,
  });

  final ChatRepository chatRepository;
  final ApiPresetRepository presetRepository;
  final SettingsRepository settingsRepository;
  final BackupRepository backupRepository;

  /// 备份格式版本（v2：全量数据，含故事模式表）
  static const int backupVersion = 2;

  // ─── 导出 ───

  /// 全量导出为 JSON 字符串
  ///
  /// 根据 [options] 决定导出哪些数据类型。返回的 JSON 符合 LMStory 备份格式
  /// （version + exportedAt + 可选的 presets/sessions/preferences）。
  Future<String> exportFullBackup(DataExportOptions options);

  /// 导出单个会话为 JSON 字符串
  ///
  /// 返回 LMStory 备份格式的子集（version + 单个 session），可再导入。
  Future<String> exportSessionAsJson(String sessionId);

  /// 导出单个会话为 Markdown
  Future<String> exportSessionAsMarkdown(String sessionId);

  /// 导出单个会话为纯文本
  Future<String> exportSessionAsText(String sessionId);

  // ─── 导入 ───

  /// 从 JSON 字符串导入数据
  ///
  /// 自动识别完整备份格式和旧版仅会话格式。
  /// 根据 [mode] 决定追加或覆盖策略：
  /// - [ImportMode.append]：按业务 ID 去重，已存在的跳过，只导入新的
  /// - [ImportMode.overwrite]：清空备份包含的数据类型，再用备份重建
  Future<ImportResult> importBackup(String jsonContent, ImportMode mode);

  // ─── 统计 ───

  /// 获取存储统计信息
  ///
  /// [dbSizeBytes] 由调用方通过文件系统 API 获取数据库文件大小后传入。
  /// [templateCount] 由调用方通过 TemplateRepository 获取后传入。
  Future<StorageStats> getStorageStats({
    required int dbSizeBytes,
    int templateCount = 0,
  });

  // ─── 数据恢复 ───

  /// 扫描孤立消息
  ///
  /// 返回按 sessionId 分组的孤立消息列表（每组按时间升序）。
  Future<List<OrphanMessageGroup>> scanOrphanMessages();

  /// 将孤立消息组恢复为新会话
  ///
  /// 每组创建一个新会话，迁移所有消息（重新生成 messageId，保留原内容和时间戳），
  /// 然后删除孤立消息。会话名根据消息最早时间生成。
  Future<List<ChatSession>> recoverOrphanMessages(List<OrphanMessageGroup> groups);

  // ─── 清空 ───

  /// 清空所有会话和消息（保留 API 供应商和偏好）
  Future<void> clearAllConversations();

  // ─── 表结构修复 ───

  /// 修复数据库表结构
  ///
  /// 委托 `ChatRepository.repairSchema()`，检查并修复缺失的表/列/索引。
  /// 返回 [SchemaRepairResult]，包含修复前后的差异信息。
  Future<SchemaRepairResult> repairDatabaseSchema();
}
```

**备份格式（v2）**:

v2 格式使用原始数据库行（snake_case 列名），而非 v1 的语义化字段（camelCase）。presets 为 `api_presets` 表原始行 + `api_key` 字段；sessions 中每个元素是一个 Map，包含全部关联表的原始行。

```json
{
  "version": 2,
  "exportedAt": "2026-07-28T10:00:00.000Z",
  "presets": [
    {
      "preset_id": "uuid",
      "name": "供应商名",
      "base_url": "https://...",
      "is_builtin": 0,
      "protocol": "openaiCompatible",
      "template_id": null,
      "provider_options": null,
      "cached_models": "[]",
      "created_at": "ISO-8601",
      "updated_at": "ISO-8601",
      "api_key": "明文key或不存在"
    }
  ],
  "sessions": [
    {
      "session": { "session_id": "...", "title": "...", "mode": "...", "...": "chat_sessions 全部列" },
      "messages": [ { "message_id": "...", "session_id": "...", "...": "chat_messages 全部列" } ],
      "compactionPoints": [ "...compaction_points 全部列..." ],
      "forkBranches": [ "...chat_session_branches 全部列..." ],
      "experientialMemories": [ { "memory_id": "...", "embedding": "base64...", "...": "experiential_memories 全部列" } ],
      "factualEntities": [ "...factual_entities 全部列..." ],
      "factualAttributes": [ "...factual_attributes 全部列..." ],
      "factualHistory": [ "...factual_memory_history 全部列..." ],
      "intermediateArtifacts": [ "...intermediate_round_artifacts 全部列..." ],
      "failureLogs": [ "...failure_logs 全部列..." ],
      "memoriesFts": [ "...memories_fts 全部列..." ]
    }
  ],
  "preferences": { }
}
```

> **备份格式说明**：
> - `presets[].api_key` 仅当 `includeApiKeys=true` 时存在
> - `sessions[]` 中每个 Map 的 key 固定为上述 11 个（session / messages / compactionPoints / forkBranches / experientialMemories / factualEntities / factualAttributes / factualHistory / intermediateArtifacts / failureLogs / memoriesFts），value 为对应表的原始行列表
> - 原始行中 DateTime 为 ISO-8601 字符串，Boolean 为 0/1 整数，BLOB（embedding）为 base64 字符串
> - `preferences` 为用户覆盖配置的 `Map<String, dynamic>`

**导入策略**:

导入时自动识别三条路径：

| 路径 | 识别条件 | 处理方式 |
|------|---------|---------|
| **v2** | `version == 2` | 使用 `BackupRepository` 全量导入，保留原始 ID，含故事模式全部数据表 |
| **v1** | 有 `version` 字段但值非 2 | 旧逻辑，仅会话+消息+供应商+偏好。v1 导入已修复 messageId 保留问题（保留原始 messageId，不再生成新 UUID） |
| **legacy** | 无 `version` 字段 | 仅会话列表格式，生成新 ID |

- **追加模式（append）**:
  - v2：预设按 `preset_id` 去重（已存在则跳过），会话按 `session_id` 去重，偏好按 `key` 跳过
  - v1：预设按 `name` 去重（同名跳过），会话按 `sessionId` 去重
- **覆盖模式（overwrite）**: 按备份包含的数据类型先清空，再用备份重建
  - v2：含 sessions -> `backupRepository.deleteAllSessionData()`（跨全部表含 FTS5 索引）；含 presets -> `backupRepository.deleteAllCustomPresets()`；含 preferences -> `clearAllUserOverrides()`
  - v1：含 sessions -> `chatRepository.deleteAllSessions()`；含 presets -> `presetRepository.deleteAllCustomPresets()`；含 preferences -> `clearAllUserOverrides()`

**数据恢复策略**:
- 扫描 `chat_messages` 表中 `sessionId` 在 `chat_sessions` 表已不存在的"孤立消息"
- 按 `sessionId` 分组，组内按时间升序
- 每组创建新会话（标题按最早消息时间生成，格式"恢复的会话 yyyy-MM-dd HH:mm"）
- 迁移消息：重新生成 `messageId`，保留原 `content` 和 `createdAt`
- 删除原孤立消息

### 8.1.1 BackupRepository（v0.2，Domain 层抽象）

**所属模块**: Settings（Domain 层 Repository）
**版本**: v0.2
**职责**: 数据备份/恢复专用的跨表批量数据访问。提供原始行级别的数据读写能力，保留原始业务 ID，确保导出再导入后数据完全无损（ID 引用关系、分支结构、记忆关联等不变）。与业务 Repository（ChatRepository / ExperienceRepository 等）分离，避免在业务接口中堆积导入/导出专用方法。
**接口定义位置**: `features/settings/domain/repositories/backup_repository.dart`
**实现**: `features/settings/data/repositories/backup_repository_impl.dart`

**设计特点**:
- 使用 drift 的 `customSelect` / `customStatement` 进行原始行级别读写
- 导出时排除自增 `id` 列（让数据库自动生成）
- 导入时使用 `INSERT OR IGNORE` 避免唯一约束冲突
- FTS5 虚拟表不支持 `INSERT OR IGNORE`，导入时先 DELETE 再 INSERT

**数据格式约定**:
- DateTime 字段：ISO-8601 字符串
- Boolean 字段：0/1 整数（SQLite 原生存储格式）
- BLOB 字段（embedding）：base64 编码字符串
- JSON 字符串字段（tags/aliases 等）：保持原始 JSON 字符串

**接口定义**:

```dart
abstract class BackupRepository {
  // ─── 会话数据导出 ───

  /// 导出单个会话的所有关联数据（跨 12 张表）
  ///
  /// 返回的 Map 包含以下 key：
  /// - session / messages / compactionPoints / forkBranches
  /// - experientialMemories / factualEntities / factualAttributes
  /// - factualHistory / intermediateArtifacts / failureLogs / memoriesFts
  Future<Map<String, dynamic>> exportSessionData(String sessionId);

  /// 导出所有会话的所有关联数据
  Future<List<Map<String, dynamic>>> exportAllSessionsData();

  // ─── 会话数据导入 ───

  /// 导入单个会话的备份数据（保留原始 ID）
  ///
  /// 追加模式下 sessionId 已存在则跳过，返回 false。
  Future<bool> importSessionData(
    Map<String, dynamic> data, {
    required ImportMode mode,
  });

  // ─── 会话数据删除 ───

  /// 删除单个会话的所有关联数据（跨全部表，含 FTS5 索引）
  Future<void> deleteSessionData(String sessionId);

  /// 删除所有会话的所有关联数据（跨全部表，含 FTS5 索引）
  ///
  /// 保留 api_presets / templates / user_overrides（非会话级数据）。
  Future<void> deleteAllSessionData();

  // ─── FTS5 索引重建 ───

  /// 重建指定会话的 FTS5 全文检索索引
  Future<void> rebuildFtsIndex(String sessionId);

  /// 重建所有会话的 FTS5 全文检索索引
  Future<void> rebuildAllFtsIndex();

  // ─── 供应商数据 ───

  /// 导出所有供应商（含内置和自定义，原始行数据）
  ///
  /// API Key 不在此处导出（由 DataManagementService 通过 SettingsRepository 处理）。
  Future<List<Map<String, dynamic>>> exportAllPresets();

  /// 导入供应商（保留原始 presetId）
  ///
  /// 内置供应商始终跳过（应用启动时自动创建）。
  Future<bool> importPreset(
    Map<String, dynamic> data, {
    required ImportMode mode,
  });

  /// 删除所有自定义供应商（保留内置）
  Future<void> deleteAllCustomPresets();
}
```

### 8.2 UpdateWorldUseCase（v0.2）

**职责**: 编排 update_world Tool Call 的双写协议
**所属模块**: Memory（双写核心操作对象为 MemoryRepository）
**接口定义位置**: `features/memory/domain/usecases/update_world_usecase.dart`

```dart
class UpdateWorldUseCase {
  final MemoryRepository _memoryRepo;
  final EmbeddingQueue _embeddingQueue;

  /// 执行 update_world 双写
  /// 1. StatePatchParser.parse(input.statePatch) → List<FactualUpdate>
  /// 2. 业务过滤：importance < minImportance 则跳过追加
  /// 3. drift transaction 内:
  ///    a. MemoryRepository.upsertFacts(sessionId, factualUpdates)
  ///    b. MemoryRepository.appendEvent(sessionId, ...)
  /// 4. 事务外异步:
  ///    a. EmbeddingQueue.enqueue(memoryId)
  ///    b. 发出 FactualMemoryChangeEvent（HudController 监听此事件刷新面板）
  /// 异常: ToolCallParseException (E003)
  Future<void> execute({
    required String sessionId,
    required UpdateWorldInput input,
    required int turnNumber,
    required int minImportance,
  });
}
```

> **v1.2 变更说明**：
> - 从 HUD 模块移至 Memory 模块（核心操作对象为 MemoryRepository，避免 HUD→Memory 跨模块依赖）
> - 移除 `HudController.refreshPanel()` 调用（Domain 层不应引用 Presentation 层），改为发出 `FactualMemoryChangeEvent` 领域事件
> - 新增 `minImportance` 参数（业务过滤逻辑从 MemoryRepository.appendEvent 移入）
> - StatePatchParser 随 UpdateWorldUseCase 一起归入 Memory 模块

### 8.3 PromptAssembler（v0.2）

**职责**: Advanced 模式工作上下文组装
**所属模块**: Memory
**接口定义位置**: `features/memory/domain/services/prompt_assembler.dart`

```dart
class PromptAssembler {
  final MemoryRepository _memoryRepo;
  final TemplateRepository _templateRepo;
  final TokenCounter _tokenCounter;

  /// 组装缓存优先上下文
  /// [dialogueHistory] 由调用方（AdvancedChatController）从 ChatRepository 获取并传入
  Future<List<AssembledMessage>> assembleCacheFirst({
    required String sessionId,
    required String userInput,
    required List<Message> dialogueHistory,
    required int contextWindow,
    required int outputReserve,
  });

  /// 组装语义优先上下文
  /// [dialogueHistory] 由调用方（AdvancedChatController）从 ChatRepository 获取并传入
  Future<List<AssembledMessage>> assembleSemanticFirst({
    required String sessionId,
    required String userInput,
    required List<Message> dialogueHistory,
    required int contextWindow,
    required int outputReserve,
  });

  /// 生成记忆摘要（语义优先模式专用，零 API 成本）
  /// 从经历类记忆中按 turn_number 范围提取，按 narrative_period 分组
  /// 格式化为结构化文本替代被截断的对话原文
  Future<String> generateMemorySummary({
    required String sessionId,
    required int startTurn,
    required int endTurn,
  });
}
```

> **v1.2 变更说明**：移除对 `ChatRepository` 的直接依赖（避免 Memory→Chat 跨模块依赖），改为由调用方传入 `dialogueHistory` 参数。

### 8.4 EmbeddingQueue（v0.2）

**职责**: 异步 Embedding 生成队列
**所属模块**: Memory
**接口定义位置**: `features/memory/domain/services/embedding_queue.dart`

```dart
class EmbeddingQueue {
  final EmbeddingService _embeddingService;
  final MemoryRepository _memoryRepo;

  /// 入队（异步，不阻塞调用方）
  void enqueue(String memoryId);

  /// 启动消费循环
  void start();

  /// 停止消费循环
  void stop();

  /// 当前队列长度
  int get pendingCount;
}
```

> **v1.2 变更说明**：
> - 依赖 `EmbeddingService`（Domain 层抽象接口）而非 `EmbeddingRemoteDS`（Data 层），遵循依赖倒置原则
> - 依赖 `MemoryRepository` 用于更新 embedding 向量和查询记忆
> - `enqueue` 参数从 `int memoryId` 改为 `String memoryId`（与 MemoryRepository 统一）

### 8.5 EmbeddingService（v0.2，Domain 层抽象）

**职责**: Embedding 向量生成的 Domain 层抽象接口
**所属模块**: Memory
**接口定义位置**: `features/memory/domain/services/embedding_service.dart`

```dart
/// Domain 层抽象接口，由 Data 层 EmbeddingRemoteDS 实现
abstract class EmbeddingService {
  /// 生成文本的 Embedding 向量
  /// 异常: EmbeddingRateLimitedException (E104), ApiException (E103)
  Future<Float32List> embed({
    required String text,
    required String model,
    required String baseUrl,
    required String? apiKey,
  });
}
```

> **v1.2 新增**：解决 EmbeddingQueue（Domain）直接依赖 EmbeddingRemoteDS（Data）的分层违规问题。
>
> **实现说明**：`ApiException (E103)` 在 v0.2 实现中由 `AppHttpException` 承担（不新建 `ApiException` 类）。调用方 catch 时用 `AppHttpException` 替代文档中的 `ApiException`。

### 8.6 LlmService（v0.2，Domain 层共享抽象）

**职责**: LLM 调用的 Domain 层抽象接口（流式 + 非流式 + 工具调用）
**所属模块**: Chat（Domain 层，被 Chat 和 Memory 模块共同依赖）
**接口定义位置**: `features/chat/domain/services/llm_service.dart`

> **V2 四步重构演进**（2026-07-10）：LlmService 从 v0.2 初期的单一 `generate` 方法演进为 `streamChat` + `chat` 双方法架构，新增 `LlmRequest`/`LlmResponse`/`LlmStreamEvent` 值对象体系。V2 四步重构中 extracting/summarizing 步骤通过 `tools` + `toolChoice` 参数发起工具调用请求（降级链详见 DOC-09A-2 §6.9.0）。

```dart
/// Domain 层抽象接口，由 Data 层实现（基于 Dio HTTP + SSE 解析）
/// 被 Chat 子系统（Simple/Intermediate Controller、SessionTitleGenerator）和
/// Memory 子系统（ConsolidationUseCase）共同依赖
abstract class LlmService {
  /// 流式对话：返回 [LlmStreamEvent] 流
  ///
  /// 调用方监听本流接收增量（文本/思考/工具调用），cancel subscription 即可取消请求。
  /// 流异常时发出 [LlmStreamError] 而非直接抛错，调用方自行处理。
  Stream<LlmStreamEvent> streamChat(LlmRequest request);

  /// 非流式对话：返回完整响应
  ///
  /// HTTP 错误（非 200）抛 `AppHttpException`（由调用方失败分类器处理）。
  Future<LlmResponse> chat(LlmRequest request);
}
```

**LlmRequest 值对象**（收口 OpenAI 兼容 `/v1/chat/completions` 请求参数）：

```dart
class LlmRequest {
  const LlmRequest({
    required this.baseUrl,
    required this.modelId,
    required this.messages,
    this.apiKey,
    this.temperature,
    this.topP,
    this.maxTokens,
    this.stream = true,
    this.includeUsage = false,
    this.responseFormat,   // LlmResponseFormat?（JsonObject / JsonSchema / null）
    this.tools,            // List<ToolDefinition>?（V2 工具调用）
    this.toolChoice,       // ToolChoice?（auto/required/none/指定工具）
    this.connectTimeout,
    this.readTimeout,
    this.cancelToken,
  });
  // ... 字段略，详见代码
}
```

**LlmStreamEvent 体系**（sealed class，流式事件）：

| 事件类 | 说明 | V2 用途 |
|--------|------|---------|
| `LlmTextDelta` | 文本增量（`delta.content`） | drafting/revising 纯文本流式 |
| `LlmThinkingDelta` | 思考内容增量（`delta.reasoning_content`） | DeepSeek-R1 等推理模型 |
| `LlmStreamDone` | 流正常结束（`[DONE]`/`finish_reason=stop`） | 所有步骤结束 |
| `LlmStreamError` | 流内错误 | 所有步骤错误 |
| `LlmToolCallStart` | 工具调用开始（含 id + name） | **V2 新增**：extracting/summarizing 工具调用 |
| `LlmToolCallArgs` | 工具调用参数增量（分片） | **V2 新增**：参数累积 |
| `LlmToolCallComplete` | 工具调用完成（arguments 已解析） | **V2 新增**：提取结构化结果 |

**LlmResponse 值对象**（非流式响应）：

```dart
class LlmResponse {
  final String content;
  final LlmUsage? usage;
  final List<ToolCall>? toolCalls;  // 非流式请求携带 tools 时返回
  final String? reasoningContent;   // LLM 思考/推理内容（DeepSeek V4 thinking 模式）
}
```

> **v1.4 变更说明**（2026-07-24）：`LlmResponse` 新增 `reasoningContent` 字段，承载非流式响应中 `message.reasoning_content`（DeepSeek V4 thinking 模式思维链）。多轮工具调用场景下，调用方需将此字段回传给 API（注入到 assistant 消息的 `reasoning_content` 字段），否则 DeepSeek 会返回 400 错误。仅当模型支持 reasoning 时有值，其他模型为 null（不影响兼容性）。同步配套：`LlmRemoteDataSource.chat` 解析 `message.reasoning_content`；`ToolCallResult` 新增 `reasoningContent` 字段（流式工具调用场景，`StreamRunner.runWithToolCall` 累积 `LlmThinkingDelta`）；`ChatModeController._buildMessagesForApi` 构造带 `tool_calls` 的 assistant 消息时注入 `reasoning_content`（仅当 `thinkingContent` 非空）。详见 DOC-09A-2 §6.9.0。

**LlmResponseFormat 体系**（sealed class，响应格式约束）：
- `LlmResponseFormatJsonObject`：`{type: 'json_object'}`，仅保证合法 JSON
- `LlmResponseFormatJsonSchema`：`{type: 'json_schema', strict: true}`，100% schema 合规
- null：不注入 response_format，纯提示词约束

**工具调用核心类型**（`core/llm/tool_calling/`）：
- `ToolDefinition`：工具定义（name/description/parametersSchema），V2 extracting/summarizing 使用
- `ToolChoice`：工具选择策略（auto/required/none/指定工具名）
- `ToolCall`：工具调用结果（toolCallId/name/arguments）

> **v1.3 变更说明**：LlmService 原放在 `core/domain/services/`，后迁移到 `features/chat/domain/services/llm_service.dart`（属 Chat 子系统 Domain 层），因为其主要消费者是 Chat 子系统。Memory 模块通过依赖注入使用。Core 层的 `core/llm/tool_calling/` 目录存放工具调用相关的纯数据类型（ToolDefinition/ToolChoice/ToolCall），不包含业务逻辑。

### 8.7 StatePatchParser（v0.2）

**职责**: 将 LLM 输出的自由 JSON state_patch 拆解为扁平 key-value 对
**所属模块**: Memory（输出类型 FactualUpdate 直接服务于 MemoryRepository）
**接口定义位置**: `features/memory/domain/services/state_patch_parser.dart`

```dart
class StatePatchParser {
  static const String deletedMarker = '__deleted__';

  /// 将自由 JSON 拆解为扁平 FactualUpdate 列表
  /// - 顶层标量 → 直接映射
  /// - characters 数组 → 按 name 展开为 角色.{name}.{attr}
  /// - 嵌套对象 → 用 . 连接路径
  /// - null 值 → value = "__deleted__"
  static List<FactualUpdate> parse(Map<String, dynamic> patch);
}
```

> **v1.2 变更说明**：从 HUD 模块移至 Memory 模块（输出类型 FactualUpdate 被 MemoryRepository.upsertFacts 消费，与 HUD 的 UI 展示无关）。

### 8.8 ConsolidationUseCase（v0.2）

**职责**: 编排记忆折叠流程（涉及 LLM 调用，属于 UseCase 而非 Repository 方法）
**所属模块**: Memory
**接口定义位置**: `features/memory/domain/usecases/consolidation_usecase.dart`

```dart
class ConsolidationUseCase {
  final MemoryRepository _memoryRepo;
  final TemplateRepository _templateRepo;
  final LlmService _llmService;

  /// 执行记忆折叠
  /// 1. 选择候选（importance < keyEventImportance 且 is_archived = false）
  /// 2. 按 narrative_period 分组
  /// 3. 每组 ≥ 3 条时调用 LlmService 生成摘要
  /// 4. LLM 失败则保留不折叠，下次重试
  /// 5. 成功 → 插入摘要事件 + 标记原事件归档
  /// 返回折叠统计结果
  Future<ConsolidationResult> execute({
    required String sessionId,
    required int threshold,
    required int keyEventImportance,
  });
}
```

> **v1.2 变更说明**：
> - 新增 `LlmService` 依赖（解决缺少 LLM 调用能力的问题）
> - 返回类型从 `List<ExperientialMemory>` 改为 `ConsolidationResult`（含折叠统计信息，与 DOC-04 Section 1.6 一致）

### 8.9 IntermediatePersistenceService（v0.2 中级模式，Domain 层抽象）

**所属模块**: Intermediate（Domain 层 Service）
**版本**: v0.2（新增 `persistRegeneratedRound` + `deleteRoundAndDownstream`）
**职责**: 中级模式原子持久化服务，提供三个原子持久化操作，均包在**单一 drift transaction** 内执行，保证原子性（DOC-08 §6.1）。任一步骤失败 → 事务回滚，抛异常（Controller 捕获后置 phase=failed, E018）
**接口定义位置**: `features/intermediate/domain/services/intermediate_persistence_service.dart`
**实现**: `features/intermediate/data/services/intermediate_persistence_service_impl.dart`

> **登记说明**：本接口的 `persistRound` 方法已存在但未及时登记到 DOC-05，后补登记并同步新增的两个 Fork 相关方法。详细时序见 DOC-09C §1。

```dart
abstract interface class IntermediatePersistenceService {
  /// 原子持久化一轮对话（写 user + assistant + 事件摘要）
  ///
  /// 步骤（DOC-09C §1）：
  /// 1. INSERT user message → chat_messages
  /// 2. INSERT assistant message → chat_messages
  /// 3. INSERT event summary → experiential_memories（has_embedding=false 先写）
  /// 4. 若 [embedding] 非空：UPDATE embedding + has_embedding=true
  /// 5. 若 [indexForRetrieval]=true：INSERT FTS5 索引 → memories_fts
  /// 6. UPDATE session（lastActiveAt, messageCount+2）
  /// 7. 若 [artifacts] 非空：INSERT intermediate_round_artifacts
  ///
  /// [embedding] 为 null 表示 embedding 生成降级（has_embedding=false，事务仍提交）。
  /// [artifacts] 为 null 表示无中间产物需持久化（向后兼容旧调用方）。
  /// [indexForRetrieval] 为 false 时跳过 FTS5 索引（importance < threshold
  /// 的低重要性记忆不建索引，仍写入 experiential_memories 供后续批量提炼）。
  /// 返回写入的 [ExperientialMemory]（含 memoryId）。
  Future<ExperientialMemory> persistRound({
    required ChatMessage userMessage,
    required ChatMessage assistantMessage,
    required EventSummary eventSummary,
    required Float32List? embedding,
    required IntermediateRoundArtifacts? artifacts,
    bool indexForRetrieval = true,
  });

  /// 原子持久化重新生成的助手回复（简化 Fork）
  ///
  /// 用于"重新生成"场景：用户消息（user_N）已存在于 chat_messages，
  /// 仅需写入新的助手回复 + 事件摘要。与 [persistRound] 的差异：
  /// 不写 user 消息，session messageCount +1（非 +2）。
  /// [indexForRetrieval] 语义同 [persistRound]。
  /// 详见 DOC-09A-1 §2.4。
  Future<ExperientialMemory> persistRegeneratedRound({
    required ChatMessage assistantMessage,
    required EventSummary eventSummary,
    required Float32List? embedding,
    required IntermediateRoundArtifacts? artifacts,
    bool indexForRetrieval = true,
  });

  /// 原子删除指定轮次及下游所有消息 + 事件摘要（简化 Fork）
  ///
  /// 用于"重新生成/编辑重发/删除整轮"的删除阶段（DOC-09A-1 §2.4-§2.6）：
  /// 1. 删除 turn_number >= [fromTurnNumber] 的经历记忆 + FTS 索引
  ///    （调 ExperienceRepository.deleteExperienceByTurns）
  /// 2. 删除 [messageIdsToDelete] 列表中的所有 chat_messages
  ///    （循环 ChatRepository.deleteMessage，物理 DELETE 无级联）
  /// 3. UPDATE session（lastActiveAt, messageCount = 实际消息数）
  ///
  /// [messageIdsToDelete] 由 Controller 从 state.messages 按索引推导
  /// （chat_messages 无 turn_number 列，无法按 turn 删消息）。
  Future<void> deleteRoundAndDownstream({
    required String sessionId,
    required int fromTurnNumber,
    required List<String> messageIdsToDelete,
  });
}
```

---



---

## 变更记录

| 版本 | 日期 | 变更 |
|------|------|------|
| v1.0 | 2026-06-30 | 从原 DOC-05 v2.2 拆分（05 因 2841 行严重超限拆为 05-1 ~ 05-8），本文档包含原 §8。原节号保持不变 |
| v1.1 | 2026-07-03 | 补登记：新增 §8.9 IntermediatePersistenceService 接口（含 `persistRound`/`persistRegeneratedRound`/`deleteRoundAndDownstream` 三个方法）。其中 `persistRound` 此前已存在但未登记，本次一并补齐；后两个为简化 Fork 新增 |
| v1.2 | 2026-07-08 | 接口同步：§8.9 `persistRound`/`persistRegeneratedRound` 签名新增 `artifacts`（此前已加，本次补登记）+ `indexForRetrieval`（新增，默认 true，false 时跳过 FTS5 索引）参数；步骤说明同步更新（步骤 5 条件化 + 步骤 7 artifacts） |
| v1.3 | 2026-07-10 | V2 四步重构：§8.6 LlmService 全面更新——从单一 `generate` 方法演进为 `streamChat` + `chat` 双方法架构，新增 `LlmRequest`/`LlmResponse`/`LlmStreamEvent` 值对象体系；LlmRequest 新增 `tools`/`toolChoice`/`responseFormat` 字段（V2 extracting/summarizing 工具调用降级链）；LlmStreamEvent 新增 `LlmToolCallStart`/`LlmToolCallArgs`/`LlmToolCallComplete` 三个工具调用事件；接口定义位置更正为 `features/chat/domain/services/llm_service.dart`。配合 DOC-09A-2 §6.9.0 降级链、DOC-09B §8.4 结构化输出格式 |
| v1.4 | 2026-07-24 | reasoning_content 回传链路：`LlmResponse` 新增 `reasoningContent` 字段（非流式响应 `message.reasoning_content`，DeepSeek V4 thinking 模式思维链）。多轮工具调用场景下调用方需将此字段回传给 API，否则 DeepSeek 返回 400 错误。仅当模型支持 reasoning 时有值，其他模型为 null（不影响兼容性）。同步头部版本号 v1.0→v1.4（修正前会话 v1.1/v1.2/v1.3 未同步头部）。配合 DOC-09A-2 v2.10 |
| v1.5 | 2026-08-04 | §8.1 DataManagementService 全面更新：`backupVersion` 从 1 升级为 2（全量数据，含故事模式表）；新增 `BackupRepository` 依赖（跨表原始行级别批量读写）；新增 `repairDatabaseSchema()` 方法；备份格式替换为 v2（原始数据库行 snake_case 列名，presets 含 protocol/template_id/provider_options 等全部字段，sessions 含 11 个关联表原始行）；导入策略更新为三条路径（v2/v1/legacy），v2 预设按 `preset_id` 去重、覆盖模式使用 `backupRepository.deleteAllSessionData()`；新增 §8.1.1 BackupRepository 接口定义 |
