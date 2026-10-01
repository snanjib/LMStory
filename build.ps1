<#
.SYNOPSIS
    LMStory 一键打包脚本

.DESCRIPTION
    从 git 克隆项目到新机器后，运行此脚本即可自动检测环境、安装 Flutter、
    选择平台并打包。版本号统一在 pubspec.yaml 中配置，构建号按日期自动生成。

    交互模式：直接运行 .\build.ps1（不带任何参数），脚本会依次引导输入
    版本号、构建号、构建模式、是否 clean、目标平台——任何一项留空则使用默认值。
    通过命令行参数显式传入的项不会再问（适合 CI 或脚本化调用）。

    注意：不同平台的产品包只能在对应操作系统上构建（苹果/微软强制要求）：
    - 安卓 APK/AAB：Windows / Mac / Linux 均可
    - Windows exe：只能 Windows
    - Web：v0.1 不支持（移动应用，Web 适配未做）
    - iOS / macOS：只能 Mac（本脚本运行在 Windows，故不支持）

.PARAMETER Platform
    目标平台，不传则交互式选择。可选：apk, aab, windows, web, all

.PARAMETER Version
    临时覆盖版本号（如 0.2.0），不传则交互询问，留空用 pubspec.yaml 中的版本号。不修改文件。

.PARAMETER BuildNumber
    手动指定构建号，不传则交互询问，留空按日期自动生成（格式 yyyyMMddNN，同一天自动递增）。

.PARAMETER BuildMode
    构建模式：release / debug / profile。不传则交互询问，默认 release。
    - release：正式发布包，体积小、无日志
    - debug  ：调试包，含日志与断言，体积较大
    - profile：性能分析包

.PARAMETER SkipEnvCheck
    跳过环境检测，直接开始构建。

.PARAMETER NoClean
    构建前不执行 flutter clean（不传此参数则交互询问，默认执行 clean）。

.EXAMPLE
    .\build.ps1
    全交互模式：依次引导版本号 / 构建号 / 构建模式 / 是否 clean / 平台

.EXAMPLE
    .\build.ps1 -Platform apk
    跳过平台选择，其余项仍交互询问（版本号、构建模式、是否 clean）

.EXAMPLE
    .\build.ps1 -Platform apk -Version 0.2.0 -BuildMode release -BuildNumber 2026080101
    完全非交互：直接用指定参数构建，适合 CI

.EXAMPLE
    .\build.ps1 -Platform all -Version 0.2.0
    用临时版本号 0.2.0 打所有当前系统支持的包

.NOTES
    若 PowerShell 执行策略阻止运行，请用：
    powershell -ExecutionPolicy Bypass -File .\build.ps1
#>

param(
    [ValidateSet('apk', 'aab', 'windows', 'web', 'all')]
    [string]$Platform,

    [string]$Version,

    [int]$BuildNumber,

    [ValidateSet('release', 'debug', 'profile')]
    [string]$BuildMode,

    [switch]$SkipEnvCheck,

    [switch]$NoClean,

    [switch]$Help
)

# ========== 工具函数 ==========

function Write-Info  { param([string]$Msg) Write-Host "[INFO]  $Msg" -ForegroundColor Cyan }
function Write-Ok    { param([string]$Msg) Write-Host "[OK]    $Msg" -ForegroundColor Green }
function Write-Warn  { param([string]$Msg) Write-Host "[WARN]  $Msg" -ForegroundColor Yellow }
function Write-Err   { param([string]$Msg) Write-Host "[ERROR] $Msg" -ForegroundColor Red }
function Write-Step  { param([string]$Msg) Write-Host "`n=== $Msg ===" -ForegroundColor Magenta }

function Test-Command {
    param([string]$Name)
    return [bool](Get-Command $Name -ErrorAction SilentlyContinue)
}

# ========== 帮助信息 ==========

if ($Help) {
    Get-Help $MyInvocation.MyCommand.Path -Detailed
    exit 0
}

# ========== 环境检测与安装 ==========

