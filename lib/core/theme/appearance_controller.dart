import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lmstory/core/di/providers.dart';
import 'package:lmstory/core/storage/preferences.dart';
import 'package:lmstory/core/theme/system/theme_catalog.dart';

final appearanceProvider =
    StateNotifierProvider<AppearanceNotifier, LmAppearance>(
  (ref) => AppearanceNotifier(ref.read(preferencesProvider)),
);

final appearanceThemesProvider = Provider<({ThemeData light, ThemeData dark})>(
  (ref) {
    final appearance = ref.watch(appearanceProvider);
    return (
      light: ThemeCatalog.assemble(appearance, Brightness.light),
      dark: ThemeCatalog.assemble(appearance, Brightness.dark),
    );
  },
);

class AppearanceNotifier extends StateNotifier<LmAppearance> {
  AppearanceNotifier(this._prefs, {LmAppearance? initialValue})
      : super(ThemeCatalog.resolve(initialValue ?? ThemeCatalog.defaults)) {
    _loading = initialValue == null ? _load() : Future<void>.value();
  }

  static const structureKey = 'appearance_structure';
  static const paletteKey = 'appearance_palette';
  final Preferences _prefs;
  late final Future<void> _loading;
  Future<void> _writing = Future<void>.value();

  static Future<LmAppearance> readInitial(Preferences prefs) async {
    final structureId = await prefs.getString(structureKey);
    final paletteId = await prefs.getString(paletteKey);
    final resolved = ThemeCatalog.resolve(
      LmAppearance(
        structureId: structureId ?? ThemeCatalog.defaults.structureId,
        paletteId: paletteId ?? ThemeCatalog.defaults.paletteId,
      ),
    );
    if (structureId != resolved.structureId) {
      await prefs.setString(structureKey, resolved.structureId);
    }
    if (paletteId != resolved.paletteId) {
      await prefs.setString(paletteKey, resolved.paletteId);
    }
    return resolved;
  }

  Future<void> _load() async {
    final initial = await readInitial(_prefs);
    if (mounted) state = initial;
  }

  Future<void> setAppearance(LmAppearance requested) async {
    await _loading;
    if (!mounted) return;
    final resolved = ThemeCatalog.resolve(requested);
    state = resolved;
    final writing = _writing.then(
      (_) async {
        await _prefs.setString(structureKey, resolved.structureId);
        await _prefs.setString(paletteKey, resolved.paletteId);
      },
    );
    // A failed write is reported to its caller but does not poison later saves.
    _writing = writing.catchError((Object _) {});
    await writing;
  }
}
