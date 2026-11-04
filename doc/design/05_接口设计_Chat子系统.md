# LMStory 接口设计（4）：Chat 子系统

> **状态：历史接口快照。** 当前 Controller 已委托给 ConfigurationResolver、MessageManager、StreamHandler、ForkManager 等职责组件，分支状态可持久化；下文内联/纯内存描述已失效。

| 属性 | 值 |
|------|-----|
| 文档编号 | LMStory-DOC-05-4 |
| 版本 | v1.0 |
| 日期 | 2026-06-30 |
| 状态 | 审定（拆分自 DOC-05 v2.2） |
| 前置文档 | LMStory-DOC-01 ~ 04 |
| 配套文档 | LMStory-DOC-05-1 ~ 05-8（其他子文档） |

---

## 0. 文档定位

本文档是接口设计的第 4 部分，覆盖 §3.4-3.6（Chat 子系统内部组件接口 + ChatRemoteDS + IntermediateChatController）。

> **拆分说明**：本文档原属 DOC-05 v2.2，因 05 行数严重超限（2841 行 > 500 行限制）拆分为 DOC-05-1 ~ DOC-05-8 共 8 个子文档。本文档保留原节号以保持交叉引用稳定。原 DOC-05 文件替换为索引页（指向各子文档）。

---

### 3.4 Chat 子系统内部组件接口（v0.1）

> **v0.1 实际实现差异**：原始设计将 Controller 拆分为 StreamManager/BranchManager/SettingsResolver 等独立组件。
> v0.1 实际实现中 `ChatModeController` 为直接 `StateNotifier<ChatModeState>`，不继承 `ChatControllerBase`，
> 内部逻辑直接内联而非委托给独立组件。具体差异：
> 1. **StreamManager** → Controller 直接持有 `HttpClient` + `SseParser`，内联 `_sendToApi()`/`_handleSseEvent()`/`_finishStreaming()`
> 2. **BranchManager** → Controller 内联 `regenerateLastResponse()`/`navigateFork()`/`_buildForkAnchorsForRegenerate()`/`_computeActiveView()`
> 3. **SettingsResolver** → Controller 内联 `_resolveSettings()` 方法
> 4. **CompactionDetector + CompactionExecutor + ContextBuilder + SummaryGenerator** → 合并为 `CompactionService`（Domain 层服务）
> 5. **ChatState** → 简化为 `ChatModeState`，字段：session, messages, forkAnchors, isSending, isStreaming, isThinking, isCompressing, error, currentAssistantMessageId, currentCompactionSummaryId, generatingAnchorUserMsgId, quoteText, currentModelName, currentProviderName, contextWindowTokens
>
> 以下为原始设计的组件接口，标记为已废弃，保留供 v0.2 重构参考。

#### 3.4.1 StreamManager（流式管理器 — 已废弃，v0.1 内联到 Controller）

```dart
// v0.1 实际实现：Controller 直接持有 HttpClient + SseParser
// _sendToApi() → _httpClient.streamPost() → _sseParser.parse() → _handleSseEvent()
// 取消：_currentCancelToken?.cancel() + _currentSubscription?.cancel()

class StreamManager_DEPRECATED {
  final ChatRepository _chatRepo;

  /// 发起 SSE 请求（委托 ChatRepository.streamChat）
  Future<void> dispatchSend({
    required String sessionId,
    required List<Message> messages,
    required ResolvedChatSessionSettings settings,
  });

  /// 取消当前流
  void cancelStream();

  /// 流式文本增量回调
  void onTextDelta(String delta);

  /// 流结束回调（持久化消息 + 回填 messageId + 写入 tokensUsed/firstTokenLatency/modelName）
  Future<void> onStreamEnd(String? finishReason, SseUsage? usage);

  /// 流错误回调
  void onStreamError(AppError error);
}
```

#### 3.4.2 BranchManager（分支管理器 — 已废弃，v0.1 内联到 Controller）

```dart
// v0.1 实际实现：
// - regenerateLastResponse()：在用户消息处创建新分支，保留旧消息
// - navigateFork(parentUserMsgId, direction)：循环切换分支
// - _computeActiveView()：根据 ForkAnchor 计算显示消息列表
// - _buildForkAnchorsForRegenerate()：重新生成时更新分支锚点
// 分支数据结构：Map<String, ForkAnchor> forkAnchors（纯内存，不持久化到 chat_session_branches 表）

class BranchManager_DEPRECATED {
  final ChatRepository _chatRepo;

  /// 创建分支
  Future<BranchInfo> createForkBranch(String sessionId, String anchorUserMsgId);

  /// 切换活跃分支
  Future<BranchInfo> switchActiveBranch(String sessionId, String anchorUserMsgId, int targetBranchIndex);

  /// 删除当前分支
  Future<BranchInfo> deleteActiveBranch(String sessionId, String anchorUserMsgId);

  /// 展开所有分支
  Future<void> expandBranch(String sessionId, String anchorUserMsgId);

  /// Regenerate：在用户消息处 fork 后重新生成
  Future<void> regenerateInNewFork(String sessionId, Message assistantMsg);

  /// GenerateMore：在同一分支追加生成
  Future<void> generateMore(String sessionId, String userMsgId);
}
```

