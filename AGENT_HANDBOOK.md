# ezBookkeeping Agent 代码手册

本手册补充 [AGENTS.md](AGENTS.md)，帮助 Agent 定位实现、判断修改范围并选择验证方式。审阅日期：2026-09-22；依据为当前工作区源码，包含尚未提交的变更。本文记录实现约定，功能验收结果见 [Flutter 验收记录](flutter_app/docs/ACCEPTANCE.md)。

## 1. 接手任务的阅读顺序

1. 读根目录及目标目录的 `AGENTS.md`，运行 `git status --short` 和目标文件的 `git diff`，区分本次任务与已有改动。
2. 涉及业务名词时读 [CONTEXT.md](CONTEXT.md)；涉及 Flutter 迁移时读 [MIGRATION.md](flutter_app/docs/MIGRATION.md) 对应路由及弹层条目，再查验收证据。
3. 用下表定位入口，跟到实际请求、数据模型和持久化代码。搜索优先使用 `rg` / `rg --files`，大文件按函数或相关片段阅读。
4. 写明成功标准、影响端和最小验证。先复现业务缺陷，再修改；UI 使用设备或浏览器操作验收，不新增 UI 单元测试。

### 代码地图

| 要找的内容 | 从这里开始 | 继续追踪 |
| --- | --- | --- |
| Go 命令、服务器启动 | [ezbookkeeping.go](ezbookkeeping.go)、[cmd/webserver.go](cmd/webserver.go) | [cmd/initializer.go](cmd/initializer.go)、[pkg/settings/setting.go](pkg/settings/setting.go) |
| HTTP 契约与校验 | [pkg/api/](pkg/api/)、[pkg/models/](pkg/models/) | [pkg/validators/](pkg/validators/)、[pkg/errs/](pkg/errs/)、[pkg/middlewares/](pkg/middlewares/) |
| 业务写入与数据库 | [pkg/services/](pkg/services/)、[pkg/datastore/database.go](pkg/datastore/database.go) | [pkg/datastore/client_sync.go](pkg/datastore/client_sync.go)、[cmd/database.go](cmd/database.go) |
| Web 页面与路由 | [src/desktop-main.ts](src/desktop-main.ts)、[src/mobile-main.ts](src/mobile-main.ts) | [src/router/](src/router/)、[src/views/desktop/](src/views/desktop/)、[src/views/mobile/](src/views/mobile/) |
| Web 共用业务 | [src/views/base/](src/views/base/)、[src/stores/](src/stores/) | [src/models/](src/models/)、[src/core/](src/core/)、[src/lib/services.ts](src/lib/services.ts) |
| Flutter 启动与导航 | [flutter_app/lib/main.dart](flutter_app/lib/main.dart)、[app.dart](flutter_app/lib/app.dart) | [features/mobile.dart](flutter_app/lib/features/mobile.dart)、[core/app_controller.dart](flutter_app/lib/core/app_controller.dart) |
| Flutter 离线与同步 | [ledger_repository.dart](flutter_app/lib/data/ledger_repository.dart) | [ledger_database.dart](flutter_app/lib/data/ledger_database.dart)、[api_client.dart](flutter_app/lib/core/api_client.dart) |
| Flutter 公共 UI | [ui/common.dart](flutter_app/lib/ui/common.dart)、[ui/selection_sheets.dart](flutter_app/lib/ui/selection_sheets.dart) | [features/](flutter_app/lib/features/)、[ui/quick_add_startup.dart](flutter_app/lib/ui/quick_add_startup.dart) |
| Android 平台能力 | [MainActivity.kt](flutter_app/android/app/src/main/kotlin/net/ezbookkeeping/app/MainActivity.kt) | [BookkeepingWidgetProvider.kt](flutter_app/android/app/src/main/kotlin/net/ezbookkeeping/app/BookkeepingWidgetProvider.kt)、[AndroidManifest.xml](flutter_app/android/app/src/main/AndroidManifest.xml) |
| 地图桥接 | [src/native-map-main.ts](src/native-map-main.ts)、[native_features.dart](flutter_app/lib/features/system/native_features.dart) | [amap_location.dart](flutter_app/lib/features/system/amap_location.dart)、Go 的 `/native-map` 与地图代理路由 |
| 汇率、导入与定时交易 | [pkg/exchangerates/](pkg/exchangerates/)、[pkg/converters/](pkg/converters/)、[pkg/cron/](pkg/cron/) | 对应 API、服务及同目录测试 |

