# LMStory 接口设计（8）：Core 层与非功能

> **状态：历史接口快照。** 协议/SSE 部分可与源码交叉参考；不存在的 IsolateRunner、UpdateWorld 异常映射和未测量性能指标不得写成已实现保证。

| 属性 | 值 |
|------|-----|
| 文档编号 | LMStory-DOC-05-8 |
| 版本 | v3.2 |
| 日期 | 2026-07-27 |
| 状态 | 审定（拆分自 DOC-05 v2.2） |
| 前置文档 | LMStory-DOC-01 ~ 04 |
| 配套文档 | LMStory-DOC-05-1 ~ 05-8（其他子文档） |

---

## 0. 文档定位

本文档是接口设计的第 8 部分，覆盖 §9-13（Core 层 12 个接口 + 错误码与异常映射 + 性能要求 + 安全限制 + 变更记录）。

> **拆分说明**：本文档原属 DOC-05 v2.2，因 05 行数严重超限（2841 行 > 500 行限制）拆分为 DOC-05-1 ~ DOC-05-8 共 8 个子文档。本文档保留原节号以保持交叉引用稳定。原 DOC-05 文件替换为索引页（指向各子文档）。

---

## 9. Core 层接口

### 9.1 DioClient（HTTP 客户端）

```dart
class DioClient {
  /// 发起常规 HTTP 请求
  Future<Response<T>> request<T>(
    String path, {
    required String baseUrl,
    required String? apiKey,
    Object? data,
    Map<String, dynamic>? queryParameters,
    Cancellable? cancellable,
  });
}
```

### 9.2 HttpClient（SSE 专用 HTTP 客户端）

> **架构决策**：SSE 流式请求使用 `http` 包而非 Dio，绕开 Dio 在 Android 上的流式 TLS bug（DOC-01/02/03 双引擎架构）。

```dart
class HttpClient {
  /// 发起 SSE 流式 POST 请求
  /// 使用 http 包实现，绕开 Dio Android 流式 TLS 问题
  /// 返回原始 SSE 行流
  /// [cancelToken] 取消令牌，内部映射到 http Client.close()
  /// [connectTimeout] 连接服务器最长等待时间（可选，默认使用构造函数值）
  /// [readTimeout] 无数据接收超时（可选，默认使用构造函数值）
  Stream<String> streamPost(
    String url,
    Map<String, String> headers, {
    String? body,
    Encoding encoding = utf8,
    CancellationToken? cancelToken,
    Duration? connectTimeout,
    Duration? readTimeout,
  });
}
```

> **超时配置**：`connectTimeout` 和 `readTimeout` 由 `ChatModeController._sendToApi()` 从 `SettingsRepository.getResolvedConfig()` 读取用户配置后传入，支持用户在通用设置中动态调整（默认连接超时 15s，响应超时 30s）。

> **v1.2 变更说明**：DioClient 和 HttpClient 均使用 `Cancellable?` 替代 `CancelToken?`（统一取消抽象，Dio/http 各自适配实现）。

### 9.3 SseParser（SSE 解析器）

```dart
class SseParser {
  /// 解析 SSE 行流，输出结构化事件
  /// 内部维护 5 态状态机
  Stream<SseEvent> parse(Stream<String> sseLines);

  /// 修复不完整 JSON（自动闭合括号、删除尾部逗号）
  static dynamic repairJson(String raw);
}
```

> **v3.1 关系说明**（DOC-12 v1.1 同步）：本 `SseParser` 为 OpenAI 兼容协议专用 SSE 解析器（解析 `choices[0].delta` 结构）。多协议适配引入后，底层 SSE 事件块切分抽取为 §9.16 `RawSseChunkParser`（协议无关），各协议适配器内部使用 RawSseChunkParser 切分事件块后自行解析协议格式。SseParser 与 RawSseChunkParser 关系详见 §9.16。

### 9.4 AppDatabase（drift 数据库）

```dart
class AppDatabase {
  /// 执行 drift 事务
  Future<T> transaction<T>(Future<T> Function() action);
}
```

### 9.5 SecureStorage（安全存储）

```dart
class SecureStorage {
  Future<void> write(String key, String value);
  Future<String?> read(String key);
  Future<void> delete(String key);
}
```

### 9.6 ConfigLoader（配置加载）

```dart
class ConfigLoader {
  /// 从 assets/configs/default_config.json 加载默认配置
  Future<AppConfig> loadDefaultConfig();
}
```

### 9.7 TokenCounter（Token 计数）

```dart
class TokenCounter {
  /// 估算消息列表的 token 数
  /// 使用 tiktoken 算法，结果缓存到 L1（消息级）和 L2（上下文级）
  Future<int> estimateTokens(List<Message> messages);

  /// 使 L2 缓存失效（消息变更后调用）
  void invalidateL2Cache(String sessionId);
}
```

### 9.8 IsolateRunner（Isolate 并发）

```dart
class IsolateRunner {
  /// 在 Isolate 中执行计算密集型任务
  Future<T> compute<T, P>(Future<T> Function(P) callback, P param);
}
```

### 9.9 Preferences（用户偏好存储）

```dart
class Preferences {
  Future<T?> get<T>(String key);
  Future<void> set<T>(String key, T value);
  Future<void> remove(String key);
}
```

### 9.10 ToolCallAccumulator（分片 JSON 累积器）

```dart
class ToolCallAccumulator {
  /// 追加分片 JSON
  void append(String chunk);

  /// 检查 JSON 是否完整
  bool isComplete();

  /// 获取修复后的完整 JSON
  /// 自动闭合括号、删除尾部逗号
  /// 异常: ToolCallParseException (E003)
  Map<String, dynamic> getRepairedJson();
}
```

### 9.11 EmbeddingRemoteDS（Embedding API 数据源，Data 层）

