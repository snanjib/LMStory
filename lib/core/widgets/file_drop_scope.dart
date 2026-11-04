import 'dart:async';

import 'package:flutter/material.dart';
import 'package:lmstory/core/services/file_drop_receiver.dart';
import 'package:lmstory/core/services/incoming_file_receiver.dart';
import 'package:lmstory/core/theme/system/lm_motion.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';
import 'package:lmstory/i18n/strings.g.dart';

/// macOS 文件拖放外壳：接收原生拖入事件，拖动悬停时显示全屏投放
/// 提示遮罩，松手后把文件交给 [onFiles] 分发（会话附件 / 资源导入）。
///
/// 仅 macOS 有原生端（receiver 在其他平台静默），遮罩永不出现，
/// 零开销。
class FileDropScope extends StatefulWidget {
  const FileDropScope({
    required this.child,
    required this.inChatSession,
    required this.onFiles,
    super.key,
  });

  final Widget child;

  /// 当前是否处于对话（chat）会话——决定遮罩文案
  /// （「加入会话附件」vs「导入文件」）。
  final bool inChatSession;

  final void Function(List<IncomingFile> files) onFiles;

  @override
  State<FileDropScope> createState() => _FileDropScopeState();
}

class _FileDropScopeState extends State<FileDropScope> {
  final _receiver = FileDropReceiver();

  @override
  void initState() {
    super.initState();
    _receiver.onFiles = (files) => widget.onFiles(files);
    // 事件是回调式的，init 只注册 handler——不等待，避免拖延首帧
    unawaited(_receiver.init());
  }

  @override
  void dispose() {
    _receiver.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: _receiver.dragActive,
      builder: (context, active, child) {
        if (!active) return child!;
        final t = Translations.of(context);
        final colors = context.lm.palette;
        return Stack(
          children: [
            child!,
            IgnorePointer(
              child: AnimatedOpacity(
                duration: LmMotion.durationFor(context, LmMotion.micro),
                opacity: 1,
                child: ColoredBox(
                  color: colors.ink.withValues(alpha: 0.45),
                  child: Center(
                    child: Container(
                      padding: const EdgeInsets.all(28),
                      decoration: BoxDecoration(
                        color: colors.bg,
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(
                          color: colors.ink,
                          width: 1.5,
                        ),
                      ),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.file_download_outlined,
                            size: 40,
                            color: colors.ink,
                          ),
                          const SizedBox(height: 12),
                          Text(
                            widget.inChatSession
                                ? t.chat.attachment.dropOverlaySession
                                : t.chat.attachment.dropOverlayImport,
                            style: TextStyle(
                              color: colors.ink,
                              fontSize: 16,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        );
      },
      child: widget.child,
    );
  }
}
