# LMStory 接口设计（2）：Domain 实体

> **状态：历史接口快照。** 当前实体已增加 `reasoningContent`、故事阶段覆盖和 Schema 32/33 字段；下文旧字段表不得用于迁移或序列化实现。

| 属性 | 值 |
|------|-----|
| 文档编号 | LMStory-DOC-05-2 |
| 版本 | v1.6 |
| 日期 | 2026-08-01 |
| 状态 | 审定（拆分自 DOC-05 v2.2） |
| 前置文档 | LMStory-DOC-01 ~ 04 |
| 配套文档 | LMStory-DOC-05-1 ~ 05-8（其他子文档） |

---

## 0. 文档定位

本文档是接口设计的第 2 部分，覆盖 §2.3（Domain 实体定义：ChatMessage/ChatSession/ForkAnchor/FactualMemory/ExperientialMemory/IntermediateChatState 等）。

> **拆分说明**：本文档原属 DOC-05 v2.2，因 05 行数严重超限（2841 行 > 500 行限制）拆分为 DOC-05-1 ~ DOC-05-8 共 8 个子文档。本文档保留原节号以保持交叉引用稳定。原 DOC-05 文件替换为索引页（指向各子文档）。

---

### 2.3 Domain 实体定义

> 以下实体定义与 DOC-04 Section 2.1 对齐。DOC-04 中的完整字段说明以本文档为准。
>
> **v0.1 实际实现差异汇总**：
> 1. `ChatSession.mode` 使用 `String`（'chat'/'advanced'）而非 `ChatMode` 枚举
> 2. `ChatSession` 的 9 个会话级设置直接作为扁平可空字段，无独立 `ChatSessionSettings` 实体
> 3. `ChatSession` 新增 `lastMessagePreview` 字段
> 4. `ChatMessage.role` 使用 `String` 而非 `MessageRole` 枚举
> 5. `ChatMessage.toolCalls` 为 `String?`（JSON 字符串），而非 `List<ToolCall>?`
> 6. `ChatMessage` 无 `dbId` 字段
> 7. `ChatSessionSettings`（v0.1 实际实现）为单一已解析类，所有字段非空
> 8. `ForkAnchor` 替代 `BranchInfo`，使用 `siblingIds` + `activeIndex`
> 9. `CompactionPoint` 在 Repository 接口中使用 `Map<String, dynamic>`
> 10. `ChatMessage` 新增 `attachments` 字段（`List<MessageAttachment>?`），支持图片/文件附件

