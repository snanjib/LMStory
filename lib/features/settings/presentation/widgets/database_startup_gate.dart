import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:lmstory/core/theme/api/lm_component_kit.dart';
import 'package:lmstory/core/theme/simple/simple_spacing.dart';
import 'package:lmstory/features/settings/data/database_startup_recovery.dart';
import 'package:lmstory/features/settings/presentation/pages/database_recovery_page.dart';
import 'package:lmstory/i18n/strings.g.dart';

/// Owns the opened executor and mounts the application only after a real query.
class DatabaseStartupGate extends StatefulWidget {
  const DatabaseStartupGate({
    required this.recovery,
    required this.buildApplication,
    required this.lightTheme,
    required this.darkTheme,
    required this.themeMode,
    super.key,
  });

  final DatabaseStartupRecovery recovery;
  final Future<Widget> Function(OpenedDatabase) buildApplication;
  final ThemeData lightTheme;
  final ThemeData darkTheme;
  final ThemeMode themeMode;

  @override
  State<DatabaseStartupGate> createState() => _DatabaseStartupGateState();
}

class _DatabaseStartupGateState extends State<DatabaseStartupGate> {
  DatabaseOpenFailure? _failure;
  OpenedDatabase? _opened;
  Widget? _application;

  @override
  void initState() {
    super.initState();
    unawaited(_open());
  }

  @override
  void dispose() {
    if (_opened case final opened?) {
      unawaited(closeStartupDatabase(opened.database));
    }
    super.dispose();
  }

  Future<void> _open() async {
    final OpenedDatabase opened;
    try {
      opened = await widget.recovery.open();
    } on DatabaseOpenFailure catch (failure) {
      if (mounted) setState(() => _failure = failure);
      return;
    }
    await _continueWith(opened);
  }

  void _retry() {
    setState(() => _failure = null);
    unawaited(_open());
  }

  Future<void> _continueWith(OpenedDatabase opened) async {
    if (!mounted) {
      await closeStartupDatabase(opened.database);
      return;
    }
    setState(() {
      _opened = opened;
      _failure = null;
    });
    final application = await widget.buildApplication(opened);
    if (mounted) setState(() => _application = application);
  }

  @override
  Widget build(BuildContext context) {
    if (_application case final app?) return app;

    final failure = _failure;
    return TranslationProvider(
      child: Builder(
        builder: (context) => MaterialApp(
          title: 'LMStory',
          locale: TranslationProvider.of(context).flutterLocale,
          theme: widget.lightTheme,
          darkTheme: widget.darkTheme,
          themeMode: widget.themeMode,
          localizationsDelegates: const [
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          supportedLocales:
              AppLocale.values.map((locale) => locale.flutterLocale),
          builder: (context, child) =>
              context.lmVenue(child ?? const SizedBox.shrink()),
          home: failure == null
              ? const _OpeningDatabase()
              : DatabaseRecoveryPage(
                  recovery: widget.recovery,
                  failure: failure,
                  onRetry: _retry,
                  onRecovered: (opened) => unawaited(_continueWith(opened)),
                ),
        ),
      ),
    );
  }
}

class _OpeningDatabase extends StatelessWidget {
  const _OpeningDatabase();

  @override
  Widget build(BuildContext context) {
    final label =
        Translations.of(context).settings.data.startupRecovery.opening;
    return Scaffold(
      backgroundColor:
          context.scaffoldBgOf(Theme.of(context).colorScheme.surface),
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(semanticsLabel: label),
            const SizedBox(height: SimpleSpacing.sMd),
            Text(label),
          ],
        ),
      ),
    );
  }
}