#### 3.4.3 SettingsResolver（设置解析器 — 已废弃，v0.1.1 重构为 ConfigurationResolver）

```dart
// v0.1.1 重构实现：ConfigurationResolver 独立服务类
// 位于 lib/features/chat/domain/services/configuration_resolver.dart
// 解析顺序：会话级设置 → 激活预设 → 第一个可用 preset → 用户覆盖 → 配置文件默认
// API Key 缓存：_cachedApiKey（Controller 实例变量）
// 返回 ChatSessionSettings（单一已解析类，所有字段非空）
//
// 主要方法：
// - resolveModelDisplayInfo(ChatSession) → ModelDisplayInfo
// - resolveModelDisplayName(ApiPreset?, String modelId) → String?
// - resolveSettings(ChatSession) → ({ChatSessionSettings settings, String? apiKey})
// - resolveTitleNamingConfig() → NamingConfig?                                            // 2026-07-21 配置架构重构新增
// - resolveIntermediateSettings(ChatSession) → ({ChatSessionSettings, String? apiKey})  // v0.2 新增（2026-07-21 重构：不返回 modelId/presetId/apiKey）
// - resolveIntermediatePhaseNamingConfig(ChatSession session, String phase) → NamingConfig?  // 2026-07-21 配置架构重构新增
// - resolveEmbeddingConfig() → EmbeddingApiConfig?                                        // V1 新增
//
// 2026-07-21 配置架构重构：
// - 删除 resolveNamingConfig(ChatSession) 与 resolveIntermediateNamingConfig(ChatSession)
//   （标题生成与业务模型解耦，标题统一走 resolveTitleNamingConfig() 从 common.title_model 全局配置读取）
// - 新增 resolveTitleNamingConfig()：无参数，跨模式共享，用于会话标题生成
//   （ChatModeController._autoNameSession 与 IntermediateChatController._autoNameSession 均改用此方法）。
//   从 `common.title_model` 全局配置节点（preset_id + model_id 两字段）读取；
//   未配置时返回 null，调用方应使用 SessionTitleGenerator.fallbackTitle 降级。
// - resolveIntermediateSettings(ChatSession) 调整：不再返回 modelId/presetId（始终空串）
//   和 apiKey（始终 null），仅返回生成参数（temperature/topP/maxTokens/presencePenalty/
//   frequencyPenalty）和非生成参数（systemPrompt/autoCompaction/compactionThreshold/
//   streamEnabled/maxContextMessages/reasoningEffort）。
// - 故事模式业务模型走 resolveIntermediatePhaseNamingConfig(session, phase) 分步骤解析，
//   优先级链简化为两层：会话级 phase > 全局 phase（都没配置时返回 null，
//   generating 阶段触发 E010 错误；v0.2.2 阶段名重命名：drafting→generating、revising→reviewing；DB 列名/JSON key 保留 drafting_/revising_ 前缀不变，Dart 字段名 generating*/reviewing*）。详见 DOC-09C §10.2、DOC-05-2 §2.3 SessionPhaseModels 实体定义。
//
// V1 语义检索专用方法（resolveEmbeddingConfig）：
// 读取 `intermediate.embedding_preset_id` / `intermediate.embedding_model_id` 两个 user_overrides
// + preset 的 baseUrl/apiKey，组装成 EmbeddingApiConfig（model/baseUrl/apiKey/timeoutMs/fallbackOnFailure）。
// 返回 null 的场景：未配置 / preset 不存在 / apiKey 缺失 / apiKey 空串。
// 全局配置（非会话级）——embedding 模型切换影响向量维度，会话级切换会导致向量不一致。
// 详见 DOC-09A-1 §3.9、DOC-09C §10.1。
//
// EmbeddingApiConfig 值对象（V1 新增，与 NamingConfig 平行）：
// - model: String           embedding 模型 ID（如 text-embedding-3-small）
// - baseUrl: String         API 基础地址
// - apiKey: String?         API 密钥（nullable，本地部署可为 null）
// - timeoutMs: int          embedding API 超时（毫秒，来自 EmbeddingConfig.timeoutMs）
// - fallbackOnFailure: bool 失败降级开关（来自 EmbeddingConfig.fallbackOnFailure）

class SettingsResolver_DEPRECATED {
  final SettingsRepository _settingsRepo;
  final ApiPresetRepository _presetRepo;

  /// 解析会话级设置 → ResolvedChatSessionSettings
  /// 合并全局默认 + 会话覆盖 + 预设配置
  Future<ResolvedChatSessionSettings> resolve(String sessionId);

  /// 响应设置变更（ref.invalidate）
  void invalidate(String sessionId);
}
```