function Ensure-Flutter {
    Write-Step '检测 Flutter SDK'

    if (Test-Command 'flutter') {
        $fv = (& flutter --version 2>$null | Select-Object -First 1)
        Write-Ok "已安装：$fv"
        return $true
    }

    Write-Warn '未检测到 Flutter SDK，开始自动安装（通过 git clone stable 分支）...'

    if (-not (Test-Command 'git')) {
        Write-Err '未检测到 git。请先安装 Git for Windows：https://git-scm.com/download/win'
        return $false
    }

    $flutterDir = Join-Path $env:LOCALAPPDATA 'flutter'
    if (Test-Path $flutterDir) {
        Write-Info "目录已存在：$flutterDir，跳过克隆"
    } else {
        Write-Info "克隆 Flutter stable 分支到 $flutterDir ..."
        git clone --depth 1 -b stable https://github.com/flutter/flutter.git $flutterDir
        if ($LASTEXITCODE -ne 0) {
            Write-Err 'Flutter 克隆失败，请检查网络或手动安装：https://docs.flutter.dev/get-started/install'
            return $false
        }
    }

    # 加入当前会话 PATH
    $env:PATH = "$flutterDir\bin;$env:PATH"

    if (-not (Test-Command 'flutter')) {
        Write-Err 'Flutter 安装后仍无法调用，请检查 PATH 环境变量'
        return $false
    }

    # 首次运行会自动下载 Dart SDK，耗时较长
    Write-Info '首次运行 flutter，正在初始化（下载 Dart SDK，可能需要几分钟）...'
    & flutter --version 2>&1 | Out-Null

    Write-Ok "Flutter 安装完成：$(& flutter --version 2>$null | Select-Object -First 1)"
    Write-Warn "提示：已临时加入当前会话 PATH。如需永久生效，请手动将 $flutterDir\bin 加入系统环境变量。"
    return $true
}

function Check-Java {
    if (Test-Command 'java') {
        $jv = (& java -version 2>&1 | Select-Object -First 1)
        Write-Ok "Java 已安装：$jv"
        return $true
    }
    Write-Warn '未检测到 Java JDK（打安卓包必需）。'
    Write-Warn '请下载安装 Microsoft OpenJDK 17（Android 官方推荐）：'
    Write-Warn '  https://learn.microsoft.com/java/openjdk/download'
    Write-Warn '安装后需配置 JAVA_HOME 环境变量指向 JDK 目录。'
    return $false
}

function Check-AndroidSdk {
    $sdkRoot = $env:ANDROID_HOME
    if (-not $sdkRoot) { $sdkRoot = $env:ANDROID_SDK_ROOT }
    if (-not $sdkRoot) {
        $defaultPath = Join-Path $env:LOCALAPPDATA 'Android\Sdk'
        if (Test-Path $defaultPath) { $sdkRoot = $defaultPath }
    }

    if ($sdkRoot -and (Test-Path $sdkRoot)) {
        Write-Ok "Android SDK 已安装：$sdkRoot"
        if (-not $env:ANDROID_HOME) {
            Write-Warn "提示：建议设置 ANDROID_HOME 环境变量 = $sdkRoot"
        }
        return $true
    }

    Write-Warn '未检测到 Android SDK（打安卓包必需）。'
    Write-Warn '推荐方式：安装 Android Studio（含 SDK）：https://developer.android.com/studio'
    Write-Warn '或仅下载命令行工具：https://developer.android.com/tools'
    Write-Warn '安装后请设置 ANDROID_HOME 环境变量指向 SDK 目录。'
    return $false
}

function Check-VisualStudio {
    $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
    if (-not (Test-Path $vswhere)) {
        $vswhere = Join-Path $env:ProgramFiles 'Microsoft Visual Studio\Installer\vswhere.exe'
    }

    if (Test-Path $vswhere) {
        $vsName = & $vswhere -latest -products * `
            -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 `
            -property displayName 2>$null
        if ($vsName) {
            Write-Ok "Visual Studio 已安装：$vsName（含 C++ 桌面开发）"
            return $true
        }
    }

    Write-Warn '未检测到 Visual Studio（打 Windows 包必需，需含 C++ 桌面开发工作负载）。'
    Write-Warn '请下载安装 Visual Studio 2022 Community：'
    Write-Warn '  https://visualstudio.microsoft.com/downloads/'
    Write-Warn '安装时必须勾选"使用 C++ 的桌面开发"工作负载。'
    return $false
}