Web desktop 使用 Vue + Vuetify；原 mobile 使用 Vue + Framework7。两者共享页面基础逻辑、Pinia store、模型和请求层。Flutter 是独立原生客户端，通过相同 Go 服务及额外的同步协议工作；不是 Web 页面外包一层 WebView。

## 2. 请求与数据怎样流动

### Web 与 Go

```text
desktop / mobile 页面
  → views/base + stores + models
  → src/lib/services.ts（Axios、认证头、时区头、部署前缀）
  → cmd/webserver.go（路由、功能开关、中间件）
  → pkg/api（绑定请求、认证上下文、参数及权限校验）
  → pkg/services（业务规则、余额、关联记录）
  → pkg/datastore（Xorm、事务、同步日志）
  → SQLite / MySQL / PostgreSQL
```

注册路由时检查所属路由组及功能开关。多数登录后业务接口位于 `/api/v1/`；登录、2FA、客户端配置与原生 OAuth 有各自的入口。沿用现有 `bindApi`、`core.WebContext`、错误码和响应封装，不在页面重新实现请求协议。

### Flutter

```text
main.dart → AppController + Riverpod → app.dart / GoRouter
  → features 页面调用 AppController
  → 交易增删改进入 LedgerRepository 的持久队列
  → LedgerDatabase 保存远端副本、操作和图片映射
  → synchronize：首次快照 / 拉取 → 推送 → 再拉取
  → Go /api/v1/sync/* → 原有交易 API 与服务
```

`AppController` 负责会话、生命周期、设置、锁屏和刷新；`LedgerRepository` 负责本地有效账本、队列、图片和冲突；`LedgerDatabase` 使用 Drift 配合显式 SQL，并通过 `sqlite3mc` 加密。这里没有需要运行 `build_runner` 的数据库生成流程；修改表结构应检查现有 `schemaVersion` 与升级策略。

资料管理等在线写入通过 `AppController.post` 处理。改变账户或账本基准前，它会先同步并检查待处理操作；成功后按现有页面调用 `refreshAfterMutation`。新增入口不能绕过这些步骤，否则页面和本地余额可能继续显示旧副本。

## 3. 不能随意改变的业务约束

### 3.1 金额、币种与标识符

| 约束 | 当前实现与修改要求 |
| --- | --- |
| 金额单位 | 交易金额使用货币单位的 **100 倍整数**。Go 的单笔范围为 `-999999999999999` 到 `999999999999999`；表单和业务可能进一步限制符号。不要直接用二进制浮点做记账运算。 |
| 金额计算入口 | Web 使用 [src/lib/numeral.ts](src/lib/numeral.ts) 的 Decimal 封装；Flutter 使用 [money.dart](flutter_app/lib/core/money.dart)、[aggregate_amount.dart](flutter_app/lib/core/aggregate_amount.dart) 和 [formatting.dart](flutter_app/lib/core/formatting.dart)。汇总可能超过单笔范围，不能把所有 BigInt 合计改成普通整数或 double。 |
| 舍入与汇总 | 单笔换汇、逐账户合计、分组统计和日历汇总有不同截断时机。以相应 Web 实现、Flutter fixture 和业务测试为依据；不要统一替换成一个 `round()`。 |
| 账户金额与原始金额 | 按 [CONTEXT.md](CONTEXT.md) 区分 Account Amount 与 Original Amount。`originalCurrency` / `originalAmount` 是一组附加字段，账户余额仍按账户币种金额更新；当前服务端仅允许信用卡账户的收入或支出携带不同于账户币种的原始币种。 |
| 启用货币 | 默认选择集为 CNY、USD；有效选择还应保留用户默认币种、已有账户及子账户币种，编辑时保留当前值。关闭一种货币不能改写历史交易或账户。对照 [src/core/currency.ts](src/core/currency.ts) 和 [currency_selection.dart](flutter_app/lib/core/currency_selection.dart)。 |
| ID 与版本 | API 中的交易、账户等 ID 以及同步版本使用字符串传输；Go 内部可为 int64。Web 不得转成 `Number` 后比较或保存；Flutter 排序使用 [transaction_ordering.dart](flutter_app/lib/core/transaction_ordering.dart)，保留同一秒内的交易顺序。 |
| 时间 | 区分秒级 `time`、`timeSequenceId`、`utcOffset` 和用户时区。请求携带 `X-Timezone-Offset` / `X-Timezone-Name`；日期筛选与统计要覆盖跨日、DST 和交易时区偏好。 |

