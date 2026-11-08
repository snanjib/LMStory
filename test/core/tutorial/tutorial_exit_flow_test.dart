import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/tutorial/tutorial_controller.dart';

/// r3 修复回归：退出确认不能提前终止教程。
///
/// 遮罩「退出体验」按钮现在只请求退出（requestExit，不结束教程）；
/// 宿主弹确认框后：继续体验→cancelExit 原地恢复；确认退出/放弃→
/// end/宿主销毁。保留原步骤、输入锁与回放进度。
void main() {
  TutorialStep step(String id, {String? targetId}) => TutorialStep(
        id: id,
        title: id,
        message: id,
        targetId: targetId,
      );

  group('requestExit 不提前终止', () {
    test('requestExit：保持活动与当前步骤，仅置退出请求态', () {
      var exitRequested = 0;
      var aborted = 0;
      final c = TutorialController()
        ..onExitRequested = () {
          exitRequested++;
        }
        ..onAborted = () {
          aborted++;
        }
        ..begin([step('a'), step('b')])
        ..next() // 到 b
        ..requestExit();
      expect(c.active, isTrue, reason: '请求退出不得终止教程');
      expect(c.current!.id, 'b', reason: '原步骤保留');
      expect(c.exitRequestOpen, isTrue);
      expect(exitRequested, 1, reason: '宿主收到退出请求（弹确认框）');
      expect(aborted, 0);
    });

    test('cancelExit：清除请求态，教程原地继续（不重启一轮）', () {
      final c = TutorialController()
        ..onExitRequested = () {}
        ..begin([step('a'), step('b')])
        ..next()
        ..requestExit()
        ..cancelExit();
      expect(c.active, isTrue);
      expect(c.exitRequestOpen, isFalse);
      expect(c.current!.id, 'b', reason: '步骤与进度原样保留');
    });

    test('重复 requestExit 不重复通知；end 后请求态清除', () {
      var exitRequested = 0;
      final c = TutorialController()
        ..onExitRequested = () {
          exitRequested++;
        }
        ..begin([step('a')])
        ..requestExit()
        ..requestExit();
      expect(exitRequested, 1, reason: '请求打开期间不重复通知宿主');

      c.end(aborted: true);
      expect(c.exitRequestOpen, isFalse);
    });

    test('abort 语义保留（直接结束，供宿主确认后调用）', () {
      var aborted = 0;
      final c = TutorialController()
        ..onAborted = () {
          aborted++;
        }
        ..begin([step('a')])
        ..abort();
      expect(c.active, isFalse);
      expect(aborted, 1);
    });
  });
}
