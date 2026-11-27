import 'dart:io';

/// 是否运行于 flutter_tester 测试环境（flutter_tools 向测试进程注入
/// `FLUTTER_TEST=true`，本地实测 2026-11-28）。
///
/// 仅原生可见：本文件经条件导入挂到 token_counter.dart，Web 构建选
/// token_counter_env_stub.dart，dart:io 不进 Web 编译。
bool isFlutterTestEnv() => Platform.environment['FLUTTER_TEST'] == 'true';