#### 3.4.4 CompactionService（压缩服务 — v0.1 实际实现）

> v0.1 实际实现将原始设计的 CompactionDetector + CompactionExecutor + ContextBuilder + SummaryGenerator 合并为 `CompactionService`（阈值检查 + 非流式摘要 + 压缩点落库）+ `CompactionStreamer`（流式 LLM 摘要请求）。

```dart
class CompactionService {
  final ChatRepository _chatRepository;
  final TokenCounter _tokenCounter;
  final SettingsRepository _settingsRepository;
  final ApiPresetRepository _presetRepository;
  final ConfigLoader _configLoader;
  final CompactionStreamer _streamer;  // v0.1 实际实现新增（流式压缩）

  /// 检查是否需要压缩（仅判断阈值，不执行压缩）（v0.1 实际实现新增）
  ///
  /// 阈值公式（对标 ChatBox compaction-detector.ts）：
  ///   availableWindow = max(contextWindow - 32000, floor(contextWindow × 0.5))
  ///   thresholdTokens  = floor(availableWindow × threshold)
  ///   isOverflow       = (currentTokens > thresholdTokens)
  /// contextWindow 未知（null）时不触发自动压缩；LMStory 中未知时使用默认值 96000（对标 ChatBox DEFAULT_CONTEXT_WINDOW）。
  ///
  /// 公开方法：供 controller 在自动压缩前预检，命中后由 controller 走流式压缩路径
  ///（[compactWithStream]），以便 UI 展示摘要横幅的流式生成过程。
  Future<bool> shouldCompact({
    required List<ChatMessage> messages,
    required double threshold,  // 百分比（0.4-0.9，默认 0.6），对标 ChatBox
    int? contextWindow,         // 模型上下文窗口大小；null 时使用默认值 96000
  });

  /// 检查并执行压缩（非流式路径，保留用于兼容）
  ///
  /// [threshold] 压缩阈值（百分比，0.4-0.9，默认 0.6，对标 ChatBox compactionThreshold）
  /// [contextWindow] 模型上下文窗口大小（来源：模型缓存的 contextWindow 字段；null 时使用默认值 96000）
  /// [force] 是否强制压缩（忽略阈值检查）
  /// 返回是否执行了压缩
  ///
  /// 注意：本方法走非流式摘要生成，UI 无法展示流式生成过程。
  /// 自动压缩场景应改用 [shouldCompact] + controller 流式压缩路径（[compactWithStream]），
  /// 以便 UI 展示摘要横幅的实时生成动画。本方法保留用于兼容旧调用方。
  Future<bool> checkAndCompact({
    required String sessionId,
    required List<ChatMessage> messages,
    required double threshold,  // 百分比（0.4-0.9，默认 0.6），对标 ChatBox
    int? contextWindow,         // 模型上下文窗口大小；null 时使用默认值 96000
    bool force = false,
  });

  /// 流式压缩（手动压缩，v0.1 实际实现新增）
  ///
  /// 编排流程：
  /// 1. 校验非摘要消息数 >= 2（失败调 [onError]）
  /// 2. 解析 [SummaryConfig]（失败调 [onError]）
  /// 3. 调 [CompactionStreamer.stream] 发起流式 LLM 请求
  /// 4. 增量回调 [onTextDelta]、完成回调 [onComplete]、失败回调 [onError]
  ///
  /// 本方法**不**创建摘要消息和 CompactionPoint，由调用方（controller）
  /// 在回调中完成落库，避免 service 与 controller 状态不同步。
  Future<void> compactWithStream({
    required String sessionId,
    required List<ChatMessage> messages,
    required OnCompactionDelta onTextDelta,
    required OnCompactionComplete onComplete,
    required OnCompactionError onError,
  });

  /// 解析摘要生成所需的 API 配置（v0.1 实际实现新增）
  /// 公开方法：供 controller 在流式压缩前预检配置是否可用
  /// 返回 null 表示配置不可用（无 preset / api key / model）
  Future<SummaryConfig?> resolveSummaryConfig(String sessionId);

  /// 获取压缩后的消息列表
  /// 返回包含摘要和压缩点之后消息的列表
  Future<List<ChatMessage>> getCompressedMessages(String sessionId);
}

/// 流式压缩回调类型定义（v0.1 实际实现新增）
typedef OnCompactionDelta = Future<void> Function(String delta);
typedef OnCompactionComplete = Future<void> Function(String fullSummary, int? tokensUsed);
typedef OnCompactionError = Future<void> Function(Object error);

/// 摘要生成所需的 API 配置（v0.1 实际实现新增）
class SummaryConfig {
  final String baseUrl;
  final String apiKey;
  final String modelId;
  const SummaryConfig({
    required this.baseUrl,
    required this.apiKey,
    required this.modelId,
  });
}

/// 流式压缩器（v0.1 实际实现新增）
///
/// 纯流式 LLM 摘要请求，不碰 DB。通过 [HttpClient.streamPost] 发起 SSE 请求，
/// [SseParser] 解析事件流，回调 [onTextDelta] / [onComplete] / [onError]。
/// 请求体设置 `stream_options.include_usage=true` 确保最后一个 chunk 携带 usage。
class CompactionStreamer {
  final HttpClient _httpClient;
  final SseParser _sseParser;

  Future<void> stream({
    required SummaryConfig config,
    required List<ChatMessage> messages,
    required OnCompactionDelta onTextDelta,
    required OnCompactionComplete onComplete,
    required OnCompactionError onError,
    Duration readTimeout = const Duration(seconds: 90),
  });
}
```

