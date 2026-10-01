import 'package:flutter/material.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';

/// 结构感知表面助手：棱角结构下的批A 表面分流接线层。
///
/// 与琉璃 `glass_surface.dart` 同范式——同一表面代码按当前结构轴分流，
/// 不复制页面。棱角无场地装饰（平涂纸面，scaffold 底=palette.bg
/// 由既有非 glass 路径天然承接），这里只提供结构身份判定。
extension BrutalSurfaceContext on BuildContext {
  /// 当前是否棱角结构（catalog 结构轴）。
  bool get isBrutalSurface =>
      Theme.of(this).extension<LmTokens>()?.structureId == 'brutal';
}