```dart
/// Data 层实现，实现 EmbeddingService 接口
class EmbeddingRemoteDS implements EmbeddingService {
  /// 调用 Embedding API 生成向量
  /// 异常: EmbeddingRateLimitedException (E104), ApiException (E103)
  @override
  Future<Float32List> embed({
    required String text,
    required String model,
    required String baseUrl,
    required String? apiKey,
  });
}
```

> **实现说明**：
> - 429 限流 → 抛 `EmbeddingRateLimitedException` (E104)，新建于 `lib/core/exceptions/app_exceptions.dart`
> - 其他 HTTP 错误 → 透传 `AppHttpException`（DioClient 已将 DioException 转换）
> - **不新建 `ApiException` (E103)**：与现有 `AppHttpException` 功能重叠，复用 `AppHttpException`。设计文档 §10.1 异常层次中的 `ApiException` 在 v0.2 实现中由 `AppHttpException` 承担。
> - 响应解析：`data[0].embedding` 数组 → `Float32List`（Float32 精度，与 VectorEngine 对齐）
> - URL 拼接：`ApiUrlResolver.resolve(baseUrl, '/v1/embeddings')`，复用现有 URL 智能解析逻辑
> - 超时策略：EmbeddingRemoteDS 不处理超时（用 DioClient 默认 30s）；中级模式 5s 超时（`embedding.timeout_ms`）由 EmbeddingQueue 用 `Future.timeout` 包装

### 9.12 VectorEngine（向量计算引擎）

> **v0.2 方案**：v0.2 中级模式向量检索**主方案 = 纯 Dart 暴力检索**，通过 `VectorEngine.batchSearch` 在 Isolate 内计算余弦相似度。原计划的 `sqlite-vec` 扩展因 pub 包损坏（`src/` 缺失 `sqlite-vec.c` 源文件，CMake 构建全平台失败、包已废弃）而废弃。向量数据存储在 `experiential_memories.embedding` BLOB 字段，检索时由 ExperienceRepositoryImpl 加载该 session 全部向量到内存后调用 `batchSearch` 计算。

```dart
class VectorEngine {
  /// 计算两个向量的余弦相似度
  double cosineSimilarity(Float32List a, Float32List b);

  /// 在 Isolate 中执行批量向量相似度计算（v0.2 主方案）
  /// 返回 Core 层纯计算结果（不含 Domain 业务实体）
  /// 从 experiential_memories.embedding BLOB 加载该 session 全部向量后调用本方法
  /// 性能：1536 维 × 1000 条 ≈ 5-15ms（ARM64 Isolate），满足 Q-02 ≤50ms 目标
  Future<List<VectorSearchResult>> batchSearch({
    required Float32List queryVector,
    required List<Float32List> candidates,
    required List<int> candidateIds,
  });
}
```

> **v1.2 变更说明**：`batchSearch` 返回类型从 `List<ScoredMemory>` 改为 `List<VectorSearchResult>`。VectorEngine 作为 Core 层基础设施不应依赖 Domain 业务实体（ExperientialMemory）。由 ExperienceRepositoryImpl（Data 层）负责将 VectorSearchResult 映射为 ScoredMemory。
>
> **v2.6 变更说明**：原计划 v0.2 主方案改为 sqlite-vec SQL KNN 检索，VectorEngine.batchSearch 降级为回退方案。
>
> **v2.7 变更说明**：sqlite-vec pub 包损坏废弃，VectorEngine.batchSearch 升回 **v0.2 主方案**。检索流程：ExperienceRepositoryImpl 从 `experiential_memories.embedding` BLOB 加载该 session 全部向量 → 调用 VectorEngine.batchSearch（Isolate 内余弦相似度）→ 返回 VectorSearchResult。不再建 `memory_vectors` 虚拟表。v0.3 升级路径：待 vec1（SQLite 官方向量扩展，2026 年新出）出现 Dart 绑定后重新评估 SQL KNN 方案。

> **实现说明**：
> - `VectorEngine` 为 `const` 构造无状态类，注册为 `vectorEngineProvider`（全局单例安全）
> - `cosineSimilarity` 同步执行于主 Isolate（单次计算 <1ms，无需跨 Isolate 开销）；维度不一致或空向量抛 `ArgumentError`
> - `batchSearch` 用 `Isolate.run`（一次性 Isolate）+ 闭包捕获参数；Float32List 可跨 Isolate 传递
> - 预校验在主 Isolate 完成（空候选返回空列表、长度不一致、维度不一致），比子 Isolate 抛错更易诊断
> - `_cosineSimilarityPure` 为顶级纯函数（无 this 依赖），`_Scored` 为 const 构造可跨 Isolate 传递的中间结构
> - 零向量保护：`denom == 0` 时返回 0（避免除零）
> - **不做 topK 截断**：调用方（ExperienceRepositoryImpl）需 topK×2 候选做合并排序（DOC-09A-1 §3.4）
> - `cosineScore` 返回原始 [-1,1]，归一化到 [0,1] 由 Repository 层完成（DOC-09A-1 §3.5）
> - **性能验证通过**：1536 维 × 1000 条 batchSearch = 30ms（debug 模式，远低于 Q-02 ≤50ms 目标）；cosineSimilarity 单次 = 416μs

### 9.13 FailureLogRepository（D2 诊断包，diagnostics feature）

> **归属说明**：本接口属于 `features/diagnostics` feature 的 Domain 层 Repository 接口（非纯 Core 基础设施）。因行数限制和子文档划分（diagnostics feature 独立于 chat/memory/settings），暂放在本文档 §9 末尾。v0.3 若 diagnostics feature 扩展为完整子系统，可考虑拆分为独立子文档 DOC-05-9。

