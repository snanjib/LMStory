/// 稿件变体行数端口
///
/// settings 域的存储统计需要「稿件变体行数」这一最小能力——
/// message_variants 行含正文/思考/幕后过程/锚快照，存储膨胀须可见
///（与  的删除链修复互相配合：残留问题不再互相遮蔽）。
/// 域层声明端口、由组合根（core/di/providers.dart）适配注入，
/// 避免 domain 直接 import 其他 feature 的仓库实现（模式）。
// ignore: one_member_abstracts, 单方法抽象接口为 Clean Architecture 依赖反转所需
abstract interface class MessageVariantsCountPort {
  /// message_variants 全表行数。
  Future<int> messageVariantCount();
}
