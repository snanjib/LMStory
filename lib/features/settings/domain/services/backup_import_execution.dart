part of 'data_management_service.dart';

extension on DataManagementService {
  Future<ImportResult> _overwrite(
    _BackupImportPlan plan, {
    required Future<void> Function()? preImportSnapshot,
    required bool importApiKeys,
  }) async {
    final scope = plan.domains;
    final settings = _BackupImportSettings(settingsRepository);
    BackupOverwriteState? before;
    var startedWriting = false;

    try {
      return await backupRepository.runInTransaction(() async {
        try {
          if (scope.isNotEmpty) {
            before = await backupRepository.readOverwriteState(scope);
          }
          if (plan.preferences.isNotEmpty) {
            await settings.capturePreferences();
            if (!settings.previousPreferences.entries.every(
              _BackupImportPlan._isSupportedPreference,
            )) {
              throw const BackupSnapshotException();
            }
          }
          if (importApiKeys) {
            for (final preset in plan.presets) {
              final id = preset.presetId;
              if (id != null && preset.key != null) {
                await settings.captureKey(id);
              }
            }
          }

          if ((before?.hasData ?? false) || settings.hasPriorValues) {
            if (preImportSnapshot == null) {
              throw const BackupSnapshotException();
            }
            await preImportSnapshot();
            settings.hasSnapshot = true;
          }
        } catch (_) {
          // 无法确认原数据已受保护时，禁止开始写入。
          throw const BackupSnapshotException();
        }

        startedWriting = true;
        return _applyImport(
          plan,
          ImportMode.overwrite,
          importApiKeys: importApiKeys,
          changes: settings,
        );
      });
    } catch (_) {
      if (startedWriting) {
        final settingsRestored = await settings.restore();
        var sqliteRestored = true;
        if (before != null) {
          try {
            sqliteRestored = await backupRepository.runInTransaction(
                  () => backupRepository.readOverwriteState(scope),
                ) ==
                before;
          } catch (_) {
            sqliteRestored = false;
          }
        }
        if (!settingsRestored || !sqliteRestored) {
          throw const BackupRollbackException();
        }
      }
      rethrow;
    }
  }

  Future<ImportResult> _applyImport(
    _BackupImportPlan plan,
    ImportMode mode, {
    required bool importApiKeys,
    _BackupImportSettings? changes,
  }) async {
    if (mode == ImportMode.overwrite) {
      if (plan.rowSessions.isNotEmpty || plan.oldSessions.isNotEmpty) {
        await backupRepository.deleteAllSessionData();
      }
      if (plan.presets.isNotEmpty) {
        await backupRepository.deleteAllCustomPresets();
      }
    }

    final presets =
        await _importPresets(plan, mode, importApiKeys: importApiKeys);
    final sessions = await _importSessions(plan, mode);
    final assets = plan.assets.isEmpty
        ? 0
        : await backupRepository.importGlobalAssets(plan.assets, mode: mode);
    final assetCandidates =
        plan.assets.values.fold<int>(0, (sum, rows) => sum + rows.length);
    final preferences = await _importPreferences(plan, mode, changes: changes);

    final repo = settingsRepository;
    for (final entry in presets.keys) {
      if (changes != null) {
        await changes.writeKey(entry.id, entry.value);
      } else if (repo case final SettingsImportStorage storage) {
        await storage.writeApiKeyForImport(entry.id, entry.value);
      } else {
        await repo.saveApiKey(entry.id, entry.value);
      }
    }

    return ImportResult(
      importedPresets: presets.imported,
      skippedPresets: plan.skippedPresets + presets.skipped,
      importedSessions: sessions.imported,
      skippedSessions: plan.skippedSessions + sessions.skipped,
      importedMessages: sessions.messages,
      skippedMessages: plan.skippedMessages + sessions.skippedMessages,
      skippedSessionRows: plan.skippedSessionRows,
      importedPreferences: preferences.imported,
      skippedPreferences: plan.skippedPreferences + preferences.skipped,
      importedAssets: assets,
      skippedAssets: plan.skippedAssets + math.max(0, assetCandidates - assets),
      importedApiKeys: presets.keys.length,
      mode: mode,
    );
  }