**接口定义**（`lib/features/diagnostics/domain/repositories/failure_log_repository.dart`）：

```dart
abstract class FailureLogRepository {
  /// 插入一条失败日志，返回含回填 id 的 FailureLogEntry。
  ///
  /// [mode] 来源模式：'chat'（对话模式）| 'intermediate'（故事模式）| 'advanced'（v0.3）。
  /// [errorCategory] ErrorCategory.name（config/network/.../unknown）。
  /// [failedPhase] 失败阶段名（IntermediatePhase.name）；Simple 模式传 null。
  /// [rawError] 原始异常 toString（已截断）。
  ///
  /// 异常: QueryException (E301)
  Future<FailureLogEntry> insertLog({
    required String sessionId,
    required String mode,
    required String errorCategory,
    String? errorCode,
    String? failedPhase,
    int? httpStatus,
    String? errorMessage,
    String? rawError,
  });

  /// 获取最近 [limit] 条失败日志（按 createdAt 降序）。
  ///
  /// 可选过滤：[mode] 按模式；[sessionId] 按会话。
  /// 诊断页默认 limit=50，按时间倒序展示。
  ///
  /// 异常: QueryException (E301)
  Future<List<FailureLogEntry>> getRecentLogs({
    int limit = 50,
    String? mode,
    String? sessionId,
  });

  /// 清空所有失败日志（诊断页"清空"按钮，二次确认后调用）。
  ///
  /// 异常: QueryException (E301)
  Future<void> clearAll();

  /// 删除指定会话的全部失败日志（会话删除时级联清理）。
  ///
  /// 返回删除的行数。异常: QueryException (E301)
  Future<int> deleteBySession(String sessionId);
}
```

**实体定义**（`lib/features/diagnostics/domain/entities/failure_log_entry.dart`）：

| 字段 | 类型 | 说明 |
|------|------|------|
| id | int? | 数据库自增主键（插入后回填，业务层不直接使用） |
| sessionId | String | 来源会话 ID |
| mode | String | 来源模式（chat/intermediate/advanced） |
| errorCategory | String | ErrorCategory.name（config/network/auth/rateLimit/server/timeout/format/persist/unknown） |
| errorCode | String? | 错误码（Simple 模式 S001-S009；Intermediate 模式 E010-E018） |
| failedPhase | String? | 失败阶段（IntermediatePhase.name；Simple 模式为 null） |
| httpStatus | int? | HTTP 状态码（来自 AppHttpException） |
| errorMessage | String? | 用户可见的友好提示文案 |
| rawError | String? | 原始异常 toString（截断前 2000 字符） |
| createdAt | DateTime | 日志创建时间 |

**对应数据库表**：`failure_logs`（schemaVersion=16 新增），详见 DOC-02 §6.2、DOC-09C §5。

**业务约束**：
- Repository 仅含纯数据存取（硬约束），业务逻辑（如何构造日志、何时写入）在 Controller
- 写入时机：Controller 进入 failed 状态时调用 `insertLog`（Simple 模式：`ChatModeController._recordError`；Intermediate 模式：`IntermediateChatController._recordError`）
- 读取时机：诊断页（D3）调用 `getRecentLogs` 列出最近 N 条
- 清理时机：诊断页清空按钮调用 `clearAll`；会话删除时调用 `deleteBySession` 级联清理

### 9.14 LlmProtocolAdapter（多协议适配器抽象接口，v3.1 新增）

> **v3.1 新增**（DOC-12 v1.1 同步）：多协议适配层抽象接口。每种协议（OpenAI 兼容 / Anthropic / Gemini / Responses）实现此接口，负责构造请求 URL/Header/Body + 解析响应/SSE。运行时由 `LlmAdapterFactory` 按 `ApiPreset.protocol` 字段选择对应适配器实例。

**所属模块**: Core（网络层适配器抽象）
**版本**: v3.1（DOC-12 v1.1 同步）
**职责**: 协议转换——将统一的 LlmRequest 转换为协议特定的请求格式，将协议特定的响应/SSE 转换为统一的 LlmResponse/LlmStreamEvent
**接口定义位置**: `core/network/llm_adapters/llm_protocol_adapter.dart`

```dart
abstract class LlmProtocolAdapter {
  /// 构造完整请求 URL（含路径）
  /// [baseUrl] 为供应商根 URL（如 'https://api.openai.com'）
  /// [modelId] 用于 Gemini 等需要把模型名拼到路径里的协议
  /// [stream] 区分流式/非流式端点（如 Gemini ':streamGenerateContent'）
  String buildUrl(String baseUrl, String modelId, {required bool stream});

  /// 构造请求头（含认证 + 协议特有 header）
  /// [request] 提供完整请求上下文：apiKey / providerOptions['extra_headers'] /
  /// providerOptions['anthropic_beta']
  /// 适配器自行决定注入哪些协议 header（如 Anthropic 始终注入
  /// 'anthropic-version: 2023-06-01'），调用方无需感知协议差异
  /// [extra] 可选额外头（向后兼容 v0.1 调用方），与 providerOptions 中的
  /// extra_headers 合并，extra 优先级更高
  Map<String, String> buildHeaders(LlmRequest request, {Map<String, String>? extra});

  /// 构造请求体 JSON
  /// 将统一的 LlmRequest 转换为协议特定的请求体结构：
  /// - OpenAI: {model, messages, stream, ...}
  /// - Anthropic: {model, messages, system, max_tokens, ...}
  /// - Gemini: {contents, systemInstruction, generationConfig, ...}
  Map<String, dynamic> buildRequestBody(LlmRequest request, {required bool stream});

  /// 解析流式响应为统一事件流
  /// 输入为原始 SSE 字符串流，输出为 LlmStreamEvent 统一事件
  /// 实现应内部使用 RawSseChunkParser（§9.16）切分事件块，再按协议格式解析
  Stream<LlmStreamEvent> parseStream(Stream<String> rawStream);

  /// 解析非流式响应
  /// 输入为 HTTP 响应 body 的 JSON Map，输出为统一的 LlmResponse
  LlmResponse parseResponse(Map<String, dynamic> body);

  /// 获取模型列表的端点 URL（用于"获取模型"功能）
  /// - OpenAI 兼容 / Anthropic: {baseUrl}/v1/models
  /// - Gemini: {baseUrl}/v1beta/models
  String buildModelsUrl(String baseUrl);
}
```