```dart
/// 消息（v0.1 实际实现）
class ChatMessage {
  final String messageId;       // TEXT PK，UUID
  final String sessionId;       // 所属会话
  final String role;            // 'system'/'user'/'assistant'/'tool'（String，非 MessageRole 枚举）
  final String? content;        // 消息内容（tool 角色消息的 content 可为 null）
  final String? toolCalls;      // ToolCall JSON 数组字符串（v0.1 为 String?，非 List<ToolCall>?）
  final String? toolCallId;     // Tool Call 关联 ID（role=tool 时必填）
  final String? thinkingContent; // 思考/推理内容（DeepSeek-R1 <arg_key> 标签、Claude thinking、OpenAI reasoning_content）
  final int? thinkingDuration;  // 思考耗时（秒）
  final String? parentUserMsgId;// 父用户消息 ID（分支锚点）
  final int branchIndex;        // 分支索引
  final bool isSummary;         // 是否为压缩摘要消息
  final List<MessageAttachment>? attachments; // 附件列表（图片/文件）
  final String? error;          // 错误信息（API 调用失败时持久化到消息中，切换分支时保留，v0.1 新增）
  final int? tokensUsed;        // Tokens 使用量（usage.total_tokens，仅助手消息，v0.1 新增）
  final int? firstTokenLatency; // 首字延迟（毫秒，从请求发送到首个文本 token，仅助手消息，v0.1 新增）
  final String? modelName;      // 模型名称（生成此消息时使用的模型显示名，仅助手消息，v0.1 新增）
  final DateTime createdAt;
  const ChatMessage({
    required this.messageId,
    required this.sessionId,
    required this.role,
    this.content,
    this.toolCalls,
    this.toolCallId,
    this.thinkingContent,
    this.thinkingDuration,
    this.parentUserMsgId,
    this.branchIndex = 0,
    this.isSummary = false,
    this.attachments,
    this.error,
    this.tokensUsed,
    this.firstTokenLatency,
    this.modelName,
    required this.createdAt,
  });
}

/// 消息附件（v0.1 实际实现）
class MessageAttachment {
  final String type;        // 'image' / 'file'
  final String? name;       // 文件名
  final String? mimeType;   // MIME 类型
  final String? base64Data; // Base64 编码数据（图片必填）
  final String? textContent; // 文本内容（文本文件）
  final int? fileSize;      // 文件大小（字节）

  const MessageAttachment({
    required this.type,
    this.name,
    this.mimeType,
    this.base64Data,
    this.textContent,
    this.fileSize,
  });

  bool get isImage => type == 'image';
  bool get isFile => type == 'file';
}

/// 消息（原始设计 — 已废弃，保留供 v0.2 重构参考）
/// 差异：role 使用 MessageRole 枚举，toolCalls 为 List<ToolCall>?，含 dbId 和 usage 字段
class Message_DEPRECATED {
  final int? dbId;                    // 数据库 ID（v0.1 实际实现中不存在）
  final String messageId;
  final String sessionId;
  final MessageRole role;             // 枚举（v0.1 实际使用 String）
  final String? content;
  final List<ToolCall>? toolCalls;    // 结构化列表（v0.1 实际使用 JSON String?）
  final String? toolCallId;
  final String? parentUserMsgId;
  final int branchIndex;
  final bool isSummary;
  final DateTime createdAt;
  final MessageUsage? usage;          // v0.1 实际未实现
}

/// 会话（v0.1 实际实现）
class ChatSession {
  final String sessionId;       // TEXT PK，UUID
  final String mode;            // 'chat'/'intermediate'/'advanced'（String，非 ChatMode 枚举；v0.2 新增 intermediate）
  final String title;
  final DateTime createdAt;
  final DateTime lastActiveAt;
  final int messageCount;
  // ─── 9 个会话级设置（扁平可空字段，NULL = 使用全局默认） ───
  final String? modelId;
  final String? presetId;
  final String? systemPromptOverride;
  final double? temperature;
  final double? topP;
  final int? maxTokens;
  final bool? autoCompaction;
  final double? compactionThreshold;
  final bool? streamEnabled;
  // ─── 会话级分步骤模型配置（v0.2 schemaVersion 23 新增，2026-07-21 配置架构重构） ───
  final SessionPhaseModels phaseModels;  // 默认 SessionPhaseModels.empty()（8 字段全 null），用于替代已删除的 intermediate.modelId/presetId 中间层；详见 SessionPhaseModels 实体定义
  // ─── 其他 ───
  final String? lastMessagePreview;  // v0.1 新增：最后消息预览（前 50 字符）
  final bool isStarred;              // v0.1 实际实现新增：是否收藏
  final int? maxContextMessages;     // v0.1 实际实现新增：最大上下文消息数（0=不限）
  final double sortOrder;            // v0.1 实际实现新增：排序权重（值越小越靠前）
  final ReasoningEffort? reasoningEffort;  // v0.1 新增：思考预算档位（disabled/low/medium/high，NULL=使用全局默认）
  // ─── 叙事时间（v0.2 叙事时间机制，2026-07-25 新增）───
  final String? currentNarrativeTime;  // 当前叙事时间（绝对故事内时间，如"来公寓第三天"。每轮 summarizing 阶段由 LLM 输出 `EventSummary.narrativeTime` 后由控制器 upsert 写入；持久化到 `chat_sessions.current_narrative_time` 列（schemaVersion=26）。NULL=首轮或 LLM 未输出叙事时间。详见 DOC-08 §5.7、DOC-09A-2 §8.1）
  const ChatSession({
    required this.sessionId,
    required this.mode,
    required this.title,
    required this.createdAt,
    required this.lastActiveAt,
    required this.messageCount,
    this.modelId,
    this.presetId,
    this.systemPromptOverride,
    this.temperature,
    this.topP,
    this.maxTokens,
    this.autoCompaction,
    this.compactionThreshold,
    this.streamEnabled,
    this.phaseModels = SessionPhaseModels.empty,  // 2026-07-21 配置架构重构
    this.lastMessagePreview,
    this.isStarred = false,
    this.maxContextMessages,
    this.sortOrder = 0,
    this.reasoningEffort,
    this.currentNarrativeTime,  // v0.2 叙事时间机制（2026-07-25）
  });
  // copyWith 使用 sentinel 模式区分"未提供"和"显式 null"
}

/// 会话（原始设计 — 已废弃，保留供 v0.2 重构参考）
/// 差异：mode 使用 ChatMode 枚举，设置嵌套为 ChatSessionSettings?，
///       含 compactionPoints 列表，无 lastMessagePreview
class ChatSession_DEPRECATED {
  final String sessionId;
  final ChatMode mode;              // 枚举（v0.1 实际使用 String）
  final String title;
  final ChatSessionSettings? settings;  // 嵌套实体（v0.1 实际为扁平字段）
  final List<CompactionPoint> compactionPoints;  // v0.1 不在 ChatSession 中持有
  final DateTime createdAt;
  final DateTime updatedAt;
}

/// 会话级分步骤模型配置（v0.2 schemaVersion 23 新增，2026-07-21 配置架构重构）
///
/// 允许四步生成流程的每个步骤使用不同的模型/供应商。
/// 持久化：`chat_sessions` 表 8 列（drafting_preset_id / drafting_model_id /
/// extracting_preset_id / extracting_model_id / revising_preset_id /
/// revising_model_id / summarizing_preset_id / summarizing_model_id）。
/// 注：DB 列名保留 drafting_/revising_ 前缀不变（向后兼容），
/// Dart 字段名 v0.2.2 重命名：draftingPresetId→generatingPresetId、
/// revisingPresetId→reviewingPresetId（阶段名重命名：drafting→generating、revising→reviewing）。
///
/// 优先级：会话级 phase > 全局 `intermediate.phase_models.{phase}_preset_id/model_id`
/// （都没配置时返回 null，generating 阶段触发 E010 错误）。
/// 详见 DOC-09C §10.2、DOC-05-4 §3.4.3 ConfigurationResolver。
///
/// | 字段 | 类型 | 说明 |
/// |------|------|------|
/// | generatingPresetId | String? | 生成步骤的供应商 ID（null = 使用全局 phase_models 配置；v0.2.2 重命名：draftingPresetId→generatingPresetId） |
/// | generatingModelId | String? | 生成步骤的模型 ID（null = 使用全局 phase_models 配置；v0.2.2 重命名：draftingModelId→generatingModelId） |
/// | extractingPresetId | String? | 关键词提取步骤的供应商 ID |
/// | extractingModelId | String? | 关键词提取步骤的模型 ID |
/// | reviewingPresetId | String? | 审查步骤的供应商 ID（v0.2.2 重命名：revisingPresetId→reviewingPresetId） |
/// | reviewingModelId | String? | 审查步骤的模型 ID（v0.2.2 重命名：revisingModelId→reviewingModelId） |
/// | summarizingPresetId | String? | 事件摘要步骤的供应商 ID |
/// | summarizingModelId | String? | 事件摘要步骤的模型 ID |
class SessionPhaseModels {
  final String? generatingPresetId;
  final String? generatingModelId;
  final String? extractingPresetId;
  final String? extractingModelId;
  final String? reviewingPresetId;
  final String? reviewingModelId;
  final String? summarizingPresetId;
  final String? summarizingModelId;

  /// 构造函数（8 个可选字段，全 null 等价于 [empty]）
  const SessionPhaseModels({
    this.generatingPresetId,
    this.generatingModelId,
    this.extractingPresetId,
    this.extractingModelId,
    this.reviewingPresetId,
    this.reviewingModelId,
    this.summarizingPresetId,
    this.summarizingModelId,
  });

  /// 全空实例（ChatSession.phaseModels 默认值）
  const SessionPhaseModels.empty() : this();

  /// 按 phase 名称返回对应字段对
  /// phase 取值：'drafting' / 'extracting' / 'revising' / 'summarizing'
  /// （参数 'drafting'/'revising' 为 DB 列名前缀/JSON key，保留不变避免 API 破坏性变更；
  ///  v0.2.2 阶段名重命名：drafting→generating、revising→reviewing，但路由参数保留旧名）
  /// 未知 phase 抛 ArgumentError
  (String? presetId, String? modelId) forPhase(String phase);

  /// 返回新实例，仅更新指定 phase 的字段对（其他 phase 字段不变）
  SessionPhaseModels copyWithPhase(String phase, String? presetId, String? modelId);
}

/// 会话级设置（v0.1 实际实现 — 单一已解析类，所有字段非空）
/// 与原始设计的两步方案（可空 ChatSessionSettings + 非空 ResolvedChatSessionSettings）不同，
/// v0.1 使用单一 ChatSessionSettings 类，resolve 逻辑在 Controller 的 _resolveSettings() 中完成。
/// compactionThreshold 语义为百分比（0.4-0.9，默认 0.6），对标 ChatBox compactionThreshold。
/// reasoningEffort 为思考预算档位（disabled/low/medium/high），对标 ChatBox reasoning effort，
/// null 表示未配置（不发送 reasoning_effort 参数，由模型自行决定）。
///
/// **modelId/presetId 跨模式语义（2026-07-21 配置架构重构）**：
/// - 故事模式语义：modelId/presetId 始终为空串（业务模型由分步骤解析器
///   `ConfigurationResolver.resolveIntermediatePhaseNamingConfig(session, phase)` 负责，
///   配置源为 `ChatSession.phaseModels` 或全局 `intermediate.phase_models`）
/// - Simple 模式语义：modelId/presetId 来自 `broadcastChat` 全局配置或会话级覆盖
class ChatSessionSettings {
  final String modelId;
  final String presetId;
  final String systemPrompt;
  final double temperature;
  final double topP;
  final int maxTokens;
  final bool autoCompaction;
  final double compactionThreshold;  // 百分比（0.4-0.9，默认 0.6），对标 ChatBox
  final bool streamEnabled;
  final ReasoningEffort? reasoningEffort;  // 思考预算档位，null=未配置
  final int? maxContextMessages;  // 最大上下文消息数（0=不限）
  const ChatSessionSettings({
    required this.modelId,
    required this.presetId,
    required this.systemPrompt,
    required this.temperature,
    required this.topP,
    required this.maxTokens,
    required this.autoCompaction,
    required this.compactionThreshold,
    required this.streamEnabled,
    this.reasoningEffort,
    this.maxContextMessages,
  });
}

/// 思考预算档位枚举（对标 ChatBox reasoning effort）
///
/// 统一为 4 档：disabled/low/medium/high。
/// 存储于 chat_sessions.reasoning_effort 列（枚举 name），NULL=使用全局默认。
/// 仅对具备 ModelCapability.reasoning 能力的模型生效。
enum ReasoningEffort {
  disabled,  // 禁用思考
  low,       // 低预算
  medium,    // 中预算
  high;      // 高预算

  static ReasoningEffort? fromString(String? value);
  String toJson();
  bool get isEnabled;  // 非 disabled 即启用
}

/// 会话级设置覆盖（原始设计 — 已废弃，v0.1 实际实现中 9 个可空字段直接在 ChatSession 上）
class ChatSessionSettings_DEPRECATED {
  final String? modelId;
  final String? presetId;
  final String? systemPromptOverride;
  final double? temperature;
  final double? topP;
  final int? maxTokens;
  final bool? autoCompaction;
  final double? compactionThreshold;
  final bool? streamEnabled;
}

/// 已解析的运行时配置（原始设计 — 已废弃，v0.1 实际使用 ChatSessionSettings 单一类）
/// 差异：原始设计含 baseUrl/apiKey 字段，v0.1 实际由 Controller 在运行时从 preset 解析
class ResolvedChatSessionSettings_DEPRECATED {
  final String modelId;
  final String presetId;
  final String baseUrl;          // v0.1 实际不在 settings 中，由 preset 动态获取
  final String? apiKey;          // v0.1 实际不在 settings 中，由 Controller 缓存
  final String systemPrompt;
  final double temperature;
  final double topP;
  final int maxTokens;
  final bool autoCompaction;
  final double compactionThreshold;
  final bool streamEnabled;
}

/// 分支锚点（v0.1 实际实现 — 替代原始设计的 BranchInfo）
/// ForkAnchor 是 chat_session_branches 表的内存视图，由 Repository 层从 DB 加载。
/// 快照模型（v0.1 快照模型重构）：chat_messages 表仅存储当前活跃分支的消息，
/// 非活跃分支的消息以 JSON 快照存储在 chat_session_branches.branch_snapshots。
/// ForkAnchor 仅记录锚点位置和分支计数，不持有消息 ID 列表。
class ForkAnchor {
  final String parentUserMsgId;   // 锚点用户消息 ID
  final int activeIndex;          // 当前激活的分支索引（0-based）
  final int branchCount;          // 分支总数
  int get displayIndex => activeIndex + 1;  // 1-based 显示序号
  bool get hasForks => branchCount > 1;     // 是否存在多个分支
  const ForkAnchor({
    required this.parentUserMsgId,
    required this.activeIndex,
    required this.branchCount,
  });
}

/// 分支信息（原始设计 — 已废弃，v0.1 实际使用 ForkAnchor）
/// 差异：BranchInfo 对应 chat_session_branches 表，ForkAnchor 为纯内存结构
class BranchInfo_DEPRECATED {
  final String sessionId;
  final String anchorUserMsgId;
  final int activeBranchIndex;    // v0.1 实际使用 activeIndex
  final int branchCount;          // v0.1 实际使用 siblingIds.length
  final DateTime createdAt;
}

/// 压缩点（原始设计实体 — v0.1 实际在 Repository 接口中使用 Map<String, dynamic>）
/// CompactionPoint 作为独立实体在 v0.1 代码中不存在，
/// ChatRepository.getCompactionPoints() 返回 List<Map<String, dynamic>>
class CompactionPoint {
  final String sessionId;
  final String summaryMessageId;
  final String boundaryMessageId;
  final DateTime createdAt;
  const CompactionPoint({
    required this.sessionId,
    required this.summaryMessageId,
    required this.boundaryMessageId,
    required this.createdAt,
  });
}

/// 事实类记忆
class FactualMemory {
  final String sessionId;
  final String key;             // 唯一键，如 "世界.当前地点"
  final String value;           // 值
  final String? category;       // 分类，如 "世界"、"角色.张三"
  final DateTime updatedAt;
  const FactualMemory({
    required this.sessionId,
    required this.key,
    required this.value,
    this.category,
    required this.updatedAt,
  });
}

/// 经历类记忆
///
/// **V2.5（5W1E 多字段结构）**：
/// - `summary` 降级为可选（`String?`）：宏摘要（is_summary=true）继续使用 summary，
///   单事件优先使用 5W1E 6 字段
/// - 新增 5W1E 6 字段（when/where/who/what/significance/extra，均 String?），
///   与 `memories_fts` 表 7 内容字段对齐，支持 FTS5 多字段检索
class ExperientialMemory {
  final String memoryId;        // TEXT，UUID（业务 ID，非数据库自增主键）
  final String sessionId;
  final String? summary;         // 事件摘要（V2.5 降级为可选，宏摘要使用）
  final int importance;         // 重要性 1-5
  final List<String> tags;      // 标签列表
  final int turnNumber;         // 对话轮次
  final String? narrativeTime;  // 绝对叙事时间锚点（v0.2 启用，2026-07-25，如"来公寓第三天"；由 summarizing 阶段 LLM 输出）
  final String? narrativePeriod;// 叙事周期（v0.3 启用，中级模式恒 null，如"修炼第三天"）
  // ─── 5W1E（V2.5）───
  final String? when;          // 何时
  final String? where;         // 何地
  final String? who;            // 谁
  final String? what;           // 发生什么
  final String? significance;   // 意义
  final String? extra;          // 额外信息
  final bool isArchived;        // 是否已归档
  final bool isSummary;         // 是否为折叠摘要事件
  final bool hasEmbedding;      // 是否已生成向量
  final DateTime createdAt;
  const ExperientialMemory({
    required this.memoryId,
    required this.sessionId,
    this.summary,
    required this.importance,
    required this.tags,
    required this.turnNumber,
    this.narrativeTime,
    this.narrativePeriod,
    this.when,
    this.where,
    this.who,
    this.what,
    this.significance,
    this.extra,
    this.isArchived = false,
    this.isSummary = false,
    this.hasEmbedding = false,
    required this.createdAt,
  });
}

// ════════════════════════════════════════════════════════════════
// v0.2 中级模式实体（DOC-08 / DOC-09A-1 / DOC-09A-2 / DOC-09B）
// ════════════════════════════════════════════════════════════════

/// 中级模式阶段枚举（v0.2，替代 09B §7.1 的 String phase）
/// 6 个正常状态 + 3 个重试状态，对应状态机（DOC-09A-1 §2）
/// v0.2.2 阶段名重命名：drafting→generating、revising→reviewing
enum IntermediatePhase {
  idle,             // 空闲
  generating,       // 生成中（请求1；v0.2.2 重命名：drafting→generating）
  retrieving,       // 检索中
  reviewing,        // 审查中（请求2；v0.2.2 重命名：revising→reviewing）
  persisting,       // 持久化中
  failed,           // 失败
  generatingRetry,  // 生成重试（v0.2.2 重命名：draftingRetry→generatingRetry）
  retrievingRetry,  // 检索重试
  reviewingRetry,   // 审查重试（v0.2.2 重命名：revisingRetry→reviewingRetry）
}

/// 事件摘要（v0.2 中级模式，LLM 输出结构，DOC-09B §8.1）
/// 从请求2回复中通过 `<<<EVENT_SUMMARY>>>` 分隔标记解析得到。
/// turnNumber 由程序填充（非 LLM 输出），基于会话当前轮次计数。
///
/// **V2.5（5W1E 多字段结构）**：
/// - `summary` 降级为可选（`String?`）：宏摘要继续使用 summary，单事件优先使用 5W1E 6 字段
/// - 新增 5W1E 6 字段（when/where/who/what/significance/extra，均 String?），
///   与 `memories_fts` 表 7 内容字段对齐，支持 FTS5 多字段检索
/// - Controller 从本实体提取 5W1E 字段传入 `appendExperience` / `insertFtsIndex`
///
/// **v0.2 叙事时间机制（2026-07-25 新增）**：
/// - 新增 `narrativeTime` 字段（`String?`）：绝对故事内时间锚点（如"来公寓第三天"）
/// - LLM 在 summarizing 阶段输出，持久化到 `experiential_memories.narrative_time` 列
/// - persist 成功后由控制器 upsert 到 `chat_sessions.current_narrative_time`
/// - 与 5W1E `when` 字段的区别：`when` 是相对时间（如"次日清晨"），`narrativeTime` 是绝对时间锚点
/// - 详见 DOC-08 §5.7、DOC-09A-2 §8.1
class EventSummary {
  final String? summary;         // 事件摘要文本（V2.5 降级为可选，宏摘要使用）
  final int importance;         // 重要性 1-5
  final List<String> tags;      // 标签数组
  final int turnNumber;         // 对话轮次序号（程序填充）
  // ─── 5W1E（V2.5）───
  final String? when;          // 何时（相对时间描述，如"次日清晨"）
  final String? where;         // 何地
  final String? who;            // 谁
  final String? what;           // 发生什么
  final String? significance;   // 意义
  final String? extra;          // 额外信息
  // ─── 叙事时间（v0.2 叙事时间机制，2026-07-25 新增）───
  final String? narrativeTime;  // 绝对叙事时间锚点（如"来公寓第三天"）
  const EventSummary({
    this.summary,
    required this.importance,
    required this.tags,
    required this.turnNumber,
    this.when,
    this.where,
    this.who,
    this.what,
    this.significance,
    this.extra,
    this.narrativeTime,
  });
}

/// 失败上下文（v0.2 中级模式，DOC-09B §7.5）
/// phase = failed 时非 null，用于 FailureBar 显示和重试逻辑判定。
class FailureContext {
  final IntermediatePhase failedPhase;  // 失败的阶段（generating/retrieving/reviewing；v0.2.2 阶段名重命名：drafting→generating、revising→reviewing）
  final String errorMessage;            // 失败原因（用户可读）
  final AppError? error;                // 结构化错误（可选，用于错误码映射）
  const FailureContext({
    required this.failedPhase,
    required this.errorMessage,
    this.error,
  });
}

/// 中级模式 Controller 状态（v0.2，DOC-09B §7.1）
/// 在 ChatModeState 基础上扩展，复用基础字段（session, messages, forkAnchors,
/// isSending, isStreaming, error 等）。phase 使用枚举替代 09B 的 String。
class IntermediateChatState {
  final IntermediatePhase phase;                    // 当前阶段
  final String? streamingGenerated;                 // 请求1生成流式内容（v0.2.2 重命名：streamingDraft→streamingGenerated）
  final List<String>? draftKeywords;                // 请求1输出的检索关键词（字段名保留，artifacts 表 DB 列名 draft_keywords）
  final List<ExperientialMemory>? retrievedMemories;  // 检索到的经历记忆
  final String? streamingReply;                     // 请求2回复流式内容
  final EventSummary? currentEventSummary;          // 请求2输出的事件摘要
  final FailureContext? failureContext;             // 失败上下文（phase=failed 时非 null）
  final Map<IntermediatePhase, int> retryCounts;    // 按阶段分别计数的重试次数
  const IntermediateChatState({
    required this.phase,
    this.streamingGenerated,
    this.draftKeywords,
    this.retrievedMemories,
    this.streamingReply,
    this.currentEventSummary,
    this.failureContext,
    this.retryCounts = const {},
  });
  // copyWith 使用 sentinel 模式区分"未提供"和"显式 null"
}

/// Tool Call（SSE 流中的工具调用）
class ToolCall {
  final String id;              // 工具调用 ID
  final String name;            // 工具名称，如 "update_world"
  final Map<String, dynamic> arguments; // 工具参数
  const ToolCall({required this.id, required this.name, required this.arguments});
}

/// API 预设
class ApiPreset {
  final String presetId;        // TEXT PK
  final String name;
  final String baseUrl;
  final bool isBuiltIn;         // 是否内置
  final List<ModelInfo> cachedModels;
  final DateTime createdAt;
  final DateTime updatedAt;
  const ApiPreset({
    required this.presetId,
    required this.name,
    required this.baseUrl,
    this.isBuiltIn = false,
    this.cachedModels = const [],
    required this.createdAt,
    required this.updatedAt,
  });
}

/// 模型类型（对标 ChatBox type 字段）
enum ModelType {
  chat,        // 对话模型（默认）
  embedding,   // 嵌入式模型（Advanced 模式记忆子系统使用）
  rerank,      // 重排序模型（Advanced 模式可选）
}

/// 模型能力（对标 ChatBox capabilities 字段，与 ModelType 正交）
enum ModelCapability {
  vision,      // 支持视觉/图像输入
  reasoning,   // 支持思考/推理模式
  toolUse,     // 支持工具调用（function calling）
  webSearch,   // 支持网络搜索
}

/// 模型信息（对标 ChatBox ProviderModelInfo）
class ModelInfo {
  final String modelId;                      // 模型 ID，如 "gpt-4o"
  final String? displayName;                 // 显示名称（用户可自定义，对应 ChatBox nickname）
  final ModelType type;                      // 模型类型（默认 chat）
  final List<ModelCapability> capabilities;  // 能力标签列表
  final int? contextWindow;                  // 上下文窗口大小（tokens），从 API/models.dev 获取或手动设置
  final int? maxOutput;                      // 最大输出 token 数
  final List<String> labels;                 // 标签（如 recommended/pro/new）
  const ModelInfo({
    required this.modelId,
    this.displayName,
    this.type = ModelType.chat,
    this.capabilities = const [],
    this.contextWindow,
    this.maxOutput,
    this.labels = const [],
  });

  /// JSON 序列化（用于 drift cached_models 字段存储）
  Map<String, dynamic> toJson();
  /// JSON 反序列化（兼容旧 snake_case key 格式）
  static ModelInfo fromJson(Map<String, dynamic> json);
}

/// 模板
class Template {
  final String templateId;      // TEXT PK
  final String name;
  final TemplateKind kind;
  final String content;         // 模板内容
  final bool isBuiltIn;         // 是否内置
  final DateTime createdAt;
  final DateTime updatedAt;
  const Template({
    required this.templateId,
    required this.name,
    required this.kind,
    required this.content,
    this.isBuiltIn = false,
    required this.createdAt,
    required this.updatedAt,
  });
}
```

