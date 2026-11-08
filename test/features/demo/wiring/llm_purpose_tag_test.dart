import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// T-WI-3：LlmRequest 用途标注完备性（回放匹配键的先决条件）。
/// 源码级断言：已知用途的构造点必须携带 purpose。
void main() {
  final repoRoot = Directory.current.path;

  String read(String rel) => File('$repoRoot/$rel').readAsStringSync();

  test('Agent 网关两处（流式+非流式回退）标注 agentStep', () {
    final src =
        read('lib/features/chat/data/agent/llm_service_agent_gateway.dart');
    expect(
      src,
      contains('purpose: LlmPurposes.agentStep'),
      reason: 'Agent 步请求必须带用途（回放匹配键）',
    );
    expect(
      src,
      contains('purpose: baseRequest.purpose'),
      reason: '非流式回退重建请求必须透传 purpose',
    );
  });

  test('标题/推荐回复/世界观生成各自标注', () {
    expect(
      read(
        'lib/features/story_runtime/domain/services/session_title_generator.dart',
      ),
      contains('purpose: LlmPurposes.sessionTitle'),
    );
    expect(
      read(
        'lib/features/story_runtime/domain/services/suggest_reply_generator.dart',
      ),
      contains('purpose: LlmPurposes.suggestReply'),
    );
    expect(
      read(
        'lib/features/director_wizard/domain/services/world_prompt_generator.dart',
      ),
      contains('purpose: LlmPurposes.worldPrompt'),
    );
  });

  test('压缩三处与记忆归并两处标注', () {
    expect(
      read(
        'lib/features/story_runtime/domain/services/compaction_service.dart',
      ),
      contains('purpose: LlmPurposes.compaction'),
    );
    expect(
      read('lib/features/chat/domain/services/compaction_service.dart'),
      contains('purpose: LlmPurposes.compaction'),
    );
    expect(
      read('lib/features/chat/domain/services/compaction_streamer.dart'),
      contains('purpose: LlmPurposes.compaction'),
    );
    expect(
      read(
        'lib/features/story_runtime/domain/services/memory_consolidator.dart',
      ),
      contains('purpose: LlmPurposes.memoryMerge'),
    );
    expect(
      read('lib/features/memory/domain/services/facts_merge_service.dart'),
      contains('purpose: LlmPurposes.memoryMerge'),
    );
  });

  test('LlmPurposes 常量与回放匹配键同源', () {
    final src = read('lib/features/chat/domain/services/llm_service.dart');
    for (final key in [
      "agentStep = 'agent_step'",
      "sessionTitle = 'session_title'",
      "suggestReply = 'suggest_reply'",
      "worldPrompt = 'world_prompt'",
    ]) {
      expect(src, contains(key), reason: '常量漂移会破坏回放匹配');
    }
  });
}
