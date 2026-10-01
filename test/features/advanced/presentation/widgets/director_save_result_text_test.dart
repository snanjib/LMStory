import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/features/advanced/presentation/widgets/director_session_settings_sheet.dart';
import 'package:lmstory/features/story_runtime/domain/entities/story_phase_models.dart';
import 'package:lmstory/i18n/strings.g.dart';

/// 会话设置保存反馈文案两分
///
/// 生成中被 updateSession 拒绝（phase 非终态）→ 专用引导文案；
/// 真失败（idle/failed 下写库失败）→ 通用保存失败。
/// 判据与 AdvancedChatController.updateSession 守卫同口径。
void main() {
  setUpAll(() {
    LocaleSettings.setLocale(AppLocale.zhCn);
  });

  test('保存成功 → 已保存', () {
    expect(
      directorSaveResultText(t, saved: true, phase: IntermediatePhase.idle),
      '已保存',
    );
  });

  test('生成中拒绝 → 专用文案（可行动：先停止本轮）', () {
    for (final phase in IntermediatePhase.values) {
      if (phase == IntermediatePhase.idle ||
          phase == IntermediatePhase.failed) {
        continue;
      }
      expect(
        directorSaveResultText(t, saved: false, phase: phase),
        '生成进行中，设置暂不可保存——请先停止本轮',
        reason: '$phase 属生成中，应走专用文案',
      );
    }
  });

  test('真失败（idle/failed 下保存失败）→ 通用保存失败', () {
    expect(
      directorSaveResultText(t, saved: false, phase: IntermediatePhase.idle),
      '保存失败，请稍后重试',
    );
    expect(
      directorSaveResultText(t, saved: false, phase: IntermediatePhase.failed),
      '保存失败，请稍后重试',
    );
  });
}
