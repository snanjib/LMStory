import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/features/chat/domain/services/configuration_resolver.dart';
import 'package:lmstory/features/chat/domain/services/llm_service.dart';
import 'package:lmstory/features/story_runtime/domain/services/session_title_generator.dart';

void main() {
  group('SessionTitleGenerator.fallbackTitle', () {
    test('普通消息截取前 20 字符并清理换行', () {
      final title = SessionTitleGenerator.fallbackTitle(
        '第一行内容\n第二行内容超出二十个字符部分省略',
        defaultTitle: '新建会话',
      );
      expect(title, '第一行内容 第二行内容超出二十个字符部分');
      expect(title.length, 20);
    });

    test('空消息或纯空白回退到 defaultTitle', () {
      expect(
        SessionTitleGenerator.fallbackTitle(
          '',
          defaultTitle: '新建会话',
        ),
        '新建会话',
      );
      expect(
        SessionTitleGenerator.fallbackTitle(
          '   \n\t  ',
          defaultTitle: 'New Session',
        ),
        'New Session',
      );
    });
  });

  test('温度统一键：普通模型 0.3，禁发名单模型 null', () async {
    final llm = _RecordingLlmService('标题');
    final generator = SessionTitleGenerator(llmService: llm);

    await generator.generate(
      userMessage: '你好',
      assistantReply: '你好呀',
      namingConfig: const NamingConfig(
        baseUrl: 'https://a.com',
        apiKey: 'k',
        modelId: 'deepseek-chat',
      ),
    );
    expect(llm.lastRequest!.temperature, 0.3);

    await generator.generate(
      userMessage: '你好',
      assistantReply: '你好呀',
      namingConfig: const NamingConfig(
        baseUrl: 'https://a.com',
        apiKey: 'k',
        modelId: 'kimi-k2.6',
      ),
    );
    expect(llm.lastRequest!.temperature, isNull);
  });
}

class _RecordingLlmService implements LlmService {
  _RecordingLlmService(this.reply);

  final String reply;
  LlmRequest? lastRequest;

  @override
  Future<LlmResponse> chat(LlmRequest request) async {
    lastRequest = request;
    return LlmResponse(content: reply);
  }

  @override
  Stream<LlmStreamEvent> streamChat(LlmRequest request) {
    throw UnimplementedError();
  }
}
