import 'dart:async';

import 'package:flutter/material.dart';
import 'package:lmstory/core/theme/api/lm_component_kit.dart';
import 'package:lmstory/core/theme/shared/components/section_heading.dart';
import 'package:lmstory/core/theme/simple/simple_spacing.dart';
import 'package:lmstory/core/theme/system/lm_layout.dart';
import 'package:lmstory/core/theme/system/lm_overlays.dart';
import 'package:lmstory/features/settings/data/database_startup_recovery.dart';
import 'package:lmstory/features/settings/domain/services/data_management_service.dart';
import 'package:lmstory/features/settings/presentation/widgets/backup_file_picker.dart';
import 'package:lmstory/i18n/strings.g.dart';

/// Startup recovery uses only the backup catalog and isolated trial store.
class DatabaseRecoveryPage extends StatefulWidget {
  const DatabaseRecoveryPage({
    required this.recovery,
    required this.failure,
    required this.onRetry,
    required this.onRecovered,
    super.key,
  });

  final DatabaseStartupRecovery recovery;
  final DatabaseOpenFailure failure;
  final VoidCallback onRetry;
  final ValueChanged<OpenedDatabase> onRecovered;

  @override
  State<DatabaseRecoveryPage> createState() => _DatabaseRecoveryPageState();
}

class _DatabaseRecoveryPageState extends State<DatabaseRecoveryPage> {
  late final Future<List<RecoveryBackup>> _backups =
      widget.recovery.listBackups();
  RecoveryBackup? _selected;
  final _scrollController = ScrollController();
  ({int? version, DateTime? exportedAt, int skippedItems})? _checked;
  PreparedDatabaseRecovery? _trial;
  bool _busy = false;
  String? _status;