# ========== 版本号处理 ==========

function Read-PubspecVersion {
    # 从 pubspec.yaml 读取 version 字段（格式：version: 0.1.0+1）
    $pubspec = Join-Path $PSScriptRoot 'pubspec.yaml'
    if (-not (Test-Path $pubspec)) {
        Write-Err "未找到 pubspec.yaml：$pubspec"
        exit 1
    }

    $line = Get-Content $pubspec | Where-Object { $_ -match '^version:\s*(.+)$' } | Select-Object -First 1
    if (-not $line) {
        Write-Err 'pubspec.yaml 中未找到 version 字段'
        exit 1
    }

    $raw = $line -replace '^version:\s*', '' -replace '\s', ''
    # 格式：major.minor.patch+buildNumber
    $parts = $raw -split '\+', 2
    $versionName = $parts[0]
    return $versionName
}

function Get-NextBuildNumber {
    <#
        构建号策略：yyyyMMddNN（10位整数）
        - 前缀 yyyyMMdd 是当天日期
        - 后两位 NN 是当天序号（00-99）
        - 同一天多次打包自动递增
        - 最大值约 2.06e9，低于 Android versionCode 上限 2.1e9
        - 记录文件：.build/last_build_number
    #>
    $recordDir = Join-Path $PSScriptRoot '.build'
    $recordFile = Join-Path $recordDir 'last_build_number'
    $todayBase = [int](Get-Date -Format 'yyyyMMdd') * 100

    $last = 0
    if (Test-Path $recordFile) {
        $last = [int](Get-Content $recordFile -Raw).Trim()
    }

    $next = if ($last -ge $todayBase) { $last + 1 } else { $todayBase }

    if (-not (Test-Path $recordDir)) { New-Item -ItemType Directory -Path $recordDir -Force | Out-Null }
    Set-Content -Path $recordFile -Value $next -Encoding UTF8

    return $next
}

# ========== 平台选择 ==========

function Select-Platform {
    Write-Step '选择目标平台'
    Write-Host '  [1] Android APK  （可直接安装到手机）'
    Write-Host '  [2] Android AAB  （Google Play 上架格式）'
    Write-Host '  [3] Windows      （exe 可执行文件）'
    Write-Host '  [4] Web          （v0.1 不支持，将跳过）'
    Write-Host '  [5] 全部          （当前系统支持的所有平台）'
    Write-Host ''
    Write-Host '  注：iOS / macOS 需在苹果系统（macOS）上打包，本脚本运行于 Windows，不可用。' -ForegroundColor DarkGray
    Write-Host '      如需 iOS/macOS 包，请在 Mac 上使用 Xcode + Flutter 执行构建。' -ForegroundColor DarkGray
    Write-Host ''

    $choice = Read-Host '请输入序号（1-5）'
    switch ($choice) {
        '1' { return 'apk' }
        '2' { return 'aab' }
        '3' { return 'windows' }
        '4' { return 'web' }
        '5' { return 'all' }
        default {
            Write-Err "无效选择：$choice"
            exit 1
        }
    }
}

# ========== 交互式引导 ==========

