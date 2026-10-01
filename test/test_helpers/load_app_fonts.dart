import 'dart:io';

import 'package:flutter/services.dart';

/// 在测试环境注册 pubspec 打包字体（Inter / LMSerif / LMSerifSC / LMMono），
/// 让 golden 与截图有真实字形而不是占位方块。
///
/// flutter_test 不解析系统字体；可选 [withSystemCjkFallback] 从 Windows
/// 系统目录补一个全量中文字体（等线 Deng.ttf）注册到常用回退族名，
/// 供中文 UI 截图使用（golden 夹具文本为英文时无需开启）。
Future<bool> loadAppFonts({bool withSystemCjkFallback = false}) async {
  Future<void> loadFamily(String family, List<String> assets) async {
    final loader = FontLoader(family);
    for (final path in assets) {
      final data = await rootBundle.load(path);
      loader.addFont(Future<ByteData>.value(data));
    }
    await loader.load();
  }

  const inter = 'assets/fonts/Inter';
  const serif = 'assets/fonts/LMSerif';
  const sc = 'assets/fonts/LMSerifSC/LMSerifSC-Regular.ttf';
  const mono = 'assets/fonts/LMMono';

  await loadFamily('Inter', <String>[
    '$inter/Inter-Light.ttf',
    '$inter/Inter-Regular.ttf',
    '$inter/Inter-Medium.ttf',
    '$inter/Inter-SemiBold.ttf',
    '$inter/Inter-Bold.ttf',
  ]);
  await loadFamily('LMSerif', <String>[
    '$serif/LMSerif-Regular.ttf',
    '$serif/LMSerif-Medium.ttf',
  ]);
  await loadFamily('LMSerifSC', <String>[sc]);
  await loadFamily('LMMono', <String>[
    '$mono/LMMono-Regular.ttf',
    '$mono/LMMono-Medium.ttf',
  ]);

  if (!withSystemCjkFallback) {
    return false;
  }
  const dengPath = r'C:\Windows\Fonts\Deng.ttf';
  if (!File(dengPath).existsSync()) {
    return false;
  }
  final cjk = File(dengPath).readAsBytesSync();
  for (final fallbackFamily in const ['Roboto', 'Microsoft YaHei']) {
    final loader = FontLoader(fallbackFamily)
      ..addFont(
        Future<ByteData>.value(
          ByteData.view(cjk.buffer, cjk.offsetInBytes, cjk.lengthInBytes),
        ),
      );
    await loader.load();
  }
  return true;
}

/// flutter_tester 没有平台字体管理器：family 为 null 的文本样式会落到
/// 引擎默认 Roboto——测试占位字体自称拥有全部字形，任何 familyFallback
/// 都轮不到。golden / 截图夹具若涉及中文，必须给样式显式 family。
const kCjkFallbackFamilies = <String>['Microsoft YaHei', 'LMSerifSC'];
