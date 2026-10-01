import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/config/config_loader.dart';

void main() {
  group('AppConfig', () {
    test('fromJson 正确解析完整配置', () {
      final json = {
        'version': '0.1',
        'broadcast_chat': {
          'model_id': 'gpt-4',
          'temperature': 0.9,
          'max_tokens': 8192,
          'auto_compaction': false,
          'compaction_threshold': 32000,
          'stream_enabled': false,
        },
      };

      final config = AppConfig.fromJson(json);

      expect(config.version, '0.1');
      expect(config.broadcastChat.modelId, 'gpt-4');
      expect(config.broadcastChat.temperature, 0.9);
      expect(config.broadcastChat.maxTokens, 8192);
      expect(config.broadcastChat.autoCompaction, false);
      expect(config.broadcastChat.compactionThreshold, 32000);
      expect(config.broadcastChat.streamEnabled, false);
    });

    test('fromJson 使用默认值处理缺失字段', () {
      final json = <String, dynamic>{};

      final config = AppConfig.fromJson(json);

      expect(config.version, '0.1');
      expect(config.broadcastChat.modelId, '');
      expect(config.broadcastChat.temperature, 0.7);
      expect(config.broadcastChat.maxTokens, isNull);
      expect(config.broadcastChat.autoCompaction, true);
      expect(config.broadcastChat.compactionThreshold, 0.6);
      expect(config.broadcastChat.streamEnabled, true);
    });

    test('fromJson 处理部分缺失的 broadcast_chat', () {
      final json = {
        'version': '0.2',
        'broadcast_chat': {
          'model_id': 'deepseek-chat',
        },
      };

      final config = AppConfig.fromJson(json);

      expect(config.version, '0.2');
      expect(config.broadcastChat.modelId, 'deepseek-chat');
      expect(config.broadcastChat.temperature, 0.7);
      expect(config.broadcastChat.maxTokens, isNull);
    });
  });

  group('BroadcastChatConfig', () {
    test('默认值正确（B9：maxTokens 默认 null = 由模型决定）', () {
      const config = BroadcastChatConfig();

      expect(config.modelId, '');
      expect(config.temperature, 0.7);
      expect(config.maxTokens, isNull);
      expect(config.autoCompaction, true);
      expect(config.compactionThreshold, 0.6);
      expect(config.streamEnabled, true);
    });

    test('B9：max_tokens 显式 null/缺键为 null，显式 0 透传（无上限哨兵）', () {
      expect(BroadcastChatConfig.fromJson(const {}).maxTokens, isNull);
      expect(
        BroadcastChatConfig.fromJson(const {'max_tokens': null}).maxTokens,
        isNull,
      );
      expect(
        BroadcastChatConfig.fromJson(const {'max_tokens': 0}).maxTokens,
        0,
      );
      expect(
        BroadcastChatConfig.fromJson(const {'max_tokens': 2048}).maxTokens,
        2048,
      );
    });

    test('fromJson 解析 temperature 为 num 类型', () {
      final json = {
        'temperature': 1,
      };

      final config = BroadcastChatConfig.fromJson(json);

      expect(config.temperature, 1.0);
    });
  });

  group('ConfigLoader', () {
    test('从 JSON 字符串解析配置', () async {
      // 直接测试 AppConfig.fromJson 而非 rootBundle（需要 Flutter 环境）
      const jsonStr = '''
      {
        "version": "0.1",
        "broadcast_chat": {
          "temperature": 0.7,
          "max_tokens": 4096,
          "auto_compaction": true,
          "compaction_threshold": 16000,
          "stream_enabled": true
        }
      }''';

      final jsonMap = jsonDecode(jsonStr) as Map<String, dynamic>;
      final config = AppConfig.fromJson(jsonMap);

      expect(config.version, '0.1');
      expect(config.broadcastChat.modelId, '');
      expect(config.broadcastChat.temperature, 0.7);
      expect(config.broadcastChat.maxTokens, 4096);
      expect(config.broadcastChat.autoCompaction, true);
      expect(config.broadcastChat.compactionThreshold, 16000);
      expect(config.broadcastChat.streamEnabled, true);
    });
  });

  group('ResourceAiConfig', () {
    test('默认解析：maxSteps=6、model 未配置', () {
      final config = AppConfig.fromJson({});
      expect(config.resourceAi.maxSteps, 6);
      expect(config.resourceAi.modelPresetId, isNull);
      expect(config.resourceAi.modelId, isNull);
    });

    test('fromJson 解析 resource_ai 段（模型引用+max_steps）', () {
      final config = AppConfig.fromJson({
        'resource_ai': {
          'max_steps': 8,
          'model': {'preset_id': 'openrouter', 'model_id': 'agnes-2.5-flash'},
        },
      });
      expect(config.resourceAi.maxSteps, 8);
      expect(config.resourceAi.modelPresetId, 'openrouter');
      expect(config.resourceAi.modelId, 'agnes-2.5-flash');
    });
  });
}