### 3.2 转账与手续费

外部交易类型为：余额调整 `1`、收入 `2`、支出 `3`、转账 `4`。数据库中转账分为转出 `4` 和转入 `5` 两条关联记录，必须在同一事务内处理双方余额及增删改。

当前工作区已包含 `serviceCharge`。API 的 `sourceAmount` 表示转账本金，`serviceCharge` 单独传输；服务端转出记录的 `Amount` 包含本金与手续费，返回 API 时再拆开。例如本金 `10000`、手续费 `200`，转出账户扣减 `10200`；同币种转入为 `10000`。不要把数据库 `Amount` 直接当作接口本金，也不要再次叠加已计入的手续费。

修改时同时检查 [交易模型](pkg/models/transaction.go)、[交易 API](pkg/api/transactions.go)、[交易服务](pkg/services/transactions.go)、模板与计划交易、Web 模型、Flutter 本地余额投影及统计。`originalCurrency` / `originalAmount` 与 `serviceCharge` 是不同概念，不可互相替代。

### 3.3 离线同步

实现入口为 [client_sync.go API](pkg/api/client_sync.go)、[同步模型](pkg/models/client_sync.go) 和 [datastore/client_sync.go](pkg/datastore/client_sync.go)。审查任何账本写入时核对以下规则：

1. **提交原子性**：业务写入、余额、公开记录投影及变更日志通过 `DoLedgerTransaction` 同一事务提交；同步 push 的操作回执也在账本锁保护的事务内保存。普通 Web 写入、批量导入和计划交易同样需要让客户端收到变化。
2. **锁与会话复用**：`WithSyncTransaction` 以用户账本状态行串行化写入；嵌套服务使用同一同步会话，不能额外提交一半业务。
3. **重试身份**：`deviceId + operationId` 标识一次操作，回执保存请求哈希与响应。重试同一操作应保持身份和内容；发生冲突后的新决定按现有替换操作流程生成新操作。
4. **版本与代次**：`baseVersion` 检查记录冲突；`generation` 防止清空账本前的离线队列重新写回。删除标记、游标和持久回执不是普通缓存，不可随清缓存一并移除。
5. **投影范围**：`DoLedgerTransaction` 的交易 ID 参数传 `nil` 表示全扫描，空列表表示只刷新元数据，非空列表表示涉及的交易及关联记录。选择错误会漏同步或引入不必要的扫描。
6. **本地持久性**：远端副本与待提交操作分开保存；本地可见数据叠加有效操作。首次完整同步后才能离线记账；离线队列支持收入、支出、转账，余额调整走在线账户操作。
7. **冲突与图片**：保留服务器和本地副本供用户决定；拒绝和冲突不等于成功。图片暂存及上传映射必须支持重启与重试，不能只存在 Widget 内存中。

### 3.4 会话、应用锁与平台入口

账本隔离键由规范化服务器地址与用户 ID 生成。服务器部署前缀必须保留，例如 `https://example.com/books/` 下的请求不能解析成站点根 `/api/`。令牌和数据库密钥使用安全存储；清缓存保留待提交业务，认证失效保留本地账本并暂停同步。

