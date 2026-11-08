// 风格豁免：状态机测试的「构造→操作→断言」天然连续触碰同一控制器，
// cascade 会破坏断言可读性（规则与测试语义冲突）。
// ignore_for_file: cascade_invocations
import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/tutorial/tutorial_controller.dart';

// 读取助手：隔离连续同接收者语句（风格规则 cascade_invocations）
String currentId(TutorialController c) => c.current!.id;
bool isActive(TutorialController c) => c.active;

void main() {
  TutorialStep step(String id, {String? targetId, bool skippable = false}) =>
      TutorialStep(
        id: id,
        title: id,
        message: id,
        targetId: targetId,
        skippable: skippable,
      );

  test('begin/next/end 全流程回调', () {
    var finished = 0;
    var aborted = 0;
    final c = TutorialController(
      onFinished: () => finished++,
      onAborted: () => aborted++,
    );

    c.begin([step('a'), step('b')]);
    expect(isActive(c), isTrue);
    expect(currentId(c), 'a');

    c.next();
    expect(currentId(c), 'b');

    c.next(); // 末步 → 收尾
    expect(isActive(c), isFalse);
    expect(finished, 1);
    expect(aborted, 0);
  });

  test('abort 触发 onAborted', () {
    var aborted = 0;
    final c = TutorialController(onAborted: () => aborted++);
    c
      ..begin([step('a')])
      ..abort();
    expect(isActive(c), isFalse);
    expect(aborted, 1);
  });

  test('空步骤列表立即完成', () {
    var finished = 0;
    final c = TutorialController(onFinished: () => finished++);
    c.begin(const []);
    expect(isActive(c), isFalse);
    expect(finished, 1);
  });

  test('跳过仅限 skippable 步骤', () {
    final c = TutorialController();
    c.begin([step('a'), step('b', skippable: true)]);

    c.skipCurrent();
    expect(currentId(c), 'a', reason: '必需步不可跳过');

    c.jumpTo('b');
    expect(currentId(c), 'b');

    c.skipCurrent();
    expect(isActive(c), isFalse, reason: '可跳过步=末步 → 跳过即收尾');
  });

  test('jumpTo 未知 id 为 no-op；等待态翻转通知', () {
    final c = TutorialController();
    c.begin([step('a')]);

    c.jumpTo('ghost');
    expect(currentId(c), 'a');

    var notified = 0;
    c.addListener(() => notified++);
    c.setWaitingForTarget(waiting: true);
    expect(notified, 1);

    c.setWaitingForTarget(waiting: true); // 同值不通知
    expect(notified, 1);
  });

  test('重复 begin 重置状态', () {
    final c = TutorialController();
    c.begin([step('a'), step('b')]);

    c.next();
    expect(currentId(c), 'b');

    c.begin([step('x')]);
    expect(currentId(c), 'x');
    expect(c.steps, hasLength(1));
  });
}
