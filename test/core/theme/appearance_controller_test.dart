import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/di/providers.dart';
import 'package:lmstory/core/storage/preferences.dart';
import 'package:lmstory/core/theme/appearance_controller.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';
import 'package:lmstory/core/theme/system/theme_catalog.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<Preferences> preferences(Map<String, Object> values) async {
    SharedPreferences.setMockInitialValues(values);
    return Preferences(prefs: await SharedPreferences.getInstance());
  }

  test(
    'startup pre-read persists defaults for absent axes',
    () async {
      final prefs = await preferences({});
      expect(
        await AppearanceNotifier.readInitial(prefs),
        ThemeCatalog.defaults,
      );
      expect(await prefs.getString('appearance_structure'), 'classic');
      expect(await prefs.getString('appearance_palette'), 'classic');
    },
  );

  for (final key in ['appearance_structure', 'appearance_palette']) {
    test(
      'unknown $key falls back and repairs the stored pair',
      () async {
        final prefs = await preferences({key: 'removed-package'});
        expect(
          await AppearanceNotifier.readInitial(prefs),
          ThemeCatalog.defaults,
        );
        expect(await prefs.getString('appearance_structure'), 'classic');
        expect(await prefs.getString('appearance_palette'), 'classic');
      },
    );
  }

  test(
    'pre-read injection exposes the selected assembly immediately',
    () async {
      final prefs = await preferences(
        {
          'appearance_structure': 'classic',
          'appearance_palette': 'classic',
        },
      );
      final initial = await AppearanceNotifier.readInitial(prefs);
      final container = ProviderContainer(
        overrides: [
          preferencesProvider.overrideWithValue(prefs),
          appearanceProvider.overrideWith(
            (ref) => AppearanceNotifier(prefs, initialValue: initial),
          ),
        ],
      );
      addTearDown(container.dispose);
      expect(container.read(appearanceProvider), initial);
      final themes = container.read(appearanceThemesProvider);
      expect(themes.light.brightness, Brightness.light);
      expect(themes.dark.brightness, Brightness.dark);
      expect(
        themes.light.extension<LmTokens>()?.structureId,
        initial.structureId,
      );
      expect(themes.dark.extension<LmTokens>()?.paletteId, initial.paletteId);
      expect(
        themes.light.scaffoldBackgroundColor,
        isNot(themes.dark.scaffoldBackgroundColor),
      );
    },
  );

  test(
    'switching axes resolves and persists before subsequent startup',
    () async {
      final prefs = await preferences({});
      final notifier = AppearanceNotifier(prefs);
      addTearDown(notifier.dispose);
      await notifier.setAppearance(
        const LmAppearance(structureId: 'unknown', paletteId: 'unknown'),
      );
      await notifier.setAppearance(ThemeCatalog.defaults);
      expect(notifier.state, await AppearanceNotifier.readInitial(prefs));
    },
  );

  test(
    'startup loading cannot overwrite a subsequent axis selection',
    () async {
      final prefs = await preferences({'appearance_structure': 'removed'});
      final notifier = AppearanceNotifier(prefs);
      addTearDown(notifier.dispose);
      await Future.wait(
        [
          notifier.setAppearance(ThemeCatalog.defaults),
          notifier.setAppearance(const LmAppearance(paletteId: 'removed')),
        ],
      );
      expect(notifier.state, ThemeCatalog.defaults);
      expect(await AppearanceNotifier.readInitial(prefs), notifier.state);
    },
  );

  test('catalog exposes registered axes; unregistered ids fall back', () {
    expect(ThemeCatalog.structures.map((entry) => entry.id), [
      'classic',
      'glass',
      'brutal',
      'wonder',
    ]);
    expect(ThemeCatalog.palettes.map((entry) => entry.id), [
      'classic',
      'bordeaux',
    ]);
    expect(
      ThemeCatalog.resolve(const LmAppearance(paletteId: 'nightvoyage')),
      ThemeCatalog.defaults,
    );
  });
}