> **与 DOC-04 的对齐说明**：以上实体定义与 DOC-04 Section 2.1 一致。关键差异：
> 1. ExperientialMemory 使用 `memoryId`（String UUID）替代 DOC-04 中的 `dbId`（int 自增主键），遵循"接口不暴露实现细节"原则。Data 层实现时需在 experiential_memories 表新增 `memory_id TEXT` 列作为业务主键。
> 2. Message 新增 `toolCallId`、`toolCallName`、`toolCallArguments` 字段，支持 SSE Tool Call 场景（v0.2）。
> 3. ModelInfo 全面升级（对标 ChatBox ProviderModelInfo）：新增 `type`（ModelType 枚举）、`capabilities`（ModelCapability 列表）、`maxOutput`、`labels` 字段；新增 ModelType 和 ModelCapability 枚举定义。支持模型类型区分（chat/embedding/rerank）和能力标签（vision/reasoning/toolUse/webSearch）。`fromJson` 兼容旧 snake_case key 格式，无需数据库迁移。
>
> **跨文档同步说明**：DOC-02/03/04 中仍引用旧设计（如 `dbId`、`HudController.refreshPanel()`），以本文档（DOC-05 v1.4）为准。后续需同步更新 DOC-02/03/04 中的过时引用。

---

### 2.4 LlmService 相关值对象（v1.3 新增，DOC-12 v1.1 同步）