function Invoke-InteractiveSetup {
    <#
        .SYNOPSIS
            交互式收集未通过命令行参数传入的构建配置。
        .DESCRIPTION
            仅对 $ask* = $true 的项提问；用户留空则回退到默认值。
            返回 hashtable，仅包含被询问过的字段（调用方用 ContainsKey 判断）。
    #>
    param(
        [switch]$AskVersion,
        [switch]$AskBuildNumber,
        [switch]$AskBuildMode,
        [switch]$AskClean,
        [switch]$AskPlatform
    )

    $cfg = @{}

    if ($AskVersion) {
        Write-Host ''
        $default = Read-PubspecVersion
        Write-Host "  当前 pubspec.yaml 版本号：$default" -ForegroundColor DarkGray
        Write-Host '  留空则使用上述默认值（不写回 pubspec.yaml，仅本次构建生效）' -ForegroundColor DarkGray
        $input = Read-Host '请输入版本号（如 0.2.0）'
        $cfg.Version = if ([string]::IsNullOrWhiteSpace($input)) { $default } else { $input.Trim() }
    }

    if ($AskBuildNumber) {
        Write-Host ''
        Write-Host '  构建号留空则按日期自动生成（格式 yyyyMMddNN，同一天自动递增）' -ForegroundColor DarkGray
        $input = Read-Host '请输入构建号（留空自动生成）'
        if ([string]::IsNullOrWhiteSpace($input)) {
            $cfg.BuildNumber = 0
        } else {
            $n = 0
            if ([int]::TryParse($input.Trim(), [ref]$n) -and $n -gt 0) {
                $cfg.BuildNumber = $n
            } else {
                Write-Warn '构建号格式无效（需正整数），将自动生成'
                $cfg.BuildNumber = 0
            }
        }
    }

    if ($AskBuildMode) {
        Write-Host ''
        Write-Host '  [1] release  （正式发布包，体积小、无日志，推荐）'
        Write-Host '  [2] debug     （调试包，含日志与断言，体积较大）'
        Write-Host '  [3] profile   （性能分析包，保留部分调试信息）'
        $choice = Read-Host '请选择构建模式（1-3，默认 1）'
        $cfg.BuildMode = switch ($choice) {
            '2' { 'debug' }
            '3' { 'profile' }
            default { 'release' }
        }
    }

    if ($AskClean) {
        Write-Host ''
        Write-Host '  flutter clean 会清空 build/ 与 .dart_tool/，构建更干净但更慢。' -ForegroundColor DarkGray
        $choice = Read-Host '构建前执行 flutter clean？（Y/n，默认 Y）'
        $cfg.NoClean = ($choice.Trim() -match '^[nN]')
    }

    if ($AskPlatform) {
        $cfg.Platform = Select-Platform
    }

    return $cfg
}

# ========== 构建执行 ==========

function Invoke-PreBuild {
    param([string]$VersionName, [int]$BuildNum)

    Write-Step '构建前准备'

    if (-not $NoClean) {
        Write-Info 'flutter clean ...'
        & flutter clean 2>&1 | Out-Null
    }

    Write-Info 'flutter pub get ...'
    & flutter pub get
    if ($LASTEXITCODE -ne 0) { Write-Err '依赖获取失败'; exit 1 }

    Write-Info 'dart run build_runner build（代码生成）...'
    & dart run build_runner build --delete-conflicting-outputs
    if ($LASTEXITCODE -ne 0) { Write-Err '代码生成失败'; exit 1 }

    Write-Ok "版本号：$VersionName"
    Write-Ok "构建号：$BuildNum"
}

function Copy-Artifact {
    param([string]$Src, [string]$DestDir, [string]$DestName)

    if (-not (Test-Path $Src)) {
        Write-Warn "未找到产物：$Src"
        return $false
    }

    if (-not (Test-Path $DestDir)) {
        New-Item -ItemType Directory -Path $DestDir -Force | Out-Null
    }

    $dest = Join-Path $DestDir $DestName
    Copy-Item -Path $Src -Destination $dest -Force
    Write-Ok "产物已复制：$dest"
    return $true
}

