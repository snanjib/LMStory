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

  /// 已在主 isolate 完成首次物化的 BPE 表编码名（原生路径）。
  ///
  /// tiktoken 的 rank 表是巨型 const 字面量（cl100k_base 约 10 万条目），
  /// 在 isolate group 内首次物化后跨 isolate 共享；若首次物化由多个并发
  /// spawn 的新 isolate 同时进行，VM 竞态下会字段错乱——CI（ubuntu，
  /// 2026-11-27）偶发 `type '_Type' is not a subtype of type 'String'`
  /// 于 cl100kBase 懒初始化（本地 macOS 不复现），极端时表现为
  /// flutter_tester segfault。主 isolate 先行物化把首次初始化串行化，
  /// 关闭该竞态窗口；成本为首个计数调用在主线程同步加载一次
  /// BPE 表（约 5-20ms，与 Web 路径行为一致）。
  static final Set<String> _warmedEncodings = <String>{};

  void _warmUpNative() {
    if (kIsWeb) return;
    if (_warmedEncodings.add(_encodingName)) {
      getEncoding(_encodingName);
    }
  }

  /// 计算文本的 token 数
  Future<int> countTokens(String text) async {
    if (kIsWeb) {
      return _cachedEncoding.encode(text).length;
    }
    _warmUpNative();
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
    _warmUpNative();
    final encodingName = _encodingName;
    return Isolate.run(() {
      final encoding = getEncoding(encodingName);
      return texts.map((t) => encoding.encode(t).length).toList();
    });
  }
}
