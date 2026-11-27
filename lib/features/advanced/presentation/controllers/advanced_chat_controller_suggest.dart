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

/// 拆分到本 part 文件的推荐回复（suggest_reply）方法（拆分）
///
/// 通过 extension 机制让方法仍属于 [AdvancedChatController] 类成员，
/// 可访问主文件中的私有字段（_suggestGenerator / _configurationResolver 等）。
extension AdvancedChatControllerSuggest on AdvancedChatController {
  // ==================== 推荐回复（suggest_reply，2026-07-29 新增）==========

  /// 生成推荐回复
  ///
  /// 点击输入框工具栏的"推荐回复"按钮时调用。基于当前剧情上下文调用 LLM
  /// 生成 3 条候选用户回复，气泡浮层展示供用户选择。
  ///
  /// **上下文采集**（省 token 设计）：
  /// - 最近 1 轮全文：最后一条 user 消息 + 最后一条 assistant 消息
  /// - 前 2 轮 micro 摘要：从 [ExperienceRepository.getRecentExperiences] 取
  ///   最近 2 条 micro 摘要（按 turn 降序）
  ///
  /// **配置优先级**（由 [ConfigurationResolver] 解析）：
  /// - 模型：会话级 suggestReplyPresetId/ModelId > 全局 suggest_reply 配置 >
  ///   generating 阶段模型 fallback
  /// - 提示词：会话级 suggestReplyPromptOverride > 全局 suggest_reply.prompt >
  ///   内置默认 kSuggestReplyDefaultPrompt
  ///
  /// **失败处理**：返回 false 时 UI 显示失败提示（不阻塞用户输入）。
  /// 成功返回 true，候选列表写入 [AdvancedChatState.suggestReplies]。
  ///
  /// **不阻塞原则**：生成期间用户仍可正常输入和发送消息。用户发送消息时
  /// [sendMessage] 会清空 suggestReplies，生成结果作废。
  Future<bool> generateSuggestReplies() async {
    // 守卫：生成中拒绝重复点击
    if (!mounted || state.isGeneratingSuggest) return false;

    // 守卫：无历史消息时无法生成（需要至少 1 轮对话作为上下文）
    if (state.messages.isEmpty) {
      return _suggestFailed(
        const AuxiliaryGenerationFailure(
          AuxiliaryGenerationFailureKind.noConversation,
        ),
      );
    }

    // 提取最近 1 轮 user + assistant 消息
    final lastUserMsg = state.messages.lastWhere(
      (m) => m.role == 'user',
      orElse: () => state.messages.last,
    );
    final lastAssistantMsg = state.messages.lastWhere(
      (m) => m.role == 'assistant',
      orElse: () => state.messages.last,
    );
    final lastUserContent = lastUserMsg.content?.trim() ?? '';
    final lastAssistantContent = lastAssistantMsg.content?.trim() ?? '';
    if (lastUserContent.isEmpty || lastAssistantContent.isEmpty) {
      return _suggestFailed(
        const AuxiliaryGenerationFailure(
          AuxiliaryGenerationFailureKind.noConversation,
        ),
      );
    }

    final generation = ++_suggestGeneration;
    bool isCurrent() =>
        mounted &&
        state.isGeneratingSuggest &&
        generation == _suggestGeneration;

    // 置生成中状态（清空旧候选，避免 UI 显示过期数据）
    state = state.copyWith(
      isGeneratingSuggest: true,
      suggestReplies: [],
      suggestExpanded: false,
      suggestFailure: null,
    );

    try {
      // 1. 解析模型配置（会话级 > advanced.suggest_reply > 导演 GM fallback；
      //    2026-08-29 审查 ：改读 advanced 段，不再寄生 intermediate 键）
      final namingConfig = await _configurationResolver
          .resolveAdvancedSuggestReplyNamingConfig(state.session);
      // 竞态检查：用户可能在 await 期间发送了消息（sendMessage 会置
      // isGeneratingSuggest=false），此时应放弃生成结果。
      if (!isCurrent()) return false;

      if (namingConfig == null) {
        return _suggestFailed(
          const AuxiliaryGenerationFailure(
            AuxiliaryGenerationFailureKind.modelOrKeyUnavailable,
          ),
        );
      }

      // 2. 解析提示词（会话级 > advanced.suggest_reply.prompt > 内置默认）
      final systemPrompt =
          await _configurationResolver.resolveAdvancedSuggestReplyPrompt(
        state.session,
      );
      if (!isCurrent()) return false;

      // 3. 读取生成参数（温度 / maxTokens / candidateCount / maxReplyLength）
      final config = await _getConfig();
      if (!isCurrent()) return false;
      final suggestConfig = config.suggestReply;

      // 4. 采集前 2 轮 micro 摘要（按 turn 降序取最近 2 条）
      final recentExperiences =
          await _experienceRepository.getRecentExperiences(
        state.session.sessionId,
        limit: 5, // 多取几条过滤 macro 后取 2 条
      );
      if (!isCurrent()) return false;
      final microSummaries = recentExperiences
          .where((e) => e.memoryLevel == MemoryLevel.micro)
          .take(2)
          .map((e) => e.summary ?? '')
          .where((s) => s.isNotEmpty)
          .toList()
          // 反转为时间升序（旧 → 新），便于 LLM 理解剧情流
          .reversed
          .toList();

      // 5. 调用 LLM 生成候选回复
      // 用户 network.* 超时透传
      final timeouts = await _configurationResolver.resolveTimeouts();
      if (!isCurrent()) return false;
      final result = await _suggestGenerator.generateWithResult(
        namingConfig: namingConfig,
        systemPrompt: systemPrompt,
        lastUserMessage: lastUserContent,
        lastAssistantReply: lastAssistantContent,
        prevSummaries: microSummaries,
        temperature: suggestConfig.temperature,
        maxTokens: suggestConfig.maxTokens,
        candidateCount: suggestConfig.candidateCount,
        maxReplyLength: suggestConfig.maxReplyLength,
        connectTimeout: timeouts.connectTimeout,
        readTimeout: timeouts.readTimeout,
      );
      // 竞态检查：LLM 响应返回前用户可能已发送消息
      if (!isCurrent()) return false;

      if (result.failure case final failure?) {
        return _suggestFailed(failure);
      }

      // 6. 写入 state，展开气泡
      state = state.copyWith(
        isGeneratingSuggest: false,
        suggestReplies: result.value ?? const [],
        suggestExpanded: true,
        suggestFailure: null,
      );
      return true;
    } catch (e) {
      if (!isCurrent()) return false;
      return _suggestFailed(AuxiliaryGenerationFailure.fromException(e));
    }
  }

