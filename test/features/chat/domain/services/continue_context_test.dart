import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/features/chat/domain/services/continue_context.dart';

/// 续写接写合并的 API 上下文构造（纯函数）
void main() {
  group('mergeContinueContext', () {
    test('末条为半截 assistant → 原位替换为单条 user（指令前缀+半截内容）', () {
      final context = [
        {'role': 'system', 'content': 'prompt'},
        {'role': 'user', 'content': '写个故事'},
        {'role': 'assistant', 'content': '从前有座山，'},
      ];

      final merged = mergeContinueContext(context, halfContent: '从前有座山，');

      expect(merged, hasLength(3));
      // 前两条不动
      expect(merged[0]['role'], 'system');
      expect(merged[1]['content'], '写个故事');
      // 末条：user 角色，指令前缀 + 半截内容
      expect(merged.last['role'], 'user');
      final content = merged.last['content'] as String;
      expect(content, startsWith('下面是上一条被中断的回复'));
      expect(content, contains('从中断处继续写完'));
      expect(content, endsWith('从前有座山，'));
    });

    test('截断裁掉半截条目（末条非 assistant）→ 追加在末尾，半截正文不丢', () {
      final context = [
        {'role': 'system', 'content': 'prompt'},
        {'role': 'user', 'content': '写个故事'},
      ];

      final merged = mergeContinueContext(context, halfContent: '半截');

      expect(merged, hasLength(3));
      expect(merged.last['role'], 'user');
      expect(merged.last['content'] as String, contains('半截'));
    });

    test('半截内容为空 → 原样返回（无可接写内容）', () {
      final context = [
        {'role': 'user', 'content': '写个故事'},
      ];
      expect(mergeContinueContext(context, halfContent: ''), same(context));
    });

    test('自定义指令生效', () {
      final merged = mergeContinueContext(
        [
          {'role': 'assistant', 'content': 'x'},
        ],
        halfContent: 'x',
        directive: 'GO',
      );
      expect(merged.last['content'], 'GO\n\nx');
    });
  });
}
