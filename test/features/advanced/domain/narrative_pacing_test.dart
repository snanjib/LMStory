import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/features/advanced/domain/entities/narrative_pacing.dart';

void main() {
  group('NarrativePacing 解析', () {
    test('三合法值解析与回写往返', () {
      for (final v in const ['conservative', 'balanced', 'aggressive']) {
        expect(NarrativePacing.fromConfigValue(v).configValue, v);
        expect(NarrativePacing.tryFromConfigValue(v)!.configValue, v);
      }
    });

    test('非法值：fromConfigValue 抛 FormatException，tryFromConfigValue 归 null', () {
      expect(
        () => NarrativePacing.fromConfigValue('fast'),
        throwsFormatException,
      );
      expect(NarrativePacing.tryFromConfigValue('fast'), isNull);
      expect(NarrativePacing.tryFromConfigValue(null), isNull);
    });
  });
}
