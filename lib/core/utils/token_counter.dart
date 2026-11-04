import 'dart:isolate';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:tiktoken/tiktoken.dart';

/// Token 计数器
///
/// - 原生平台：在 Isolate 中计算，避免阻塞 UI。isolate 间无法共享内存，
///   每次 [countTokens]/[countTokensForEach] 都会在 isolate 内重新加载
///   BPE 表（各约 5-20ms）——多段计数请用 [countTokensForEach] 单次批量，
///   不要对 [countTokens] 做 Future.wait（教训）。
/// - Web 平台：浏览器不支持 Isolate，直接在主线程同步计算。
///   tiktoken 编码是纯 CPU 计算，短文本通常 <1ms；encoding 实例
///   进程内缓存复用（[_cachedEncoding]，仅 Web 有此待遇）。
class TokenCounter {
  TokenCounter({String encoding = 'cl100k_base'}) : _encodingName = encoding;

  final String _encodingName;

  /// Web 平台缓存的 encoding 实例（lazy 初始化，复用避免重复加载 BPE 表）
  late final _cachedEncoding = getEncoding(_encodingName);

  /// 计算文本的 token 数
  Future<int> countTokens(String text) async {
    if (kIsWeb) {
      return _cachedEncoding.encode(text).length;
    }
    final encodingName = _encodingName;
    return Isolate.run(() => getEncoding(encodingName).encode(text).length);
  }

  /// 计算多条文本的总 token 数
  Future<int> countTokensForMessages(List<String> messages) async {
    return countTokens(messages.join(' '));
  }

  /// 逐条计算文本 token 数（2026-08-22 新增）
  ///
  /// 单次 Isolate 批量编码，避免逐条调用 [countTokens] 的 N 次 Isolate
  /// 开销。供压缩边界查找等需要 per-message 精确计数的调用方使用——
  /// 边界预算的单位必须与 shouldCompact 的 tiktoken 计数一致，
  /// 否则保留量约束会被字符估算误差架空（中文内容下 chars/3.5 偏差 2-4 倍）。
  Future<List<int>> countTokensForEach(List<String> texts) async {
    if (texts.isEmpty) return const <int>[];
    if (kIsWeb) {
      return texts.map((t) => _cachedEncoding.encode(t).length).toList();
    }
    final encodingName = _encodingName;
    return Isolate.run(() {
      final encoding = getEncoding(encodingName);
      return texts.map((t) => encoding.encode(t).length).toList();
    });
  }
}
