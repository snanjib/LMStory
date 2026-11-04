// clang-format off
// coverage:ignore-file
// part of IntermediateChatController，仅拆分用途，不引入新逻辑。
// 详见 intermediate_chat_controller.dart 顶部说明。
//
//  拆分：extension 不是 StateNotifier 子类，访问 `state`
// 触发 invalid_use_of_protected_member / invalid_use_of_visible_for_testing_member。
// 这是 part + extension 拆分方案的固有约束，运行无误，文件级忽略。
// ignore_for_file: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member

part of 'advanced_chat_controller.dart';

/// 拆分到本 part 文件的 embedding 辅助方法（拆分）
///
/// 通过 extension 机制让方法仍属于 [AdvancedChatController] 类成员，
/// 可访问主文件中的私有字段（_round / _embeddingService / _logger / state 等）。
extension AdvancedChatControllerEmbeddings on AdvancedChatController {
  // ==================== Embedding 辅助（V1 语义检索）====================

  /// 解析检索查询的向量（V1 启用语义检索）
  ///
  /// 未配置 embedding（[EmbeddingApiConfig] 为 null）→ 返回 null → FTS5 兜底。
  /// 配置完整 → 调用 [EmbeddingService.embed] 生成查询向量。
  /// 调用失败 + [EmbeddingApiConfig.fallbackOnFailure]=true → 返回 null（降级 FTS5）。
  /// 调用失败 + fallbackOnFailure=false → 抛 [EmbeddingCallFailedException]
  /// （[EmbeddingRateLimitedException] 直接 rethrow），由失败分类器归为 E104，
  /// 触发 FailureBar 显示，用户可选重试/临时降级/中止。
  ///
  /// 2026-07-21：新增 [AdvancedChatState.embeddingDegradedForRound] 检查，
  /// 当用户在 E104 错误后选择"临时降级继续"时，本轮后续调用直接返回 null。
  Future<Float32List?> _resolveQueryVector(String queryText) async {
    final cfg = _round?.embeddingConfig;
    if (cfg == null) return null;
    // 2026-07-21：本轮临时降级模式（用户在 E104 错误时选择"临时降级继续"）
    // 跳过 embedding 调用，避免再次失败中断
    if (state.embeddingDegradedForRound) return null;
    try {
      return await _embeddingService.embed(
        text: queryText,
        // 检索查询侧（非对称模型注入 input_type=query）
        kind: EmbeddingInputKind.query,
        model: cfg.model,
        baseUrl: cfg.baseUrl,
        apiKey: cfg.apiKey,
        timeout: Duration(milliseconds: cfg.timeoutMs),
      );
    } catch (e) {
      if (cfg.fallbackOnFailure) {
        // 旧行为：静默降级（仅高级用户主动配置 fallback_on_failure=true 时生效）
        _logger.warn(
          'Query embedding failed, falling back to FTS5 only',
          detail: '$e',
        );
        return null;
      }
      // 新行为：包装为 EmbeddingCallFailedException 抛出，触发 E104 错误处理流程
      if (e is EmbeddingRateLimitedException ||
          e is EmbeddingCallFailedException) {
        rethrow;
      }
      throw EmbeddingCallFailedException(e.toString());
    }
  }

