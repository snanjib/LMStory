import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/agent/agent_llm_gateway.dart';
import 'package:lmstory/core/di/providers.dart';
import 'package:lmstory/features/chat/data/agent/llm_service_agent_gateway.dart';

/// core/agent 去反向依赖后的
/// DI 装配测试——抽象在 core、实现在 feature，装配点经 provider 取用。
void main() {
  test('agentLlmGatewayProvider 装配出 feature 实现的 core 抽象', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    final gateway = container.read(agentLlmGatewayProvider);
    expect(gateway, isA<AgentLlmGateway>());
    expect(
      gateway,
      isA<LlmServiceAgentGateway>(),
      reason: '实现撤回 feature 层（chat/data/agent），core 只留抽象',
    );
  });
}