**设计原则**：
- 接口仅做"协议转换"职责，不含业务逻辑
- 调用方（LlmRemoteDataSource）零感知协议差异
- SSE 解析分两层：底层 RawSseChunkParser（§9.16）共享切分，协议层独立解析事件格式

**已实现适配器**（4 个）：

| 适配器 | 协议 | 端点 | 认证头 | 关键差异 |
|--------|------|------|--------|----------|
| `OpenAiAdapter` | openaiCompatible | `/v1/chat/completions` | `Authorization: Bearer` | 现有 LlmRemoteDataSource 逻辑下沉；通用 OpenAI 兼容协议，不携带任何供应商特化逻辑；支持 OpenRouter 等兼容供应商 |
| `DeepSeekAdapter` | openaiCompatible | `/v1/chat/completions` | `Authorization: Bearer` | 继承 `OpenAiAdapter`，仅处理 DeepSeek 专属兼容性差异：思考模式下 `tool_choice:"required"` 降级为 `auto`、跳过 `parallel_tool_calls` 字段。由 `LlmAdapterFactory` 在 `openaiCompatible` 协议下按端点信息（baseUrl+modelId）自动路由（详见 §9.15 + DOC-12 §5.3） |
| `AnthropicAdapter` | anthropic | `/v1/messages` | `x-api-key` + `anthropic-version: 2023-06-01` | system 顶层字段、max_tokens 必填、tools 字段名 input_schema、thinking block signature 累积 |
| `GeminiAdapter` | geminiNative | `/v1beta/models/{model}:generateContent` | `x-goog-api-key` | contents 替代 messages、role 是 user/model、generationConfig 包裹采样参数、safetySettings 默认宽松、thinkingConfig 双轨制 |

**待实现适配器**（v0.3+）：

| 适配器 | 协议 | 状态 |
|--------|------|------|
| `OpenAiResponsesAdapter` | openaiResponses | ⏳ v0.3+。当前 LlmAdapterFactory.getAdapter({protocol: openaiResponses, ...}) 抛 UnimplementedError |

详见 DOC-12 §5.1-§5.5。

### 9.15 LlmAdapterFactory（适配器工厂，v3.1 新增）

> **v3.1 新增**（DOC-12 v1.1 同步）：按 LlmProtocol + 端点信息（baseUrl + modelId）分发到对应的适配器实例。LlmRemoteDataSource 持有本工厂，运行时按 `preset.protocol` + 端点信息获取适配器。

**所属模块**: Core（网络层适配器工厂）
**版本**: v3.1（DOC-12 v1.1 同步）；2026-07-28 扩展：DeepSeek 端点路由
**职责**: 协议分发——单例语义持有 4 个适配器实例（OpenAi/DeepSeek/Anthropic/Gemini），按 LlmProtocol + 端点信息返回对应实例
**接口定义位置**: `core/network/llm_adapters/llm_adapter_factory.dart`

```dart
class LlmAdapterFactory {
  /// 构造时创建单例适配器，支持依赖注入（测试场景）
  LlmAdapterFactory({
    OpenAiAdapter? openaiAdapter,
    DeepSeekAdapter? deepSeekAdapter,
    AnthropicAdapter? anthropicAdapter,
    GeminiAdapter? geminiAdapter,
  });

  /// 按协议类型 + 端点信息获取适配器（单例语义：同一协议同端点多次调用返回同一实例）
  ///
  /// **路由规则**：
  /// - openaiCompatible 协议下，若 DeepSeekAdapter.isDeepSeekEndpoint(baseUrl, modelId)
  ///   判定为 DeepSeek 端点，返回 DeepSeekAdapter；否则返回 OpenAiAdapter
  /// - 其他协议直接返回对应适配器
  ///
  /// 未实现的协议抛 UnimplementedError
  /// - openaiResponses 协议待 v0.3+ 实现
  LlmProtocolAdapter getAdapter({
    required LlmProtocol protocol,
    required String baseUrl,
    required String modelId,
  });
}
```

**单例语义说明**：工厂持有适配器实例而非每次 `new`，原因：
1. 适配器内部 SSE 解析器在 `parse()` 方法入口会重置状态，单例可安全复用
2. 减少 GC 压力（高频调用场景）
3. 测试场景可通过构造参数注入 mock 适配器

**异常**：
- `getAdapter({protocol: LlmProtocol.openaiResponses, ...})` 抛 `UnimplementedError`（待 v0.3+ 落地）

详见 DOC-12 §5.3。

### 9.16 RawSseChunkParser（SSE 底层解析器，v3.1 新增）

> **v3.1 新增**（DOC-12 v1.1 同步）：SSE 底层解析器——协议无关的 SSE 事件块切分器。所有协议层适配器（OpenAiAdapter / AnthropicAdapter / GeminiAdapter）共享此底层。

**所属模块**: Core（网络层 SSE 解析基础设施）
**版本**: v3.1（DOC-12 v1.1 同步）
**职责**: SSE 事件块切分——接收原始字符串流，按双换行 `\n\n` 切分为独立 SSE 事件块，提取 `event:` 和 `data:` 字段，忽略 SSE 注释行
**接口定义位置**: `core/network/sse/raw_sse_chunk_parser.dart`

