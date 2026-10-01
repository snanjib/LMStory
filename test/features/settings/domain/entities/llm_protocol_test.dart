import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/features/settings/domain/entities/llm_protocol.dart';

void main() {
  group('LlmProtocol', () {
    test('toJson 返回 name 字符串', () {
      expect(LlmProtocol.openaiCompatible.toJson(), 'openaiCompatible');
      expect(LlmProtocol.openaiResponses.toJson(), 'openaiResponses');
      expect(LlmProtocol.anthropic.toJson(), 'anthropic');
      expect(LlmProtocol.geminiNative.toJson(), 'geminiNative');
    });

    test('fromJson 正确解析已知值', () {
      expect(
        LlmProtocol.fromJson('openaiCompatible'),
        LlmProtocol.openaiCompatible,
      );
      expect(LlmProtocol.fromJson('anthropic'), LlmProtocol.anthropic);
      expect(LlmProtocol.fromJson('geminiNative'), LlmProtocol.geminiNative);
      expect(
        LlmProtocol.fromJson('openaiResponses'),
        LlmProtocol.openaiResponses,
      );
    });

    test('fromJson 对未知值回退到 openaiCompatible', () {
      expect(LlmProtocol.fromJson('unknown'), LlmProtocol.openaiCompatible);
      expect(LlmProtocol.fromJson(''), LlmProtocol.openaiCompatible);
    });

    test('fromJson 对 null 回退到 openaiCompatible', () {
      expect(LlmProtocol.fromJson(null), LlmProtocol.openaiCompatible);
    });

    test('displayName 返回非空中文显示名', () {
      for (final protocol in LlmProtocol.values) {
        expect(protocol.displayName, isNotEmpty);
      }
    });
  });
}
