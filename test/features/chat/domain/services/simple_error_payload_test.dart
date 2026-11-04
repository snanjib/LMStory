import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/theme/system/structures/classic/conversation/simple_message_bubble.dart';
import 'package:lmstory/features/chat/domain/entities/chat_message.dart';
import 'package:lmstory/features/chat/domain/services/simple_failure_classifier.dart';
import 'package:lmstory/i18n/strings.g.dart';

/// 错误卡结构化存储。
///
/// 新写入 = `lmerr:` JSON 前缀（SimpleErrorPayload）；渲染层（_ErrorMessage
/// 的 _parseErrorText）先试结构化解码，失败回退旧 `\n建议：`/`\n详细信息：`
/// 分隔符——存量消息兼容，英文 locale 不再依赖硬编码中文分隔符隐性协议。
void main() {
  setUpAll(() {
    LocaleSettings.setLocale(AppLocale.zhCn);
  });

  group('SimpleErrorPayload 编解码往返', () {
    test('全字段 encode → tryDecode 无损往返（rawError 含换行与建议字样）', () {
      const payload = SimpleErrorPayload(
        message: '网络连接失败，请检查网络后重试',
        code: 'S002',
        suggestion: '切换 Wi-Fi/移动数据',
        detail: 'Connection refused\n建议：这是原始错误里混入的字样',
      );
      final decoded = SimpleErrorPayload.tryDecode(payload.encode());
      expect(decoded, isNotNull);
      expect(decoded!.message, payload.message);
      expect(decoded.code, 'S002');
      expect(decoded.suggestion, payload.suggestion);
      expect(decoded.detail, contains('Connection refused'));
    });

    test('null 字段省略不进 JSON；code/detail null 往返仍 null', () {
      const payload = SimpleErrorPayload(message: '配置不完整');
      final encoded = payload.encode();
      expect(encoded, 'lmerr:{"message":"配置不完整"}');
      final decoded = SimpleErrorPayload.tryDecode(encoded);
      expect(decoded!.code, isNull);
      expect(decoded.suggestion, isNull);
      expect(decoded.detail, isNull);
    });

    test('非本格式/坏 JSON/缺 message → null（调用方回退旧解析）', () {
      expect(SimpleErrorPayload.tryDecode('网络连接失败（S002）'), isNull);
      expect(SimpleErrorPayload.tryDecode('lmerr:{broken'), isNull);
      expect(SimpleErrorPayload.tryDecode('lmerr:{"code":"S002"}'), isNull);
      expect(SimpleErrorPayload.tryDecode('lmerr:"plain string"'), isNull);
    });

    test('formatPersisted 与 buildErrorPayload 同源（分类取值+detail 截断）', () {
      const classifier = SimpleFailureClassifier();
      final persisted = classifier.formatPersisted(
        SimpleFailureClassifier.network,
        'S002',
        rawError: 'x' * 600,
      );
      final decoded = SimpleErrorPayload.tryDecode(persisted);
      expect(decoded, isNotNull);
      expect(
        decoded!.message,
        classifier.resolveMessage(SimpleFailureClassifier.network),
      );
      expect(
        decoded.suggestion,
        classifier.resolveSuggestion(SimpleFailureClassifier.network),
      );
      expect(decoded.detail!.length, 500, reason: 'rawError 截断 500');
    });
  });

  group('_ErrorMessage 渲染（新格式优先，旧格式 fallback）', () {
    Future<void> pumpError(WidgetTester tester, String errorText) async {
      await tester.pumpWidget(
        TranslationProvider(
          child: MaterialApp(
            home: Scaffold(
              body: SizedBox(
                width: 800,
                height: 600,
                child: ListView(
                  children: [
                    SimpleMessageBubble(
                      message: ChatMessage(
                        messageId: 'm1',
                        sessionId: 's1',
                        role: 'assistant',
                        content: '',
                        error: errorText,
                        createdAt: DateTime(2026),
                      ),
                      isStreaming: false,
                      isConsecutive: false,
                      onCopy: () {},
                      onDelete: () {},
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    }

    testWidgets('lmerr: 新格式——错误描述+错误码+建议行均渲染', (tester) async {
      const payload = SimpleErrorPayload(
        message: '网络连接失败，请检查网络后重试',
        code: 'S002',
        suggestion: '切换 Wi-Fi/移动数据',
        detail: 'Connection refused',
      );
      await pumpError(tester, payload.encode());
      expect(
        find.textContaining('网络连接失败，请检查网络后重试（S002）'),
        findsOneWidget,
        reason: '结构化渲染：message+code 拼接',
      );
      expect(find.textContaining('切换 Wi-Fi/移动数据'), findsOneWidget);
      // detail 默认折叠为可展开区域，展开按钮在
      expect(find.textContaining('详细信息'), findsWidgets);
    });

    testWidgets(r'lmerr: 新格式——原始 detail 含「\n建议：」字样不再劫持解析', (tester) async {
      const payload = SimpleErrorPayload(
        message: '服务器异常，请稍后重试',
        code: 'S005',
        suggestion: '真正的建议行',
        detail: '原始错误\n建议：混入的字样',
      );
      await pumpError(tester, payload.encode());
      expect(
        find.textContaining('真正的建议行'),
        findsOneWidget,
        reason: '建议行取 payload.suggestion，而非 detail 里的字样',
      );
    });

    testWidgets(r'旧格式 fallback——\n建议：/\n详细信息： 分隔符照旧解析', (tester) async {
      await pumpError(
        tester,
        '网络连接失败，请检查网络后重试（S002）\n建议：切换 Wi-Fi\n详细信息：boom',
      );
      expect(find.textContaining('网络连接失败，请检查网络后重试（S002）'), findsOneWidget);
      expect(find.textContaining('切换 Wi-Fi'), findsOneWidget);
    });

    testWidgets('无分隔符裸文本——整串按错误描述渲染（最老存量形态）', (tester) async {
      await pumpError(tester, '只是一句裸错误');
      expect(find.textContaining('只是一句裸错误'), findsOneWidget);
    });
  });
}