```dart
class RawSseChunkParser {
  /// 解析原始 SSE 流，输出 (event, data) 元组
  ///
  /// 实例可复用：每次调用 parse 会重置内部缓冲区
  Stream<({String? event, String data})> parse(Stream<String> rawStream);
}
```

**职责范围**：
- 接收原始字符串流（可能跨 chunk 切分）
- 按双换行 `\n\n` 切分为独立 SSE 事件块
- 提取每个块的 `event:` 和 `data:` 字段（多行 data 用 `\n` 拼接）
- 忽略 SSE 注释行（以 `:` 开头，如 DeepSeek 的 `: keep-alive`）
- 输出 `({String? event, String data})` 元组流，供各协议层解析器消费

**与 §9.3 SseParser 的关系**：
- §9.3 `SseParser`：OpenAI 兼容协议专用 SSE 解析器，输出 `SseEvent` 结构化事件（解析 `choices[0].delta` 结构）
- §9.16 `RawSseChunkParser`：协议无关底层，输出 `(event, data)` 元组（不做协议特定解析）
- 多协议适配引入后，各协议适配器内部使用 RawSseChunkParser 切分事件块后自行解析协议格式（如 AnthropicAdapter 解析 6 事件 + 4 delta 状态机、GeminiAdapter 解析 `candidates[0].content.parts` 数组）

**注释忽略场景**：DeepSeek 流式响应的 `: keep-alive` 注释会被 RawSseChunkParser 忽略，不影响各协议层解析。

详见 DOC-12 §6.1。

---

### 9.17 ThinkingParamBuilder（思考参数统一构建器，v3.2 新增）

> **v3.2 新增**（DOC-12 v1.3 同步）：思考参数统一构建器——按 modelId 路由到 6 套厂商原生适配（OpenAI/DeepSeek/Qwen3/GLM/Kimi/OpenRouter），输出可直接合并到 OpenAI 兼容请求体的参数 Map。Simple 模式和故事模式共用本类。

**所属模块**: Core（网络层 LLM 适配基础设施）
**版本**: v3.2（DOC-12 v1.3 同步）
**职责**: 统一构建思考/推理参数，避免各适配器/控制器重复实现厂商适配逻辑
**接口定义位置**: `core/network/llm_adapters/thinking_param_builder.dart`

```dart
class ThinkingParamBuilder {
  ThinkingParamBuilder._();

  /// 构建思考参数 Map，可直接合并到 OpenAI 兼容请求体
  ///
  /// 返回空 Map 表示不发送任何思考参数。
  ///
  /// 参数：
  /// - [modelId]：模型 ID（用于厂商路由）
  /// - [reasoningEffort]：用户配置的思考档位
  ///   - null（未配置/跟随全局）：不发参数，跟随模型默认行为
  ///   - disabled（显式禁用）：发送厂商原生关闭参数，强制关闭思考
  ///   - low/medium/high：按 modelId 适配原生参数
  /// - [providerOptions]：协议特有参数透传（含 thinking/reasoning 时生效，
  ///   但被 disabled 覆盖）
  /// - [baseUrl]：API 基础地址（可选，用于检测 OpenRouter 聚合层）
  static Map<String, dynamic> build({
    required String modelId,
    required ReasoningEffort? reasoningEffort,
    Map<String, dynamic>? providerOptions,
    String baseUrl = '',
  });
}
```

**优先级**（从高到低，2026-07-28 修订）：
1. `reasoningEffort == disabled`（显式禁用）→ 按 modelId 路由发送**显式关闭参数**，优先级最高，覆盖 providerOptions 透传
2. `providerOptions.thinking` 或 `providerOptions.reasoning` 存在 → 直接透传（仅在用户未显式禁用时生效）
3. `reasoningEffort` 启用（非 null 非 disabled）→ 按 modelId 适配原生参数
4. `reasoningEffort == null`（未配置）→ 返回空 Map（跟随模型默认行为）

> **disabled vs null 语义差异**（2026-07-28 新增）：
> - `null`（未配置/跟随全局）→ 不发参数，跟随模型默认行为（对思考模型通常为开启思考）
> - `disabled`（显式禁用）→ 发送厂商原生关闭参数，强制关闭思考
> - 不支持关闭的纯思考模型（DeepSeek-R1、OpenAI o-series）选 disabled 时退化为不发参数

**厂商适配规则**：详见 DOC-12 §5.6.1 速查表。

**调用方**：
- `OpenAiAdapter.buildRequestBody`：故事模式所有 LLM 请求
- `ChatModeController._buildRequestBody`：Simple 模式聊天请求

详见 DOC-12 §5.6.1。

---

### 9.18 ModelCapabilityInferrer（模型能力兜底推断器，v3.2 新增）

> **v3.2 新增**（DOC-12 v1.3 同步）：基于 modelId 模式匹配的 reasoning 能力兜底推断器——解决 DeepSeek/智谱/Qwen3/Kimi 等供应商 `/v1/models` 响应无 reasoning 字段导致能力永远推断不出的问题。

**所属模块**: Core（模型注册表基础设施）
**版本**: v3.2（DOC-12 v1.3 同步）
**职责**: 基于 modelId 关键词模式匹配，对主流厂商思考模型做 reasoning 能力兜底推断
**接口定义位置**: `core/model_registry/model_capability_inferrer.dart`

```dart
class ModelCapabilityInferrer {
  ModelCapabilityInferrer._();

  /// 推断 modelId 是否支持 reasoning/thinking 能力
  ///
  /// 匹配规则：modelId 转小写后包含任一关键词即认为支持 reasoning。
  /// 调用方应在查 preset.cachedModels.capabilities 失败后调用本类作为兜底。
  static bool infersReasoning(String modelId);
}
```

