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