> **v1.3 新增**（DOC-12 v1.1 同步）：LlmService 接口关联的请求/响应/事件值对象扩展。LlmService 完整接口定义见 DOC-05-3，此处仅描述 v1.3 扩展字段。LlmRequest / LlmResponse / LlmStreamEvent / LlmThinkingBlock 完整定义位于 `lib/features/chat/domain/services/llm_service.dart`。

#### 2.4.1 LlmRequest 扩展字段

LlmRequest 在原字段基础上新增 2 个字段，支持多协议适配与协议特有参数透传：

| 字段 | 类型 | 默认值 | 说明 |
|------|------|--------|------|
| `protocol` | `LlmProtocol` | `openaiCompatible` | LLM 协议类型（决定 LlmProtocolAdapter 分发目标）。默认 openaiCompatible 兼容 v0.1 调用方（未显式传 protocol 时走 OpenAI 兼容协议）。调用方应从 ApiPreset.protocol 读取并传入此字段，以支持 Claude/Gemini 等非 OpenAI 协议供应商。详见 DOC-05-6 §6.5 |
| `providerOptions` | `Map<String, dynamic>?` | `null` | 协议特有参数透传字段（DOC-12 §7）。用于承载无法用统一字段表达的协议特有参数。适配器从此 Map 中提取自己识别的 key，忽略不识别的 key |