  /// 构造 embedding 输入文本（v0.2 Phase C 方案二，2026-07-19 新增）
  ///
  /// 从 [EventSummary] 拼接 5W1E 6 字段 + summary 兜底，生成 embedding 输入文本。
  /// 策略：
  /// 1. summary 非空时作为首行（保留向后兼容的概括信息）
  /// 2. 5W1E 字段非空时按「中文标签: 值」格式追加，提供清晰语义结构
  /// 3. 全部为空时返回 [EventSummary.displayText] 兜底（避免空字符串 embedding 报错）
  ///
  /// 与 [ExperienceRepositoryImpl.insertFtsIndex] 的 FTS5 索引内容对应：
  /// FTS5 索引 7 个字段（summary + 5W1E 6 字段），embedding 拼接同样 7 个字段，
  /// 保证关键词检索与向量检索的输入空间一致。
  String _buildEmbeddingText(EventSummary eventSummary) {
    final lines = <String>[];
    if (eventSummary.summary != null && eventSummary.summary!.isNotEmpty) {
      lines.add(eventSummary.summary!);
    }
    if (eventSummary.when != null && eventSummary.when!.isNotEmpty) {
      lines.add('时间: ${eventSummary.when}');
    }
    if (eventSummary.where != null && eventSummary.where!.isNotEmpty) {
      lines.add('地点: ${eventSummary.where}');
    }
    if (eventSummary.who != null && eventSummary.who!.isNotEmpty) {
      lines.add('人物: ${eventSummary.who}');
    }
    if (eventSummary.what != null && eventSummary.what!.isNotEmpty) {
      lines.add('事件: ${eventSummary.what}');
    }
    if (eventSummary.significance != null &&
        eventSummary.significance!.isNotEmpty) {
      lines.add('意义: ${eventSummary.significance}');
    }
    if (eventSummary.extra != null && eventSummary.extra!.isNotEmpty) {
      lines.add('补充: ${eventSummary.extra}');
    }
    if (lines.isEmpty) {
      return eventSummary.displayText;
    }
    return lines.join('\n');
  }

  /// 解析事件摘要的向量（V1 启用语义检索，写入时同步生成）
  ///
  /// 未配置 embedding → 返回 null → has_embedding=false（FTS5 兜底）。
  /// 配置完整 → 调用 [EmbeddingService.embed] 生成摘要向量，供后续语义检索。
  /// 失败降级行为同 [_resolveQueryVector]。
  ///
  /// 2026-07-21：新增 embeddingDegradedForRound 检查，
  /// 当用户在 E104 错误后选择"临时降级继续"时，本轮 persisting 阶段也跳过
  /// embedding 调用，has_embedding=false（后续可通过"重建向量索引"补全）。
  Future<Float32List?> _resolveEmbedding(String summary) async {
    final cfg = _round?.embeddingConfig;
    if (cfg == null) return null;
    // 2026-07-21：本轮临时降级模式，跳过 embedding 调用
    if (state.embeddingDegradedForRound) return null;
    try {
      return await _embeddingService.embed(
        text: summary,
        // 入库文本侧（非对称模型注入 input_type=passage）。
        // 本 helper 仅服务 persist 阶段的事件摘要向量化。
        kind: EmbeddingInputKind.passage,
        model: cfg.model,
        baseUrl: cfg.baseUrl,
        apiKey: cfg.apiKey,
        timeout: Duration(milliseconds: cfg.timeoutMs),
      );
    } catch (e) {
      if (cfg.fallbackOnFailure) {
        _logger.warn(
          'Event embedding failed, has_embedding=false',
          detail: '$e',
        );
        return null;
      }
      if (e is EmbeddingRateLimitedException ||
          e is EmbeddingCallFailedException) {
        rethrow;
      }
      throw EmbeddingCallFailedException(e.toString());
    }
  }

  /// 手动压缩宏摘要向量化
  ///
  /// 手动压缩发生在轮次之外（[_round] 为 null），persist 阶段的
  /// [_resolveEmbedding]（读 _round.embeddingConfig）不可用——此处走
  /// advanced 段配置解析。未配置 → null（has_embedding=false）；失败一律
  /// 降级 null + warn，不阻断压缩落库（FTS5 兜底，重建向量索引可补）。
  Future<Float32List?> _resolveManualMacroEmbedding(String text) async {
    try {
      final config =
          await _configurationResolver.resolveAdvancedEmbeddingConfig();
      if (config == null) return null;
      return await _embeddingService.embed(
        text: text,
        // 入库文本侧（非对称模型注入 input_type=passage）
        kind: EmbeddingInputKind.passage,
        model: config.model,
        baseUrl: config.baseUrl,
        apiKey: config.apiKey,
        timeout: Duration(milliseconds: config.timeoutMs),
      );
    } catch (e) {
      _logger.warn(
        'Manual compaction macro embedding failed, degrade to null',
        detail: '$e',
      );
      return null;
    }
  }
}
