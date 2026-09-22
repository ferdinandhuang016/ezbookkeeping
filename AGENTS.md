# ezBookkeeping Agent 工作指南

本文件适用于仓库根目录及所有子目录。执行任务时，以用户当前指令为最高优先级，并遵守更深层目录中可能存在的 `AGENTS.md`。

代码入口、业务约束和按任务修改的步骤见 [Agent 代码手册](AGENT_HANDBOOK.md)。涉及账户币种、原始金额或启用货币时，先阅读 [领域术语](CONTEXT.md)。本文件负责执行约定与本机命令，手册负责解释代码；功能是否通过验收仍以对应证据为准。

## 1. 开始工作前

1. 阅读任务涉及的代码、现有文档和 `git status --short`，不要覆盖、回滚或格式化用户及其他任务的改动。
2. 写清本次任务的成功标准和最小验证方式。存在会改变产品行为的歧义时，列出解释并询问；可从现有代码和验收文档确定的内容直接执行。
3. 只修改任务直接涉及的文件。不要顺手重构相邻模块，也不要删除原有死代码；本次修改产生的无效导入和变量应清理。
4. 优先使用项目已有结构和组件，以最少代码完成需求。不要为一次性需求增加抽象层或预留配置。
5. 前端 UI 不新增单元测试。UI 通过真机或模拟器操作、截图和必要的 ADB 证据验收；金额、同步、数据库等业务规则可写自动化测试。

## 2. 仓库结构

| 路径 | 内容 |
| --- | --- |
| `src/`、`public/` | Vue Web 源码与静态资源；desktop 使用 Vuetify，原 mobile 使用 Framework7 |
| `ezbookkeeping.go`、`cmd/`、`pkg/` | Go 命令入口、HTTP 路由、API、业务逻辑和持久化 |
| `dist/` | Vite 生成的 Web 构建产物，不直接修改 |
| `flutter_app/` | Flutter Android 客户端 |
| `scripts/` | 银行流水转换、只读核对与独立调整脚本，入口见各脚本及说明 |
| `CONTEXT.md`、`AGENT_HANDBOOK.md` | 领域术语、代码导航和修改流程 |
| `flutter_app/docs/MIGRATION.md` | 原 mobile 到 Flutter 的功能对应清单 |
| `flutter_app/docs/ACCEPTANCE.md` | 当前验收结果、证据和已知限制 |
| `.planning/flutter-android/` | Flutter 迁移过程中的计划和辅助验收脚本 |

构建成功不代表功能迁移完成。涉及 Flutter 功能状态时，同时更新并核对迁移清单与验收记录，不得把未操作验证的功能标为通过。

## 3. 本机工具链

当前开发机为 Windows 11，默认使用 PowerShell。以下路径是本机已验证路径；工具升级或迁移后应先重新检查实际位置。

| 工具 | 本机路径 / 版本 |
| --- | --- |
| 仓库 | `D:\Work\Codes\ezbookkeeping` |
| Flutter | `D:\DEV-TOOLS\flutter`，3.47.2 stable |
| Flutter 命令 | `D:\DEV-TOOLS\flutter\bin\flutter.bat` |
| Dart | `D:\DEV-TOOLS\flutter\bin\dart.bat` |
| Android SDK | `D:\DEV-TOOLS\Android\Sdk` |
| ADB | `D:\DEV-TOOLS\Android\Sdk\platform-tools\adb.exe` |
| Emulator | `D:\DEV-TOOLS\Android\Sdk\emulator\emulator.exe` |
| JDK | `D:\DEV-TOOLS\jdk21`，Zulu OpenJDK 21 |
| Chrome | `C:\Program Files\Google\Chrome\Application\chrome.exe` |
| Go / Node / pnpm | 已加入 `PATH`；当前分别为 Go 1.27.1、Node 24.19.0、pnpm 11.19.0 |
| MinGW GCC | `D:\DEV-TOOLS\mingw64\bin\gcc.exe`；SQLite 构建和测试需要 CGO，使用前按 7.2 配置 |

Flutter 和 Dart 当前未加入 `PATH`，Agent 不应假设可直接执行 `flutter`。在新的 PowerShell 会话中先设置：

```powershell
$repoRoot = 'D:\Work\Codes\ezbookkeeping'
$flutterExe = 'D:\DEV-TOOLS\flutter\bin\flutter.bat'
$adbExe = 'D:\DEV-TOOLS\Android\Sdk\platform-tools\adb.exe'
$emulatorExe = 'D:\DEV-TOOLS\Android\Sdk\emulator\emulator.exe'
$env:JAVA_HOME = 'D:\DEV-TOOLS\jdk21'
$env:ANDROID_HOME = 'D:\DEV-TOOLS\Android\Sdk'
$env:ANDROID_SDK_ROOT = $env:ANDROID_HOME
```

Android 字节码目标为 Java 17，但本机构建使用 JDK 21。`flutter doctor -v` 中缺少 Visual Studio 只影响 Windows 桌面构建，不阻塞本项目的 Android 构建。

## 4. Flutter Android 开发

