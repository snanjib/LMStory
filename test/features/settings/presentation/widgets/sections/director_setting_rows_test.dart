import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/features/settings/presentation/widgets/sections/director_setting_rows.dart';
import 'package:lmstory/i18n/strings.g.dart';

/// DirectorSettingRows 步进行触控热区测试
///
/// 口径：UA 批 8把 28×28 触控目标收敛为 ≥44px——导演设置页
/// 全部 stepper（预算/记忆分区 +  两行）同批未收敛，± 按钮热区
/// 须垫到 ≥44（图标视觉 16px 不变）。
void main() {
  setUpAll(() {
    LocaleSettings.setLocale(AppLocale.zhCn);
  });

  testWidgets('DirectorStepperRow ± 按钮触控热区 ≥44px', (tester) async {
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          home: Scaffold(
            body: DirectorStepperRow(
              label: '回复候选数量',
              value: 3,
              min: 1,
              max: 5,
              onChanged: (_) {},
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    final minusSize =
        tester.getSize(find.widgetWithIcon(IconButton, Icons.remove));
    expect(
      minusSize.height,
      greaterThanOrEqualTo(44),
      reason: '「−」按钮热区须 ≥44px（UA 批 8 触控目标口径）',
    );
    final plusSize = tester.getSize(find.widgetWithIcon(IconButton, Icons.add));
    expect(
      plusSize.height,
      greaterThanOrEqualTo(44),
      reason: '「+」按钮热区须 ≥44px（UA 批 8 触控目标口径）',
    );
  });
}