> **v0.1 实际实现 vs 原始设计差异**：
>
> | 维度 | 原始设计 | v0.1 实际实现 |
> |------|---------|-------------|
> | 组件拆分 | CompactionDetector + CompactionExecutor + ContextBuilder + SummaryGenerator | CompactionService（阈值 + 非流式 + 落库）+ CompactionStreamer（流式 LLM 请求） |
> | 阈值语义 | `compactionThreshold` 为比例值（0.6 = 上下文占用 60%） | `compactionThreshold` 为百分比（0.4-0.9，默认 0.6），对标 ChatBox `compactionThreshold` |
> | 阈值公式 | `currentTokens > availableWindow × compactionThreshold`，`availableWindow = max(contextWindow - outputReserve, contextWindow × 0.5)` | `currentTokens > thresholdTokens`，`availableWindow = max(contextWindow - 32000, floor(contextWindow × 0.5))`，`thresholdTokens = floor(availableWindow × compactionThreshold)`（对标 ChatBox `compaction-detector.ts`） |
> | contextWindow 来源 | 接口参数传入 | 模型缓存的 `contextWindow` 字段；未知（null）时不触发自动压缩，LMStory 中未知时使用默认值 96000（对标 ChatBox `DEFAULT_CONTEXT_WINDOW`） |
> | checkAndCompact 签名 | `checkAndCompact({sessionId, messages, threshold, force})` | `checkAndCompact({sessionId, messages, threshold, contextWindow, force})`（新增 `contextWindow` 参数）+ 新增 `shouldCompact` 公开方法（仅判断阈值） |
> | 摘要生成 | 通过 `LlmService`（Domain 抽象） | 自动压缩与手动压缩均走流式路径：`shouldCompact` 预检 → controller `_compressHistoryCore` → `compactWithStream` → `CompactionStreamer` + `HttpClient.streamPost` + `SseParser`。`checkAndCompact`（非流式）保留兼容但不再用于自动压缩 |
> | 摘要消息角色 | `role: assistant`（设计文档） | `role: 'system'`（实际代码）⚠️ **待修正** |
> | 失败处理 | 无 | 手动压缩失败时保留已生成 content + error 字段，渲染为常驻失败卡片（用户手动关闭或重试） |
> | 上下文构建 | 独立 `ContextBuilder` 组件 | `getCompressedMessages()` 方法内联 |
> | 压缩点持久化 | `CompactionPoint` 实体 | `Map<String, dynamic>` |

#### 3.4.5 CompactionDetector（压缩检测器 — 已废弃，合并到 CompactionService）

```dart
class CompactionDetector_DEPRECATED {
  final TokenCounter _tokenCounter;

  /// 检查是否需要压缩
  /// availableWindow = max(contextWindow - outputReserve, contextWindow × 0.5)
  /// currentTokens > availableWindow × compactionThreshold
  Future<bool> needsCompaction({
    required String sessionId,
    required int contextWindow,
    required int outputReserve,
    required double compactionThreshold,
  });
}
```

#### 3.4.6 CompactionExecutor（压缩执行器 — 已废弃，合并到 CompactionService）

```dart
class CompactionExecutor_DEPRECATED {
  final ChatRepository _chatRepo;
  final SummaryGenerator _summaryGenerator;
  final CompactionDetector _detector;

  /// 执行压缩
  Future<CompactionPoint> execute({
    required String sessionId,
    required int contextWindow,
    required int outputReserve,
    required double compactionThreshold,
    bool force = false,
  });
}
```

#### 3.4.7 ContextBuilder（上下文构建器 — 已废弃，合并到 CompactionService）

```dart
class ContextBuilder_DEPRECATED {
  final ChatRepository _chatRepo;

  /// 构建 Simple 模式上下文
  Future<List<Message>> buildSimpleContext(String sessionId);
}
```

