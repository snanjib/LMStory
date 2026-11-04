import 'package:lmstory/core/config/config_loader.dart';

/// 全局配置与 API Key 管理仓库接口
abstract class SettingsRepository {
  /// 安全存储 API Key
  Future<void> saveApiKey(String presetId, String apiKey);

  /// 读取 API Key（每次请求时动态读取，不缓存）
  Future<String?> getApiKey(String presetId);

  /// 删除 API Key
  Future<void> deleteApiKey(String presetId);

  /// 获取用户覆盖配置
  Future<Map<String, dynamic>> getUserOverrides();

  /// 设置用户覆盖项
  Future<void> setUserOverride(String key, dynamic value);

  /// 移除用户覆盖项（恢复默认）
  Future<void> removeUserOverride(String key);

  /// 获取合并后的完整配置（默认 + 用户覆盖）
  Future<AppConfig> getResolvedConfig();

  /// 清空所有用户覆盖项（恢复全部默认值）
  ///
  /// 用于数据导入覆盖模式。
  Future<void> clearAllUserOverrides();

  /// 获取用户覆盖项数量
  Future<int> getUserOverrideCount();
}
