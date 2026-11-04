import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/features/advanced/domain/entities/retrieval_profile.dart';

/// 导演会话「检索松紧度」快照值类测试。
///
/// 口径：三档持有具体值（快照语义，选中即写入、互不追溯）；
/// 「平衡」= 当前全局行为的具体快照（topK 8、不过滤）；
/// 解码宽容——坏 JSON/非对象返回 null，缺键回落消费方默认值。
void main() {
  group('三档预设', () {
    test('平衡档 = 全局行为快照（topK 8、不过滤）', () {
      expect(RetrievalProfile.balanced.topK, 8);
      expect(RetrievalProfile.balanced.vectorScoreThreshold, 0);
    });

    test('保守档比平衡档更挑剔（更少条数 + 过滤低分）', () {
      expect(
        RetrievalProfile.conservative.topK,
        lessThan(RetrievalProfile.balanced.topK!),
      );
      expect(
        RetrievalProfile.conservative.vectorScoreThreshold,
        greaterThan(0),
      );
    });

    test('宽松档比平衡档更广（更多条数）', () {
      expect(
        RetrievalProfile.loose.topK,
        greaterThan(RetrievalProfile.balanced.topK!),
      );
    });

    test('三档互不相同（选中态回显依赖同值判定）', () {
      final [c, b, l] = RetrievalProfile.tiers;
      expect(c.sameAs(b), isFalse);
      expect(b.sameAs(l), isFalse);
      expect(c.sameAs(l), isFalse);
    });
  });

  group('编解码 roundtrip', () {
    test('encode → decode 逐字段存活', () {
      for (final tier in RetrievalProfile.tiers) {
        final decoded = RetrievalProfile.tryDecode(tier.encode());
        expect(decoded, isNotNull);
        expect(decoded!.sameAs(tier), isTrue, reason: tier.encode());
      }
    });

    test('坏 JSON → null（不抛）', () {
      expect(RetrievalProfile.tryDecode('{not-json'), isNull);
    });

    test('非对象 JSON（数组）→ null', () {
      expect(RetrievalProfile.tryDecode('[1]'), isNull);
    });

    test('null/空串 → null', () {
      expect(RetrievalProfile.tryDecode(null), isNull);
      expect(RetrievalProfile.tryDecode(''), isNull);
    });

    test('缺键宽容：未知键忽略、缺键回落 null', () {
      final decoded = RetrievalProfile.fromJson({
        'top_k': 6,
        'unknown_key': 'x',
      });
      expect(decoded.topK, 6);
      expect(decoded.vectorScoreThreshold, isNull);
    });

    test('浮点容错：阈值以 num 存储也能解码', () {
      final decoded = RetrievalProfile.fromJson({
        'top_k': 8,
        'vector_score_threshold': 0.55,
      });
      expect(decoded.vectorScoreThreshold, 0.55);
    });
  });
}