#### 3.4.8 SummaryGenerator（摘要生成器 — 已废弃，合并到 CompactionService）

```dart
class SummaryGenerator_DEPRECATED {
  final LlmService _llmService;

  /// 调用 LLM 生成对话摘要
  Future<String> generateSummary({
    required String sessionId,
    required List<Message> contextMessages,
  });
}
```

#### 3.4.9 ChatModeState（v0.1 实际实现状态类）

```dart
/// v0.1 实际实现的 ChatMode 状态
/// 与原始设计的 ChatState 差异：
/// - 无 isLoading/isCompacting/isExecutingToolCall/executingToolName
/// - 无 resolvedSettings/compactionPoints（压缩点从 DB 按需加载）
/// - 新增 isSending（区分发送中和流式接收中）
/// - 新增 isThinking（标记 LLM 思考阶段，UI 显示思考指示器）
/// - 新增 quoteText（引用回复时被引用的消息内容）
/// - 新增 currentAssistantMessageId（跟踪当前流式助手消息）
/// - 新增 currentCompactionSummaryId（v0.1 新增，跟踪当前流式生成内容的占位摘要消息 ID，UI 据此展示流式状态）
/// - error 为 String? 而非 AppError?
/// - forkAnchors 为 List<ForkAnchor>（chat_session_branches 表的内存视图），而非 Map<String, BranchInfo>
class ChatModeState {
  final ChatSession session;
  final List<ChatMessage> messages;
  final List<ForkAnchor> forkAnchors;  // chat_session_branches 表的内存视图
  final bool isSending;           // 正在发送（含请求准备阶段）
  final bool isStreaming;         // 正在流式接收
  final bool isThinking;          // LLM 思考阶段（reasoning_content 接收中）
  final String? error;            // 错误消息（非结构化 AppError）
  final String? currentAssistantMessageId;  // 当前流式助手消息 ID
  final String? currentCompactionSummaryId;  // 当前正在流式生成内容的占位摘要消息 ID（仅压缩进行中非 null）
  final String? generatingAnchorUserMsgId;  // 当前流式生成对应的 Fork 锚点用户消息 ID（regenerate/editAndResend 时非 null，用于占位气泡显示分支导航）
  final String? quoteText;        // 引用回复的被引用消息内容
  // copyWith 使用 sentinel 模式：error、currentAssistantMessageId、currentCompactionSummaryId、generatingAnchorUserMsgId、quoteText 用 sentinel 值区分"未提供"和"显式 null"（v0.1 实际实现新增）
}
```

### 3.5 ChatRemoteDS（Data 层抽象，v0.2 中级模式起）

**所属模块**: Chat（Data 层）
**版本**: v0.2 起可用（v0.1 由 Controller 直接管理 SSE；v0.2 起抽象为 Data 层接口以支持 tools 参数）
**职责**: 封装 SSE 流式聊天请求（含 tools 参数，V2 四步重构 extracting/summarizing 传入工具定义）
**接口定义位置**: `features/chat/data/datasources/chat_remote_ds.dart`

> **v0.1→v0.2 演进**：v0.1 中 SSE 流由 Controller 直接通过 `HttpClient.streamPost()` + `SseParser.parse()` 管理。v0.2 中级模式起抽象为 `ChatRemoteDS` 接口，以支持 `tools` 参数。**V2 四步重构**（2026-07-10）后，中级模式 extracting/summarizing 步骤传入工具定义（`extract_keywords`/`extract_event_summary`），不再传 null。v0.3 高级模式传入 update_world 等工具定义。08 §7.2 定义。

```dart
/// Data 层抽象接口，封装 SSE 流式聊天请求
/// V2 四步重构：extracting/summarizing 传入工具定义（工具调用降级链首选）
/// generating/reviewing：tools 传 null（纯文本输出，无结构化；v0.2.2 阶段名重命名：drafting→generating、revising→reviewing）
/// v0.3 高级模式：tools 传入工具定义（update_world 等）
abstract interface class ChatRemoteDS {
  /// 发起 SSE 流式聊天请求
  /// [messages] 上下文消息列表
  /// [settings] 已解析的运行时配置（含 baseUrl/apiKey/model 等）
  /// [tools] 工具定义列表（extracting/summarizing 传入，generating/reviewing 传 null）
  /// [toolChoice] 工具选择策略（extracting/summarizing 传 required，其他传 null）
  /// [cancellable] 取消令牌
  /// 异常: InvalidApiKeyException (E201), TimeoutException (E101), ConnectionException (E102), ApiException (E103)
  Stream<SseEvent> streamChat({
    required List<ChatMessage> messages,
    required ChatSessionSettings settings,
    List<ToolDefinition>? tools,
    ToolChoice? toolChoice,
    Cancellable? cancellable,
  });
}

/// 工具定义（V2 四步重构 extracting/summarizing 使用，v0.3 高级模式 update_world 等）
class ToolDefinition {
  final String name;              // 工具名称，如 "extract_keywords" / "extract_event_summary" / "update_world"
  final String description;       // 工具描述
  final Map<String, dynamic> parametersSchema;  // JSON Schema 参数定义
  const ToolDefinition({
    required this.name,
    required this.description,
    required this.parametersSchema,
  });
}
```