**覆盖范围**：OpenAI o-series / DeepSeek R1+V3.1+/V4 / Qwen3 / GLM-4.6/4.5 / Kimi K2-thinking/K3 / Claude 3.7+/4.x / Gemini 2.5+/3 / 通用关键词兜底（`-reasoning` / `-thinking` / `-reasoner` / `-thinker`）。详见 DOC-12 §5.6.2 速查表。

**调用方**：
- `ConfigurationResolver.resolveModelDisplayInfo`：Simple 模式模型选择芯片显示
- `ApiPresetRepositoryImpl._inferModelFromApi`：从 `/v1/models` 拉取模型列表时自动标记

**维护**：新模型上线后，需在 `infersReasoning()` 方法中补充关键词。

详见 DOC-12 §5.6.2。

---

## 10. 错误码与异常映射

### 10.1 异常层次

```
LMStoryException (abstract)
├── NetworkException
│   ├── TimeoutException (E101)
│   ├── ConnectionException (E102)
│   ├── ApiException (E103)
│   ├── EmbeddingRateLimitedException (E104)
│   └── ToolCallTimeoutException (E105)
├── DatabaseException
│   ├── QueryException (E301)
│   └── MigrationException (E302)
├── BusinessException
│   ├── SessionNotFoundException (E001)
│   ├── InvalidConfigurationException (E002)
│   ├── ToolCallParseException (E003)
│   ├── CompactionFailedException (E004)
│   ├── CompactionPointCorruptedException (E005)
│   ├── ContextWindowExceededException (E006)
│   └── ModelNotFoundException (E007)
└── AuthException
    └── InvalidApiKeyException (E201)
```

> **v0.2 实现差异**：
> - `EmbeddingRateLimitedException` (E104)：已实现于 `lib/core/exceptions/app_exceptions.dart`，继承 `AppException`
> - `ApiException` (E103)：**v0.2 不新建**，由现有 `AppHttpException`（`lib/core/network/http_client.dart`）承担 API 错误处理。`AppHttpException` 含 `statusCode` 字段，可区分各类 HTTP 错误。后续若需统一异常层次，v0.3 评审时再决定是否迁移。
> - `TimeoutException` (E101) / `ConnectionException` (E102)：v0.1/v0.2 复用 `dart:async.TimeoutException` + `AppHttpException(code: 'connection_error')`，未新建独立类

### 10.2 接口→异常映射表

| 接口方法 | 可能抛出的异常 | 处理策略 |
|---------|--------------|---------|
| `ChatRepository.getSession` | SessionNotFoundException (E001) | 引导用户返回列表 |
| `ChatRepository.updateSession` | SessionNotFoundException (E001) | 刷新列表 |
| `ChatRepository.deleteSession` | QueryException (E301) | 提示重试 |
| `ChatRepository.streamChat` | InvalidApiKeyException (E201), TimeoutException (E101), ConnectionException (E102), ApiException (E103) | 显示错误+重试按钮 |
| `ChatRepository.deleteCompactionPoint` | CompactionPointCorruptedException (E005) | 提示数据损坏 |
| `CompactionExecutor.execute` | CompactionFailedException (E004), ContextWindowExceededException (E006) | 跳过压缩继续发送 / 提示手动压缩 |
| `MemoryRepository.getByMemoryId` | ModelNotFoundException (E007) | 检查 memoryId |
| `MemoryRepository.hybridSearch` | QueryException (E301) | 降级为空结果 |
| `MemoryRepository.upsertFacts` | QueryException (E301) | 提示重试 |
| `MemoryRepository.appendEvent` | QueryException (E301) | 提示重试 |
| `ConsolidationUseCase.execute` | ApiException (E103) | 保留不折叠，下次重试 |
| `ApiPresetRepository.getPreset` | ModelNotFoundException (E007) | 刷新预设列表 |
| `ApiPresetRepository.deletePreset` | InvalidConfigurationException (E002) | 提示内置不可删 |
| `ApiPresetRepository.fetchModels` | ConnectionException (E102), ApiException (E103), InvalidApiKeyException (E201) | 显示错误+引导设置 |
| `TemplateRepository.getTemplate` | ModelNotFoundException (E007) | 刷新模板列表 |
| `TemplateRepository.updateTemplate` | InvalidConfigurationException (E002) | 提示内置不可改 |
| `TemplateRepository.deleteTemplate` | InvalidConfigurationException (E002) | 提示内置不可删 |
| `UpdateWorldUseCase.execute` | ToolCallParseException (E003) | 跳过该 Tool Call |
| `EmbeddingService.embed` | EmbeddingRateLimitedException (E104), ApiException (E103) | 3次指数退避重试 |
| `LlmService.generate` | InvalidApiKeyException (E201), TimeoutException (E101), ApiException (E103) | 降级处理或提示重试 |
| `EmbeddingQueue` (内部) | EmbeddingRateLimitedException (E104) | 3次指数退避重试，失败标记 has_embedding=false |
| `LlmAdapterFactory.getAdapter` | UnimplementedError | 仅 openaiResponses 协议抛此异常（v0.3+ 落地）。其余 3 个协议返回单例适配器实例（v3.1 新增） |

---

## 11. 性能要求

| 接口 | 性能指标 | 要求 |
|------|---------|------|
| `getSessionInfoList` | 列表加载时间 | < 100ms（100 个会话） |
| `getMessages` | 消息加载时间 | < 200ms（1000 条消息） |
| `ContextBuilder.buildSimpleContext` | 上下文构建时间 | < 50ms |
| `hybridSearch` | 混合检索时间 | < 500ms（Isolate 内执行） |
| `upsertFacts` | 单次 upsert | < 10ms |
| `appendEvent` | 单次追加 | < 10ms |
| `estimateTokens` | Token 估算 | L1 命中 < 1ms，L2 命中 < 5ms，未命中 < 50ms |
| `streamChat` | 首 token 延迟 | 依赖网络，无本地阻塞 |