`app.dart` 在锁定时保留编辑器并叠加锁屏，避免相机、图库等外部操作返回后丢失输入。快捷记账、桌面组件、分享和 OAuth 返回都要经过相同的会话与解锁流程。修改 `ezbookkeeping/native` MethodChannel 时，同时检查 Dart 调用和 Kotlin 实现；桌面组件只接收格式化汇总，不保存令牌、数据库密钥或交易明细。

## 4. 按任务执行修改

### 新增或修改交易字段

1. 从模型明确类型、默认值、缺省与清空语义、金额单位和适用交易类型。
2. 检查 Go 请求绑定、服务校验、Xorm 字段、更新列列表及响应序列化；需要持久化时检查 [cmd/database.go](cmd/database.go) 和已有数据升级。
3. 检查同步投影、Flutter 请求队列、本地副本与编辑预填；同时检查 Web store、模型和共用页面基础逻辑。
4. 按字段用途检查普通模板、计划交易、复制／草稿、导入导出、详情、列表和统计，避免只能新增不能再次编辑。
5. 用正常值、缺省／清空、边界／非法值、修改后重读和离线重试验证；跨端规则用同一账本核对。

### 修改设置、货币或语言

设置从 [src/core/setting.ts](src/core/setting.ts)、[src/stores/setting.ts](src/stores/setting.ts) 追踪。若属于云设置，还要检查 [服务端设置模型](pkg/models/user_app_cloud_setting.go)、Web 云设置页面、Flutter 的 [application_settings.dart](flutter_app/lib/core/application_settings.dart) 与 `AppController`，同步更新生成的设置资源。

新增设置不仅要出现在设置页，还要在目标页面产生可验证的效果。覆盖默认值、旧配置未含此键、关闭／恢复、重启以及云端应用后的行为。货币选择复用有效货币计算，不在每个选择器另写白名单。

### 修改 UI、导航或 Android 能力

先在现有 `views/base`、共用组件或 Flutter `ui/` 中找复用入口，保持现有文件风格，不借布局修改重构业务。Flutter 路由同时检查 `app.dart` 的路由表、`mobilePage` 分发和 `MIGRATION.md`；修改底栏时检查一级页面与筛选后列表的返回路径。

Web 在实际浏览器验证 desktop / mobile 受影响的页面；Flutter 至少在 API 36 验证，兼容性相关再覆盖 API 24。锁屏、键盘、返回键、明暗主题、小屏及字号按受影响场景选择。原生 Intent、小组件和冷／热启动的具体命令见 [AGENTS.md](AGENTS.md)。

### 修改数据库或同步

先写可以失败的业务用例，再修改事务或迁移。服务端新增模型要纳入真实升级入口，不能只在测试 fixture 中建表；Flutter schema 变更要能打开已有本地账本并保留待提交操作。

同步测试检查最终记录数、双方账户余额、游标／版本、重试回执和删除标记；只断言 HTTP 200 不足以证明正确。使用独立测试账本执行断网、强停重启、恢复网络、并发修改、响应丢失后的重试及账本清空场景。

## 5. 生成资源的维护入口

下面的 Node 命令在仓库根目录运行，脚本直接读取原 Web 常量，部分脚本依赖根目录 `node_modules`。只运行本次任务需要的生成器，检查生成差异后再提交。