function Build-Android {
    param([string]$Mode, [string]$VersionName, [int]$BuildNum, [string]$BuildMode = 'release')

    $modeFlag = if ($Mode -eq 'aab') { 'appbundle' } else { 'apk' }
    Write-Step "构建 Android $Mode ($BuildMode)"

    & flutter build $modeFlag --$BuildMode `
        --build-name=$VersionName --build-number=$BuildNum
    if ($LASTEXITCODE -ne 0) {
        Write-Err "Android $Mode 构建失败"
        return $false
    }

    $releaseDir = Join-Path $PSScriptRoot 'build\release'
    $stamp = "v${VersionName}-b${BuildNum}"

    if ($Mode -eq 'apk') {
        $src = Join-Path $PSScriptRoot "build\app\outputs\flutter-apk\app-${BuildMode}.apk"
        Copy-Artifact $src $releaseDir "lmstory-${stamp}-${BuildMode}-android.apk"
    } else {
        $src = Join-Path $PSScriptRoot "build\app\outputs\bundle\${BuildMode}\app-${BuildMode}.aab"
        Copy-Artifact $src $releaseDir "lmstory-${stamp}-${BuildMode}-android.aab"
    }
    return $true
}

function Build-Windows {
    param([string]$VersionName, [int]$BuildNum, [string]$BuildMode = 'release')

    Write-Step "构建 Windows ($BuildMode)"

    & flutter build windows --$BuildMode `
        --build-name=$VersionName --build-number=$BuildNum
    if ($LASTEXITCODE -ne 0) {
        Write-Err 'Windows 构建失败'
        return $false
    }

    # Flutter Windows 产物目录：debug → Debug，release/profile → Release
    $configDir = if ($BuildMode -eq 'debug') { 'Debug' } else { 'Release' }
    $srcDir = Join-Path $PSScriptRoot "build\windows\x64\runner\$configDir"
    if (-not (Test-Path $srcDir)) {
        Write-Warn "未找到 Windows 产物目录：$srcDir"
        return $false
    }

    $releaseDir = Join-Path $PSScriptRoot 'build\release'
    $stamp = "v${VersionName}-b${BuildNum}"
    $destDir = Join-Path $releaseDir "lmstory-${stamp}-${BuildMode}-windows"

    if (Test-Path $destDir) { Remove-Item $destDir -Recurse -Force }
    Copy-Item -Path $srcDir -Destination $destDir -Recurse -Force
    Write-Ok "产物已复制：$destDir"
    Write-Info "（Windows 产物是一个文件夹，包含 exe 和依赖 dll，整体打包分发）"
    return $true
}

function Build-Web {
    param([string]$VersionName, [int]$BuildNum)

    # P0-D 修复：v0.1 不支持 Web 平台（README 已声明）
    # LMStory 是移动应用（Android/iOS），Web 适配未做（无响应式布局、移动专属交互）
    # v0.2+ 视需求决定是否支持 Web
    # 返回 $true 表示"已处理（跳过）"，避免 'all' 选项误判为构建失败
    Write-Warn 'v0.1 不支持 Web 平台构建，已跳过。'
    Write-Warn 'LMStory 是移动应用，Web 适配未做（无响应式布局、移动专属交互）。'
    Write-Warn '如需 Web 支持，请在 v0.2+ 版本规划。'
    return $true
}

# ========== 主流程 ==========

Write-Host ''
Write-Host '========================================' -ForegroundColor Magenta
Write-Host '         LMStory 一键打包脚本           ' -ForegroundColor Magenta
Write-Host '========================================' -ForegroundColor Magenta
Write-Host ''

# 1. 环境检测
if (-not $SkipEnvCheck) {
    Write-Step '环境检测'

    if (-not (Ensure-Flutter)) {
        Write-Err 'Flutter 环境未就绪，无法继续'
        exit 1
    }

    # 平台相关环境检测放到选择平台后做
}

# 2. 交互式配置：未通过命令行参数传入的项，逐一询问
$askVersion     = -not $PSBoundParameters.ContainsKey('Version')
$askBuildNumber = -not $PSBoundParameters.ContainsKey('BuildNumber')
$askBuildMode   = -not $PSBoundParameters.ContainsKey('BuildMode')
$askClean       = -not $PSBoundParameters.ContainsKey('NoClean')
$askPlatform    = -not $PSBoundParameters.ContainsKey('Platform')