---

## 12. 安全限制

| 接口 | 限制 | 说明 |
|------|------|------|
| `SettingsRepository.saveApiKey` | 加密存储 | flutter_secure_storage，平台 Keychain/Keystore |
| `SettingsRepository.getApiKey` | 不缓存 | 每次请求时动态读取，不在内存中长期持有 |
| `ChatRepository.streamChat` | HTTPS 强制 | 所有 API 请求强制 HTTPS |
| `DioClient` / `HttpClient` | 日志脱敏 | 禁止记录 API Key、Authorization Header |
| `ChatRepository.exportSession` | 本地导出 | 不上传到任何服务器 |
| `ChatRepository.importSession` | 输入校验 | 校验 JSON 结构和字段类型，防止注入 |
| `MemoryRepository` (全部) | 会话隔离 | 所有查询必须带 sessionId，禁止跨会话访问 |
| `ApiPresetRepository.updatePreset` | 覆盖式更新（v1.8+） | 内置预设直接 UPDATE 原行（Fork-on-Write 已废弃，详见 DOC-05-6 §6.3）；提供重置功能从 ProviderTemplates 恢复默认值 |
| `TemplateRepository.updateTemplate` | 内置保护 | 内置模板不可修改/删除，抛出 InvalidConfigurationException |
| `ApiPresetRepository.deletePreset` | 内置保护 | 内置预设不可删除，抛出 InvalidConfigurationException |
| `EmbeddingService.embed` | 限流保护 | 遇到 429 自动指数退避重试（最多 3 次） |
| `LlmAdapterFactory.getAdapter` | 协议分发 | openaiResponses 协议抛 UnimplementedError，避免误用未实现适配器（v0.3+ 落地，v3.1 新增） |

---

## 13. 变更记录