**providerOptions 用途示例**（DOC-12 §7，优先级：适配器先读 `reasoningEffort` 统一枚举做基础映射，再用 providerOptions 中的协议特有配置覆盖）：

| 协议 | key | 值示例 | 用途 |
|------|-----|--------|------|
| Anthropic | `thinking` | `{'type': 'enabled', 'budget_tokens': 2000}` | 启用 thinking 模式 + 预算 |
| Anthropic | `anthropic_beta` | `['interleaved-thinking-2025-05-14']` | beta 特性标识 |
| Gemini | `thinkingConfig` | `{'thinkingLevel': 'high'}` | 思考强度（Gemini 3 用 thinkingLevel，2.5 用 thinkingBudget） |
| OpenRouter | `reasoning` | `{'effort': 'high'}` | 跨供应商统一 reasoning 配置 |
| OpenRouter | `extra_headers` | `{'HTTP-Referer': '...', 'X-Title': '...'}` | 可选 header（排行榜归属，不影响功能） |

#### 2.4.2 LlmResponse 扩展字段

LlmResponse 在原 `content` / `usage` / `toolCalls` / `reasoningContent` 字段基础上新增 1 个字段：

| 字段 | 类型 | 默认值 | 说明 |
|------|------|--------|------|
| `thinkingBlocks` | `List<LlmThinkingBlock>?` | `null` | Anthropic 结构化 thinking blocks（含 signature）。仅 Anthropic 协议响应有值，OpenAI/DeepSeek/Gemini 为 null。多轮对话中调用方必须将此列表原样回传到下轮请求的 messages 中，否则 Anthropic 服务端 signature 验证失败（400 错误）。详见 §2.4.4 |