### 3.6 IntermediateChatController（Presentation 层，v0.2 中级模式）

**所属模块**: Chat（Presentation 层）
**版本**: v0.2（V2 四步重构 2026-07-10）
**职责**: 编排中级模式四步生成流程（generating → extracting → retrieving → reviewing → summarizing → persisting；v0.2.2 阶段名重命名：drafting→generating、revising→reviewing），管理 `IntermediateChatState`
**接口定义位置**: `features/intermediate/presentation/controllers/intermediate_chat_controller.dart`

> **登记说明**：本节仅登记 Controller 职责边界，详细状态机见 DOC-09A-1 §2，交互见 DOC-09B §7。Controller 为 `StateNotifier<IntermediateChatState>`（Riverpod），不继承 `ChatModeController`（独立组件路线）。V2 四步重构后状态机扩展为 6 主阶段 + idle/failed + 5 重试状态（共 13 枚举值，见 DOC-09B §7.1）。
>
> **标题生成（2026-07-21 配置架构重构）**：`_autoNameSession` 方法改用 `ConfigurationResolver.resolveTitleNamingConfig()` 从 `common.title_model` 全局配置节点读取标题生成模型（preset_id + model_id），与业务模型解耦。未配置时返回 null，调用方使用 `SessionTitleGenerator.fallbackTitle` 降级。`ChatModeController._autoNameSession` 同步改造。详见 §3.4.3 ConfigurationResolver 注释。

```dart
class IntermediateChatController extends StateNotifier<IntermediateChatState> {
  IntermediateChatController({
    required ChatRepository chatRepository,
    required ConfigurationResolver configurationResolver,
    required LlmService llmService,
    required ExperienceRepository experienceRepository,
    required EmbeddingService embeddingService,
    required IntermediatePersistenceService persistenceService,
    required FailureLogRepository failureLogRepository,
    required TokenCounter tokenCounter,
    required Future<IntermediateConfig> Function() getConfig,
    required Logger logger,
    required ChatSession session,
    SessionTitleGenerator? titleGenerator,
    MemoryConsolidator? consolidator,
  });

  /// 加载历史消息（非草稿会话，构造函数自动调用）
  ///
  /// 2026-07-22 修复：从页面 initState 调用改为构造函数调用，
  /// 与 ChatModeController 一致。修复故事模式→故事模式切换会话时
  /// State 复用导致 initState 不重新调用、消息不加载的问题。
  Future<void> loadHistory();

  /// 发送消息：触发四步生成流程
  /// 状态机：idle → generating → extracting → retrieving → reviewing
  ///       → summarizing → persisting → idle
  /// （v0.2.2 阶段名重命名：drafting→generating、revising→reviewing）
  /// v0.2.2 后审查可选：reviewEnabled=false 时跳过 reviewing，生成即最终
  /// 任一阶段失败 → phase=failed，保留已生成内容，FailureBar 显示重试
  Future<void> sendMessage(String userInput);

  /// 重试当前失败阶段（自动重试用尽后手动重试）
  Future<void> retry();

  /// 取消当前生成：停止 SSE + 清空临时状态 -> idle（不进 failed，DOC-09C §3）
  ///
  /// 同时清空 pendingUserMessage（气泡消失），保留 userInput 供页面层
  /// 回写到输入框（用户无需重新打字）。
  Future<void> cancel();

  /// 清空本轮：移除中间产物 + 清空 pendingUserMessage，回 idle
  ///
  /// pendingUserMessage 清空后气泡消失，userInput 保留供页面层回写到输入框。
  /// 用于失败后用户主动放弃。
  void clearRound();

  // ---- 简化 Fork（覆盖式重写，DOC-09A-1 §2.4-§2.7）----

  /// 重新生成助手回复（targetMessage 可以是 user 或 assistant）
  /// - assistant 消息：直接作为目标，保留前一条 user_N
  /// - user 消息：自动找到下一条 assistant 作为目标，效果一致
  /// 删除 assistant_N + 下游 + turn≥N 事件摘要 -> 走 persistRegeneratedRound
  Future<void> regenerateMessage(ChatMessage targetMessage);

  /// 编辑用户消息后重发（targetMessage 必须是 user）
  /// 删除 user_N + assistant_N + 下游 + turn≥N 事件摘要 → 走 persistRound
  Future<void> editAndResend(ChatMessage targetMessage, String newContent);

  /// 删除整轮（targetMessage 可以是 user 或 assistant）
  /// 删除 user_N + 下游 + turn≥N 事件摘要，不重新生成
  Future<void> deleteRound(ChatMessage targetMessage);

  /// 判断消息是否在 Fork 窗口内（可操作）
  /// targetTurn >= totalRounds - windowRounds + 1
  bool canOperateMessage(ChatMessage message, {required int windowRounds});

  // ---- 消息编辑与状态恢复（v0.2.3 新增）----

  /// 清空 IntermediateChatState.userInput
  ///
  /// 页面层把 userInput 回写到输入框后调用，避免重复触发回写逻辑。
  /// 典型场景：取消生成 / 清空本轮 / 后台恢复后，页面层检测到
  /// pendingUserMessage 为空且 userInput 非空，将文本回写输入框后调此方法清空。
  void clearUserInput();

  /// 仅更新数据库中消息的文本内容（不重新生成）
  ///
  /// 不清理记忆、不删除下游消息、不重新触发生成流程。
  /// 适用于修正错别字等小修改。若需基于新内容重新生成，请用 [editAndResend]。
  /// 仅针对已持久化消息；pendingUserMessage 的编辑请用
  /// [updatePendingUserMessageContent]。
  Future<void> editMessageContent(ChatMessage targetMessage, String newContent);

  /// 更新内存中 pendingUserMessage 的文本内容（不持久化、不发送）
  ///
  /// 适用于失败/取消后保留的临时用户消息，用户编辑后只想保存修改不立即发送。
  /// 若需编辑后重发，请用 editPendingUserMessage（走 sendMessage 重新生成）。
  void updatePendingUserMessageContent(String newContent);

  /// App 从后台恢复时检测卡死状态
  ///
  /// 检测条件：当前 phase 处于流式阶段（generating/reviewing/extracting/
  /// summarizing 及其 Retry 变体）但 StreamRunner 实际未在流式传输--
  /// 说明 App 后台期间 SSE 连接已断但状态机未正常收尾。
  ///
  /// 恢复动作：清空临时状态 + 清空 pendingUserMessage（气泡消失），
  /// 保留 userInput 供页面层回写到输入框（用户无需重新打字）。
  ///
  /// 返回 true 表示发生了恢复（调用方应提示用户"后台生成已中断"）；
  /// 返回 false 表示状态正常，无需恢复。
  bool recoverIfStuck();
}
```

