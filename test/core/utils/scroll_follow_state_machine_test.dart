import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/utils/scroll_follow_state_machine.dart';

/// ScrollFollowStateMachine 单元测试（chatbox smooth-follow-output.ts 语义移植）
///
/// 三语义：
/// 1. 上划即停——任意上划（>0.5px）首帧即冻结，不需要脱离 80px 容差带
/// 2. 内容收缩（maxScrollExtent 下降伴随 pixels 下降）不是用户上划，不冻结
/// 3. 滚回距底 ≤4px 自动恢复；发送/「回到最新」强制恢复
void main() {
  /// 冻结态状态机：距底 100px 处一次 -100px 上划。
  ScrollFollowStateMachine frozen() => ScrollFollowStateMachine()
    ..onUserScroll(
      pixelsDelta: -100,
      maxExtentDelta: 0,
      distanceToBottom: 100,
    );

  group('初始与复位', () {
    test('初始状态为跟随', () {
      expect(ScrollFollowStateMachine().following, isTrue);
    });

    test('forceFollowing 强制恢复；reset 恢复', () {
      final m = frozen();
      expect(m.following, isFalse);
      m.forceFollowing();
      expect(m.following, isTrue);
      final frozenAgain = frozen()..reset();
      expect(frozenAgain.following, isTrue);
    });
  });

  group('上划即停', () {
    test('慢速上划多帧小步负 delta：首帧即冻结', () {
      final m = ScrollFollowStateMachine()
        ..onUserScroll(
          pixelsDelta: -20,
          maxExtentDelta: 0,
          distanceToBottom: 60,
        );
      expect(
        m.following,
        isFalse,
        reason: '首帧 -20px 上划即停，不需要脱离 80px 容差带',
      );
      m
        ..onUserScroll(
          pixelsDelta: -5,
          maxExtentDelta: 0,
          distanceToBottom: 65,
        )
        ..onUserScroll(
          pixelsDelta: -1,
          maxExtentDelta: 0,
          distanceToBottom: 66,
        );
      expect(m.following, isFalse);
    });

    test('亚像素抖动（|delta| ≤ 0.5px）不算滚动', () {
      final m = ScrollFollowStateMachine()
        ..onUserScroll(
          pixelsDelta: -0.3,
          maxExtentDelta: 0,
          distanceToBottom: 10,
        );
      expect(m.following, isTrue);
      final frozenAfterJitter = frozen()
        ..onUserScroll(
          pixelsDelta: 0.3,
          maxExtentDelta: 0,
          distanceToBottom: 2,
        );
      expect(
        frozenAfterJitter.following,
        isFalse,
        reason: '冻结后亚像素正 delta 也不恢复',
      );
    });
  });

  group('内容收缩豁免', () {
    test('内容收缩（maxExtentDelta 负）伴随 pixels 下降不冻结', () {
      final m = ScrollFollowStateMachine()
        ..onUserScroll(
          pixelsDelta: -120,
          maxExtentDelta: -150,
          distanceToBottom: 0,
        );
      expect(
        m.following,
        isTrue,
        reason: '收缩钳位把 pixels 拉低不是用户上划',
      );
      m.onUserScroll(
        pixelsDelta: -30,
        maxExtentDelta: 0,
        distanceToBottom: 30,
      );
      expect(
        m.following,
        isFalse,
        reason: '收缩停止后继续上划（extent 不再变化）才是真上划',
      );
    });

    test('内容增长伴随 pixels 上升不影响跟随', () {
      final m = ScrollFollowStateMachine()
        ..onUserScroll(
          pixelsDelta: 200,
          maxExtentDelta: 200,
          distanceToBottom: 0,
        );
      expect(m.following, isTrue);
    });
  });

  group('回底自动恢复', () {
    test('冻结后向下滚且距底 ≤4px 恢复跟随', () {
      final m = frozen()
        ..onUserScroll(
          pixelsDelta: 10,
          maxExtentDelta: 0,
          distanceToBottom: 90,
        );
      expect(m.following, isFalse, reason: '距底 90px > 48px 恢复带：未到恢复线');
      m.onUserScroll(
        pixelsDelta: 86,
        maxExtentDelta: 0,
        distanceToBottom: 4,
      );
      expect(m.following, isTrue, reason: '距底恰为 4px（≤48px 恢复带）应恢复');
    });

    test('D5：冻结后向下滚入缓冲带（≤48px）即恢复跟随', () {
      final m = frozen()
        ..onUserScroll(
          pixelsDelta: 60,
          maxExtentDelta: 0,
          distanceToBottom: 60,
        );
      expect(m.following, isFalse, reason: '距底 60px 超出恢复带：不恢复');
      m.onUserScroll(
        pixelsDelta: 15,
        maxExtentDelta: 0,
        distanceToBottom: 45,
      );
      expect(
        m.following,
        isTrue,
        reason: '写入行拉回视口（距底 45px ≤ max(4, cushion=48) 缓冲带）应恢复',
      );
    });

    test('距底超出恢复带（>48px）向下滚不恢复', () {
      final m = frozen()
        ..onUserScroll(
          pixelsDelta: 90,
          maxExtentDelta: 0,
          distanceToBottom: 60,
        );
      expect(m.following, isFalse, reason: '60px > 48px 恢复带：不恢复');
    });

    test('resumeBandPx 显式注入可收窄恢复带', () {
      final m = ScrollFollowStateMachine(resumeBandPx: 4)
        ..onUserScroll(
          pixelsDelta: -100,
          maxExtentDelta: 0,
          distanceToBottom: 100,
        )
        ..onUserScroll(
          pixelsDelta: 90,
          maxExtentDelta: 0,
          distanceToBottom: 10,
        );
      expect(m.following, isFalse, reason: '注入恢复带 4px：10px 不恢复');
    });
  });

  group('首次调用', () {
    test('宿主首帧传 delta 0：不动状态', () {
      final m = ScrollFollowStateMachine()
        ..onUserScroll(
          pixelsDelta: 0,
          maxExtentDelta: 0,
          distanceToBottom: 500,
        );
      expect(m.following, isTrue);
      final frozenAtRest = frozen()
        ..onUserScroll(
          pixelsDelta: 0,
          maxExtentDelta: 0,
          distanceToBottom: 100,
        );
      expect(frozenAtRest.following, isFalse, reason: '冻结态下 delta 0 同样不动');
    });
  });
}