Flutter SDK 版本由 `flutter_app/.fvmrc` 锁定为 3.47.2，依赖由 `pubspec.lock` 锁定。最低系统版本为 Android 7.0 / API 24。

### 4.1 获取依赖和静态验证

在 `D:\Work\Codes\ezbookkeeping\flutter_app` 执行：

```powershell
& $flutterExe pub get --enforce-lockfile
& $flutterExe analyze --no-pub
& $flutterExe test --no-pub
```

只改文档时不必运行 Flutter 全套测试。改动 Dart 业务逻辑时运行相关测试，准备交付或改动跨模块能力时再运行完整测试。不要为了 UI 布局新增 widget 单元测试。

### 4.2 构建 APK

```powershell
& $flutterExe build apk --debug --no-pub
& $flutterExe build apk --release --no-pub
```

输出位置：

- Debug：`flutter_app\build\app\outputs\flutter-apk\app-debug.apk`
- Release：`flutter_app\build\app\outputs\flutter-apk\app-release.apk`

Debug 包名为 `net.ezbookkeeping.app.debug`，正式包名为 `net.ezbookkeeping.app`。当前 release 本地验收包使用 debug 签名，正式分发前必须配置私有签名。

地图密钥只写入已忽略的 `flutter_app\android\local.properties`，禁止提交真实密钥：

```properties
amap.debugApiKey=本机调试密钥
amap.releaseApiKey=发布密钥
```

### 4.3 模拟器选择

本机已有以下 AVD：

| AVD | 用途 |
| --- | --- |
| `ezbookkeeping_audit_api24` | 最低版本兼容、小屏和旧系统行为验收 |
| `ezbookkeeping_debug_api36` | 日常开发、当前 Android 系统行为和深浅色主题调试 |
| `ezbookkeeping_test_api36` | 独立测试数据或并行验收 |

先查看已有设备，避免重复启动：

```powershell
& $adbExe devices -l
& $emulatorExe -list-avds
```

需要时启动一个模拟器：

```powershell
& $emulatorExe -avd ezbookkeeping_debug_api36
# 最低版本验收时改用：ezbookkeeping_audit_api24
```

等待设备完成启动后再安装。设备序列号可能变化，必须从 `adb devices -l` 读取，不要永久写死 `emulator-5554` 等值：

```powershell
& $adbExe devices -l
$deviceSerial = '从上一条命令选择的序列号'
& $adbExe -s $deviceSerial shell getprop sys.boot_completed
& $adbExe -s $deviceSerial shell getprop ro.build.version.sdk
& $adbExe -s $deviceSerial install -r "$repoRoot\flutter_app\build\app\outputs\flutter-apk\app-debug.apk"
```

如需边改边调试，可直接运行：

```powershell
Set-Location "$repoRoot\flutter_app"
& $flutterExe run -d $deviceSerial
```

## 5. ADB 操作验收

### 5.1 启动、停止和快捷入口

```powershell
& $adbExe -s $deviceSerial shell am force-stop net.ezbookkeeping.app.debug
& $adbExe -s $deviceSerial shell monkey -p net.ezbookkeeping.app.debug -c android.intent.category.LAUNCHER 1

# 长按图标“记一笔”所使用的原生 Intent
& $adbExe -s $deviceSerial shell am start -W `
  -a net.ezbookkeeping.app.action.QUICK_ADD `
  -n net.ezbookkeeping.app.debug/net.ezbookkeeping.app.MainActivity

# 桌面概要组件点击首页所使用的 Intent
& $adbExe -s $deviceSerial shell am start -W `
  -a net.ezbookkeeping.app.action.OPEN_HOME `
  -n net.ezbookkeeping.app.debug/net.ezbookkeeping.app.MainActivity
```

涉及冷启动、快捷记账或小组件性能时，至少记录 `am start -W` 返回的 `TotalTime`，并在冷启动和已有进程两种状态下各操作一次。修改小组件尺寸或布局后，桌面上已有组件可能保留旧尺寸，应删除后重新添加再验收。

### 5.2 日志

```powershell
& $adbExe -s $deviceSerial logcat -c
$appProcessId = (& $adbExe -s $deviceSerial shell pidof -s net.ezbookkeeping.app.debug).Trim()
& $adbExe -s $deviceSerial logcat --pid=$appProcessId
```

需要保存日志时使用 `Tee-Object` 写入 `.planning/flutter-android/artifacts/`，不要提交含令牌、服务器地址、用户数据或地图密钥的日志。

### 5.3 截图和界面树

PowerShell 直接重定向 `adb exec-out screencap -p` 可能破坏二进制 PNG。统一先写到设备，再拉取：

```powershell
$artifactDir = "$repoRoot\.planning\flutter-android\artifacts"
New-Item -ItemType Directory -Force -Path $artifactDir | Out-Null
& $adbExe -s $deviceSerial shell screencap -p /sdcard/ezb-screen.png
& $adbExe -s $deviceSerial pull /sdcard/ezb-screen.png "$artifactDir\ezb-screen.png"
& $adbExe -s $deviceSerial shell uiautomator dump /sdcard/ezb-window.xml
& $adbExe -s $deviceSerial pull /sdcard/ezb-window.xml "$artifactDir\ezb-window.xml"
```

