import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/config/intermediate_config.dart';
import 'package:lmstory/core/config/intermediate_prompts.dart';
import 'package:lmstory/core/config/intermediate_prompts_v2.dart';
import 'package:lmstory/core/utils/token_counter.dart';
import 'package:lmstory/features/chat/domain/entities/chat_message.dart';
import 'package:lmstory/features/intermediate/domain/services/intermediate_context_builder.dart';
import 'package:lmstory/features/memory/domain/entities/experiential_memory.dart';
import 'package:lmstory/features/memory/domain/entities/scored_memory.dart';

/// IntermediateContextBuilder 单元测试（计划 §5）
///
/// 验证四步生成的消息组装顺序、token 预算缩减、
/// 系统提示词拼接、记忆格式化。
///
/// buildGenerateMessages / buildReviewMessages 新增 `prompts` 参数，
/// 测试统一传入 `const PromptsConfig()`（默认值 = intermediate_prompts.dart 常量）。
///
/// 使用 [_FakeTokenCounter] 按字符数估算 token，避免依赖 Isolate + tiktoken，
/// 使 token 预算测试可控。
void main() {
  late IntermediateContextBuilder builder;

  setUp(() {
    builder = IntermediateContextBuilder(
      tokenCounter: _FakeTokenCounter(),
    );
  });

  group('buildGenerateMessages', () {
    test('1. 消息顺序：[system] + [history...] + [user]', () async {
      final history = [
        _msg('u1', 'user', '你好'),
        _msg('a1', 'assistant', '你好，有什么可以帮你？'),
      ];

      final messages = await builder.buildGenerateMessages(
        userInput: '继续冒险',
        history: history,
        sessionSystemPrompt: '你是冒险向导',
        contextWindow: 100000,
        outputReserve: 100,
        prompts: const PromptsConfig(),
      );

      expect(messages.first['role'], 'system');
      expect(messages.last['role'], 'user');
      expect(messages.last['content'], '继续冒险');
      // 中间为 history（user, assistant 交替）
      expect(messages.length, 4); // system + 2 history + user
      expect(messages[1]['role'], 'user');
      expect(messages[2]['role'], 'assistant');
    });

    test('2. 无限制保留全部历史', () async {
      final history = [
        _msg('u1', 'user', '一'),
        _msg('a1', 'assistant', '二'),
        _msg('u2', 'user', '三'),
        _msg('a2', 'assistant', '四'),
      ];

      final messages = await builder.buildGenerateMessages(
        userInput: '五',
        history: history,
        sessionSystemPrompt: '向导',
        contextWindow: 100000,
        outputReserve: 100,
        prompts: const PromptsConfig(),
      );

      // 全部 history 保留：system + 4 history + user
      expect(messages.length, 6);
    });

    test('4. token 预算缩减 → 保底最近 4 条', () async {
      // 8 条超长历史，token 预算极小 → dialogueBudget 非正 → 保底 4 条
      final longContent = 'x' * 200;
      final history = [
        for (var i = 0; i < 8; i++)
          _msg('m$i', i.isEven ? 'user' : 'assistant', '$longContent$i'),
      ];

      final messages = await builder.buildGenerateMessages(
        userInput: '继续',
        history: history,
        sessionSystemPrompt: '向导',
        contextWindow: 300, // 极小预算，system prompt 已超
        outputReserve: 50,
        prompts: const PromptsConfig(),
      );

      // system + 4 history(保底) + user
      expect(messages.length, 6);
      // 保留的是最近 4 条（m4, m5, m6, m7）
      expect(messages[1]['content'], '${longContent}4');
      expect(messages[4]['content'], '${longContent}7');
    });

    test('5. sessionSystemPrompt 为空 → 用 kDefaultRolePrompt', () async {
      final messages = await builder.buildGenerateMessages(
        userInput: '你好',
        history: const [],
        sessionSystemPrompt: null,
        contextWindow: 100000,
        outputReserve: 100,
        prompts: const PromptsConfig(),
      );

      final systemContent = messages.first['content']!;
      expect(systemContent.startsWith(kDefaultRolePrompt), isTrue);
      // 拼接了草稿后缀
      expect(systemContent, contains(kDraftSuffixPrompt));
    });

    test('5b. sessionSystemPrompt 非空 → 拼接为前缀', () async {
      final messages = await builder.buildGenerateMessages(
        userInput: '你好',
        history: const [],
        sessionSystemPrompt: '自定义角色设定',
        contextWindow: 100000,
        outputReserve: 100,
        prompts: const PromptsConfig(),
      );

      final systemContent = messages.first['content']!;
      expect(systemContent.startsWith('自定义角色设定'), isTrue);
      expect(systemContent, contains(kDraftSuffixPrompt));
    });

    test('5c. P2.5 优先级：session > global > default', () async {
      // session 非空 → 用 session（即便 global 也非空）
      final m1 = await builder.buildGenerateMessages(
        userInput: 'x',
        history: const [],
        sessionSystemPrompt: '会话级',
        contextWindow: 100000,
        outputReserve: 100,
        prompts: const PromptsConfig(),
        globalSystemPrompt: '全局级',
      );
      expect(m1.first['content']!.startsWith('会话级'), isTrue);

      // session 为空、global 非空 → 用 global
      final m2 = await builder.buildGenerateMessages(
        userInput: 'x',
        history: const [],
        sessionSystemPrompt: null,
        contextWindow: 100000,
        outputReserve: 100,
        prompts: const PromptsConfig(),
        globalSystemPrompt: '全局级',
      );
      expect(m2.first['content']!.startsWith('全局级'), isTrue);
      expect(m2.first['content']!.contains(kDefaultRolePrompt), isFalse);

      // session 为空、global 为空（默认）→ 用 kDefaultRolePrompt
      final m3 = await builder.buildGenerateMessages(
        userInput: 'x',
        history: const [],
        sessionSystemPrompt: null,
        contextWindow: 100000,
        outputReserve: 100,
        prompts: const PromptsConfig(),
      );
      expect(m3.first['content']!.startsWith(kDefaultRolePrompt), isTrue);
    });
  });

  group('buildReviewMessages', () {
    test('6. 消息顺序：[system] + [history] + [system(草稿)] + [system(往事)?] + [user]',
        () async {
      final history = [_msg('u1', 'user', '你好'), _msg('a1', 'assistant', '回复')];
      final memories = [_scoredMemory('mem1', '勇者击败恶龙', 4, 1)];

      final messages = await builder.buildReviewMessages(
        userInput: '继续',
        generated: '草稿正文',
        retrievedMemories: memories,
        history: history,
        sessionSystemPrompt: '向导',
        contextWindow: 100000,
        outputReserve: 100,
        dialogueBudgetRatio: 0.7,
        currentTurnNumber: 5,
        prompts: const PromptsConfig(),
      );

      expect(messages.first['role'], 'system');
      expect(messages.last['role'], 'user');
      // V1 方法（已废弃）：草稿用 system 角色注入
      // 顺序：system, user, assistant, system(草稿), system(往事), user
      // V2 方法（buildReviewMessagesV2）已改为草稿合并到最后 user 消息，
      // 但本测试覆盖 V1，保留原断言。V2 由集成测试覆盖。
      expect(messages.length, 6);
      expect(messages[3]['content'], startsWith(kGeneratedInjectionPrefix));
      expect(messages[3]['content'], contains('草稿正文'));
      expect(messages[4]['content'], contains(kMemoriesInjectionTitle));
      expect(messages[5]['role'], 'user');
    });

    test('7. 记忆格式化：【相关往事】+ [X轮前·重要性N] 多行结构化（v0.2 方案二）', () async {
      final memories = [
        _scoredMemory('mem1', '勇者击败恶龙', 4, 1),
        _scoredMemory('mem2', '村民赠送地图', 2, 3),
      ];

      final messages = await builder.buildReviewMessages(
        userInput: '继续',
        generated: '草稿',
        retrievedMemories: memories,
        history: const [],
        sessionSystemPrompt: '向导',
        contextWindow: 100000,
        outputReserve: 100,
        dialogueBudgetRatio: 0.7,
        currentTurnNumber: 5,
        prompts: const PromptsConfig(),
      );

      final memoriesMsg = messages[messages.length - 2]['content']!;
      expect(memoriesMsg, startsWith(kMemoriesInjectionTitle));
      // mem1: turnNumber=1, currentTurn=5 → 4轮前·重要性4
      // 5W1E 字段全空（旧数据兼容），回退使用 summary 单行格式
      expect(memoriesMsg, contains('[4轮前·重要性4]'));
      expect(memoriesMsg, contains('· 勇者击败恶龙'));
      // mem2: turnNumber=3, currentTurn=5 → 2轮前·重要性2
      expect(memoriesMsg, contains('[2轮前·重要性2]'));
      expect(memoriesMsg, contains('· 村民赠送地图'));
    });

    test('8. 无记忆 → 不注入往事 system 消息', () async {
      final messages = await builder.buildReviewMessages(
        userInput: '继续',
        generated: '草稿',
        retrievedMemories: const [],
        history: const [],
        sessionSystemPrompt: '向导',
        contextWindow: 100000,
        outputReserve: 100,
        dialogueBudgetRatio: 0.7,
        currentTurnNumber: 5,
        prompts: const PromptsConfig(),
      );

      // V1 方法（已废弃）：顺序 system, system(草稿), user —— 无 system(往事)
      // V2 方法已改为草稿合并到最后 user 消息，但本测试覆盖 V1。
      expect(messages.length, 3);
      expect(messages[1]['content'], startsWith(kGeneratedInjectionPrefix));
      expect(messages[2]['role'], 'user');
    });

    test('9. token 预算缩减 → 保底最近 4 条', () async {
      final longContent = 'x' * 200;
      final history = [
        for (var i = 0; i < 8; i++)
          _msg('m$i', i.isEven ? 'user' : 'assistant', '$longContent$i'),
      ];

      final messages = await builder.buildReviewMessages(
        userInput: '继续',
        generated: '草稿',
        retrievedMemories: const [],
        history: history,
        sessionSystemPrompt: '向导',
        contextWindow: 400, // 极小预算
        outputReserve: 50,
        dialogueBudgetRatio: 0.7,
        currentTurnNumber: 9,
        prompts: const PromptsConfig(),
      );

      // V1 方法（已废弃）：system + 4 history(保底) + system(草稿) + user
      expect(messages.length, 7);
      // 保留最近 4 条
      expect(messages[1]['content'], '${longContent}4');
      expect(messages[4]['content'], '${longContent}7');
    });

    test('10. sessionSystemPrompt 非空 → 拼接修正后缀', () async {
      final messages = await builder.buildReviewMessages(
        userInput: '你好',
        generated: '草稿',
        retrievedMemories: const [],
        history: const [],
        sessionSystemPrompt: '自定义角色',
        contextWindow: 100000,
        outputReserve: 100,
        dialogueBudgetRatio: 0.7,
        currentTurnNumber: 1,
        prompts: const PromptsConfig(),
      );

      final systemContent = messages.first['content']!;
      expect(systemContent.startsWith('自定义角色'), isTrue);
      expect(systemContent, contains(kReviseSuffixPrompt));
    });
  });

  // ==================== V2 四步流程（2026-07-22 双 system 结构）====================

  group('buildExtractMessagesV2（2026-08-23：末条 user 带任务包装，与请求侧一致）', () {
    test('E-1. 消息顺序：提示词 + 摘要? + 历史 + user(任务包装)', () {
      final history = [
        _msg('u1', 'user', '你好'),
        _msg('a1', 'assistant', '你好，有什么可以帮你？'),
      ];

      final messages = builder.buildExtractMessagesV2(
        userInput: '继续冒险',
        history: history,
        prompts: const PromptsConfig(),
        compactionSummary: '来公寓第九天：主角在阁楼发现旧日记。',
      );

      expect(messages[0]['role'], 'system');
      expect(messages[0]['content'], kExtractKeywordsToolPrompt);
      expect(messages[1]['role'], 'system');
      expect(messages[1]['content'], '来公寓第九天：主角在阁楼发现旧日记。');
      expect(messages[2]['role'], 'user');
      expect(messages[3]['role'], 'assistant');
      expect(messages.last['role'], 'user');
      // 与 ExtractPhaseHandler 请求侧一致（预览即所得）：
      // 任务标记紧贴输入内容，防止模型把末条 user 消息当角色扮演续写
      expect(
        messages.last['content'],
        '【提取关键词任务 - 从以下用户消息提取关键词，'
        ' 不是角色扮演对话续写】\n\n继续冒险',
      );
      expect(messages.length, 5);
    });

    test('E-2. 无摘要时省略摘要消息', () {
      final messages = builder.buildExtractMessagesV2(
        userInput: '你好',
        history: const [],
        prompts: const PromptsConfig(),
      );

      expect(messages.length, 2); // 提示词 + user(包装)
      expect(
        messages.last['content'],
        startsWith('【提取关键词任务'),
      );
    });
  });

  group('buildGenerateMessagesV2（2026-07-22：去除草稿后缀；B3：注入记忆）', () {
    test('V2-1. 消息顺序：[system(角色提示词)] + [history...] + [user]', () async {
      final history = [
        _msg('u1', 'user', '你好'),
        _msg('a1', 'assistant', '你好，有什么可以帮你？'),
      ];

      final messages = await builder.buildGenerateMessagesV2(
        userInput: '继续冒险',
        history: history,
        sessionSystemPrompt: '你是冒险向导',
        contextWindow: 100000,
        maxTokens: 100,
        prompts: const PromptsConfig(),
        retrievedMemories: const [],
        factBlock: '',
        currentTurnNumber: 1,
      );

      expect(messages.first['role'], 'system');
      expect(messages.last['role'], 'user');
      expect(messages.length, 4); // system + 2 history + user
    });

    test('V2-2. 不再拼接草稿后缀 → system 纯角色提示词', () async {
      final messages = await builder.buildGenerateMessagesV2(
        userInput: '你好',
        history: const [],
        sessionSystemPrompt: '你是冒险向导',
        contextWindow: 100000,
        maxTokens: 100,
        prompts: const PromptsConfig(),
        retrievedMemories: const [],
        factBlock: '',
        currentTurnNumber: 1,
      );

      final systemContent = messages.first['content']!;
      // 应当完全是角色提示词，不含后缀
      expect(systemContent, '你是冒险向导');
      // 不应包含草稿后缀的任何特征字眼
      expect(systemContent, isNot(contains(kGeneratingSuffixPromptV2)));
      expect(systemContent, isNot(contains('草稿')));
      expect(systemContent, isNot(contains('初步')));
    });

    test('V2-3. sessionSystemPrompt=null → 用 kDefaultRolePrompt（无后缀）',
        () async {
      final messages = await builder.buildGenerateMessagesV2(
        userInput: '你好',
        history: const [],
        sessionSystemPrompt: null,
        contextWindow: 100000,
        maxTokens: 100,
        prompts: const PromptsConfig(),
        retrievedMemories: const [],
        factBlock: '',
        currentTurnNumber: 1,
      );

      final systemContent = messages.first['content']!;
      expect(systemContent, kDefaultRolePrompt);
      expect(systemContent, isNot(contains(kGeneratingSuffixPromptV2)));
    });

    test('V2-4. 缓存友好：与 revising 第一条 system 文本一致', () async {
      // drafting 的 system 应当与 revising 的第一条 system 完全一致
      // （同一会话同一角色提示词），可被 OpenAI prefix caching 跨请求命中
      const sessionPrompt = '你是固定角色提示词';
      final draftMessages = await builder.buildGenerateMessagesV2(
        userInput: '你好',
        history: const [],
        sessionSystemPrompt: sessionPrompt,
        contextWindow: 100000,
        maxTokens: 100,
        prompts: const PromptsConfig(),
        retrievedMemories: const [],
        factBlock: '',
        currentTurnNumber: 1,
      );

      final reviseMessages = await builder.buildReviewMessagesV2(
        userInput: '你好',
        generated: '草稿',
        retrievedMemories: const [],
        sessionSystemPrompt: sessionPrompt,
        contextWindow: 100000,
        maxTokens: 100,
        currentTurnNumber: 1,
        prompts: const PromptsConfig(),
      );

      // drafting 的 system[0] == revising 的 system[0]
      // （新结构：角色提示词在两条方法中都是第一条 system，可被 prefix caching 跨请求命中）
      expect(draftMessages[0]['content'], sessionPrompt);
      expect(reviseMessages[0]['content'], sessionPrompt);
      expect(draftMessages[0]['content'], reviseMessages[0]['content']);
    });

    // ==================== drafting 注入记忆测试 ====================

    test('V2-B3-1. 有记忆 → 消息列表包含【相关往事】system 消息', () async {
      final memories = [_scoredMemory('mem1', '勇者击败恶龙', 4, 1)];

      final messages = await builder.buildGenerateMessagesV2(
        userInput: '继续冒险',
        history: const [],
        sessionSystemPrompt: '你是冒险向导',
        contextWindow: 100000,
        maxTokens: 100,
        prompts: const PromptsConfig(),
        retrievedMemories: memories,
        factBlock: '',
        currentTurnNumber: 5,
      );

      // 顺序：system(角色提示词) + system(往事) + user
      expect(messages[0]['role'], 'system');
      expect(messages[0]['content'], '你是冒险向导');
      expect(messages[1]['role'], 'system');
      expect(messages[1]['content'], contains(kMemoriesInjectionTitle));
      expect(messages[1]['content'], contains('勇者击败恶龙'));
      expect(messages.last['role'], 'user');
    });

    test('V2-B3-2. 有 factBlock → 消息列表包含【世界设定】system 消息', () async {
      const factBlock = '【世界设定】\n角色：勇者（年龄 25）';

      final messages = await builder.buildGenerateMessagesV2(
        userInput: '继续冒险',
        history: const [],
        sessionSystemPrompt: '你是冒险向导',
        contextWindow: 100000,
        maxTokens: 100,
        prompts: const PromptsConfig(),
        retrievedMemories: const [],
        factBlock: factBlock,
        currentTurnNumber: 1,
      );

      // 顺序：system(角色提示词) + system(世界设定) + user
      expect(messages[0]['role'], 'system');
      expect(messages[0]['content'], '你是冒险向导');
      expect(messages[1]['role'], 'system');
      expect(messages[1]['content'], factBlock);
      expect(messages.last['role'], 'user');
    });

    test('V2-B3-3. 无记忆 + 无 factBlock → 仅角色提示词，不注入记忆块', () async {
      final messages = await builder.buildGenerateMessagesV2(
        userInput: '继续冒险',
        history: const [],
        sessionSystemPrompt: '你是冒险向导',
        contextWindow: 100000,
        maxTokens: 100,
        prompts: const PromptsConfig(),
        retrievedMemories: const [],
        factBlock: '',
        currentTurnNumber: 1,
      );

      // 仅 system(角色提示词) + user，无记忆块
      expect(messages.length, 2);
      expect(messages[0]['role'], 'system');
      expect(messages[0]['content'], '你是冒险向导');
      expect(messages[1]['role'], 'user');
    });

    test('V2-B3-4. 消息顺序：角色提示词 → 历史 → 世界设定 → 往事 → 用户消息', () async {
      final history = [
        _msg('u1', 'user', '你好'),
        _msg('a1', 'assistant', '回复'),
      ];
      const factBlock = '【世界设定】\n角色：勇者';
      final memories = [_scoredMemory('mem1', '勇者击败恶龙', 4, 1)];

      final messages = await builder.buildGenerateMessagesV2(
        userInput: '继续冒险',
        history: history,
        sessionSystemPrompt: '你是冒险向导',
        contextWindow: 100000,
        maxTokens: 100,
        prompts: const PromptsConfig(),
        retrievedMemories: memories,
        factBlock: factBlock,
        currentTurnNumber: 5,
      );

      // v0.2.2 顺序：稳定前缀（角色 + 历史）在先，动态记忆块在后，
      // 避免每轮检索结果变化破坏历史提示词缓存。
      expect(messages[0]['role'], 'system');
      expect(messages[0]['content'], '你是冒险向导');
      expect(messages[1]['role'], 'user');
      expect(messages[1]['content'], '你好');
      expect(messages[2]['role'], 'assistant');
      expect(messages[3]['role'], 'system');
      expect(messages[3]['content'], factBlock);
      expect(messages[4]['role'], 'system');
      expect(messages[4]['content'], contains(kMemoriesInjectionTitle));
      expect(messages[5]['role'], 'user');
      expect(messages[5]['content'], '继续冒险');
    });

    test('V2-B3-5. token 预算正确计算 → 记忆块占用预算，历史被缩减', () async {
      // 8 条超长历史 + 长 factBlock + 有记忆 → 预算被记忆块占用 → 历史保底 4 条
      final longContent = 'x' * 200;
      final history = [
        for (var i = 0; i < 8; i++)
          _msg('m$i', i.isEven ? 'user' : 'assistant', '$longContent$i'),
      ];
      // factBlock 长度 100，memoriesInjection 也有一定长度
      final factBlock = '【世界设定】\n${'y' * 100}';
      final memories = [_scoredMemory('mem1', '勇者击败恶龙', 4, 1)];

      final messages = await builder.buildGenerateMessagesV2(
        userInput: '继续',
        history: history,
        sessionSystemPrompt: '向导',
        contextWindow: 800, // 较小预算，记忆块 + 历史 → 触发缩减
        maxTokens: 50,
        prompts: const PromptsConfig(),
        retrievedMemories: memories,
        factBlock: factBlock,
        currentTurnNumber: 5,
      );

      // 预期：system(角色) + 4 history(保底) + system(世界设定) +
      // system(往事) + user = 8
      expect(messages.length, 8);
      expect(messages[0]['role'], 'system');
      // 保留最近 4 条历史（m4-m7）
      expect(messages[1]['content'], '${longContent}4');
      expect(messages[4]['content'], '${longContent}7');
      expect(messages[5]['role'], 'system');
      expect(messages[6]['role'], 'system');
      // 最后是 user
      expect(messages[7]['role'], 'user');
      expect(messages[7]['content'], '继续');
    });

    test('V2-B3-6. 记忆格式化与 revising 一致（复用 _formatMemories）', () async {
      // 同样的记忆传入 drafting 和 revising，往事区块格式应一致
      final memories = [_scoredMemory('mem1', '勇者击败恶龙', 4, 1)];
      const currentTurn = 5;

      final draftMessages = await builder.buildGenerateMessagesV2(
        userInput: '继续',
        history: const [],
        sessionSystemPrompt: '向导',
        contextWindow: 100000,
        maxTokens: 100,
        prompts: const PromptsConfig(),
        retrievedMemories: memories,
        factBlock: '',
        currentTurnNumber: currentTurn,
      );

      final reviseMessages = await builder.buildReviewMessagesV2(
        userInput: '继续',
        generated: '草稿',
        retrievedMemories: memories,
        sessionSystemPrompt: '向导',
        contextWindow: 100000,
        maxTokens: 100,
        currentTurnNumber: currentTurn,
        prompts: const PromptsConfig(),
      );

      // drafting 的往事 system（索引 1）应与 revising 的往事 system
      // （最后一条 user 之前的 system）内容完全一致
      final draftMemoriesContent = draftMessages[1]['content']!;
      // revising 中往事是倒数第二条消息（最后是 user(用户消息+生成内容)）
      final reviseMemoriesContent =
          reviseMessages[reviseMessages.length - 2]['content']!;
      expect(draftMemoriesContent, reviseMemoriesContent);
    });
  });

  group('buildReviewMessagesV2（2026-08-05：角色提示词 + 审查提示词 双 system 结构）', () {
    test('V2-5. 消息顺序：双 system + [system(往事)?] + user(用户消息+生成内容)', () async {
      final memories = [_scoredMemory('mem1', '勇者击败恶龙', 4, 1)];

      final messages = await builder.buildReviewMessagesV2(
        userInput: '继续',
        generated: '草稿正文',
        retrievedMemories: memories,
        sessionSystemPrompt: '你是冒险向导',
        contextWindow: 100000,
        maxTokens: 100,
        currentTurnNumber: 5,
        prompts: const PromptsConfig(),
      );

      // 顺序：system(角色提示词) + system(审查提示词) + system(往事) + user(用户消息+生成内容)
      expect(messages[0]['role'], 'system');
      expect(messages[0]['content'], '你是冒险向导');
      expect(messages[1]['role'], 'system');
      // 审查提示词中占位符已替换为实际标题，检查稳定子串
      expect(messages[1]['content'], contains('审查并修正'));
      expect(messages[1]['content'], isNot(contains('{factInjectionTitle}')));
      expect(messages[2]['role'], 'system');
      expect(messages[2]['content'], contains(kMemoriesInjectionTitle));
      expect(messages[3]['role'], 'user');
      expect(messages[3]['content'], contains('草稿正文'));
      expect(messages[3]['content'], contains('继续'));
    });

    test('V2-6. 第二条 system = 审查提示词（编辑任务指令）', () async {
      final messages = await builder.buildReviewMessagesV2(
        userInput: '你好',
        generated: '草稿',
        retrievedMemories: const [],
        sessionSystemPrompt: '你是向导',
        contextWindow: 100000,
        maxTokens: 100,
        currentTurnNumber: 1,
        prompts: const PromptsConfig(),
      );

      // 第二条 system 是审查提示词（编辑任务指令）
      // 占位符已替换为实际标题，不能直接比较 kReviewSuffixPromptV2
      expect(messages[1]['content'], isNot(contains('{factInjectionTitle}')));
      expect(
        messages[1]['content'],
        isNot(contains('{memoriesInjectionTitle}')),
      );
      // 应包含"编辑"任务字眼
      expect(messages[1]['content'], contains('编辑'));
      expect(messages[1]['content'], contains('审查并修正'));
    });

    test('V2-7. 第一条 system = 角色提示词（草稿生成规则）', () async {
      const rolePrompt = '你是固定的冒险向导角色';
      final messages = await builder.buildReviewMessagesV2(
        userInput: '你好',
        generated: '草稿',
        retrievedMemories: const [],
        sessionSystemPrompt: rolePrompt,
        contextWindow: 100000,
        maxTokens: 100,
        currentTurnNumber: 1,
        prompts: const PromptsConfig(),
      );

      // 第一条 system 是角色提示词（草稿生成规则）
      expect(messages[0]['role'], 'system');
      expect(messages[0]['content'], rolePrompt);
      // 不应含审查提示词
      expect(messages[0]['content'], isNot(contains(kReviewSuffixPromptV2)));
    });

    test('V2-8. 优先级：session > global > default（第一条 system）', () async {
      // session 非空 → 用 session（即便 global 也非空）
      final m1 = await builder.buildReviewMessagesV2(
        userInput: 'x',
        generated: '草稿',
        retrievedMemories: const [],
        sessionSystemPrompt: '会话级',
        contextWindow: 100000,
        maxTokens: 100,
        currentTurnNumber: 1,
        prompts: const PromptsConfig(),
        globalSystemPrompt: '全局级',
      );
      expect(m1[0]['content'], '会话级');

      // session 为空、global 非空 → 用 global
      final m2 = await builder.buildReviewMessagesV2(
        userInput: 'x',
        generated: '草稿',
        retrievedMemories: const [],
        sessionSystemPrompt: null,
        contextWindow: 100000,
        maxTokens: 100,
        currentTurnNumber: 1,
        prompts: const PromptsConfig(),
        globalSystemPrompt: '全局级',
      );
      expect(m2[0]['content'], '全局级');

      // 都为空 → 用 kDefaultRolePrompt
      final m3 = await builder.buildReviewMessagesV2(
        userInput: 'x',
        generated: '草稿',
        retrievedMemories: const [],
        sessionSystemPrompt: null,
        contextWindow: 100000,
        maxTokens: 100,
        currentTurnNumber: 1,
        prompts: const PromptsConfig(),
      );
      expect(m3[0]['content'], kDefaultRolePrompt);
    });

    test('V2-9. 事实层注入 -> 在往事之前，作为第三条 system', () async {
      const factBlock = '【世界设定】\n角色：勇者（年龄 25）';
      final messages = await builder.buildReviewMessagesV2(
        userInput: '继续',
        generated: '草稿',
        retrievedMemories: const [],
        sessionSystemPrompt: '向导',
        contextWindow: 100000,
        maxTokens: 100,
        currentTurnNumber: 1,
        prompts: const PromptsConfig(),
        factBlock: factBlock,
      );

      // 顺序：system(角色提示词) + system(审查提示词) + system(世界设定) + user(用户消息+生成内容)
      expect(messages[0]['role'], 'system');
      expect(messages[1]['role'], 'system');
      expect(messages[2]['role'], 'system');
      expect(messages[2]['content'], factBlock);
      expect(messages[3]['role'], 'user');
      expect(messages[3]['content'], contains('草稿'));
    });

    test('V2-10. 草稿合并到最后一条 user 消息（含用户消息+生成内容）', () async {
      const draftText = '这是草稿正文内容';
      final messages = await builder.buildReviewMessagesV2(
        userInput: '你好',
        generated: draftText,
        retrievedMemories: const [],
        sessionSystemPrompt: '向导',
        contextWindow: 100000,
        maxTokens: 100,
        currentTurnNumber: 1,
        prompts: const PromptsConfig(),
      );

      final lastUser = messages.last;
      expect(lastUser['role'], 'user');
      expect(lastUser['content'], contains(draftText));
      expect(lastUser['content'], contains('【用户消息】'));
      expect(lastUser['content'], contains('【需要审查的生成内容】'));
    });
  });

  // ====================  JSON 兜底提示词选择 ====================

  group('jsonFallback 提示词选择', () {
    test('11. buildGenerateMessages jsonFallback=true → 用 JSON 兜底版后缀',
        () async {
      final messages = await builder.buildGenerateMessages(
        userInput: '你好',
        history: const [],
        sessionSystemPrompt: null,
        contextWindow: 100000,
        outputReserve: 100,
        prompts: const PromptsConfig(),
        jsonFallback: true,
      );

      final systemContent = messages.first['content']!;
      expect(systemContent, contains(kDraftSuffixPromptJson));
      expect(systemContent, isNot(contains(kDraftSuffixPrompt)));
    });

    test('12. buildGenerateMessages jsonFallback=false（默认）→ 用分隔标记版后缀',
        () async {
      final messages = await builder.buildGenerateMessages(
        userInput: '你好',
        history: const [],
        sessionSystemPrompt: null,
        contextWindow: 100000,
        outputReserve: 100,
        prompts: const PromptsConfig(),
      );

      final systemContent = messages.first['content']!;
      expect(systemContent, contains(kDraftSuffixPrompt));
      expect(systemContent, isNot(contains(kDraftSuffixPromptJson)));
    });

    test('13. buildReviewMessages jsonFallback=true → 用 JSON 兜底版后缀', () async {
      final messages = await builder.buildReviewMessages(
        userInput: '你好',
        generated: '草稿',
        retrievedMemories: const [],
        history: const [],
        sessionSystemPrompt: null,
        contextWindow: 100000,
        outputReserve: 100,
        dialogueBudgetRatio: 0.7,
        currentTurnNumber: 1,
        prompts: const PromptsConfig(),
        jsonFallback: true,
      );

      final systemContent = messages.first['content']!;
      expect(systemContent, contains(kReviseSuffixPromptJson));
      expect(systemContent, isNot(contains(kReviseSuffixPrompt)));
    });

    test('14. buildReviewMessages jsonFallback=false（默认）→ 用分隔标记版后缀', () async {
      final messages = await builder.buildReviewMessages(
        userInput: '你好',
        generated: '草稿',
        retrievedMemories: const [],
        history: const [],
        sessionSystemPrompt: null,
        contextWindow: 100000,
        outputReserve: 100,
        dialogueBudgetRatio: 0.7,
        currentTurnNumber: 1,
        prompts: const PromptsConfig(),
      );

      final systemContent = messages.first['content']!;
      expect(systemContent, contains(kReviseSuffixPrompt));
      expect(systemContent, isNot(contains(kReviseSuffixPromptJson)));
    });
  });

  // ====================  PromptsConfig 自定义提示词 ====================

  group('PromptsConfig 自定义（B3-3）', () {
    test('15. 自定义 defaultRolePrompt → 替换 kDefaultRolePrompt 作为前缀', () async {
      const customPrompts = PromptsConfig(
        defaultRolePrompt: '你是赛博朋克世界的人工智能。',
      );
      final messages = await builder.buildGenerateMessages(
        userInput: '你好',
        history: const [],
        sessionSystemPrompt: null,
        contextWindow: 100000,
        outputReserve: 100,
        prompts: customPrompts,
      );

      final systemContent = messages.first['content']!;
      expect(systemContent.startsWith('你是赛博朋克世界的人工智能。'), isTrue);
      expect(systemContent.contains(kDefaultRolePrompt), isFalse);
      // 后缀仍用默认值（draftSuffix 未自定义）
      expect(systemContent, contains(kDraftSuffixPrompt));
    });

    test('16. 自定义 draftSuffix → 替换草稿后缀', () async {
      const customPrompts = PromptsConfig(
        draftSuffix: '\n【自定义草稿后缀】',
        draftSuffixJson: '\n【自定义 JSON 后缀】',
      );
      final messages = await builder.buildGenerateMessages(
        userInput: '你好',
        history: const [],
        sessionSystemPrompt: '向导',
        contextWindow: 100000,
        outputReserve: 100,
        prompts: customPrompts,
      );

      final systemContent = messages.first['content']!;
      expect(systemContent, contains('【自定义草稿后缀】'));
      expect(systemContent, isNot(contains(kDraftSuffixPrompt)));
    });

    test('17. 自定义 memoriesInjectionTitle → 替换往事标题', () async {
      const customPrompts = PromptsConfig(
        memoriesInjectionTitle: '【回响记忆】',
      );
      final memories = [_scoredMemory('mem1', '事件', 3, 1)];
      final messages = await builder.buildReviewMessages(
        userInput: '继续',
        generated: '草稿',
        retrievedMemories: memories,
        history: const [],
        sessionSystemPrompt: '向导',
        contextWindow: 100000,
        outputReserve: 100,
        dialogueBudgetRatio: 0.7,
        currentTurnNumber: 5,
        prompts: customPrompts,
      );

      final memoriesMsg = messages[messages.length - 2]['content']!;
      expect(memoriesMsg.startsWith('【回响记忆】'), isTrue);
      expect(memoriesMsg.contains(kMemoriesInjectionTitle), isFalse);
    });
  });

  // 多粒度共存：macro 与 micro 共存注入，分别标注，不去重
  group('多粒度共存（macro + micro 共存）', () {
    test('1. macro + 被覆盖的 micro 同时召回 -> 全部注入，分别标注', () async {
      // macro 聚合 mem_micro1 和 mem_micro2 两条 micro
      final memories = [
        _scoredMemory(
          'mem_macro',
          '勇者抵达龙巢并击败守卫（宏摘要）',
          4,
          3,
          memoryLevel: MemoryLevel.macro,
          parentEventIds: const ['mem_micro1', 'mem_micro2'],
        ),
        _scoredMemory('mem_micro1', '勇者抵达龙巢', 3, 1),
        _scoredMemory('mem_micro2', '勇者击败守卫', 3, 2),
        // 不被任何 macro 覆盖的独立 micro → 保留
        _scoredMemory('mem_micro3', '村民赠送地图', 2, 4),
      ];

      final messages = await builder.buildReviewMessages(
        userInput: '继续',
        generated: '草稿',
        retrievedMemories: memories,
        history: const [],
        sessionSystemPrompt: '向导',
        contextWindow: 100000,
        outputReserve: 100,
        dialogueBudgetRatio: 0.7,
        currentTurnNumber: 5,
        prompts: const PromptsConfig(),
      );

      final memoriesMsg = messages[messages.length - 2]['content']!;
      // 段落摘要标注
      expect(memoriesMsg, contains('── 段落摘要 ──'));
      // 事件记忆标注
      expect(memoriesMsg, contains('── 事件记忆 ──'));
      // macro 保留
      expect(memoriesMsg, contains('勇者抵达龙巢并击败守卫（宏摘要）'));
      // 被覆盖的 micro 也保留（共存不去重）
      // micro1 格式化为 "[4轮前·重要性3]\n· 勇者抵达龙巢"
      expect(memoriesMsg, contains('· 勇者抵达龙巢'));
      // micro2 格式化为 "[3轮前·重要性3]\n· 勇者击败守卫"
      expect(memoriesMsg, contains('· 勇者击败守卫'));
      // 独立 micro 保留
      expect(memoriesMsg, contains('村民赠送地图'));
    });

    test('2. 仅 micro 无 macro -> 全部注入，只有事件记忆标注', () async {
      final memories = [
        _scoredMemory('mem_micro1', '勇者抵达龙巢', 3, 1),
        _scoredMemory('mem_micro2', '勇者击败守卫', 3, 2),
      ];

      final messages = await builder.buildReviewMessages(
        userInput: '继续',
        generated: '草稿',
        retrievedMemories: memories,
        history: const [],
        sessionSystemPrompt: '向导',
        contextWindow: 100000,
        outputReserve: 100,
        dialogueBudgetRatio: 0.7,
        currentTurnNumber: 5,
        prompts: const PromptsConfig(),
      );

      final memoriesMsg = messages[messages.length - 2]['content']!;
      expect(memoriesMsg, contains('勇者抵达龙巢'));
      expect(memoriesMsg, contains('勇者击败守卫'));
      // 只有事件记忆标注，无段落摘要标注
      expect(memoriesMsg, contains('── 事件记忆 ──'));
      expect(memoriesMsg, isNot(contains('── 段落摘要 ──')));
    });

    test('3. macro + 独立 micro 共存 -> 分别标注', () async {
      final memories = [
        _scoredMemory(
          'mem_macro',
          '宏摘要无父事件',
          4,
          3,
          memoryLevel: MemoryLevel.macro,
          parentEventIds: const [],
        ),
        _scoredMemory('mem_micro1', '独立微摘要', 3, 1),
      ];

      final messages = await builder.buildReviewMessages(
        userInput: '继续',
        generated: '草稿',
        retrievedMemories: memories,
        history: const [],
        sessionSystemPrompt: '向导',
        contextWindow: 100000,
        outputReserve: 100,
        dialogueBudgetRatio: 0.7,
        currentTurnNumber: 5,
        prompts: const PromptsConfig(),
      );

      final memoriesMsg = messages[messages.length - 2]['content']!;
      expect(memoriesMsg, contains('宏摘要无父事件'));
      expect(memoriesMsg, contains('独立微摘要'));
      // 段落摘要和事件记忆标注都存在
      expect(memoriesMsg, contains('── 段落摘要 ──'));
      expect(memoriesMsg, contains('── 事件记忆 ──'));
    });
  });

  // ==================== v0.2 Phase C 方案二：5W1E 多行格式化测试 ====================

  group('5W1E 多行格式化（v0.2 方案二）', () {
    test('1. 5W1E 全字段填充 → 多行结构化输出', () async {
      // 所有 6 个 5W1E 字段都有值 → 每个字段独立成行
      final memories = [
        _scoredMemory5W1E(
          'mem1',
          importance: 4,
          turnNumber: 2,
          what: '勇者斩杀了巨龙',
          when: '战斗结束时',
          where: '火山口',
          who: '勇者与巨龙',
          significance: '获得了关键道具',
          extra: '巨龙临死前留下一句预言',
        ),
      ];

      final messages = await builder.buildReviewMessages(
        userInput: '继续',
        generated: '草稿',
        retrievedMemories: memories,
        history: const [],
        sessionSystemPrompt: '向导',
        contextWindow: 100000,
        outputReserve: 100,
        dialogueBudgetRatio: 0.7,
        currentTurnNumber: 5,
        prompts: const PromptsConfig(),
      );

      final memoriesMsg = messages[messages.length - 2]['content']!;
      // 标题行 + 轮次/重要性头
      expect(memoriesMsg, startsWith(kMemoriesInjectionTitle));
      // currentTurn=5, turnNumber=2 → 3轮前·重要性4
      expect(memoriesMsg, contains('[3轮前·重要性4]'));
      // 6 个 5W1E 字段每个独立成行
      expect(memoriesMsg, contains('· 何事：勇者斩杀了巨龙'));
      expect(memoriesMsg, contains('· 何时：战斗结束时'));
      expect(memoriesMsg, contains('· 何地：火山口'));
      expect(memoriesMsg, contains('· 何人：勇者与巨龙'));
      expect(memoriesMsg, contains('· 为何重要：获得了关键道具'));
      expect(memoriesMsg, contains('· 补充：巨龙临死前留下一句预言'));
    });

    test('2. 5W1E 部分字段填充 → 仅展示非空字段', () async {
      // 只填 what + when + who，其余为 null
      final memories = [
        _scoredMemory5W1E(
          'mem1',
          importance: 3,
          turnNumber: 1,
          what: '勇者与公主重逢',
          when: '黄昏',
          who: '勇者与公主',
        ),
      ];

      final messages = await builder.buildReviewMessages(
        userInput: '继续',
        generated: '草稿',
        retrievedMemories: memories,
        history: const [],
        sessionSystemPrompt: '向导',
        contextWindow: 100000,
        outputReserve: 100,
        dialogueBudgetRatio: 0.7,
        currentTurnNumber: 4,
        prompts: const PromptsConfig(),
      );

      final memoriesMsg = messages[messages.length - 2]['content']!;
      expect(memoriesMsg, contains('[3轮前·重要性3]'));
      expect(memoriesMsg, contains('· 何事：勇者与公主重逢'));
      expect(memoriesMsg, contains('· 何时：黄昏'));
      expect(memoriesMsg, contains('· 何人：勇者与公主'));
      // 未提供的字段不应出现
      expect(memoriesMsg, isNot(contains('· 何地')));
      expect(memoriesMsg, isNot(contains('· 为何重要')));
      expect(memoriesMsg, isNot(contains('· 补充')));
    });

    test('3. 5W1E 全空 + summary 非空 → 回退使用 summary 单行', () async {
      // 旧数据兼容：5W1E 全为 null，summary 有值
      // 此时不应输出多行 5W1E，应回退到单行 summary 格式
      final memories = [
        _scoredMemory5W1E(
          'mem1',
          importance: 4,
          turnNumber: 1,
          summary: '勇者击败恶龙',
        ),
      ];

      final messages = await builder.buildReviewMessages(
        userInput: '继续',
        generated: '草稿',
        retrievedMemories: memories,
        history: const [],
        sessionSystemPrompt: '向导',
        contextWindow: 100000,
        outputReserve: 100,
        dialogueBudgetRatio: 0.7,
        currentTurnNumber: 5,
        prompts: const PromptsConfig(),
      );

      final memoriesMsg = messages[messages.length - 2]['content']!;
      expect(memoriesMsg, contains('[4轮前·重要性4]'));
      // 回退到 summary 单行格式（带 · 前缀）
      expect(memoriesMsg, contains('· 勇者击败恶龙'));
      // 不应输出任何 5W1E 字段标签
      expect(memoriesMsg, isNot(contains('· 何事')));
      expect(memoriesMsg, isNot(contains('· 何时')));
      expect(memoriesMsg, isNot(contains('· 何地')));
    });

    test('4. 5W1E 全空 + summary 也为空 → 回退使用 displayText', () async {
      // 极端边界：所有字段都为 null
      // displayText getter 在全空时返回 '(空事件)'
      final memories = [
        _scoredMemory5W1E(
          'mem1',
          importance: 2,
          turnNumber: 1,
          // summary + 所有 5W1E 字段都为 null
        ),
      ];

      final messages = await builder.buildReviewMessages(
        userInput: '继续',
        generated: '草稿',
        retrievedMemories: memories,
        history: const [],
        sessionSystemPrompt: '向导',
        contextWindow: 100000,
        outputReserve: 100,
        dialogueBudgetRatio: 0.7,
        currentTurnNumber: 3,
        prompts: const PromptsConfig(),
      );

      final memoriesMsg = messages[messages.length - 2]['content']!;
      expect(memoriesMsg, contains('[2轮前·重要性2]'));
      // 全空时 displayText 返回 '(空事件)'
      expect(memoriesMsg, contains('· (空事件)'));
    });

    test('5. 5W1E 字段为空字符串 → 视为 null 不输出', () async {
      // _formatSingleMemory 使用 isNotEmpty 检查，空字符串跳过
      // 注：纯空白字符串（'   '）不被 trim，会被保留输出（与 displayText getter 一致）。
      // 实际生产中 parseEventSummary 已对纯空白 trim 为 null，所以此情况仅在
      // 直接构造实体（绕过解析器）时出现。这里只测空字符串场景。
      final memories = [
        _scoredMemory5W1E(
          'mem1',
          importance: 3,
          turnNumber: 1,
          what: '勇者发现古碑',
          when: '', // 空字符串 → 跳过
          who: '勇者',
        ),
      ];

      final messages = await builder.buildReviewMessages(
        userInput: '继续',
        generated: '草稿',
        retrievedMemories: memories,
        history: const [],
        sessionSystemPrompt: '向导',
        contextWindow: 100000,
        outputReserve: 100,
        dialogueBudgetRatio: 0.7,
        currentTurnNumber: 5,
        prompts: const PromptsConfig(),
      );

      final memoriesMsg = messages[messages.length - 2]['content']!;
      expect(memoriesMsg, contains('· 何事：勇者发现古碑'));
      expect(memoriesMsg, contains('· 何人：勇者'));
      // 空字符串字段不应出现
      expect(memoriesMsg, isNot(contains('· 何时：')));
    });

    test('6. 多条 5W1E 记忆混合 → 每条独立成块', () async {
      // 一条 5W1E 完整 + 一条仅 summary（旧数据）+ 一条 5W1E 部分
      final memories = [
        _scoredMemory5W1E(
          'mem1',
          importance: 5,
          turnNumber: 1,
          what: '勇者获得圣剑',
          where: '神殿深处',
          significance: '解锁后续主线',
        ),
        _scoredMemory5W1E(
          'mem2',
          importance: 3,
          turnNumber: 3,
          summary: '村民赠送地图', // 旧格式，5W1E 全空
        ),
        _scoredMemory5W1E(
          'mem3',
          importance: 4,
          turnNumber: 4,
          what: '勇者遭遇埋伏',
          who: '勇者与盗贼团',
        ),
      ];

      final messages = await builder.buildReviewMessages(
        userInput: '继续',
        generated: '草稿',
        retrievedMemories: memories,
        history: const [],
        sessionSystemPrompt: '向导',
        contextWindow: 100000,
        outputReserve: 100,
        dialogueBudgetRatio: 0.7,
        currentTurnNumber: 5,
        prompts: const PromptsConfig(),
      );

      final memoriesMsg = messages[messages.length - 2]['content']!;
      // mem1: 5W1E 多行格式
      expect(memoriesMsg, contains('[4轮前·重要性5]'));
      expect(memoriesMsg, contains('· 何事：勇者获得圣剑'));
      expect(memoriesMsg, contains('· 何地：神殿深处'));
      expect(memoriesMsg, contains('· 为何重要：解锁后续主线'));
      // mem2: 旧格式 summary 单行
      expect(memoriesMsg, contains('[2轮前·重要性3]'));
      expect(memoriesMsg, contains('· 村民赠送地图'));
      // mem3: 部分 5W1E
      expect(memoriesMsg, contains('[1轮前·重要性4]'));
      expect(memoriesMsg, contains('· 何事：勇者遭遇埋伏'));
      expect(memoriesMsg, contains('· 何人：勇者与盗贼团'));
    });
  });
}