| 版本 | 日期 | 变更内容 |
|------|------|---------|
| 1.0 | 2026-06-12 | 初稿：定义全部 Repository 接口、UseCase、Core 层接口 |
| 1.1 | 2026-06-13 | 修订：新增 Chat 内部组件接口（2.4）、MemoryRepository.getById、UpdateWorldUseCase 改用 UpdateWorldInput、HttpClient 双引擎架构、AssembledMessage 替代 ChatCompletionMessage、StatePatchParser、ConsolidationUseCase（从 MemoryRepository 移出 consolidate）、activatePreset、generateMemorySummary、Core 层补全（Preferences/ToolCallAccumulator/EmbeddingRemoteDS/VectorEngine）、AppConfig 实体定义、ScoredMemory 差异注释 |
| 1.2 | 2026-06-13 | 评审修订：新增 Section 2 共享类型定义（ChatMode/MessageUsage/ChatSessionInfo/FactualUpdate/UpdateWorldInput/AssembledMessage/ConsolidationResult/VectorSearchResult/Cancellable/FactualMemoryChangeEvent/extractNarrativePeriod/AppConfig）；UpdateWorldUseCase 移至 Memory 模块、改用领域事件替代 HudController 调用、新增 minImportance 参数；PromptAssembler 移除 ChatRepository 依赖改为参数传入 dialogueHistory；EmbeddingQueue 改依赖 EmbeddingService 抽象；新增 EmbeddingService/LlmService Domain 层抽象接口；VectorEngine.batchSearch 返回 VectorSearchResult；StatePatchParser 移至 Memory 模块；MemoryRepository 统一使用 memoryId 替代 dbId、hybridSearch 新增 currentTurnNumber/queryNarrativePeriod/scoreThreshold 参数、appendEvent 移除 minImportance 过滤改为非空返回；ChatRepository 移出 compactContext/needsCompaction/buildSimpleContext 至内部组件、新增 createCompactionPoint；ConsolidationUseCase 新增 LlmService 依赖、返回 ConsolidationResult；DioClient/HttpClient 统一使用 Cancellable；SettingsRepository 移除 loadDefaultConfig；依赖关系图补全；AppConfig 移至共享类型定义；HUD 模块说明 |
| 1.3 | 2026-06-13 | 评审修订：新增 Section 2.3 Domain 实体定义（Message/ChatSession/ChatSessionSettings/ResolvedChatSessionSettings/BranchInfo/CompactionPoint/FactualMemory/ExperientialMemory/ToolCall/ApiPreset/ModelInfo/Template）；MessageRole 新增 tool 角色；LlmService 明确为共享 Domain 抽象（core/domain/services/）；ExperientialMemory 新增 memoryId 字段（UUID 业务 ID）+ DOC-04 对齐说明；使用示例修复 appendEvent 返回值捕获 memoryId；异常映射表从 8 行扩展至 21 行覆盖全部接口；安全限制表从 6 行扩展至 11 行（新增 importSession 输入校验、内置保护、限流保护） |
| 1.4 | 2026-06-13 | 评审修订：Message 新增 toolCallId/toolCallName/toolCallArguments 字段（SSE Tool Call 场景）；ModelInfo 新增 contextWindow 字段；新增 AppError 类型定义（StreamErrorEvent 引用）；全部接口方法补全异常标注（ChatRepository 21 个方法、MemoryRepository 13 个方法、SettingsRepository 7 个方法、ApiPresetRepository 8 个方法、TemplateRepository 7 个方法）；跨文档同步说明（DOC-02/03/04 旧设计以 DOC-05 为准） |
| 1.5 | 2026-06-13 | 评审修订：Message 实体对齐 DB Schema（content 改可空、toolCallName+toolCallArguments→toolCalls JSON数组、toolCallId 保留）；ChatSession 新增 lastActiveAt+messageCount、移除 updatedAt（对齐 DB Schema）；BranchInfo totalBranches→branchCount（对齐 DB Schema）；ExperientialMemory 新增 archivedEventIds 字段（对齐 DB Schema）；使用示例修复事务管理（Embedding 入队移至事务外）；对齐说明从 DOC-04 改为 DOC-02 DB Schema |
| 1.6 | 2026-06-13 | 评审修订：确认并修复 ChatSession/BranchInfo/ExperientialMemory 实体定义（v1.5 声明的修改未实际生效）；LlmService 版本标注改为 v0.1 起可用（SummaryGenerator v0.1 即依赖）；依赖关系图修正（ChatRepository 移除 SettingsRepository/ApiPresetRepository/TemplateRepository 依赖，新增 ContextBuilder→ChatRepository）；BranchInfo 新增 sessionId+createdAt 字段；AppError 新增 recoverable 字段；Message.usage 标注非持久化；ModelInfo 新增 supportsStreaming/supportsToolCall；PromptAssembler 补充异常标注（内部捕获降级）；ChatRepository.streamChat 新增 Cancellable 参数；Core 层新增 EventBus 接口 |
| 2.1 | 2026-06-16 | ChatBox 功能移植更新：ChatSession 新增 isStarred/maxContextMessages 字段；ChatRepository 新增 copySession/deleteAllSessions 方法；CompactionService 新增 manualCompact 方法；新增 DisplayPreferences 实体和 SendKeyMode 枚举；ChatModeState 新增 inputHistory/compactionStatus 字段；duplicateSession 改为 copySession 实现 |
| 2.2 | 2026-06-17 | 新功能更新：ChatSession 新增 sortOrder 字段；ChatRepository 新增 updateSessionSortOrders/searchMessages 方法；新增 MessageLayoutMode 枚举、ToolCallData 实体、SearchResult 实体；DisplayPreferences 新增 messageLayoutMode 字段；ChatModeState 新增 sentinel 模式说明 |
| 2.3 | 2026-06-20 | 文档-代码一致性同步：updateSessionSortOrders 参数类型由 `List<({String sessionId, double sortOrder})>` 修正为实际实现的 `Map<String, double>`；activatePreset 重命名为 setDefaultPreset（语义对齐 DOC-06：供应商无"激活/选择"概念，仅记录新对话默认填充值），同步更新方法注释 |
| 2.4 | 2026-06-22 | 消息元信息显示更新（对标 ChatBox tips 数组）：新增 SseUsage 类（字段均可空，含 fromJson 工厂构造）；ChatMessage 新增 error/tokensUsed/firstTokenLatency/modelName 字段；DisplayPreferences 新增 showTokenUsed/showWordCount/showFirstTokenLatency 三个开关；StreamEndEvent.usage 类型从 MessageUsage? 改为 SseUsage?；onStreamEnd 回调签名更新为 SseUsage? |
| 2.5 | 2026-06-28 | 数据管理功能扩展：ChatRepository 新增 scanOrphanMessages/getTotalMessageCount；SettingsRepository 新增 clearAllUserOverrides/getUserOverrideCount；ApiPresetRepository 新增 deleteAllCustomPresets/getCustomPresetCount；新增 8.1 DataManagementService（Domain 层服务）章节，原 8.1-8.7 顺延为 8.2-8.8 |
| 2.6 | 2026-06-30 | 中级模式设计文档体系评审同步：ChatMode 枚举新增 intermediate；ChatSession.mode 注释补 intermediate；§2.3 新增中级模式实体（IntermediatePhase 枚举/EventSummary/FailureContext/IntermediateChatState，phase 用枚举替代 String）；§3.5 新增 ChatRemoteDS（Data 层抽象，含 tools 参数）+ ToolDefinition；§3.6 新增 IntermediateChatController 登记；§4 MemoryRepository 标注为 v0.3 Advanced 超集，appendEvent 重命名为 appendExperience（命名权威基准）；§4.5 新增 ExperienceRepository（v0.2 中级专用，含 searchExperiences 两路/appendExperience/getRecentExperiences/updateEmbedding/insertFtsIndex/deleteAllExperiences）；§9.12 VectorEngine 标注 v0.2 主方案改为 sqlite-vec SQL KNN，batchSearch 降级为回退方案 |
| 3.0 | 2026-06-30 | 文档拆分：原 DOC-05（2841 行）拆分为 DOC-05-1 ~ DOC-05-8，本文档（05-8）包含原 §9-13。原节号保持不变 |
| 3.1 | 2026-07-24 | DOC-12 v1.1 同步——多协议适配层：<br/>(1) §9.3 SseParser 新增 v3.1 关系说明（与 §9.16 RawSseChunkParser 分层关系）<br/>(2) 新增 §9.14 LlmProtocolAdapter 抽象接口（6 方法：buildUrl/buildHeaders/buildRequestBody/parseStream/parseResponse/buildModelsUrl）+ 3 个已实现适配器清单（OpenAiAdapter/AnthropicAdapter/GeminiAdapter）+ OpenAiResponsesAdapter 推迟 v0.3+<br/>(3) 新增 §9.15 LlmAdapterFactory 工厂类（单例语义，按 LlmProtocol 分发，openaiResponses 抛 UnimplementedError）<br/>(4) 新增 §9.16 RawSseChunkParser 共享底层（按双换行切分事件块、跨 chunk 拼接、注释忽略）<br/>(5) §10.2 异常映射表新增 LlmAdapterFactory.getAdapter → UnimplementedError 条目<br/>(6) §12 安全限制新增 LlmAdapterFactory.getAdapter 协议分发条目。详见 DOC-12 v1.1 |
