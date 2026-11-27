/// 敏感信息脱敏（复制/上报错误前调用）。
///
/// 只针对凭据类内容，不碰普通文本：API Key、Bearer/Authorization 令牌、
/// URL 内嵌凭据、常见 token 前缀（sk- / AIza / ghp / GitHub PAT / GL-i /
/// Slack xox*）。用于「复制报错」等把诊断文本带出设备前的最后一道防线。
library;

final RegExp _urlUserinfo = RegExp(r'(https?://)[^/\s@]+@');

final RegExp _authHeader = RegExp(
  r'\b(authorization\s*[:=]\s*)(?:bearer\s+)?[A-Za-z0-9._~\-/+=]+',
  caseSensitive: false,
);

final RegExp _keyAssignment = RegExp(
  r'''\b((?:api[-_]?key|apikey|access[-_]?token|refresh[-_]?token|secret[-_]?key|token)\b\s*[:=]\s*)[A-Za-z0-9._~\-/+=]{4,}''',
  caseSensitive: false,
);

final RegExp _tokenPrefix = RegExp(
  r'\b(sk[-_][A-Za-z0-9]{6,}'
  '|AIza[A-Za-z0-9_-]{10,}'
  '|ghp_[A-Za-z0-9]{6,}'
  '|github_pat_[A-Za-z0-9]{6,}'
  '|glpat-[A-Za-z0-9]{6,}'
  '|xox[baprs]-[A-Za-z0-9]{6,})',
);

/// 把 [input] 中的凭据替换为 `***`，保留键名与结构以便定位问题。
String redactSecrets(String input) {
  var result = input;
  result = result.replaceAllMapped(
    _urlUserinfo,
    (m) => '${m.group(1)}***@',
  );
  result = result.replaceAllMapped(
    _authHeader,
    (m) => '${m.group(1)}***',
  );
  result = result.replaceAllMapped(
    _keyAssignment,
    (m) => '${m.group(1)}***',
  );
  result = result.replaceAll(_tokenPrefix, '***');
  return result;
}

final RegExp _diagnosticUrl = RegExp(
  r'''(?:\braw:)?\b(https?|wss?):(?:/|\\/){2}[^\s<>"'\x60|]+''',
  caseSensitive: false,
);

final RegExp _urlPunctuation = RegExp(r'[),.;}\]]+$');

// Socket errors may repeat the host separately from the request URI.
final RegExp _hostLookup = RegExp(
  r'''(\b(?:failed host lookup|could not resolve host):[ \t]*)(?:'[^'\r\n]+'|"[^"\r\n]+"|[^\s,;]+)''',
  caseSensitive: false,
);

// Dart's SocketException prints its address as a separate optional field,
// even when no message or port is present.
final RegExp _socketAddress = RegExp(
  r'''(\bSocketException\b[^\r\n]*?,[ \t]*address[ \t]*=[ \t]*)(?:\[[^\]\r\n]+\]|[^\s,;|"'<>)}\]]+)''',
);

// Covers Dart map dumps, request/error text and JSON. A quoted header value
// can contain spaces and escaped quotes.
final RegExp _diagnosticCredential = RegExp(
  r'''(\b(?:proxy[-_]?authorization|authorization|x[-_]goog[-_]api[-_]key|x[-_]api[-_]key|api[-_ ]?key|(?:x[-_])?auth[-_]?token|access[-_]?token|refresh[-_]?token|client[-_]?secret|secret[-_]?key|token|password)["']?[ \t]*[:=][ \t]*)(?:"(?:\\.|[^"\\\r\n])*"|'(?:\\.|[^'\\\r\n])*'|\[[^\]\r\n]*\]|(?:(?:bearer|basic|token)[ \t]+)?[^\s"',;}\])|]+)''',
  caseSensitive: false,
);

/// Cleans diagnostic files and their exports, retaining protocol and context.
String redactDiagnosticText(String input) {
  final withoutUrls = input.replaceAllMapped(_diagnosticUrl, (match) {
    final punctuation = _urlPunctuation.stringMatch(match[0] ?? '') ?? '';
    return '${match[1]}://<endpoint>$punctuation';
  });
  final withoutHosts = withoutUrls
      .replaceAllMapped(_socketAddress, (match) => '${match[1]}<host>')
      .replaceAllMapped(_hostLookup, (match) => '${match[1]}<host>');
  return redactSecrets(
    withoutHosts.replaceAllMapped(_diagnosticCredential, (match) {
      final field = match[1] ?? '';
      final value = (match[0] ?? '').substring(field.length);
      final quote =
          value.startsWith('"') || value.startsWith("'") ? value[0] : '';
      return '$field$quote***$quote';
    }),
  );
}