/// 按字符数估算 token 的假 TokenCounter（测试专用）
class _FakeTokenCounter implements TokenCounter {
  @override
  Future<int> countTokens(String text) async => text.length;

  Future<List<int>> countTokensBatch(List<String> texts) async =>
      texts.map((t) => t.length).toList();

  @override
  Future<int> countTokensForMessages(List<String> messages) async =>
      messages.join(' ').length;

  @override
  Future<List<int>> countTokensForEach(List<String> texts) async =>
      texts.map((t) => t.length).toList();
}

ChatMessage _msg(String id, String role, String content) => ChatMessage(
      messageId: id,
      sessionId: 'session',
      role: role,
      content: content,
      createdAt: DateTime.now(),
    );

ScoredMemory _scoredMemory(
  String id,
  String summary,
  int importance,
  int turnNumber, {
  MemoryLevel memoryLevel = MemoryLevel.micro,
  List<String>? parentEventIds,
}) =>
    ScoredMemory(
      memory: ExperientialMemory(
        memoryId: id,
        sessionId: 'session',
        summary: summary,
        importance: importance,
        tags: const [],
        turnNumber: turnNumber,
        createdAt: DateTime.now(),
        memoryLevel: memoryLevel,
        parentEventIds: parentEventIds,
      ),
      fts5Score: 1,
      vectorScore: 0,
      temporalScore: 0,
      finalScore: 1,
    );

/// v0.2 Phase C 方案二：构造 5W1E 字段的 ScoredMemory（测试专用）
///
/// 与 [_scoredMemory] 的差异：
/// - summary 改为可选（方案二降级为 nullable）
/// - 显式接收 5W1E 6 字段，全部可选
/// - 默认 finalScore=1（与 [_scoredMemory] 一致，确保通过质量过滤阈值）
ScoredMemory _scoredMemory5W1E(
  String id, {
  required int importance,
  required int turnNumber,
  String? summary,
  String? what,
  String? when,
  String? where,
  String? who,
  String? significance,
  String? extra,
  MemoryLevel memoryLevel = MemoryLevel.micro,
}) =>
    ScoredMemory(
      memory: ExperientialMemory(
        memoryId: id,
        sessionId: 'session',
        importance: importance,
        tags: const [],
        turnNumber: turnNumber,
        createdAt: DateTime.now(),
        memoryLevel: memoryLevel,
        summary: summary,
        what: what,
        when: when,
        where: where,
        who: who,
        significance: significance,
        extra: extra,
      ),
      fts5Score: 1,
      vectorScore: 0,
      temporalScore: 0,
      finalScore: 1,
    );
