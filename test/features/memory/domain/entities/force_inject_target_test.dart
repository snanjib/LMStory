import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/features/memory/domain/entities/force_inject_target.dart';

void main() {
  test('ForceInjectTarget.fromString 解析三态', () {
    expect(ForceInjectTarget.fromString('none'), ForceInjectTarget.none);
    expect(ForceInjectTarget.fromString('world'), ForceInjectTarget.world);
    expect(
      ForceInjectTarget.fromString('directive'),
      ForceInjectTarget.directive,
    );
    expect(ForceInjectTarget.fromString('unknown'), ForceInjectTarget.none);
  });

  test('toDbString 往返一致', () {
    for (final v in ForceInjectTarget.values) {
      expect(ForceInjectTarget.fromString(v.toDbString()), v);
    }
  });
}