**reasoningContent 与 thinkingBlocks 互斥关系**：

| 协议 | 思考内容字段 | 类型 | signature | 多轮回传 |
|------|-------------|------|-----------|---------|
| OpenAI / DeepSeek | `reasoningContent` | `String?` | 无 | 字符串直接回传到 `messages[i].reasoningContent` |
| Anthropic | `thinkingBlocks` | `List<LlmThinkingBlock>?` | 有 | 必须含 signature，写入 `messages[i].content` 数组中的 `thinking` block |
| Gemini | `reasoningContent` | `String?` | 无 | 写入 `messages[i].parts[{thought:true, text:...}]` |

- `reasoningContent`（String）：OpenAI/DeepSeek 风格，纯文本思维链，无签名
- `thinkingBlocks`（List）：Anthropic 风格，结构化块，含签名，多轮回传必需
- 两者**不会同时有值**：OpenAI/DeepSeek 用 reasoningContent，Anthropic 用 thinkingBlocks

#### 2.4.3 LlmStreamEvent 新增事件类型

LlmStreamEvent sealed class 新增 1 个事件类型 `LlmThinkingBlockComplete`：

| 事件类型 | 用途 | 各协议支持情况 |
|----------|------|---------------|
| `LlmTextDelta` | 文本增量 | OpenAI / Anthropic / Gemini |
| `LlmThinkingDelta` | 思考内容增量（字符串） | OpenAI（reasoning_content）/ Anthropic（thinking_delta）/ Gemini（thought:true）|
| `LlmThinkingBlockComplete` | **思考块完成（含 signature，v1.3 新增）** | Anthropic 专用（content_block_stop 时发出，含完整 thinking + signature） |
| `LlmToolCallStart` / `LlmToolCallArgs` / `LlmToolCallComplete` | 工具调用流式事件 | OpenAI / Anthropic / Gemini（Gemini 完整返回不发 Args） |
| `LlmStreamDone` | 流正常结束（含 usage） | 全部协议 |
| `LlmStreamError` | 流内错误 | 全部协议 |