  Future<
      ({
        int imported,
        int skipped,
        List<({String id, String value})> keys,
      })> _importPresets(
    _BackupImportPlan plan,
    ImportMode mode, {
    required bool importApiKeys,
  }) async {
    var imported = 0;
    var skipped = 0;
    final keys = <({String id, String value})>[];
    final existingNames = plan.version == 1 &&
            plan.presets.isNotEmpty &&
            mode == ImportMode.append
        ? (await presetRepository.getAllPresets()).map((p) => p.name).toSet()
        : const <String>{};

    for (final preset in plan.presets) {
      final String id;
      if (preset.presetId case final presetId?) {
        if (!await backupRepository.importPreset(preset.row, mode: mode)) {
          skipped++;
          continue;
        }
        id = presetId;
      } else {
        if (existingNames.contains(preset.name)) {
          skipped++;
          continue;
        }
        final created = await presetRepository.createPreset(
          name: preset.name,
          baseUrl: preset.baseUrl,
          omitSamplingParams: false,
        );
        id = created.presetId;
      }

      imported++;
      final key = preset.key;
      if (importApiKeys && key != null) keys.add((id: id, value: key));
    }
    return (imported: imported, skipped: skipped, keys: keys);
  }

  Future<({int imported, int skipped, int messages, int skippedMessages})>
      _importSessions(_BackupImportPlan plan, ImportMode mode) async {
    var imported = 0;
    var skipped = 0;
    var messages = 0;
    var skippedMessages = 0;
    final restored = <String>{};
    for (final data in plan.rowSessions) {
      final session = data['session'] as Map<String, dynamic>;
      final id = session['session_id'] as String;
      final int inserted;
      try {
        inserted = await backupRepository.importSessionData(data, mode: mode);
      } on SavepointRollbackException {
        rethrow;
      } on BackupExperienceIdConflictException {
        if (mode == ImportMode.overwrite) rethrow;
        skipped++;
        continue;
      } on Exception {
        // 已写入的同 ID 会话由保存点恢复。后续包仍按库内实际归属检查
        // 经历 ID。新会话的存储错误继续由整文件事务处理。
        if (!restored.contains(id)) rethrow;
        skipped++;
        continue;
      }
      if (inserted < 0) {
        skipped++;
      } else {
        if (mode == ImportMode.overwrite) restored.add(id);
        imported++;
        messages += inserted;
        if (data['messages'] case final List<dynamic> rows) {
          skippedMessages += math.max(0, rows.length - inserted);
        }
      }
    }

    final existingIds = plan.version == 1 &&
            plan.oldSessions.isNotEmpty &&
            mode == ImportMode.append
        ? (await chatRepository.getAllSessions())
            .map((s) => s.sessionId)
            .toSet()
        : const <String>{};
    for (final old in plan.oldSessions) {
      final draft = old.session;
      if (existingIds.contains(draft.sessionId)) {
        skipped++;
        continue;
      }
      final session = await chatRepository.createSession(
        title: draft.title,
        mode: draft.mode,
        modelId: draft.modelId,
        presetId: draft.presetId,
      );
      if (plan.version == 1) {
        await chatRepository.updateSession(
          session.copyWith(
            isStarred: draft.isStarred,
            sortOrder: old.sortOrder,
            systemPromptOverride: draft.systemPromptOverride,
            temperature: draft.temperature,
            topP: draft.topP,
            maxTokens: draft.maxTokens,
            autoCompaction: draft.autoCompaction,
            compactionThreshold: draft.compactionThreshold,
            streamEnabled: draft.streamEnabled,
            maxContextMessages: draft.maxContextMessages,
          ),
        );
      }

      var inserted = 0;
      for (final entry in old.messages) {
        final id = entry.id;
        if (id != null && await backupRepository.containsMessageId(id)) {
          continue;
        }
        await chatRepository.addMessage(
          entry.message.copyWith(
            sessionId: session.sessionId,
            messageId: id ?? DataManagementService._uuid.v4(),
            createdAt: entry.date ?? DateTime.now(),
          ),
        );
        inserted++;
      }
      await chatRepository.updateSessionMessageCount(
        session.sessionId,
        inserted,
      );
      imported++;
      messages += inserted;
      skippedMessages += old.originalMessageCount - inserted;
    }

    return (
      imported: imported,
      skipped: skipped,
      messages: messages,
      skippedMessages: skippedMessages,
    );
  }

  Future<({int imported, int skipped})> _importPreferences(
    _BackupImportPlan plan,
    ImportMode mode, {
    _BackupImportSettings? changes,
  }) async {
    final preferences = plan.preferences;
    if (preferences.isEmpty) return (imported: 0, skipped: 0);
    if (changes != null) {
      await changes.writePreferences(preferences);
      return (imported: preferences.length, skipped: 0);
    }

    final existing = await settingsRepository.getUserOverrides();
    var imported = 0;
    for (final entry in preferences.entries) {
      if (existing.containsKey(entry.key)) continue;
      await settingsRepository.setUserOverride(entry.key, entry.value);
      imported++;
    }
    return (imported: imported, skipped: preferences.length - imported);
  }
}
