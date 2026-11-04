import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lmstory/core/di/providers.dart';
import 'package:lmstory/core/services/incoming_file_receiver.dart';
import 'package:lmstory/core/theme/system/lm_overlays.dart';
import 'package:lmstory/core/utils/file_reader.dart'
    if (dart.library.html) 'package:lmstory/core/utils/file_reader_web.dart';
import 'package:lmstory/features/resource_library/domain/services/resource_import_service.dart';
import 'package:lmstory/features/settings/domain/services/data_management_service.dart';
import 'package:lmstory/features/settings/presentation/pages/data_management_page.dart';
import 'package:lmstory/i18n/strings.g.dart';

/// 外部文件导入监听器：包裹主布局（onboarding 完成后生效）。
///
/// 其他应用（微信等）"使用 LMStory 打开/分享"文件时，原生侧经
/// MethodChannel `lmstory/incoming_file` 推送文件（见 MainActivity.kt /
/// AppDelegate.swift）；本组件收到事件后弹确认框，确认即导入资源库。
class IncomingImportListener extends ConsumerStatefulWidget {
  const IncomingImportListener({required this.child, super.key});

  final Widget child;

  @override
  ConsumerState<IncomingImportListener> createState() =>
      _IncomingImportListenerState();
}

class _IncomingImportListenerState
    extends ConsumerState<IncomingImportListener> {
  static const _pngSignature = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A];

  /// 处理中标志：同一时间只处理一个文件，后续事件忽略
  bool _handling = false;

  @override
  Widget build(BuildContext context) {
    ref.listen<AsyncValue<IncomingFile>>(incomingFileEventsProvider,
        (previous, next) {
      next.whenData(_handleIncomingFile);
    });
    return widget.child;
  }

  Future<void> _handleIncomingFile(IncomingFile file) async {
    if (_handling) return;
    _handling = true;
    try {
      final t = Translations.of(context);

      final Uint8List bytes;
      try {
        // 同步读：本地临时缓存文件（原生侧已复制），且后续
        // 解析（jsonDecode/base64）本就是同步的
        bytes = readFileBytesSyncNative(file.path);
      } catch (e) {
        if (mounted) {
          _showSnack(
            t.settings.resourceLibrary.incomingReadFailed(error: '$e'),
          );
        }
        return;
      }

      // PNG 按字节签名判定（比 mime/扩展名可靠），其余按 JSON 解码
      final isPng = bytes.length >= 8 && _isPng(bytes);
      final content =
          isPng ? null : const Utf8Decoder(allowMalformed: true).convert(bytes);

      // 应用数据备份（全量/单会话导出）优先分流：备份顶层结构会命中
      // 角色卡/世界书启发式（此前被误标并导入资源库成空卡）。确认后
      // 进数据管理页走导入主链（版本守卫/追加覆盖/前置快照全继承）。
      if (!isPng &&
          content != null &&
          DataManagementService.looksLikeAppBackupJson(content)) {
        if (!mounted) return;
        final confirmed = await showLmDialog<bool>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            title: Text(t.settings.resourceLibrary.incomingBackupTitle),
            content: Text(
              t.settings.resourceLibrary.incomingBackupConfirm(
                name: file.fileName,
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext, false),
                child: Text(t.common.cancel),
              ),
              TextButton(
                onPressed: () => Navigator.pop(dialogContext, true),
                child: Text(t.common.confirm),
              ),
            ],
          ),
        );
        if (confirmed != true || !mounted) return;
        await Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => DataManagementPage(initialImportContent: content),
          ),
        );
        return;
      }

      // 确认框类型标签
      final kind = isPng
          ? ImportKind.characterCard
          : (content == null
              ? null
              : ResourceImportService.detectJsonKind(content));
      final label = switch (kind) {
        ImportKind.characterCard => t.settings.resourceLibrary.incomingTypeCard,
        ImportKind.worldbook => t.settings.resourceLibrary.incomingTypeBook,
        _ => t.settings.resourceLibrary.incomingTypeUnknown,
      };

      if (!mounted) return;
      final confirmed = await showLmDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: Text(t.settings.resourceLibrary.incomingTitle),
          content: Text(
            t.settings.resourceLibrary.incomingConfirm(
              name: file.fileName,
              typeLabel: label,
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: Text(t.common.cancel),
            ),
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: Text(t.common.confirm),
            ),
          ],
        ),
      );
      if (confirmed != true) return;

      final imported = await ref.read(resourceImportServiceProvider).importAuto(
            bytes: isPng ? bytes : null,
            content: content,
            fallbackName: file.fileName,
          );
      if (mounted) {
        _showSnack(t.settings.resourceLibrary.imported(name: imported.name));
      }
    } catch (e) {
      if (mounted) {
        _showSnack(
          Translations.of(
            context,
          ).settings.resourceLibrary.importFailed(error: '$e'),
        );
      }
    } finally {
      _handling = false;
      // 清理原生侧复制的临时文件（iOS Inbox / Android cacheDir）
      deleteFileNative(file.path);
    }
  }

  bool _isPng(Uint8List bytes) {
    for (var i = 0; i < 8; i++) {
      if (bytes[i] != _pngSignature[i]) return false;
    }
    return true;
  }

  void _showSnack(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          behavior: SnackBarBehavior.floating,
          content: Text(message),
        ),
      );
  }
}