| 资源 | 可编辑来源／命令 | 核对点 |
| --- | --- | --- |
| 图标、币种、预设分类、概览布局 | `node flutter_app/tool/generate_reference_assets.cjs` | 更新 `assets/reference/`、字体与 `lib/ui/reference_icons.dart`；不手改生成图标映射 |
| 设置默认值、选项、云同步分组 | `node flutter_app/tool/generate_settings_reference.cjs` | 来源含 Web `core/setting.ts` 和云设置页面；核对 `settings.json` 与设置业务测试 |
| 日期、数字、历法及格式 fixture | `node flutter_app/tool/generate_formatting_assets.cjs` | 对照 `formatting.json` 和 `formatting_fixtures.json`，保留各页面的运算顺序 |
| Web 原翻译副本 | 编辑 `src/locales/` 对应文件，再同步同名文件到 `flutter_app/assets/locales/` | 原生本地化测试逐字节比较副本，CRLF/LF 差异也会失败；不要将 Android 专用文案写进副本 |
| Android 专用文案 | 编辑 `flutter_app/tool/native_messages.psv` / `native_locale_aliases.json`，运行 `node flutter_app/tool/generate_native_locales.cjs` | 生成 `assets/native_locales/`；用 `node flutter_app/tool/generate_native_locales.cjs --check` 检查语言、占位符和遗漏键 |
| 其它 Web 对照 fixture | [flutter_app/tool/](flutter_app/tool/) 中对应 `generate_*_fixtures.cjs` | 按统计、布局、汇率或会话等主题选择，不能用重新生成来掩盖行为差异 |

本地化细节见 [README_NATIVE_LOCALES.md](flutter_app/tool/README_NATIVE_LOCALES.md)。原生错误展示沿用 `app.errorText(error)`，保留重试和认证处理需要的原异常信息。

## 6. 开发与验证入口

完整工具链、环境变量和 ADB 步骤见 [AGENTS.md](AGENTS.md)。以下命令按任务选择；Go 命令先配置该文件 7.2 的 MinGW/CGO 环境，Flutter 命令在 `flutter_app/` 下使用 `$flutterExe`。

| 修改范围 | 最小自动化入口 | 还需要检查 |
| --- | --- | --- |
| Web 类型与业务 | `pnpm exec vue-tsc --noEmit`；`pnpm exec vitest run src/core/__tests__/currency.test.ts`（货币任务示例） | 受影响页面实操；交付前 `pnpm build`；`pnpm lint` 会改文件 |
| Go 金额、原始金额、手续费 | 本表下方的金额测试命令 | Web、Flutter、模板和统计的相同输入输出 |
| 服务端同步 | `go test -count=1 ./pkg/api -run '^TestClientSync'` | 隔离数据库、设备断网重启与并发冲突 |
| 已有数据库升级 | `go test -count=1 ./cmd -run '^TestDatabaseUpgradePopulatedPreSyncLedger$'` | 三种数据库、升级后写入与再次打开；新增业务列另写旧表升级用例 |
| Flutter 金额与账户业务 | `& $flutterExe test --no-pub test/money_test.dart test/catalog_business_test.dart` | UI 中输入、保存、详情与合计 |
| Flutter 本地账本和同步 | `& $flutterExe test --no-pub test/ledger_repository_test.dart test/encrypted_ledger_test.dart` | 飞行模式、进程重启、图片及待提交操作保留 |
| Flutter 设置或语言 | `& $flutterExe test --no-pub test/settings_contract_test.dart test/native_localization_test.dart` | 设置实际效果、重启、目标语言和资源生成检查 |
| Flutter UI / 原生交互 | `& $flutterExe analyze --no-pub`，原生变更再构建 debug APK | 真机／模拟器操作、截图及日志；不新增 UI 单元测试 |
| 仅文档 | 路径与链接检查、命令与源码核对、`git diff --check` | 新增且未跟踪的文档也要检查；普通 `git diff` 不会显示其内容 |

金额、原始金额和手续费的针对性测试，在仓库根目录运行：

```powershell
go test -count=1 ./pkg/models ./pkg/services ./pkg/api -run 'OriginalAmount|ServiceCharge|TransferDestination'
```

### 三种数据库不是一次默认测试

`pkg/api/client_sync_test.go` 默认使用临时 SQLite。只有设置了 `EZBOOKKEEPING_SYNC_TEST_DB_TYPE` 及对应 `HOST`、`USER`、`PASSWORD`、`NAME` 环境变量时，才会连接外部数据库。运行前检查目标，不能把默认 SQLite 结果写成“三数据库通过”。