  @override
  void dispose() {
    unawaited(_trial?.discard());
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _status = null;
    });
    try {
      await action();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _pickBackup() => _run(() async {
        final strings = Translations.of(context).settings.data.startupRecovery;
        final ({String name, String content})? file;
        try {
          file = await pickBackupFile();
        } on Object {
          if (mounted) setState(() => _status = strings.readFailed);
          return;
        }
        if (file == null || !mounted) return;
        final content = file.content;
        await _check(
          RecoveryBackup(
            name: file.name,
            source: RecoveryBackupSource.selectedFile,
            read: () async => content,
          ),
        );
      });

  Future<void> _check(RecoveryBackup backup) async {
    final trans = Translations.of(context).settings.data;
    await _discardSelection();
    if (!mounted) return;
    setState(() => _selected = backup);
    if (_scrollController.hasClients) _scrollController.jumpTo(0);

    final String content;
    try {
      content = await backup.read();
    } on Object {
      if (mounted) setState(() => _status = trans.startupRecovery.readFailed);
      return;
    }
    try {
      final metadata = DataManagementService.inspectRecoveryBackup(content);
      if (!mounted) return;
      setState(() => _checked = metadata);
    } on BackupVersionTooNewException catch (error) {
      if (mounted) {
        setState(
          () => _status = trans.repairSchema.importVersionTooNew(
            version: error.version,
          ),
        );
      }
      return;
    } on BackupNoRestorableDataException {
      if (mounted) {
        setState(() => _status = trans.startupRecovery.noRestorableData);
      }
      return;
    } on BackupDraftIndexConflictException {
      if (mounted) setState(() => _status = trans.draftIndexConflict);
      return;
    } on FormatException {
      if (mounted) {
        setState(() => _status = trans.startupRecovery.invalidBackup);
      }
      return;
    }

    if (!widget.recovery.supportsActivation) return;
    try {
      final trial = await widget.recovery.prepare(content);
      if (!mounted) {
        await trial.discard();
        return;
      }
      setState(() => _trial = trial);
    } on BackupNoRestorableDataException {
      if (mounted) {
        setState(() => _status = trans.startupRecovery.noRestorableData);
      }
    } on Object {
      if (mounted) setState(() => _status = trans.startupRecovery.trialFailed);
    }
  }

  Future<void> _discardSelection() async {
    final trial = _trial;
    setState(() {
      _selected = null;
      _checked = null;
      _trial = null;
    });
    await trial?.discard();
  }

  Future<void> _activate(PreparedDatabaseRecovery trial) => _run(() async {
        final trans = Translations.of(context);
        final strings = trans.settings.data.startupRecovery;
        final confirmed = await showLmDialog<bool>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            title: Text(strings.confirmTitle),
            content: Text(strings.confirmBody),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext, false),
                child: Text(trans.common.cancel),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(dialogContext, true),
                child: Text(strings.activate),
              ),
            ],
          ),
        );
        if (confirmed != true || !mounted) return;
        final OpenedDatabase opened;
        try {
          opened = await trial.activate();
        } on Object {
          if (mounted) setState(() => _status = strings.activationFailed);
          return;
        }
        if (!mounted) {
          await closeStartupDatabase(opened.database);
          return;
        }
        _trial = null;
        widget.onRecovered(opened);
      });

  String _sourceLabel(BuildContext context, RecoveryBackupSource source) {
    final strings = Translations.of(context).settings.data.startupRecovery;
    return switch (source) {
      RecoveryBackupSource.automatic => strings.automatic,
      RecoveryBackupSource.preImport => strings.snapshot,
      RecoveryBackupSource.selectedFile => strings.selectedFile,
    };
  }

  String _dateLabel(BuildContext context, DateTime? value) {
    if (value == null) {
      return Translations.of(context).settings.data.startupRecovery.unknownDate;
    }
    final local = value.toLocal();
    final material = MaterialLocalizations.of(context);
    final date = material.formatMediumDate(local);
    final time = material.formatTimeOfDay(TimeOfDay.fromDateTime(local));
    return '$date · $time';
  }

  @override
  Widget build(BuildContext context) {
    final trans = Translations.of(context);
    final strings = trans.settings.data.startupRecovery;
    final colors = Theme.of(context).colorScheme;
    final path = widget.failure.databasePath;
    final selected = _selected;

    return Scaffold(
      backgroundColor: context.scaffoldBgOf(colors.surface),
      appBar: context.lmUi.appBar(
        context,
        title: strings.title,
        automaticallyImplyLeading: false,
      ),
      body: SafeArea(
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: LmLayout.formMeasure),
            child: ListView(
              controller: _scrollController,
              padding: const EdgeInsets.all(SimpleSpacing.sLg),
              children: [
                Text(
                  widget.failure.preservationFailed
                      ? strings.preservationFailed
                      : strings.openFailed,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: SimpleSpacing.sSm),
                Text(
                  widget.recovery.supportsActivation
                      ? strings.nativeInstructions
                      : strings.webInstructions,
                ),
                if (path != null) ...[
                  const SizedBox(height: SimpleSpacing.sSm),
                  SelectableText(
                    strings.originalLocation(path: path),
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
                const SizedBox(height: SimpleSpacing.sLg),
                Wrap(
                  spacing: SimpleSpacing.sSm,
                  runSpacing: SimpleSpacing.sSm,
                  children: [
                    FilledButton.icon(
                      onPressed: _busy ? null : _pickBackup,
                      icon: const Icon(Icons.folder_open_outlined),
                      label: Text(strings.chooseFile),
                    ),
                    OutlinedButton(
                      onPressed: _busy ? null : widget.onRetry,
                      child: Text(strings.retryOpen),
                    ),
                  ],
                ),
                for (final preservedPath
                    in widget.failure.preservedDatabasePaths) ...[
                  const SizedBox(height: SimpleSpacing.sSm),
                  SelectableText(
                    strings.preservedLocation(path: preservedPath),
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
                if (_busy) ...[
                  const SizedBox(height: SimpleSpacing.sMd),
                  LinearProgressIndicator(semanticsLabel: strings.working),
                  const SizedBox(height: SimpleSpacing.sSm),
                  Text(strings.working),
                ],
                if (selected != null) ...[
                  const SizedBox(height: SimpleSpacing.sLg),
                  _preview(context, selected),
                ] else if (_status case final status?) ...[
                  const SizedBox(height: SimpleSpacing.sMd),
                  _error(context, status),
                ],
                const SizedBox(height: SimpleSpacing.sLg),
                SectionHeading(title: strings.savedBackups),
                FutureBuilder(
                  key: const ValueKey('recovery-backup-catalog'),
                  future: _backups,
                  builder: (context, snapshot) {
                    if (snapshot.hasError) {
                      return _error(context, strings.catalogFailed);
                    }
                    final backups = snapshot.data;
                    if (backups == null) {
                      return const LinearProgressIndicator();
                    }
                    if (backups.isEmpty) {
                      return Text(
                        trans.settings.data.autoBackup.nothingToRestore,
                      );
                    }
                    return Column(
                      children: [
                        for (final backup in backups)
                          ListTile(
                            contentPadding: EdgeInsets.zero,
                            leading: const Icon(Icons.restore_outlined),
                            title: Text(backup.name),
                            subtitle: Text(
                              '${_sourceLabel(context, backup.source)} · '
                              '${_dateLabel(context, backup.modifiedAt)}',
                            ),
                            trailing: const Icon(Icons.chevron_right),
                            onTap:
                                _busy ? null : () => _run(() => _check(backup)),
                          ),
                      ],
                    );
                  },
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _preview(BuildContext context, RecoveryBackup backup) {
    final trans = Translations.of(context);
    final strings = trans.settings.data.startupRecovery;
    final result = _trial?.result;
    final metadata = _checked;
    final status = _status;
    final trial = _trial;

    return context.lmUi.card(
      context,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(backup.name, style: Theme.of(context).textTheme.titleMedium),
          Text(_sourceLabel(context, backup.source)),
          Text(_dateLabel(context, metadata?.exportedAt ?? backup.modifiedAt)),
          if (metadata != null)
            Text(
              switch (metadata.version) {
                final int version => strings.version(number: version),
                null => strings.legacyFormat,
              },
            ),
          if (status != null) ...[
            const SizedBox(height: SimpleSpacing.sSm),
            _error(context, status),
          ],
          if (result != null) ...[
            const SizedBox(height: SimpleSpacing.sMd),
            Text(strings.trialReady),
            Text(
              strings.summary(
                sessions: result.importedSessions,
                messages: result.importedMessages,
                presets: result.importedPresets,
                preferences: result.importedPreferences,
                assets: result.importedAssets,
              ),
            ),
            if ((metadata?.skippedItems ?? 0) +
                    result.skippedSessions +
                    result.skippedSessionRows +
                    result.skippedMessages +
                    result.skippedPresets +
                    result.skippedPreferences +
                    result.skippedAssets >
                0)
              Text(strings.skippedItems),
          ] else if (metadata != null &&
              !widget.recovery.supportsActivation) ...[
            const SizedBox(height: SimpleSpacing.sSm),
            Text(
              metadata.skippedItems == 0
                  ? strings.webCheckPassed
                  : strings.webPartialCheck,
            ),
          ],
          const SizedBox(height: SimpleSpacing.sMd),
          Wrap(
            spacing: SimpleSpacing.sSm,
            children: [
              if (trial != null)
                FilledButton(
                  onPressed: _busy ? null : () => _activate(trial),
                  child: Text(strings.useBackup),
                ),
              TextButton(
                onPressed: _busy ? null : () => _run(_discardSelection),
                child: Text(trans.common.cancel),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _error(BuildContext context, String status) => Semantics(
        liveRegion: true,
        child: Text(
          status,
          style: TextStyle(color: Theme.of(context).colorScheme.error),
        ),
      );
}
