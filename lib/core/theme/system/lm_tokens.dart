import 'package:flutter/material.dart';
import 'package:lmstory/core/theme/system/lm_palette.dart';
import 'package:lmstory/core/theme/system/theme_catalog.dart';

export 'package:lmstory/core/theme/system/lm_palette.dart';

/// 外观 token 载体（ThemeExtension）：当前配色槽位 + 结构/配色身份。
///
/// 组件经 `context.lm.palette` 取色；structureId/paletteId 是缓存与
/// 主题装配的身份键（markdown 缓存失效依据）。
class LmTokens extends ThemeExtension<LmTokens> {
  const LmTokens({
    required this.structureId,
    required this.paletteId,
    required this.palette,
    required this.material,
  });

  final String structureId;
  final String paletteId;
  final LmPalette palette;
  final ColorScheme material;

  @override
  LmTokens copyWith({
    String? structureId,
    String? paletteId,
    LmPalette? palette,
    ColorScheme? material,
  }) {
    return LmTokens(
      structureId: structureId ?? this.structureId,
      paletteId: paletteId ?? this.paletteId,
      palette: palette ?? this.palette,
      material: material ?? this.material,
    );
  }

  @override
  LmTokens lerp(covariant LmTokens? other, double t) {
    if (other == null) return this;
    return LmTokens(
      structureId: t < 0.5 ? structureId : other.structureId,
      paletteId: t < 0.5 ? paletteId : other.paletteId,
      palette: palette.lerp(other.palette, t),
      material: ColorScheme.lerp(material, other.material, t),
    );
  }
}

extension LmThemeContext on BuildContext {
  LmTokens get lm {
    final theme = Theme.of(this);
    return theme.extension<LmTokens>() ??
        ThemeCatalog.fallbackTokens(theme.brightness)
            .copyWith(material: theme.colorScheme);
  }
}
