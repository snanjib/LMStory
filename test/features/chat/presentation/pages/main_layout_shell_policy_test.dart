import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/features/chat/presentation/pages/main_layout.dart';

/// 桌面壳/移动壳分流策略的行为锁（纯函数层）。
///
/// 此前壳分流纯看宽度：桌面窗口拖窄到断点下整个壳切「移动壳」——
/// 侧栏变抽屉、全局快捷键静默失效、出现触屏语义。锁三条不变量：
/// 1. 原生桌面平台恒桌面壳（任意宽度，含 0）；
/// 2. Web 与移动平台保持宽度响应式（窄=移动壳）；
/// 3. 桌面窄窗由调用方另行收侧栏（本函数只管壳形态）。
void main() {
  const bp = 600.0;

  test('原生桌面平台任意宽度都是桌面壳', () {
    for (final platform in [
      TargetPlatform.macOS,
      TargetPlatform.windows,
      TargetPlatform.linux,
    ]) {
      for (final width in [0.0, 320.0, 599.9, 600.0, 840.0, 1920.0]) {
        expect(
          MainLayout.isMobileShell(
            width: width,
            breakpoint: bp,
            isWeb: false,
            platform: platform,
          ),
          isFalse,
          reason: '$platform 宽 $width 不得切移动壳（换壳=快捷键失效/侧栏变抽屉）',
        );
      }
    }
  });

  test('Web 与移动平台保持宽度响应式', () {
    for (final (platform, isWeb) in [
      (TargetPlatform.iOS, false),
      (TargetPlatform.android, false),
      (TargetPlatform.macOS, true), // Web 浏览器宿主在 macOS
      (TargetPlatform.windows, true), // Web 浏览器宿主在 Windows
    ]) {
      expect(
        MainLayout.isMobileShell(
          width: 500,
          breakpoint: bp,
          isWeb: isWeb,
          platform: platform,
        ),
        isTrue,
        reason: '$platform(isWeb=$isWeb) 窄视口应为移动壳',
      );
      expect(
        MainLayout.isMobileShell(
          width: 1200,
          breakpoint: bp,
          isWeb: isWeb,
          platform: platform,
        ),
        isFalse,
        reason: '$platform(isWeb=$isWeb) 宽视口应为桌面壳',
      );
    }
  });
}
