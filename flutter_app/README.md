# ezBookkeeping Flutter Android

原 mobile 的原生 Android 客户端，独立于现有 Web 工程维护。业务页面使用 Flutter；地图使用服务器同源的受限 WebView 页面。首次连接支持 HTTP、HTTPS 和部署路径前缀；HTTPS 使用正常证书校验。

**当前完整性以 [迁移清单](docs/MIGRATION.md) 和 [验收记录](docs/ACCEPTANCE.md) 为准。尚未完成全部页面、弹层、功能开关和设备场景的验收，不能仅凭 APK 可运行认定全量迁移完成。**

## 工具链

| 项目 | 固定值 |
|---|---|
| Flutter / Dart | 3.47.2 / 3.13.2；`.fvmrc` 固定 Flutter 版本 |
| Java | 本地已使用 JDK 21 验证；Android 字节码目标 17 |
| Gradle / Android Gradle Plugin / Kotlin | 9.3.1 / 9.1.0 / 2.4.0 |
| Android 最低版本 | Android 7.0，API 24 |
| 应用名 | ezBookkeeping |
| 测试包标识 | `net.ezbookkeeping.app.debug` |
| Dart 依赖 | `pubspec.yaml` 使用精确版本，提交 `pubspec.lock` |

从 [Flutter SDK Archive](https://docs.flutter.dev/install/archive) 安装指定版本，将 `flutter/bin` 加入 PATH。安装 Android SDK、平台工具和 JDK，然后按 [Android 环境说明](https://docs.flutter.dev/platform-integration/android/setup) 完成许可证与设备配置。构建会使用 Flutter SDK 对应的 compile SDK 和 NDK。

```sh
flutter --version
flutter doctor -v
flutter doctor --android-licenses
cd flutter_app
flutter pub get --enforce-lockfile
flutter analyze --no-pub
flutter test --no-pub --reporter expanded
flutter build apk --debug --no-pub
```

测试 APK：`build/app/outputs/flutter-apk/app-debug.apk`。可用 `adb install -r build/app/outputs/flutter-apk/app-debug.apk` 安装，或 `flutter run` 选择已连接设备。

## 高德定位配置

App 使用高德 Android 定位 SDK，新建交易默认尝试附加当前位置。两枚 Key 写入本机已被 Git 忽略的 `android/local.properties`：

```properties
amap.debugApiKey=你的调试版Key
amap.releaseApiKey=你的发布版Key
```

之后直接执行 `flutter run` 或 `flutter build apk --release`，构建会根据 Debug/Release 类型自动选择对应 Key。

高德控制台中调试包的 Package 为 `net.ezbookkeeping.app.debug`，发布包为 `net.ezbookkeeping.app`。两者签名 SHA-1 和 Package 不同，应分别创建 Android 平台 Key；发布前必须把 release Key 绑定到真实发布证书，不能继续使用仓库本地测试用的 debug 签名。首次定位会展示高德第三方定位告知，用户拒绝或系统定位失败时不会阻塞记账。

Web（Desktop/Mobile 共用）需在服务端 `ezbookkeeping.ini` 的 `[map]` 中配置：

```ini
map_provider = amap
amap_application_key = 你的Web端(JS API)Key
amap_security_verification_method = internal_proxy
amap_application_secret = 你的安全密钥securityJsCode
```

生产环境保持 `internal_proxy`，不要把 `securityJsCode` 以 `plain_text` 下发到浏览器；站点必须使用 HTTPS 才能可靠申请浏览器定位权限。部署方还需在自己的隐私政策中说明使用“高德开放平台定位 SDK”、第三方主体、使用目的和处理的数据类型。

Windows 的 Pub Cache 和工程位于不同磁盘时，Kotlin 增量缓存曾出现 `this and base files have different roots`。工程已设置 `kotlin.incremental=false` 和 `kotlin.compiler.execution.strategy=in-process`，标准 Flutter 构建命令无需额外的本机路径或参数。该设置使用 [Kotlin Gradle 编译配置](https://kotlinlang.org/docs/gradle-compilation-and-caches.html)。

仓库的 [独立 Flutter CI](../.github/workflows/flutter.yml) 执行锁文件解析、静态检查、业务测试和 debug APK 构建；成功后可在运行的 Artifacts 中下载 APK。CI 不代替设备和视觉验收。测试包使用 debug 签名；正式发布签名需另外配置。

## 连接服务器

1. 构建并部署本分支的 Go 后端和 Web 静态资源，运行项目现有数据库升级流程。新增同步表由现有数据库初始化／升级路径创建。
2. 首次打开 App，输入服务器根地址，例如 `https://example.com/books/`。服务器必须提供同步协议 v1，旧版本会显示升级提示。
3. 使用原账号登录；首次同步分页下载完整账本，页面显示进度。完成前历史统计不能视为完整。
4. Android Emulator 访问宿主机可使用 `http://10.0.2.2:端口/前缀/`；真机使用设备可访问的服务器地址。

反向代理需保持原 Web/API 的路径前缀行为，并转发 `/api/client/config.json`、`/api/v1/sync/*`、`/api/oauth2/native/*` 和 `/native-map`。后端 `root_url` 应与设备实际访问的外部地址一致。OIDC 的提供商回调仍是服务器 `/oauth2/callback`，App 收到一次性凭证后通过 PKCE 兑换登录结果。

## 本地数据与同步

- 首次完整同步后，交易查询、筛选和统计读取加密本地账本；收入、支出和转账的新增／修改／删除先持久写入本地队列。
- 服务器地址与用户 ID 共同隔离数据；密钥和令牌由 Android 安全存储保护。SQLite 使用 `sqlite3mc` 构建。
- 同步在启动、恢复前台和前台网络恢复时触发，也可手动刷新。服务器返回记录版本、删除标记、账本代次和持久化操作回执。
- 待提交内容与服务器副本分开保存；冲突展示两边内容，由用户选择服务器版本、本地版本或稍后处理。
- 账户、分类、标签、模板等资料管理，以及余额调整、对账、批量迁移、清理、AI、认证管理、服务器导出需要联网。会改变账本基准的操作先处理待同步交易。
- 清缓存保留账本、待同步操作与待上传图片；登录失效暂停同步并保留本地数据。主动退出有待同步内容时必须同步或明确放弃。

以上为实现约定；可靠性、冲突和失败恢复的已验范围请看验收记录。

## Android 桌面入口

- Android 7.1/API 25 及以上长按应用图标会显示“记一笔”（非中文系统显示对应本地化名称），点击后进入新增交易。Android 7.0/API 24 不支持系统静态快捷方式。
- 桌面组件包含 1×1“记一笔”和 4×2“当月概要”。1×1 进入新增交易；概要可在收入、支出和总计三个 Tab 间切换，总计为收入减支出。
- 同比按当前自然月与上年同月计算；上年同月为零时显示 `—`。金额使用首页统计时区、默认币种、既有定点换汇及金额格式规则，并包含本地有效的待同步交易。
- App 在账本或相关设置变化时更新原生组件快照。原生层仅保存年月和格式化后的汇总展示值，不保存令牌、数据库密钥或交易明细。退出登录会清除汇总快照。
- 快捷入口和 1×1 组件沿用应用登录与锁屏流程；锁定状态下先解锁，再进入新增交易。

## 目录

```text
lib/core/       连接、身份、设置、金额、语言、日期和时区
lib/data/       加密数据库、远端副本、操作队列与同步 Repository
lib/features/   auth / overview / transactions / catalogs / statistics / settings / system
lib/ui/         主题公共页面、行、弹层、原图标与选择器
assets/        21 种原翻译、原字体图标、生成的业务常量和许可
test/          金额、日期、业务规则、数据库和同步测试（无 UI 单元测试）
tool/          从原 Web 常量生成参考资源
docs/          路由与弹层迁移清单、验收记录
android/       Android 工程、分享接收、权限和原生认证适配
```

在仓库根目录安装现有 Node 依赖后，可运行 `node flutter_app/tool/generate_reference_assets.cjs` 更新原图标、币种、分类预设和概览组件常量。语言、设置与格式资源由 `tool/` 中对应生成脚本维护。更新资源后核对生成差异，运行 Flutter 业务测试。金额以 100 倍整数单位处理，ID 始终作为字符串保存。

会话设备解析使用固定版本的 [UAParser Dart 移植](https://pub.dev/packages/ua_parser/versions/1.0.0)，与原 Web 的 UAParser.js 1.0.41 生成数据对照；运行 `node flutter_app/tool/generate_session_fixtures.cjs` 更新这些业务 fixture。

## 回归

Flutter 修改运行上面的 analyze/test/build。后端同步修改还需运行 `go test ./...` 和 SQLite、MySQL、PostgreSQL 的同步集成测试；测试数据库必须隔离。地图或共享 Web 代码修改需要运行仓库的 Web 测试与生产构建。完整操作场景见 [ACCEPTANCE.md](docs/ACCEPTANCE.md)。