**LlmThinkingBlockComplete 设计说明**（v1.3 新增，DOC-12 §5.4.4 + §6.4）：

```dart
class LlmThinkingBlockComplete extends LlmStreamEvent {
  const LlmThinkingBlockComplete({
    required this.thinking,
    required this.signature,
  });

  /// 思考内容文本（完整累积值，非增量）
  final String thinking;

  /// 加密签名（多轮回传必需）
  final String signature;
}
```

- Anthropic 流式响应的 `content_block_stop`（type=thinking）时发出
- 携带完整 thinking 文本 + signature（加密签名，多轮对话中必须原样回传，否则 400 错误）
- 调用方（如 IntermediateChatController）应缓存此事件信息，下一轮请求构造 assistant 消息时写入 `thinking` block 含 signature
- OpenAI/DeepSeek/Gemini 适配器不发此事件（它们用 LlmThinkingDelta 累积字符串，无 signature 概念）

#### 2.4.4 LlmThinkingBlock 值对象（v1.3 新增）

```dart
class LlmThinkingBlock {
  const LlmThinkingBlock({
    required this.thinking,
    required this.signature,
  });

  /// 思考内容文本（完整内容，非增量）
  final String thinking;

  /// 加密签名（多轮回传必需，不可修改）
  final String signature;
}
```

**用途**：LlmResponse.thinkingBlocks 列表的元素类型。Anthropic Claude 响应中的 thinking block 由 `thinking`（明文）+ `signature`（加密签名）两部分组成。

**调用方回传规则**：多轮对话中构造 assistant 消息时，应将此列表中的每个 block 原样写入 messages 的 content 数组：`{type: 'thinking', thinking: '...', signature: '...'}`。

**实现依据**：DOC-12 §5.4.4 + §11 风险表。

---

## 变更记录