if ($askVersion -or $askBuildNumber -or $askBuildMode -or $askClean -or $askPlatform) {
    Write-Step '交互式配置'
    $cfg = Invoke-InteractiveSetup `
        -AskVersion:$askVersion `
        -AskBuildNumber:$askBuildNumber `
        -AskBuildMode:$askBuildMode `
        -AskClean:$askClean `
        -AskPlatform:$askPlatform

    if ($cfg.ContainsKey('Version'))     { $Version     = $cfg.Version }
    if ($cfg.ContainsKey('BuildNumber')) { $BuildNumber = $cfg.BuildNumber }
    if ($cfg.ContainsKey('BuildMode'))   { $BuildMode   = $cfg.BuildMode }
    if ($cfg.ContainsKey('NoClean'))     { $NoClean     = $cfg.NoClean }
    if ($cfg.ContainsKey('Platform'))    { $Platform    = $cfg.Platform }
}

# 3. 最终确定版本号 / 构建号 / 构建模式
$versionName = if ($Version)               { $Version }    else { Read-PubspecVersion }
$buildNum    = if ($BuildNumber -gt 0)     { $BuildNumber } else { Get-NextBuildNumber }
$buildMode   = if ($BuildMode)             { $BuildMode }   else { 'release' }

# 4. 平台相关环境检测
if (-not $SkipEnvCheck) {
    $needAndroid = ($Platform -eq 'apk' -or $Platform -eq 'aab' -or $Platform -eq 'all')
    $needWindows = ($Platform -eq 'windows' -or $Platform -eq 'all')
    $needWeb = ($Platform -eq 'web' -or $Platform -eq 'all')

    if ($needAndroid) {
        Write-Step '检测安卓打包环境'
        $javaOk = Check-Java
        $androidSdkOk = Check-AndroidSdk
        if (-not ($javaOk -and $androidSdkOk)) {
            Write-Warn '安卓打包环境不完整，请按上述提示安装后重试。'
            Write-Warn '也可使用 -SkipEnvCheck 强制继续（可能构建失败）。'
            exit 1
        }
    }

    if ($needWindows) {
        Write-Step '检测 Windows 打包环境'
        if (-not (Check-VisualStudio)) {
            Write-Warn 'Windows 打包环境不完整，请按上述提示安装后重试。'
            Write-Warn '也可使用 -SkipEnvCheck 强制继续（可能构建失败）。'
            exit 1
        }
    }

    if ($needWeb) {
        Write-Ok 'Web 打包无需额外环境'
    }
}

# 5. 构建前准备
Invoke-PreBuild $versionName $buildNum

# 6. 执行构建
$results = @()

switch ($Platform) {
    'apk'     { $results += [pscustomobject]@{ Platform = 'Android APK';  Success = (Build-Android 'apk' $versionName $buildNum $buildMode) } }
    'aab'     { $results += [pscustomobject]@{ Platform = 'Android AAB';  Success = (Build-Android 'aab' $versionName $buildNum $buildMode) } }
    'windows' { $results += [pscustomobject]@{ Platform = 'Windows';      Success = (Build-Windows $versionName $buildNum $buildMode) } }
    'web'     { $results += [pscustomobject]@{ Platform = 'Web';          Success = (Build-Web $versionName $buildNum) } }
    'all' {
        $results += [pscustomobject]@{ Platform = 'Android APK'; Success = (Build-Android 'apk' $versionName $buildNum $buildMode) }
        $results += [pscustomobject]@{ Platform = 'Android AAB'; Success = (Build-Android 'aab' $versionName $buildNum $buildMode) }
        $results += [pscustomobject]@{ Platform = 'Windows';     Success = (Build-Windows $versionName $buildNum $buildMode) }
        $results += [pscustomobject]@{ Platform = 'Web';         Success = (Build-Web $versionName $buildNum) }
    }
}

# 7. 汇总
Write-Step '构建结果汇总'
$results | ForEach-Object {
    $status = if ($_.Success) { '成功' } else { '失败' }
    $color = if ($_.Success) { 'Green' } else { 'Red' }
    Write-Host ("  {0,-14} : {1}" -f $_.Platform, $status) -ForegroundColor $color
}

$releaseDir = Join-Path $PSScriptRoot 'build\release'
Write-Host ''
Write-Info "产物输出目录：$releaseDir"
Write-Info "版本号：$versionName  构建号：$buildNum  模式：$buildMode"

$failed = $results | Where-Object { -not $_.Success }
if ($failed) {
    Write-Err "有 $($failed.Count) 个平台构建失败"
    exit 1
}

Write-Ok '全部构建完成！'
