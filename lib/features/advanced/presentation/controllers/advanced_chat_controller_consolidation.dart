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

/// 拆分到本 part 文件的批量记忆提炼方法（拆分）
///
/// 通过 extension 机制让方法仍属于 [AdvancedChatController] 类成员，
/// 可访问主文件中的私有字段（_logger / _experienceRepository / state 等）。
extension AdvancedChatControllerConsolidation on AdvancedChatController {
  // ==================== 批量记忆提炼====================

  /// 条件触发批量记忆提炼
  ///
  /// 在 persisting 成功后异步调用（不阻塞 UI）。判断流程：
  /// 1. 估算上下文 token 占用率（messages 总 token / 可用窗口）
  /// 2. 占用率 <= [ConsolidationConfig.triggerThreshold] → 跳过
  /// 3. 查询未索引的低重要性记忆（importance < microVectorizeThreshold）
  /// 4. 未索引记忆数 >= [ConsolidationConfig.minArtifactsToConsolidate] →
  ///    调用 [_runConsolidation] 合并
  ///
  /// 设计依据：DOC-09A §4（批量提炼流程）、DOC-09B §10（配置参数）。
  Future<void> _maybeConsolidateMemories({
    required int contextWindow,
    required int maxTokens,
    required ConsolidationConfig consolidationConfig,
    required NamingConfig namingConfig,
    required EmbeddingApiConfig? embeddingConfig,
    required String consolidationPrompt,
  }) async {
    try {
      // 1. 估算上下文 token 占用率
      final budget = contextWindow - maxTokens;
      if (budget <= 0) return; // 配置异常，跳过
      final messageContents =
          state.messages.map((m) => m.content ?? '').toList(growable: false);
      final totalTokens =
          await _tokenCounter.countTokensForMessages(messageContents);
      final usageRatio = totalTokens / budget;

      if (usageRatio <= consolidationConfig.triggerThreshold) return;

      // 2. 查询未索引的低重要性记忆（按时间升序，最多 maxArtifactsToConsolidate 条）
      final unindexed = await _experienceRepository.getUnindexedExperiences(
        state.session.sessionId,
        limit: consolidationConfig.maxArtifactsToConsolidate,
      );
      if (unindexed.length < consolidationConfig.minArtifactsToConsolidate) {
        return; // 未索引记忆不足，不值得一次 LLM 调用
      }

      _logger.info(
        'Memory consolidation triggered',
        detail: 'usageRatio=${usageRatio.toStringAsFixed(2)} '
            'unindexedCount=${unindexed.length}',
      );

      await _runConsolidation(
        unindexed: unindexed,
        namingConfig: namingConfig,
        embeddingConfig: embeddingConfig,
        consolidationPrompt: consolidationPrompt,
      );
    } catch (e, stackTrace) {
      // 提炼失败不影响会话主流程，仅记日志
      _logger.warn(
        'Memory consolidation failed',
        detail: '$e\n$stackTrace',
      );
    }
  }

  /// 执行批量记忆提炼：调用 LLM 合并 → 持久化合并记忆 → 删除原始记忆。
  ///
  /// 流程：
  /// 1. 调用 [MemoryConsolidator.consolidate] 让 LLM 合并未索引记忆
  /// 2. 为每条合并记忆分配 turnNumber（取原始记忆最大 turnNumber）+ embedding
  /// 3. 调用 [StoryPersistenceService.persistConsolidatedMemories]
  ///    事务写入合并记忆 + 删除原始记忆
  /// 4. LLM 返回空列表 → 跳过持久化（无可合并内容）
  Future<void> _runConsolidation({
    required List<ExperientialMemory> unindexed,
    required NamingConfig namingConfig,
    required EmbeddingApiConfig? embeddingConfig,
    required String consolidationPrompt,
  }) async {
    final originalIds = unindexed.map((m) => m.memoryId).toList();
    final maxTurnNumber =
        unindexed.map((m) => m.turnNumber).reduce((a, b) => a > b ? a : b);

    final consolidated = await _consolidator!.consolidate(
      memories: unindexed,
      namingConfig: namingConfig,
      consolidationPrompt: consolidationPrompt,
    );

    if (consolidated.isEmpty) {
      _logger.info('Memory consolidation produced no results');
      return;
    }

    // 为每条合并记忆生成 embedding（若配置可用）+ 分配 turnNumber
    final records = <ConsolidatedMemoryRecord>[];
    for (final c in consolidated) {
      Float32List? embedding;
      if (embeddingConfig != null) {
        try {
          embedding = await _embeddingService.embed(
            text: c.summary,
            // 合并记忆入库是文本侧（非对称模型注入 input_type=passage）
            kind: EmbeddingInputKind.passage,
            model: embeddingConfig.model,
            baseUrl: embeddingConfig.baseUrl,
            apiKey: embeddingConfig.apiKey,
            timeout: Duration(milliseconds: embeddingConfig.timeoutMs),
          );
        } catch (e) {
          // embedding 失败降级（has_embedding=false，FTS5 兜底）
          _logger.warn(
            'Consolidated memory embedding failed, FTS5 fallback',
            detail: '$e',
          );
        }
      }
      records.add(
        ConsolidatedMemoryRecord(
          summary: c.summary,
          tags: c.tags,
          importance: c.importance,
          turnNumber: maxTurnNumber,
          embedding: embedding,
        ),
      );
    }

    await _persistenceService.persistConsolidatedMemories(
      sessionId: state.session.sessionId,
      records: records,
      originalMemoryIds: originalIds,
    );

    _logger.info(
      'Memory consolidation completed',
      detail: 'consolidated=${records.length} '
          'removed=${originalIds.length}',
    );
  }
}