---



---

## 变更记录

| 版本 | 日期 | 变更 |
|------|------|------|
| v1.0 | 2026-06-30 | 从原 DOC-05 v2.2 拆分（05 因 2841 行严重超限拆为 05-1 ~ 05-8），本文档包含原 §3.4-3.6。原节号保持不变 |
| v1.1 | 2026-07-03 | 接口同步：§3.6 IntermediateChatController 接口对齐实际代码——构造函数依赖更新（移除 ChatRemoteDS/TemplateRepository/AppConfig，新增 HttpClient/SseParser/ConfigurationResolver/IntermediatePersistenceService/TokenCounter/getConfig/Logger）；方法命名对齐（retryFailedPhase→retry、cancelGeneration→cancel、clearCurrentTurn→clearRound）；新增 loadHistory + 四方法（regenerateMessage/editAndResend/deleteRound/canOperateMessage） |
| v1.2 | 2026-07-03 | 接口同步：§3.4.3 ConfigurationResolver 注释补充两个中级模式专用方法（resolveIntermediateSettings/resolveIntermediateNamingConfig）及 modelId/presetId 三级优先级说明 |
| v1.3 | 2026-07-03 | V1 语义检索同步：§3.4.3 ConfigurationResolver 方法列表新增 `resolveEmbeddingConfig()` → `EmbeddingApiConfig?`，补充 `EmbeddingApiConfig` 值对象字段说明（model/baseUrl/apiKey/timeoutMs/fallbackOnFailure）及返回 null 的场景 |
| v1.4 | 2026-07-10 | V2 四步重构：§3.5 ChatRemoteDS 注释从"中级传 null"改为"V2 extracting/summarizing 传入工具定义"，streamChat 新增 `toolChoice` 参数，ToolDefinition 注释更新（新增 extract_keywords/extract_event_summary 示例）；§3.6 IntermediateChatController 职责从"两步生成"改为"四步生成"（drafting → extracting → retrieving → revising → summarizing → persisting），构造函数对齐实际代码（LlmService 替代 HttpClient/SseParser，新增 FailureLogRepository/titleGenerator/consolidator），接口定义位置更正为 `features/intermediate/presentation/controllers/`。配合 DOC-09A-1 v2.0 状态机、DOC-09B v2.0 §7.1 |
| v1.5 | 2026-07-21 | 配置架构重构：§3.4.3 ConfigurationResolver 接口签名变更——删除 `resolveNamingConfig(ChatSession)` 与 `resolveIntermediateNamingConfig(ChatSession)`（标题与业务模型解耦）；新增 `resolveTitleNamingConfig()`（无参数，从 `common.title_model` 全局配置读取，跨模式共享，未配置返回 null 由 `SessionTitleGenerator.fallbackTitle` 降级）；新增 `resolveIntermediatePhaseNamingConfig(session, phase)` 分步骤解析（会话级 phase > 全局 phase，都没配置返回 null，drafting 阶段触发 E010）；`resolveIntermediateSettings(ChatSession)` 不再返回 modelId/presetId（始终空串）和 apiKey（始终 null），仅返回生成参数 + 非生成参数；删除"与 Simple 模式方法的差异"段落。§3.6 IntermediateChatController 补充标题生成说明（`_autoNameSession` 改用 `resolveTitleNamingConfig()`）。配合 DOC-05-2 v1.2 SessionPhaseModels 新实体 |
| v1.6 | 2026-07-22 | `loadHistory()` 调用时机修复：从页面 initState 调用改为构造函数自动调用，与 ChatModeController 一致。修复故事模式→故事模式切换会话时 IntermediateChatPage State 复用导致 initState 不重新调用、消息不加载、UI 显示空状态的问题 |
| v1.7 | 2026-08-01 | v0.2.2 故事模式术语变更（阶段名重命名，与 DOC-08 v2.15、DOC-09A-1、DOC-09A-2 v2.23、DOC-09B v2.23、DOC-09C v2.7、DOC-09D v1.1、DOC-06B v3.15、DOC-02 v1.7、DOC-13 v0.2.2 同步）：为消除"草稿/终稿"在故事模式与 Simple 模式草稿会话之间的歧义，故事模式两阶段重命名——drafting（草稿阶段）→ generating（生成阶段），revising（终稿阶段）→ reviewing（审查阶段）。本文档同步更新：（1）§3.4.3 ConfigurationResolver 注释 `drafting 阶段触发 E010` → `generating 阶段触发 E010`，补充 DB 列名/JSON key 保留 drafting_/revising_ 前缀说明。（2）§3.5 ChatRemoteDS 注释 `drafting/revising：tools 传 null` → `generating/reviewing：tools 传 null`，`[tools]` 参数说明同步。（3）§3.6 IntermediateChatController 职责 `drafting → extracting → retrieving → revising → summarizing → persisting` → `generating → extracting → retrieving → reviewing → summarizing → persisting`；`sendMessage` 状态机注释 `idle → drafting → ... → revising` → `idle → generating → ... → reviewing`，`compact 降级：跳过 revising，草稿即终稿` → `v0.2.2 后审查可选：reviewEnabled=false 时跳过 reviewing，生成即最终`。**保留不变**：`resolveIntermediatePhaseNamingConfig(session, phase)` 函数签名（参数 `phase` 为 DB 列名前缀路由依据，保留 'drafting'/'revising' 字符串字面量避免 API 破坏性变更）；历史变更记录 v1.0-v1.6 中的旧术语（按"历史描述保留"规则）。配合 DOC-08 v2.15、DOC-09A-1、DOC-09A-2 v2.23、DOC-09B v2.23、DOC-09C v2.7、DOC-09D v1.1、DOC-06B v3.15、DOC-02 v1.7、DOC-05-2、DOC-13 同步修订 |
| v1.8 | 2026-08-05 | §3.6 IntermediateChatController 接口对齐实际代码（4 处不一致修复）：（1）cancel() 注释更正--原"保留已生成内容，phase 回到 idle"改为"停止 SSE + 清空临时状态 -> idle，同时清空 pendingUserMessage（气泡消失），保留 userInput 供页面层回写输入框"。（2）clearRound() 注释更正--原"用户消息保留，草稿/检索/回复移除"改为"移除中间产物 + 清空 pendingUserMessage，回 idle；userInput 保留供页面层回写"。（3）regenerateMessage 角色限制放宽--原"targetMessage 必须是 assistant"改为"可以是 user 或 assistant"（user 自动找下一条 assistant 作为目标）。（4）新增 4 个方法：clearUserInput()（清空 userInput，页面层回写输入框后调用）、editMessageContent()（仅更新 DB 消息文本，不清理记忆/不删除下游/不重新生成）、updatePendingUserMessageContent()（仅更新内存 pendingUserMessage 文本，不持久化/不发送）、recoverIfStuck()（App 后台恢复时检测卡死状态，清空 pendingUserMessage + 保留 userInput，返回 true 表示发生恢复）。配合 DOC-09D §1.2 compaction_points 清理步骤同步 |