视觉验收使用一致的语言、主题、字号、测试数据和视口。API 24 与 API 36 都需要覆盖的改动，应分别留证据。

## 6. 本机联调服务器

Android Emulator 访问宿主机不能使用 `localhost`，应使用：

```text
http://10.0.2.2:8080/
```

服务器部署在路径前缀时保留完整前缀，例如 `http://10.0.2.2:8080/ezbookkeeping/`。真机联调应使用电脑在同一局域网中的 IP，并确认 Windows 防火墙允许对应端口。不要为了调试关闭 HTTPS 证书校验。

Go 服务的正常入口是构建后的可执行文件：

```powershell
.\ezbookkeeping.exe server run
```

默认监听 8080。涉及同步、认证或 API 的修改，先确认 App 指向独立测试账本；数据清理、冲突和离线重放测试不得使用个人或生产账本。

启动过程会在 `auto_update_database=true` 时调用数据库升级；默认值为 `true`。需要隔离配置时使用 `--conf-path` 指定测试配置，再执行 `server run`。Web 开发服务器使用 `pnpm serve`，监听 8081，并按 `vite.config.ts` 代理 API 到 8080；它不负责启动 Go 后端。Web 构建输出为 `dist/`，而 Go 默认静态目录为 `public/`，联调时须核对测试配置的 `static_root_path`。

## 7. Web 和 Go 验证

### 7.1 Web

```powershell
Set-Location $repoRoot
pnpm install --frozen-lockfile
pnpm test
pnpm build
```

`pnpm lint` 会执行 `eslint --fix` 并修改文件，不要把它当作无副作用检查。只需类型检查时使用：

```powershell
pnpm exec vue-tsc --noEmit
```

只有本次任务允许自动修复并已检查 diff 时才运行 `pnpm lint`。Web 或原 mobile 的交互修改应同时用浏览器实际操作验证。

### 7.2 Go

在独立 PowerShell 会话中执行以下配置。当前本机默认 `CGO_ENABLED=0`，GCC 也未加入 `PATH`；直接运行涉及 SQLite 的测试会出现 `go-sqlite3 requires cgo to work`。这些环境设置只影响当前进程，不要用 `go env -w` 修改全局配置。

```powershell
Set-Location $repoRoot
$env:PATH = 'D:\DEV-TOOLS\mingw64\bin;' + $env:PATH
$env:CGO_ENABLED = '1'
$env:CC = 'gcc'
$env:BUILD_PIPELINE = '1'
$env:CHECK_3RD_API = '0'
go test -count=1 ./...
```

`BUILD_PIPELINE=1` 且 `CHECK_3RD_API` 不是 `1` 时，会跳过依赖外部在线数据源的检查，结果不能表述为所有第三方实时服务均已验证。数据库或同步持久化结构变更还需按 `flutter_app/docs/ACCEPTANCE.md` 的现有方式覆盖 SQLite、MySQL 和 PostgreSQL 升级测试。

需要本地 Go 二进制时，在同一 CGO 环境执行 `go build -tags timetzdata -o ezbookkeeping.exe .`。`build.ps1` / `build.sh` 是完整构建与打包脚本，会执行依赖安装、检查等步骤；其中前端 lint 带自动修复，后端包含 `go get .` 和清理编译缓存。只读审查不要直接调用完整打包流程。

## 8. 按改动范围选择验证

| 改动 | 最低验证 |
| --- | --- |
| 仅文档 | 核对路径、命令和链接；检查 diff |
| Dart 业务逻辑 | `flutter analyze`、相关 Dart 测试 |
| Flutter UI / 交互 | `flutter analyze`、API 36 操作验收；兼容性相关再测 API 24 |
| 原生 Android、快捷入口、小组件 | Debug APK 构建、安装、冷/热启动、对应 Intent 或桌面操作、日志检查 |
| 离线数据库或同步 | Dart 测试、飞行模式重启、恢复联网、重复提交和冲突场景；必要时 Go 回归 |
| Web | 类型检查、相关 Vitest、实际页面操作；交付前构建 |
| Go API / 数据库 | 相关包测试；跨模块时 `BUILD_PIPELINE=1 go test -count=1 ./...` |
| 跨端主题、金额或分类规则 | Web mobile 与 Flutter 使用同一数据、语言和主题对照 |

验证失败时先记录可复现步骤、设备/API 版本和完整错误，再修改代码。不要通过放宽断言、吞掉异常或删除验证来获得通过结果。

## 9. 提交前检查

1. `git diff --check`，并再次确认 `git status --short` 中没有误改文件、构建产物、密钥或测试数据。
2. 汇报实际运行过的命令和结果；未运行的测试要明确说明，不能推断为通过。
3. UI 变更给出设备、Android API、主题和关键操作结果。性能问题同时给出冷启动与已有进程数据。
4. 修改迁移状态时，保证 `flutter_app/docs/MIGRATION.md`、`flutter_app/docs/ACCEPTANCE.md` 与真实验收结果一致。
5. APK 交付前确认包名、版本、签名用途和输出路径，避免把本地 debug 签名包描述为生产发布包。