  bool _suggestFailed(AuxiliaryGenerationFailure failure) {
    state = state.copyWith(
      isGeneratingSuggest: false,
      suggestReplies: const [],
      suggestExpanded: false,
      suggestFailure: failure,
    );
    return false;
  }

  /// 选择某条候选回复
  ///
  /// 返回选中的回复文本，由 UI 层插入到输入框光标位置。
  /// **不清空** suggestReplies——用户可能想再次选择其他候选。
  /// 完全清空由 [closeSuggest] 或 [sendMessage] 负责。
  ///
  /// 参数 [index] 越界时返回 null。
  String? selectSuggestReply(int index) {
    if (index < 0 || index >= state.suggestReplies.length) return null;
    return state.suggestReplies[index];
  }

  /// 切换气泡展开/折叠状态
  ///
  /// 折叠态保留 [AdvancedChatState.suggestReplies] 数据，
  /// 用户可再次展开查看，避免重复生成浪费 token。
  void toggleSuggest() {
    if (state.suggestReplies.isEmpty) return;
    state = state.copyWith(suggestExpanded: !state.suggestExpanded);
  }

  /// 关闭气泡浮层（用户点击 × 按钮）
  ///
  /// 清空所有推荐回复状态（候选列表 + 展开标识）。
  /// 与 [toggleSuggest] 的差异：折叠保留数据可恢复，关闭完全清空。
  void closeSuggest() {
    state = state.copyWith(
      suggestReplies: [],
      isGeneratingSuggest: false,
      suggestExpanded: false,
      suggestFailure: null,
    );
  }
}
