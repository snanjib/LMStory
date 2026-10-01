import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/features/settings/domain/entities/api_preset.dart';
import 'package:lmstory/features/settings/domain/entities/llm_protocol.dart';

void main() {
  group('ApiPreset', () {
    test('默认 protocol 为 openaiCompatible, templateId 为 null', () {
      final preset = ApiPreset(
        presetId: 'test',
        name: 'Test',
        baseUrl: '',
        createdAt: DateTime(2026, 7, 24),
        updatedAt: DateTime(2026, 7, 24),
      );
      expect(preset.protocol, LlmProtocol.openaiCompatible);
      expect(preset.templateId, isNull);
    });

    test('可指定 protocol 和 templateId', () {
      final preset = ApiPreset(
        presetId: 'test',
        name: 'Test',
        baseUrl: '',
        protocol: LlmProtocol.anthropic,
        templateId: 'tpl-anthropic',
        createdAt: DateTime(2026, 7, 24),
        updatedAt: DateTime(2026, 7, 24),
      );
      expect(preset.protocol, LlmProtocol.anthropic);
      expect(preset.templateId, 'tpl-anthropic');
    });

    test('copyWith 可更新 protocol 和 templateId', () {
      final preset = ApiPreset(
        presetId: 'test',
        name: 'Test',
        baseUrl: '',
        createdAt: DateTime(2026, 7, 24),
        updatedAt: DateTime(2026, 7, 24),
      );
      final updated = preset.copyWith(
        protocol: LlmProtocol.geminiNative,
        templateId: 'tpl-gemini',
        name: 'Gemini Instance',
      );
      expect(updated.protocol, LlmProtocol.geminiNative);
      expect(updated.templateId, 'tpl-gemini');
      expect(updated.name, 'Gemini Instance');
      // 其他字段保持不变
      expect(updated.presetId, 'test');
      expect(updated.baseUrl, '');
    });

    test('toJson 含 protocol 和 templateId 字段', () {
      final preset = ApiPreset(
        presetId: 'test',
        name: 'Test',
        baseUrl: 'https://api.anthropic.com',
        protocol: LlmProtocol.anthropic,
        templateId: 'tpl-anthropic',
        createdAt: DateTime(2026, 7, 24),
        updatedAt: DateTime(2026, 7, 24),
      );
      final json = preset.toJson();
      expect(json['protocol'], 'anthropic');
      expect(json['templateId'], 'tpl-anthropic');
      expect(json['presetId'], 'test');
      expect(json['baseUrl'], 'https://api.anthropic.com');
    });

    test('fromJson 正确解析 protocol 和 templateId', () {
      final json = <String, dynamic>{
        'presetId': 'test',
        'name': 'Test',
        'baseUrl': '',
        'protocol': 'geminiNative',
        'templateId': 'tpl-gemini',
        'cachedModels': <Map<String, dynamic>>[],
        'createdAt': '2026-07-24T00:00:00.000',
        'updatedAt': '2026-07-24T00:00:00.000',
      };
      final preset = ApiPreset.fromJson(json);
      expect(preset.protocol, LlmProtocol.geminiNative);
      expect(preset.templateId, 'tpl-gemini');
      expect(preset.presetId, 'test');
    });

    test('fromJson 对缺失 protocol 字段回退到 openaiCompatible', () {
      final json = <String, dynamic>{
        'presetId': 'old',
        'name': 'Old',
        'baseUrl': '',
        'cachedModels': <Map<String, dynamic>>[],
        'createdAt': '2026-07-24T00:00:00.000',
        'updatedAt': '2026-07-24T00:00:00.000',
      };
      final preset = ApiPreset.fromJson(json);
      expect(preset.protocol, LlmProtocol.openaiCompatible);
      expect(preset.templateId, isNull);
    });

    test('toJson + fromJson 往返一致', () {
      final original = ApiPreset(
        presetId: 'rt-test',
        name: 'Round Trip',
        baseUrl: 'https://api.openai.com',
        isBuiltIn: true,
        createdAt: DateTime(2026, 7, 24),
        updatedAt: DateTime(2026, 7, 24, 12),
      );
      final json = original.toJson();
      final restored = ApiPreset.fromJson(json);
      expect(restored.presetId, original.presetId);
      expect(restored.name, original.name);
      expect(restored.baseUrl, original.baseUrl);
      expect(restored.isBuiltIn, original.isBuiltIn);
      expect(restored.protocol, original.protocol);
      expect(restored.templateId, original.templateId);
    });
  });
}
