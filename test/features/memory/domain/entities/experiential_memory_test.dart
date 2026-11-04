import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/features/memory/domain/entities/experiential_memory.dart';

/// ExperientialMemory 实体的 toJson/fromJson 测试
///
/// 这些方法是  为持久化 intermediate_round_artifacts 表的
/// retrieved_memories 字段新增的。验证单条/列表的往返一致性、
/// nullable 字段处理、空列表边界。
void main() {
  group('ExperientialMemory', () {
    group('toJson / fromJson 往返', () {
      test('1. 完整字段往返：所有字段精确匹配', () {
        final original = ExperientialMemory(
          memoryId: 'm-001',
          sessionId: 'session-1',
          summary: '勇者发现古碑',
          importance: 4,
          tags: const ['探索', '古碑'],
          turnNumber: 3,
          narrativeTime: '黄昏',
          narrativePeriod: '第一章',
          hasEmbedding: true,
          createdAt: DateTime(2026, 7, 4, 12, 30, 45),
        );

        final restored = ExperientialMemory.fromJson(original.toJson());

        expect(restored.memoryId, original.memoryId);
        expect(restored.sessionId, original.sessionId);
        expect(restored.summary, original.summary);
        expect(restored.importance, original.importance);
        expect(restored.tags, original.tags);
        expect(restored.turnNumber, original.turnNumber);
        expect(restored.narrativeTime, original.narrativeTime);
        expect(restored.narrativePeriod, original.narrativePeriod);
        expect(restored.isArchived, original.isArchived);
        expect(restored.isSummary, original.isSummary);
        expect(restored.hasEmbedding, original.hasEmbedding);
        // DateTime 经 ISO 字符串往返
        expect(restored.createdAt, original.createdAt);
      });

      test('2. nullable narrative 字段为 null 往返', () {
        final original = ExperientialMemory(
          memoryId: 'm-002',
          sessionId: 's',
          summary: '事件摘要',
          importance: 2,
          tags: const ['标签'],
          turnNumber: 1,
          createdAt: DateTime(2026),
        );

        final restored = ExperientialMemory.fromJson(original.toJson());

        expect(restored.narrativeTime, isNull);
        expect(restored.narrativePeriod, isNull);
        expect(restored.isArchived, isFalse);
        expect(restored.isSummary, isFalse);
        expect(restored.hasEmbedding, isFalse);
      });

      test('3. isArchived=true / isSummary=true 往返', () {
        final original = ExperientialMemory(
          memoryId: 'm-003',
          sessionId: 's',
          summary: '已归档摘要',
          importance: 5,
          tags: const ['关键事件'],
          turnNumber: 10,
          isArchived: true,
          isSummary: true,
          hasEmbedding: true,
          createdAt: DateTime(2026),
        );

        final restored = ExperientialMemory.fromJson(original.toJson());

        expect(restored.isArchived, isTrue);
        expect(restored.isSummary, isTrue);
        expect(restored.hasEmbedding, isTrue);
      });
    });

    group('listFromJsonString / listToJsonString', () {
      test('4. 空列表往返', () {
        final json = ExperientialMemory.listToJsonString(const []);
        expect(json, '[]');

        final restored = ExperientialMemory.listFromJsonString(json);
        expect(restored, isEmpty);
      });

      test('5. 单元素列表往返', () {
        final original = [
          ExperientialMemory(
            memoryId: 'm1',
            sessionId: 's',
            summary: '事件 1',
            importance: 3,
            tags: const ['探索'],
            turnNumber: 1,
            createdAt: DateTime(2026),
          ),
        ];

        final json = ExperientialMemory.listToJsonString(original);
        final restored = ExperientialMemory.listFromJsonString(json);

        expect(restored.length, 1);
        expect(restored[0].memoryId, 'm1');
        expect(restored[0].summary, '事件 1');
        expect(restored[0].importance, 3);
        expect(restored[0].tags, ['探索']);
      });

      test('6. 多元素列表往返：保留顺序与字段', () {
        final original = [
          ExperientialMemory(
            memoryId: 'm1',
            sessionId: 's',
            summary: '事件 A',
            importance: 3,
            tags: const ['探索'],
            turnNumber: 1,
            createdAt: DateTime(2026),
          ),
          ExperientialMemory(
            memoryId: 'm2',
            sessionId: 's',
            summary: '事件 B',
            importance: 5,
            tags: const ['关键', '战斗'],
            turnNumber: 2,
            hasEmbedding: true,
            createdAt: DateTime(2026, 1, 2),
          ),
          ExperientialMemory(
            memoryId: 'm3',
            sessionId: 's',
            summary: '事件 C',
            importance: 1,
            tags: const [],
            turnNumber: 3,
            createdAt: DateTime(2026, 1, 3),
          ),
        ];

        final json = ExperientialMemory.listToJsonString(original);
        final restored = ExperientialMemory.listFromJsonString(json);

        expect(restored.length, 3);
        expect(restored[0].memoryId, 'm1');
        expect(restored[1].memoryId, 'm2');
        expect(restored[2].memoryId, 'm3');
        expect(restored[1].hasEmbedding, isTrue);
        expect(restored[2].tags, isEmpty);
      });

      test('7. listToJsonString 输出 JSON 数组字符串', () {
        final original = [
          ExperientialMemory(
            memoryId: 'm1',
            sessionId: 's',
            summary: '事件 1',
            importance: 3,
            tags: const ['探索'],
            turnNumber: 1,
            createdAt: DateTime(2026),
          ),
        ];

        final json = ExperientialMemory.listToJsonString(original);
        // 是合法 JSON 数组字符串
        expect(json.startsWith('['), isTrue);
        expect(json.endsWith(']'), isTrue);
        expect(json.contains('"memoryId":"m1"'), isTrue);
      });
    });

    group('formatDisplayText 与 displayText', () {
      test('有内容时返回拼接结果', () {
        final m = ExperientialMemory(
          memoryId: 'm1',
          sessionId: 's',
          what: '发现了宝箱',
          who: '主角',
          importance: 3,
          tags: const [],
          turnNumber: 1,
          createdAt: DateTime(2026),
        );
        expect(m.formatDisplayText(emptyPlaceholder: 'Empty'), '发现了宝箱 · 主角');
        expect(m.displayText, '发现了宝箱 · 主角');
      });

      test('全空时 formatDisplayText 返回指定占位符，displayText 保持协议兜底', () {
        final m = ExperientialMemory(
          memoryId: 'm1',
          sessionId: 's',
          importance: 3,
          tags: const [],
          turnNumber: 1,
          createdAt: DateTime(2026),
        );
        expect(m.formatDisplayText(emptyPlaceholder: 'No events'), 'No events');
        expect(m.displayText, '(空事件)');
      });
    });
  });
}