已有数据升级测试另用 `EZBOOKKEEPING_UPGRADE_TEST_DB_NAME`，要求名称以 `upgrade_test_` 开头且数据库为空；不能复用普通同步测试库。具体入口见 [cmd/database_test.go](cmd/database_test.go) 与 [历史升级审查记录](flutter_app/docs/evidence/backend-upgrade-audit.md)，历史结果只证明记录中的源码与场景。

### 构建与本地配置

依赖与版本依据为 [package.json](package.json)、[go.mod](go.mod)、[pubspec.yaml](flutter_app/pubspec.yaml)、[.fvmrc](flutter_app/.fvmrc) 及各锁文件。现有 Windows 工具路径见根指南；修改版本须同步检查 [Flutter CI](.github/workflows/flutter.yml) 和相关构建脚本。

Go 优先以 `EBK_WORK_DIR` 为工作目录，未设置时使用进程当前目录；默认配置位于该目录的 `conf/ezbookkeeping.ini`，也可用 `--conf-path` 指定配置文件。`server run` 可能自动升级数据库，启动测试服务前先准备独立配置。`pnpm serve` 为 Web 开发服务；生产静态资源由 `pnpm build` 写入 `dist/`，需通过 Go 的 `static_root_path` 或打包流程提供，不能仅编译 Go 后认为前端已更新。

`build.ps1` / `build.sh` 会安装依赖、运行测试及带修复的 lint；普通审查使用单独的只读检查。Android 的包名、版本号和签名配置分别核对 [build.gradle.kts](flutter_app/android/app/build.gradle.kts) 与 `pubspec.yaml`，当前 release 构建仍使用本地 debug 签名。

### 银行流水辅助脚本

[scripts/](scripts/) 包含工行、招行转换及核对脚本，与应用构建流程独立。先阅读 [工商银行流水处理说明](scripts/工商银行流水处理说明.md) 及目标脚本的 CLI：转换后的 Excel 是后续核对输入，标准流程为转换、检查、只读核对、审核调整清单，再单独执行写入。不要在代码审查中顺带运行线上调整；`bill/`、`tmp/` 等本机数据不作为测试 fixture 提交。

## 7. 本轮审阅得到的执行结论

- 现有指南的 `internal/` 路径与工作区不符，代码实际集中在 `cmd/` 与 `pkg/`；根指南已修正，并补上代码手册入口。
- 本机 Go 1.27.1、Node 24.19.0、pnpm 11.19.0、Flutter 3.47.2 / Dart 3.13.2 已通过版本命令核对。MinGW 位于 `D:\DEV-TOOLS\mingw64\bin\gcc.exe`。
- 默认 Go 环境为 `CGO_ENABLED=0`。实际执行 `TestTransactionOriginalAmountColumnsCanUpgradePopulatedSQLiteTable` 复现 SQLite stub 错误；在进程内加入 MinGW 并设置 `CGO_ENABLED=1`、`CC=gcc` 后，同一用例通过。根指南已补齐前置条件。
- [ACCEPTANCE.md](flutter_app/docs/ACCEPTANCE.md) 仍记录完整 Flutter 迁移验收未通过，也记录过 Windows 图片重试用例清理数据库文件失败及语言副本换行差异。处理对应任务时先复现并按新构建补证据，不默认跳过用例或把历史结果推广到当前源码。

本轮实际运行的是工具版本核对与上述 SQLite 升级用例；未重新执行全量 Go / Web / Flutter 测试、APK 构建和设备验收。后续修改应按受影响范围重新验证。

## 8. 交付时说清楚什么

交付说明应包含修改目的与文件、实际执行的命令及结果、设备／API／主题与关键操作、证据路径，以及仍待验证的分支。未执行、跳过、失败和通过分别表述。功能状态发生变化时同步更新迁移清单与验收记录，不能只改勾选状态。

结束前检查本次 diff 和 `git status --short`，确认没有加入构建产物、账本、令牌、地图密钥或无关格式变更。使用新建文件时也检查其完整内容；不要自动提交用户已有的未提交修改。