| 版本 | 日期 | 变更 |
|------|------|------|
| v1.0 | 2026-06-30 | 从原 DOC-05 v2.2 拆分（05 因 2841 行严重超限拆为 05-1 ~ 05-8），本文档包含原 §2.3。原节号保持不变 |
| v1.1 | 2026-07-19 | V2.5（5W1E 改造）：<br/>1. `ExperientialMemory` 实体：`summary` 改为 `String?`（可选），新增 5W1E 6 字段（when/where/who/what/significance/extra，均 `String?`），构造函数同步<br/>2. `EventSummary` 实体：`summary` 改为 `String?`（可选），新增 5W1E 6 字段，构造函数同步；文档注释更新为"V2.5 5W1E 多字段结构"<br/>3. 5W1E 字段与 `memories_fts` 表 7 内容字段对齐，支持 FTS5 多字段检索<br/>4. 宏摘要（is_summary=true）保持 `summary` 单字段，不采用 5W1E；consolidation 已禁用（trigger_threshold=2.0） |
| v1.2 | 2026-07-21 | 配置架构重构：<br/>1. `ChatSession` 实体新增 `phaseModels: SessionPhaseModels` 字段（默认 `SessionPhaseModels.empty()`，8 字段全 null），位于 9 个会话级设置扁平字段之后；构造函数同步新增 `this.phaseModels = SessionPhaseModels.empty`<br/>2. 新增 `SessionPhaseModels` 实体定义（紧跟 `ChatSession_DEPRECATED` 之后）：8 个 nullable 字段（draftingPresetId/ModelId、extractingPresetId/ModelId、revisingPresetId/ModelId、summarizingPresetId/ModelId），构造函数 + `empty()` 常量构造 + `forPhase(phase)`/`copyWithPhase(phase, presetId, modelId)` 方法；持久化到 `chat_sessions` 表 8 列；优先级链：会话级 phase > 全局 phase（都没配置返回 null，drafting 阶段触发 E010）<br/>3. `ChatSessionSettings` 实体注释补充 modelId/presetId 跨模式语义：故事模式始终空串（业务模型走 `resolveIntermediatePhaseNamingConfig`），Simple 模式来自 broadcastChat 全局配置或会话级覆盖<br/>4. 配合 DOC-05-4 v1.5 ConfigurationResolver 接口签名变更 |
| v1.3 | 2026-07-24 | DOC-12 v1.1 同步——LlmService 相关值对象扩展：<br/>(1) 新增 §2.4 LlmService 相关值对象小节<br/>(2) §2.4.1 LlmRequest 新增 `protocol` (LlmProtocol, 默认 openaiCompatible) + `providerOptions` (Map<String, dynamic>?) 字段，附 providerOptions 用途示例表（Anthropic/Gemini/OpenRouter）<br/>(3) §2.4.2 LlmResponse 新增 `thinkingBlocks` (List<LlmThinkingBlock>?) 字段（Anthropic 专用，含 signature），附 reasoningContent vs thinkingBlocks 互斥关系表<br/>(4) §2.4.3 LlmStreamEvent sealed class 新增 `LlmThinkingBlockComplete` 事件类型（含 thinking + signature），附设计说明<br/>(5) §2.4.4 新增 `LlmThinkingBlock` 值对象（thinking + signature 两字段）。详见 DOC-12 v1.1 |
| v1.4 | 2026-07-25 | 叙事时间机制——EventSummary 实体新增 `narrativeTime` 字段：<br/>(1) `EventSummary` 类新增 `narrativeTime: String?` 字段（绝对叙事时间锚点，如"来公寓第三天"），构造函数同步新增 `this.narrativeTime`<br/>(2) 文档注释新增"v0.2 叙事时间机制（2026-07-25 新增）"段落——说明 narrativeTime 由 LLM 在 summarizing 阶段输出，持久化到 `experiential_memories.narrative_time` 列，persist 成功后由控制器 upsert 到 `chat_sessions.current_narrative_time`<br/>(3) `when` 字段注释修订为"相对时间描述（如'次日清晨'）"——明确与 `narrativeTime`（绝对时间锚点）的区别，两者共存<br/>(4) 详见 DOC-08 §5.7、DOC-09A-2 §8.1 |
| v1.5 | 2026-07-25 | 叙事时间机制补充——`ChatSession` 实体新增 `currentNarrativeTime` 字段：<br/>(1) `ChatSession` 类新增 `currentNarrativeTime: String?` 字段（当前叙事时间，绝对故事内时间，如"来公寓第三天"），位于 `reasoningEffort` 字段之后，构造函数同步新增 `this.currentNarrativeTime`<br/>(2) 字段语义：每轮 summarizing 阶段由 LLM 输出 `EventSummary.narrativeTime` 后由控制器 upsert 写入；持久化到 `chat_sessions.current_narrative_time` 列（schemaVersion=26）。NULL=首轮或 LLM 未输出叙事时间<br/>(3) 与 v1.4 EventSummary.narrativeTime 的关系：`narrativeTime` 是 LLM 每轮输出的临时值，`currentNarrativeTime` 是会话级持久状态（latest narrativeTime）。persist 成功后控制器执行 `session.copyWith(currentNarrativeTime: eventSummary.narrativeTime)`<br/>(4) 详见 DOC-02 §6.1（chat_sessions 表 current_narrative_time 列）、DOC-08 §5.7、DOC-09A-2 §6.3 步骤 6.5 |
| v1.6 | 2026-08-01 | v0.2.2 故事模式术语变更（阶段名重命名，与 DOC-08 v2.15、DOC-09A-1、DOC-09A-2 v2.23、DOC-09B v2.23、DOC-09C v2.7、DOC-09D v1.1、DOC-06B v3.15、DOC-02 v1.7、DOC-05-4 v1.7、DOC-13 v0.2.2 同步）：为消除"草稿/终稿"在故事模式与 Simple 模式草稿会话之间的歧义，故事模式两阶段重命名——drafting（草稿阶段）→ generating（生成阶段），revising（终稿阶段）→ reviewing（审查阶段）。本文档同步更新：（1）`SessionPhaseModels` 实体字段 `draftingPresetId/ModelId` → `generatingPresetId/ModelId`，`revisingPresetId/ModelId` → `reviewingPresetId/ModelId`；字段说明表 + 构造函数同步；注释补充 DB 列名保留 drafting_/revising_ 前缀说明；`forPhase` 方法参数 'drafting'/'revising' 保留旧名（DB 列名前缀路由依据，避免 API 破坏性变更）。（2）`IntermediatePhase` 枚举 `drafting` → `generating`，`revising` → `reviewing`，`draftingRetry` → `generatingRetry`，`revisingRetry` → `reviewingRetry`。（3）`FailureContext.failedPhase` 注释 `drafting/retrieving/revising` → `generating/retrieving/reviewing`。（4）`IntermediateChatState` 字段 `streamingDraft` → `streamingGenerated`，构造函数同步；`draftKeywords` 字段名保留（artifacts 表 DB 列名 draft_keywords）。**保留不变**：DB 列名 `drafting_preset_id`/`revising_preset_id`/`draft_text`/`draft_keywords`（向后兼容）；`forPhase`/`copyWithPhase` 方法参数 'drafting'/'revising' 字符串字面量（DB 列名前缀路由）；`draftKeywords` 字段名（DB 列名 draft_keywords 对应）；历史变更记录 v1.0-v1.5 中的旧术语（按"历史描述保留"规则）。配合 DOC-08 v2.15、DOC-09A-1、DOC-09A-2 v2.23、DOC-09B v2.23、DOC-09C v2.7、DOC-09D v1.1、DOC-06B v3.15、DOC-02 v1.7、DOC-05-4 v1.7、DOC-13 同步修订 |
