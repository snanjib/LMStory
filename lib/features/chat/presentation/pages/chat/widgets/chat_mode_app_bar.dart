import 'package:flutter/material.dart';
import 'package:lmstory/core/theme/simple/simple_text_styles.dart';

/// 对话模式 AppBar（自 chat_mode_page.dart 拆出，逻辑原样搬运）。
///
/// 标题只显示会话名称（对标 ChatBox Header：不显示模型名或供应商名，
/// 模型选择器位于输入框工具栏）；右上角为聊天菜单入口，移动端可挂
/// 汉堡菜单按钮（用于拉出抽屉）。
class ChatModeAppBar extends StatelessWidget implements PreferredSizeWidget {
  const ChatModeAppBar({
    required this.sessionTitle,
    required this.onMenuPressed,
    this.showHamburgerMenu = false,
    this.onHamburgerPressed,
    this.onBackToHome,
    super.key,
  });

  /// AppBar 标题：会话名称（单行省略）。
  final String sessionTitle;

  /// Whether to show the hamburger menu button in the AppBar.
  final bool showHamburgerMenu;

  /// Callback when the hamburger menu button is pressed.
  final VoidCallback? onHamburgerPressed;

  /// 非空时 leading 显示「返回上一级」（iOS 移动壳：会话导航是
  /// 内部栈非路由，边缘侧滑无效，以此提供系统位置一致的返回入口）。
  final VoidCallback? onBackToHome;

  /// Callback when the top-right menu button is pressed.
  final VoidCallback onMenuPressed;

  @override
  Size get preferredSize => const Size.fromHeight(kToolbarHeight);

  @override
  Widget build(BuildContext context) {
    return AppBar(
      leading: onBackToHome != null
          ? IconButton(
              //  语义缺口：复用框架本地化文案（不新增 i18n key）。
              tooltip: MaterialLocalizations.of(context).backButtonTooltip,
              icon: const Icon(Icons.arrow_back),
              onPressed: onBackToHome,
            )
          : showHamburgerMenu
              ? IconButton(
                  //  语义缺口：复用框架本地化文案（不新增 i18n key）。
                  tooltip:
                      MaterialLocalizations.of(context).openAppDrawerTooltip,
                  icon: const Icon(Icons.menu),
                  onPressed: onHamburgerPressed,
                )
              : null,
      title: Text(
        sessionTitle,
        style: SimpleTextStyles.title2,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      actions: [
        IconButton(
          //  语义缺口：复用框架本地化文案（不新增 i18n key）。
          tooltip: MaterialLocalizations.of(context).showMenuTooltip,
          icon: const Icon(Icons.more_vert),
          onPressed: onMenuPressed,
        ),
      ],
    );
  }
}
