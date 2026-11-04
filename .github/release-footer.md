---

## 安装说明

### Android

- 下载 `lmstory-<版本>-android.apk` 直接安装；与历史版本签名一致，可覆盖安装。

### Windows（应用未做代码签名，首次运行有系统告警）

- **绿色版**：下载 `lmstory-<版本>-windows-x64-portable.zip`，解压即用（已自带 VC++ 运行库，无需安装任何依赖）。
- **安装版**：下载 `lmstory-<版本>-windows-x64-setup.exe` 双击安装——安装到当前用户目录（`%LOCALAPPDATA%\Programs\LMStory`），全程无需管理员权限。
- 若 SmartScreen 弹出「Windows 已保护你的电脑」：点 **更多信息** → **仍要运行**。
- Windows 11 全新装机若开启了「智能应用控制」（Smart App Control），会直接拦截未签名程序且无绕过入口；如需使用，请在 系统设置 → 隐私和安全性 → Windows 安全中心 → 应用和浏览器控制 中关闭该模式。
- 可用同名 `.sha256` 文件校验完整性（PowerShell：`Get-FileHash`；macOS/Linux：`shasum -a 256 -c`）。

### macOS（Apple Silicon，未公证）

- 下载 `lmstory-<版本>-macos-arm64.dmg`，挂载后把 LMStory 拖入「应用程序」。
- 首次打开若提示「已损坏，无法打开」或被 Gatekeeper 拦截（macOS 15+ 常见）：在终端执行 `xattr -cr /Applications/lmstory.app` 后再打开。
- 免提示技巧：用命令行下载（`curl -L -O <资产直链>`）的文件不会带隔离标记，可直接打开。
- 仅支持 Apple Silicon（M1 及以上）；iOS 暂不提供安装包。
