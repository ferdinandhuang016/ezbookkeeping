# Flutter Android 验收记录

记录日期：2026-09-22。范围以 [MIGRATION.md](MIGRATION.md) 的 R01–R46、D01–D18 和条件功能矩阵为准。

**当前结论：部分业务链路通过，完整迁移验收未通过。** 下表仅记录有日志、结果 JSON 或设备操作证据的场景。源码覆盖、路由数量、单次构建和一次记账成功，都不能替代其余功能验收。

## 环境与证据

- Android Emulator：API 36 和独立的 API 24（Android 7.0），均为 x86_64，包名 `net.ezbookkeeping.app.debug`。API 24 已实际安装、启动及操作；未验证实体 Android 7 手机。
- 原 mobile 基准：Framework7 iOS 风格，`zh-Hans`，CNY 测试账本，412 × 915 CSS 视口。已采集登录、首页、交易列表和账户选择基准；没有完成所有页面的相同视口明暗对照。
- 后端／数据库：隔离的 SQLite、MySQL、PostgreSQL 测试环境；设备通过 `/books/` 前缀连接宿主机。全部清理、认证和记账测试使用测试账号。
- 原生界面测试由人工／设备自动操作完成；未编写 Flutter UI 单元测试。
- [evidence/](evidence/) 归档经过检查、不含令牌的结果 JSON，以及代表截图。其余截图名对应本次工作区 `.planning/flutter-android/artifacts/` 的原始操作证据；下文明确区分中间构建与最终复验。

## 已执行场景

| ID | 操作与预期 | 结果与证据 | 范围限制 |
|---|---|---|---|
| E01 / R02 | 从带 `/books/` 路径的服务器读取配置、登录、分页初始化 | 配置协议 v1 和续传游标通过 HTTP smoke；Android 成功进入原账本 | HTTP/HTTPS 各部署方式、旧服务器升级提示、全部初始同步中断点待验 |
| E02 / R07 | 飞行模式新增支出 12.34，强制停止，重启，恢复网络 | [device-offline-result.json](evidence/device-offline-result.json)：重启后待同步 1，联网后 0；服务器仅 1 条，现金余额 959.16，原 Web 真实页面可见 | 本条只覆盖一条支出；后续转账和冲突见 E11、E14，收入等其余分支待验 |
| E03 / R04、R28 | 配置 PIN，强停重启，错误 PIN、正确 PIN、后台恢复 | [device-pin-result.json](evidence/device-pin-result.json)：重启锁定、错误拒绝、正确解锁、后台恢复重新锁定通过 | API24无生物硬件提示后由E16覆盖；实体生物硬件成功／取消／锁定仍待验 |
| E04 / R04、R07 | 禁用自动草稿时编辑未保存交易，切后台锁定，尝试返回／边缘滑动，解锁 | [device-lock-retention-result.json](evidence/device-lock-retention-result.json)：锁定无法绕过，原编辑器及备注／账户／分类／时间保留 | 系统回收后未保存输入、其它编辑页锁定保留待验 |
| E05 / D14 | 从交易进入同源地图，显示 OSM 瓦片，启用点击选择，保存坐标 | [device-map-result.json](evidence/device-map-result.json)：`/books/`、瓦片加载、合成坐标选取、回填原生字段通过 | 其它地图提供商、真实 GPS、权限拒绝和代理组合待验；该坐标不是用户真实位置 |
| E06 / R07、D15 | 图库图片随离线支出 1.11 保存，强停重启，联网上传 | [device-picture-result.json](evidence/device-picture-result.json)：重启队列保留，服务器 1 条交易／1 张图片 | 中间构建发现离线预览缺陷，保留原 JSON 的 `offlinePreviewNeedsFix`；后续 E10 已复验相同本地图片预览路径通过。其它图片分支仍待验 |
| E07 / D13 | AI 文本与票据 HTTP 识别；Android 长按首页进入文本识别、复核、回填并保存 | [ai-smoke-result.json](evidence/ai-smoke-result.json)、[device-ai-result.json](evidence/device-ai-result.json)：18.50、分类／账户映射和保存 1 条通过 | 使用确定性本地测试提供商，未测试真实模型准确率；后续直接预填、焦点与票据复核回填已由E19覆盖 |
| E08 / R34 | HTTP 2FA 启用、令牌更新、错误码、TOTP 登录、恢复码一次使用、重生成、关闭 | [security-smoke-result.json](evidence/security-smoke-result.json)：上述接口场景通过；API24 另有二维码显示、TOTP 确认、恢复码复制／Done、密码确认关闭的设备记录 | 含密钥／恢复码截图只留ignored测试目录；后续邮件流程和2FA原生登录挑战由E22/E23覆盖，其余失败组合仍待验 |
| E09 / D16 | HTTP OIDC start→本地提供商→callback→App 兑换，错误 verifier／重复兑换／取消；Android 系统 Chrome 成功／取消回调 | [oidc-smoke-result.json](evidence/oidc-smoke-result.json)、[device-oidc-result.json](evidence/device-oidc-result.json)：一次性凭证、PKCE、回调无登录令牌；真实浏览器返回、取消原因和新账号空账本隔离通过；[设备截图](evidence/device-oidc-success.png) | 远程生产提供商、授权期间进程被回收、超时仍待验 |
| E10 / R07、D15 | Android Photos 分享图片→已锁 App→PIN→编辑器→飞行模式保存 1.23→强停重启→离线预览→联网 | [device-share-result.json](evidence/device-share-result.json)：离线队列 1、联网队列 0，服务器恰好 1 条交易／1 张图片，离线图片可见；[预览截图](evidence/device-share-offline-preview.png) | 此构建未含之后的深色交易行、汇总截断和最后翻译修正；多图片、相机、权限拒绝仍待验 |
| E11 / R08、D17 | 离线修改与 Web API 并发修改同一交易，查看差异、稍后处理、采用最新本地版本 | [device-conflict-result.json](evidence/device-conflict-result.json)：两次本地操作、双方差异保留，解决后待同步 0、服务器 1 条／1 图，金额 4.00 | 原 JSON 的 `editorReturnNeedsFix` 是中间构建问题；E12 已单独复验修复。远端删除、采用服务器版本及其它冲突分支仍需设备验收 |
| E12 / R08、R11 | 创建账户返回账户列表，交易保存返回详情，显示最新金额，深色中文标签 | [device-navigation-result.json](evidence/device-navigation-result.json)：账户创建导航及交易详情返回通过，金额由先前冲突测试 4.00 再改为 3.33，详情立即显示 | 本记录明确关闭 E11 的旧导航缺陷；不改写或删除旧失败证据 |
| E13 / R05、R09 | 切换交易列表／日历／相册；日期过滤和空日；点击凭证缩略图 | [device-transaction-views-result.json](evidence/device-transaction-views-result.json)：日期过滤、两张缩略图及进入 3.33 交易详情通过；[深色相册](evidence/device-transaction-gallery.png) | 截图对应 D89FED14 构建，随后新增的辅助功能标签未在此轮复验 |
| E14 / R07、R08 | 飞行模式新增 CNY 1.23 → USD 0.20 转账，改为 USD 0.30，重启／同步；再离线滑动删除、重启／同步 | [device-transfer-result.json](evidence/device-transfer-result.json)：创建仅 1 笔，双方金额 123/30，现金 934.99、美元 600.30；删除后 0 笔、现金 936.22、美元 600.00；[离线重启余额](evidence/device-transfer-restart-balances.png) | 构建 SHA-256 见 JSON；不替代所有换汇舍入、编辑范围和并发转账场景 |
| E15 / R33、D18 | 原生保存 CSV／TSV，取消保存，系统文件选择器返回锁定后 PIN 解锁 | [device-export-result.json](evidence/device-export-result.json)：两格式各 10 数据行、金额一致、取消不留文件、返回锁定和保存成功提示通过 | 导出失败响应解包后续已加业务测试，修改后失败设备场景仍待验 |
| E16 / R02、R04、R07、D03 | API24 最低平台安装／登录、两笔支出；320×480dp、系统字号 1.3；计算器溢出修复复验 | 独立 AVD 实际 Android 7.0；D89FED14 构建计算器 `1+2=` 回填 3.00，随后放弃；[小屏计算器](evidence/api24-retest-small-calculator.png)。标题、滚动、返回键及无生物识别硬件提示通过 | 首轮测试现金 989.77，后续管理测试继续更改独立账本，不能用后续余额覆盖历史结论。实体传感器和 API24 地图待验 |
| E17 / R25、R30、R32、R33 | 独立账号资料格式、头像返回、47 云设置、导出及两种清理 | [settings-contract-result.json](evidence/settings-contract-result.json)：47 键及局部／禁用、所有资料格式、头像直接响应、错误密码不清理、正确清理推进账本代次通过 | 真实 HTTP 加纯业务检查；设置全部目标页面效果和 Android 清理交互仍待验 |
| E18 / R10–R13、R38、R41–R46 | API24 普通模板新增／编辑／应用预填／删除，每周计划新增／删除，双子账户、期末余额修正、父子分类和分组标签使用 | [api24-management-result.json](evidence/api24-management-result.json)：模板／计划最终 0，账户 A 19.00/B 0，Cash 988.77，父子分类及分组引用匹配；[初轮历史结果](evidence/api24-server-initial-phase-result.json) 单独保留 Cash 989.77。B7188678 构建复验每周频率描述与对账保存后自动刷新通过；[返回对账页](evidence/api24-retest-reconciliation-returned.png) | 初轮后新增 A 对账支出 5.00、再次修正支出 1.00 和 Cash 支出 1.00，总支出 17.23；模板应用仅预填未提交。子账户拖动、所有频率和完整管理分支仍待验 |
| E19 / D13 | AI 文本／图片模式、中文错误、取消／重试、完成后焦点及票据复核回填 | [device-ai-retest-result.json](evidence/device-ai-retest-result.json)：B7188678 构建文字页仅粘贴、图片移除后仍为图片模式、中文接口错误、重试保留输入返回 18.50、完成不重新弹键盘、选图识别及复核回填通过；[错误提示](evidence/device-ai-error-translated.png) | 确定性本地提供商和合成票据，不声称真实模型准确率；取消保留证据来自更早 6f148a0b 构建。未额外保存重复交易 |
| E20 / R26、R27、D15 | 离线清理全部缓存、有待同步时退出取消、强停重启并预览本地图片、再同步 | [device-cache-retention-result.json](evidence/device-cache-retention-result.json)：账本／队列／本地图片保留；退出必须明确放弃，取消后会话仍在；联网仅 1 交易／1 图片 | 设备通过全清理保护；各缓存期限、单项过期与磁盘压力待验；测试交易已删并恢复原现金余额 |
| E21 / R01、R22、D10、D11 | 九组件保存、真实预览、剪贴板导出／导入、高度、未保存离开确认、复制／删除及拖动重排 | [device-layout-result.json](evidence/device-layout-result.json)：59D7EEFB 构建上述动作通过，重排强停后保留，最后恢复原九组件顺序；资产 17,241.27 CNY 与账户总额相同 | 最新紧凑组件视觉仍需下个构建复验；不代表九组件全部配置与筛选分支已验 |
| E22 / R02、R03、D09 | 独立 SMTP 原生注册、分类预览切换中文、邮箱未验证登录上下文、错误密码重发、忘记密码 | [auth-device-result.json](evidence/auth-device-result.json)：API24／59D7EEFB，注册默认 CNY／周一、实际邮件、错误保留／重试、激活后登录、重置后旧密码拒绝／新密码登录通过；[预设预览](evidence/auth-preset-chinese.png)、[重发错误](evidence/auth-unverified-resend-error.png) | 实际邮件 token 通过原接口完成；预装 Chrome 69 无法显示原 desktop 邮件网页，未声称网页成功页通过。注册仅验英／简中，完整语言及币种待验 |
| E23 / R02、R27、R34 | 认证条件开关、提示与自定义 OIDC 名称；原生 2FA 取消／错误／TOTP／恢复码 | [auth-device-result.json](evidence/auth-device-result.json)：内部与 OIDC 同开／仅内部／仅 OIDC／关闭注册重置邮箱验证和 2FA 的入口均通过；英语和中文文案通过；TOTP 成功、恢复码一次使用、复用拒绝、返回键取消通过 | 使用隔离账号；2FA 初始配置由 API 完成，设备配置流程另见 E08。远程 OIDC 提供商和完整认证故障组合待验 |
| E24 / R35 | 当前会话保护，单会话滑动取消／确认，注销其他全部取消／确认 | [device-sessions-result.json](evidence/device-sessions-result.json) 和 [auth-device-result.json](evidence/auth-device-result.json)：新会话显示 Android；单注销后旧令牌失效，批量取消保留 4 会话，确认仅余当前、其他令牌 HTTP401。6EA80F94 新包单会话按钮禁用、AX enabled=false、点击不弹确认通过 | 原 mobile 就是单列表按 API 顺序显示；API/MCP 会话专用显示只做过解析业务检查 |
| E25 / D15、D18 | 系统相机拍照，外部返回锁定，PIN 后保留附件，预览并放弃编辑 | [device-camera-result.json](evidence/device-camera-result.json)：API36／59D7EEFB，系统相机、模拟器合成照片、锁定／附件保留／本地预览通过，未保存交易 | 实体相机传感器、权限拒绝、多个附件待验；图片上传持久性见 E06／E10／E20 |
| E26 / R17、R21、R32、D05 | 最大字号／恢复默认、12 小时时间、双历法、首页与账户金额隐藏及重启 | [prefs-device-result.json](evidence/prefs-device-result.json)：API24／6EA80F94，最大字号预览／应用／重启保持，记账时间及 AM/PM 选择器，公历+伊朗历交易日历，首页／账户总额／分类／单账户遮罩和重启保持通过；F29F0C6D 新包仅改时间格式仍保持中文与 API language=zh-Hans 的复验通过 | 原生操作发现资料更新漏语言，[真实接口前后对照](evidence/auth-profile-language-result.json)及[最终设备截图](evidence/prefs-final-language-preserved.png)关闭该缺陷。其余字号、语言和偏好未推断通过 |
| E27 / R07、R09、D05 | 原生时间选择改变秒数，保存后详情和服务器保持秒精度 | [device-seconds-result.json](evidence/device-seconds-result.json)：API36／6EA80F94，18 秒改为 20 秒，详情 06:20:20，服务器时间 1789453220、恰好 1 笔 0.01 交易 | 测试交易已删除；不替代 DST／全部时区和历法边界 |
| E28 / R14 | 账户间迁移全部交易，校验同币种及目标名称，确认后返回，随后清理测试数据 | [device-account-move-result.json](evidence/device-account-move-result.json)：API36／6EA80F94，错误名称拒绝、同币种目标、确认及返回通过；服务器仅 1 笔，源余额 0、目标 100 分，测试清理后双方均 0 | 仅隔离测试账户；待同步阻止／取消／并发变更和全部账户类型仍待验 |
| E29 / R15、R05 | 同原 Web 账本对照支出饼图／金额条下钻、账户余额饼图、资产月份投影、图例显隐及月份下钻标签 | [device-statistics-parity-result.json](evidence/device-statistics-parity-result.json)：6EA80F94 支出总额及条形下钻均 63.78 CNY；F29F0C6D 锚定标题菜单、9 月资产 17,241.27、10–12 月均 0、隐藏银行卡后 4,961.27、可见账户下钻显示目标金额 100.00 USD；F921DE17 复验 2026-9 下钻显示“本月”，收入 8000／支出 63.78；[月份下钻截图](evidence/device-statistics-month-drilldown-fixed.png) | JSON 旧 `remaining` 中月份标签待验已由 `monthDrilldownRecheck` 关闭；其它图表／数据类型、全部排序筛选组合、暗色完整对照仍待验 |
| E30 / R05、R06 | 列表独立 More／账户菜单、类型与分类联动、新增预填、金额应用／取消／错误范围、复制、搜索及完整行高滑动操作 | [device-list-filters-result.json](evidence/device-list-filters-result.json)：6EA80F94 More 含类型／金额／标签，收入切换清除不兼容支出分类并预填新交易；金额大于 5.00 返回 3 笔／59.34；反向范围拒绝与取消保留；复制预填 18.50、现金、午餐。F29F0C6D 搜索 3.33／关闭恢复、多账户入口与无账户空列表通过；滑动动作与原行同高、橙色 Edit、trash Delete、关闭态 AX 排除通过；[滑动截图](evidence/device-swipe-full-height.png) | 反向金额范围证据来自 59D7；JSON `scope` 旧滑动视觉待验已由 `fullHeightSwipeRecheck` 关闭。R18–R20 后续分组选择器与 More 按钮修复仍需新包复验；其余金额关系／边界、标签组合待验。原 21 语言均 LTR，RTL 分支只做源码审查 |
| E31 / R01、R04、R05、R09、R15、R26、R29 | 最终 APK 重装 API36／API24，复核本轮修复影响的启动、锁、首页聚合、统计、汇率、缓存和远端图片 | [device-9394604-result.json](evidence/device-9394604-result.json)：SHA-256 `9394604B5BD4FE52A6F9C9E1EACA4BFA077939D3473C1A986C7FA11C41FB6EF6`；两平台安装启动通过。API36 重启显示应用锁并成功解锁；首页 63.78／8000.00／17241.27，暗色统计 63.78／100%，汇率基准 1.00 与列表、缓存保护说明、远端票据预览均显示；API24 首页与统计空态正常 | 本条绑定最终 APK，只覆盖列出的复验路径；实体设备、生物识别成功和其余迁移矩阵仍待验 |
| E32 / R23、R24、R26 | API24 图表配色、账户类别顺序和缓存页的小屏／大字号／明暗操作 | [device-dbc30-chart-order-result.json](evidence/device-dbc30-chart-order-result.json)：DBC30 构建通过 HSV `#3ca674`、Hex `#123456`、非法导入保留、合法 30 色、重复色跨屏拖动、导出/复制、Add 自动滚动、返回放弃、默认空串和重启持久化；账户顺序跨屏拖动、保存/取消/重置/重启通过；缓存页无溢出 | 未完成云端非法配色注入；未逐个统计模式观察新色；最终包仅复验缓存页，R23/R24 保留 DBC30 构建边界 |
| E33 / R16、R36、R37、R39、R40 | 最终 APK 操作统计设置、分类总入口、支出分类列表／菜单、编辑页与分类预设页 | [device-9394604-statistics-categories-result.json](evidence/device-9394604-statistics-categories-result.json)：统计默认排序由金额改名称，新开统计页显示名称后恢复金额；分类三类型入口、列表 More、行 More 的编辑/隐藏/删除/新增二级/排序、编辑字段和预设父子选择均显示，编辑草稿返回后未保存 | 本轮没有提交分类修改或批量预设；隐藏/删除、排序持久化、重复跳过、父级迁移和关联失效分支待验 |
| E34 / R07、R27、D05 | 应用图标长按“记一笔”、1×1 快速记账和 4×2 当月概要组件 | [device-27badbbb-launcher-widgets-result.json](evidence/device-27badbbb-launcher-widgets-result.json)：SHA-256 `27BADBBB704ADDD1A5D1D5E5D1EE55A88DD7AB73B27390987B6F0DE02B9D9D3C`；API36 长按快捷项显示并进入应用锁，1×1/4×2 添加成功，三个 Tab 显示收入 8,000.00、支出 63.78、总计 7,936.22 CNY；API24 两个尺寸注册/添加、Tab 切换及 1×1 进入新增交易通过；[API36 桌面](evidence/widget-home-final-api36.png)、[API24 选择器](evidence/widget-picker-api24.png)、[API24 新增页](evidence/widget-quick-add-route-api24.png) | 同比定义为自然月对上年同月，无基期显示 `—`；正负及零基期有业务测试。静态快捷方式是 API25+ 平台能力；实体厂商 Launcher、系统语言组合和有上年同月数据的设备视觉待验 |
| E35 / R07 | 金额键盘整格命中；“记一笔”直接打开且无二次切换动画；分类／账户半屏左右栏 | [device-input-shortcut-selector-result.json](evidence/device-input-shortcut-selector-result.json)：API24 数字 7 命中高度由 60px 增至 139px，点击旧命中区外 `(30,620)` 成功输入；选择器由 82% 改为 50%，左右栏及图标通过；[最终选择器](evidence/device-input-shortcut-selector.png)。冷启动首个 Flutter 界面即金额键盘，采样仅 3 帧；热启动 WaitTime 12ms，页面／金额面板零时长切换；后台弹层会先关闭。API36 安装并确认应用锁优先 | 冷启动等待值与旧包首个 loading 帧不是同一完成点，不能直接比较总耗时；实体厂商 Launcher 和真实低端机帧时间待验 |
| E36 / R07、D05 | “记一笔”首帧可输入且初始化无加载圈；概要组件改为 4×1、无品牌文字、主体进入首页 | [device-quick-start-widget-4x1-result.json](evidence/device-quick-start-widget-4x1-result.json)：初始化期间输入 7.00 并保留至正式编辑器；AOT 包 API24 冷启动 578/722ms、API36 重复冷启动 1851ms、热启动 7ms。API24 Provider 为 290×40dp，选择器显示 4×1；[桌面组件](evidence/widget-summary-4x1-api24.png)无品牌文字，[主体点击](evidence/widget-summary-open-home-api24.png)进入首页，Tab 仍在桌面原地切换 | 首次安装后的 ART 优化及设备性能会影响冷启动；debug JIT 时长不作为发布包结论。实体厂商 Launcher 和低端实体机待验 |
| E37 / D05 | 4×1 概要同比截至今日；收入／支出涨跌箭头与颜色；总计三等分 | [device-widget-yoy-total-result.json](evidence/device-widget-yoy-total-result.json)：同比只使用本月 1 日至今天与去年同月同期数据，当月展示金额继续使用整月口径；收入上涨红色▲／下跌绿色▼，支出上涨绿色▲／下跌红色▼均在 API24 验证。总计 Tab 显示收入、支出、总额三个等宽区域；[API24 浅色](evidence/widget-total-three-columns-api24.png)与[API36 深色中文](evidence/widget-total-three-columns-dark-api36.png)通过 | 涨跌截图使用确定性组件快照，区间计算由业务测试覆盖；实体厂商 Launcher 仍待验。旧 4×2 实例需移除后重加才能取得 4×1 高度 |
| E38 / R01、R05、R10、R15、R27、D02、D05 | 五个一级页面共用常驻底栏；中心首页高亮；各页右下角新增；底部选择弹窗紧凑化 | API36／`CC7B6ADA` debug 包依次切换详情、账户、首页、统计、设置，选中语义与页面原状态保留；系统返回从账户回首页，二级新增／选择页隐藏底栏；统计期间栏与公共底栏不重叠；详情仅保留一个新增入口。Theme、分类两栏和交易时间三类代表弹层显示 15–16px 可见字和至少 48dp 点击行；长按浮动新增仍进入模板／AI。原始证据：`ezb-nav-home.png`、`ezb-sheet-theme.png`、`ezb-sheet-category.png`、`ezb-sheet-time.png`、`ezb-nav-dark-large-stable.png`、`ezb-nav-landscape.png` | 已覆盖 API36 1080×2400、横屏、深浅色、系统字号 1.3、关闭动画和返回键；API24、平板、实体设备及所有语言长文案仍待验。图标／颜色和设置专用操作菜单已复用相同紧凑尺寸但未逐个设备操作，不能推广为全部弹层业务分支通过 |
| E39 / D05 | 4×1 概要左上固定“本月”；收入／支出同比下方显示增减金额；总计标签与金额放大 | API24／API36 安装 `62AE6B91` debug 包。API24 真实 4×1 组件依次点击收入、支出和总计：收入显示 `同比 ▲ 25%`／`增加 ¥2,000.00`，支出显示 `同比 ▼ 20%`／`减少 ¥300.00`，总计三栏完整且无裁切；切换简体中文后左上显示“本月”。API36 Pixel Launcher 选择器显示 4×1，深色简中收入和总计通过。原始证据：`widget-opt-api24-income-final2.png`、`widget-opt-api24-expense-final.png`、`widget-opt-api24-total-final.png`、`widget-opt-api24-zh-income.png`、`widget-opt-api36-zh-dark-income.png`、`widget-opt-api36-zh-dark-total.png` | 确定性组件快照只验证呈现，同比差额区间由业务测试覆盖；实体厂商 Launcher、超长货币金额和更多语言仍待验 |
| E40 / R11、R21 | 用户级启用货币默认 CNY/USD；新增 EUR 后持久显示；账户新建币种列表只出现有效货币 | API36 安装 `4D50A49E` debug 包，偏好页初始显示 `CNY, USD`，搜索并启用 EUR、保存后显示 `CNY, EUR, USD`；账户新建页货币选择器只显示 CNY/EUR/USD。[启用货币](evidence/currency-enabled-api36.png)、[账户货币列表](evidence/currency-account-list-api36.png) | 测试 App 原服务器当前不可达，信用卡账户创建与多币种交易保存/编辑未做设备写入验收；默认/已有账户币种强制保留由 Dart 业务测试覆盖，Web 浏览器登录态实操待验 |
| E41 / D05 | 汇率页显示日期并可打开日期选择器；当天页面强制刷新，历史日期走历史接口 | API36 安装 `D7876D0E` debug 包，汇率页显示“Date / September 17, 2026”，点击后打开带 Cancel/Done 的日期选择器；[日期入口](evidence/exchange-rate-date-api36.png)。218 项 Dart 测试、静态分析与 debug APK 构建通过 | 当前设备连接的远端测试服务器仍返回 `European Central Bank`（强制刷新后仍如此），说明该服务器尚未切换/重启为本次 SAFE 后端配置；因此 SAFE 来源和历史日期响应只完成源码/服务测试，未在该远端环境标记端到端通过 |
| E42 / R07、R10、D14 | 自动定位随新增记账页立即启动；地图冷加载显示进度和慢加载重试；账户页提高信息密度 | API36／1080×2400 debug 包：冷启动快捷记账 `TotalTime=2923ms`，金额面板打开期间系统定位已启动，随后回填 `22.319298, 114.169398`；阻塞同源地图响应后 1 秒显示 `Loading Map...`，8 秒后显示慢加载说明和 Retry；账户页浅色／深色均显示三列资产摘要，紧凑账户行无裁切且保留至少 48dp 点击高度。原始证据在 `.planning/2026-09-19-flutter-map-and-account-density/` | 当前测试 App 配置的 `127.0.0.1:18080` 服务不可达，慢加载由 ADB reverse 到无响应本地监听器验证；未声称真实高德瓦片加载耗时已缩短。API24、实体设备、真实高德成功加载及定位权限拒绝仍待验 |
| E43 / R07、D14 | 自动定位显示文字地点；金额键盘缩短 20%；长按“记一笔”加载前后键盘不跳高 | API36／1080×2400／420dpi 与 API24／768×1280／320dpi 安装 SHA-256 `12D98CBC…` debug 包。API36 系统反向地理编码显示 `664 Nathan Rd, Mong Kok, Kowloon, Hong Kong`，API24 高德回退显示“华侨商业中心”，两者均把坐标保留为副标题。键盘由 440dp 改为 352dp，API36 实测 924px、API24 实测 704px；按键行均约 54.5dp。普通新增与快捷启动页复用同一键盘组件，API36 冷启动 `TotalTime=3562ms`、API24 `TotalTime=2277ms`，加载完成不再切换到另一套高度。证据目录：`.planning/flutter-android/artifacts/followup-location-keypad-20260920/` | 两平台均为模拟器定位；实体设备及定位服务/网络均不可用时仍只能保留坐标。未为纯 UI 布局新增 widget 测试；API24/36 App 日志未见崩溃或 RenderFlex 溢出 |
| E44 / R01、R05、R09、R15 | 详情紧凑行及长按复制／删除；编辑 More 统一复制；中心首页上凸；支出分类饼图下方明细 | API36／1080×2400／420dpi，最终 debug APK SHA-256 `05D5FB7A…`。长按出现 Copy/Delete，Copy 带入 $1.00、EditLeaf、EditOpenAccount，时间由 9 月 16 日改为 9 月 21 日当前时间，定位解析为 `664 Nathan Rd, Mong Kok, Kowloon, Hong Kong`；编辑 More 显示 Copy 而无 Save Draft、Save and Add Another、Save as Template，复制后进入 Add Transaction 且当前时间更新。首页 58dp 圆形上凸，支出一级分类下方显示 1 条对应交易；饼图直径上限 220dp，浅／深色与横屏检查无溢出。`flutter analyze --no-pub`、39 项相关 Dart 测试和 debug APK 构建通过。证据目录：`.planning/flutter-android/artifacts/detail-copy-stats-20260921/` | 未执行真实删除或保存复制记录；测试账本仅有一个支出一级分类，多个分类之间切换和大量记录分页未做设备实操。API24、实体机、系统大字号及定位权限拒绝仍待验。 |
| E45 / R01 | 中心首页改为底栏内纯图标，较左右两侧更大且不越过底栏边框 | API36／1080×2400／420dpi，debug APK SHA-256 `ADDFAC709590BC893C4DEC877B8AE926DD99E5BF175E1A2047E1270C1AC25981`；首页圆形 52dp、房屋图标 30dp，左右图标 22dp，无可见 Home 文字。浅色、深色与横屏截图均显示圆形完整处于 64dp 底栏内；从账户页点击中心入口返回首页。UI 树中 Home 仍有无障碍名称及选中状态，点击区域 `[432,2169][648,2337]`，即 216×168px（82×64dp）。`flutter analyze --no-pub` 与 debug APK 构建通过。证据目录：`.planning/flutter-android/artifacts/home-icon-20260921/` | 替代 E44 上凸样式；API24、实体机和系统大字号本轮未复验。 |
| E46 / R01、R05、R10 | App 现有长按动作触发一次系统震动 | API36／1080×2400／420dpi，debug APK SHA-256 `689680AF2A60AA6BAEB3A858BC467C613786FD05E68F1CC87F1F9B32BC5DD90C`。长按交易记录出现 Copy/Delete、长按浮动新增出现 Transaction Templates、长按账户行进入 Sort；`dumpsys vibrator_manager` 对三次动作均记录本包的 `performHapticFeedback(constant=0)`。共享 `SwipeActionsRow` 的分类／标签排序长按也接入相同反馈；`flutter analyze --no-pub` 与 debug APK 构建通过。截图目录：`.planning/flutter-android/artifacts/long-press-haptic-20260921/` | 分类／标签排序未逐项实操，API24 与实体机触感未复验；模拟器系统记录证明震动请求已执行，不代表实体设备体感一致。 |
| E47 / R05、R15 | 交易详情和统计分类明细滚动接近底部自动加载下一批，不再手动点击 Load more | API36／1080×2400／浅色英文：临时仅在显示层从现有 1 条记录派生 90 条测试记录（未写入账本），交易详情首批 15 条，连续上滑自动显示后续 05:46 记录；统计支出分类明细首批 20 条，连续上滑显示后续 05:43 记录，滚动末尾显示 04:49 最后一条和原有 Details 入口，均无 Load more 按钮。移除临时代码后重新构建并安装 debug APK，SHA-256 `CC4753BBAF84766D16C85582730BA466E3F7999F740AF18B70ABB2822E94C01A`，只显示原有 06:18 记录。`flutter analyze --no-pub`、39 项相关 Dart 测试与最终 debug APK 构建通过。截图目录：`.planning/flutter-android/artifacts/auto-load-details-20260921/` | 图库共用交易详情续载逻辑，但未用大量图片记录单独实测；API24 和实体设备未复验。测试记录仅存在于临时构建的显示层，最终包及账本均不包含。 |
| E48 / R07、R44、R45 | 转账仅显示转账金额与手续费，隐藏转入金额输入；手续费计入转出账户扣款 | 2026-09-22 API36／1080×2400／浅色英文安装 debug APK SHA-256 `CDDF16F28D723FCBDDD7961BA27B84101781FDB3E9A1EE85D842E8BBC5582505`，进入新增转账页，显示 Transfer Amount、Service Charge，未显示 Transfer In Amount；原始截图 `.planning/flutter-android/artifacts/transfer-fee-form-final.png`。`flutter analyze --no-pub`、相关 Dart 账本测试、Debug APK 构建通过 | 测试账本没有可选转账分类，设备未执行保存；定期转账表单和服务器定时执行、跨币种汇率、API24 与实体设备仍待操作验收 |
| E49 / R02、R31 | 品牌更名为“当归账本 / Danggui Expense”，保留原 Android、Web/PWA 图标及启动画面图标 | 2026-09-22 API36／1080×2400／浅色英文安装最终 debug APK SHA-256 `9B60EB69DF80470381F99DF53ED56EEC2D690288FADD92EA18F182132805D17E`；原图标在 Android 应用抽屉和启动画面可见，最终进入首页并显示 Danggui Expense，截图 `.planning/flutter-android/artifacts/danggui-original-icon-launcher-api36.png`、`danggui-original-icon-final-api36.png`、`danggui-runtime-check-api36.png`。APK 资源检查确认英文标签为 Danggui Expense，`zh-CN`、`zh-TW` 标签均为“当归账本”。Web 桌面与 mobile 登录页在浏览器显示原图标和中文名称，截图 `danggui-original-icon-web-desktop.png`、`danggui-original-icon-web-mobile.png`。Flutter analyze、会话兼容测试、Debug APK、Web 类型检查与构建通过 | 本轮 API36 模拟器启动明显迟缓并曾出现无响应提示，稍后最终进入首页；启动性能仍需单独排查。Flutter 登录页和关于页、Android 中文语言下的桌面标签、API24 与实体设备未操作验收；旧应用标识作为包名和数据格式标识保留 |

| E50 / R01、R07、R10 | 从“当归之家”的“当归记账”入口打开已运行账本的首页 | 2026-09-22 API36／1080×2400／浅色英文，release APK SHA-256 `693AA510AA6E0394F160867067786D860870D1CC01EAA8A0EB46ABC1CE926838`。账本停在[账户页](evidence/danggui-home-entry-from-accounts-before.png)或[新增交易页](evidence/danggui-home-entry-from-editor-before.png)时，从外部入口返回后均显示[首页](evidence/danggui-home-entry-from-accounts-after.png)、[首页](evidence/danggui-home-entry-from-editor-after.png)。`flutter analyze --no-pub lib/app.dart lib/core/app_controller.dart` 与 release 构建通过 | 新增交易页只验证空白草稿；未验证有未保存输入、应用锁、API24 和实体机。全量 Flutter 测试 218 项通过、1 项失败；`native_localization_test.dart` 的原有 Web 西班牙语文件字节比较因 CRLF/LF 差异失败，与本次入口无关。 |
| E51 / R07 | 图标长按“记一笔”从后台设置子页进入记账页时不闪现旧页 | 2026-09-22 API36／1080×2400／浅色英文，debug APK SHA-256 `431FD617DB7EE5EB6FA8C8DA065C51B8533BB9F0C7E2FFF48544ED5FEB7869BC`。使用静态快捷项同一 `VIEW net.ezbookkeeping.app://transaction/add` Intent，从 Text Size 页退到桌面后热启动 `TotalTime=710ms`，逐帧录像 `.planning/flutter-android/artifacts/quick-add-static-warm-covered-api36.mp4` 未出现旧设置页，最终金额键盘可输入。冷启动最终也进入记账页，截图 `.planning/flutter-android/artifacts/quick-add-cold-late-api36.png`；`flutter analyze --no-pub` 与 debug APK 构建通过 | 本次冷启动 `am start -W` 等待 10.6 秒返回 timeout，模拟器随后显示记账页且日志无崩溃；因此不以这次数据声称冷启动性能改善。热启动 Android 桌面切换动画仍可见；API24、实体 Launcher、深色主题与应用锁待验。 |

E19 明确关闭先前 AI 文字页混入拍照、英文 Dio 诊断和键盘抢焦点三个设备缺陷；保留各迭代构建的原始证据。

E29／E30 同样保留迭代 JSON 的旧待验说明，并以其中带构建 SHA 的复验对象界定已关闭项目。DBC30 构建已复验账户选择器 More 的“全部不选”、Home 紧凑卡片、导航图标颜色、汇率列表、云设置、缓存和关于／许可；[设置复验结果](evidence/device-dbc30-settings-result.json)保留确切范围。最终 9394604B 构建再次复验 Home、统计、汇率、缓存和图片；账户选择器 More 的 DBC30 结果不推广到类别／标签全部分支。

后续源码补审修复的邮箱 `context` 和注册预设语言已由 E22 复验。地图依赖加载期间 GPS 更新保留由 3 项桥协议测试通过，最新地图资源已构建并部署测试服务；真实 GPS 在加载中变化仍待设备验证。邮箱请求／配置资源／认证 API 13 项业务测试通过。

隔离邮件测试还确认了原后端已有两项限制：[同一 Unix 秒内新建的重置密码 token 可再次使用](evidence/auth-reset-replay-result.json)，以及重置密码会把周起始从 1 改为 0（[前后接口复现](evidence/auth-reset-profile-boundary-result.json)）。`forget_passwords.go` 本次未修改；这些不是 Flutter 新增行为。邮件接口正常人工时序的验收不能覆盖或隐藏该边界。

迭代证据继续保留原构建边界。E31 记录 9394604B 基线包的版本、SHA-256、构建日志和两平台复验；E34 记录 27BADBBB 包新增桌面入口；E35 记录 2F12D6A9 包的输入、快捷入口与两栏选择器复验；E36 记录 17EB8431 debug 包和 89EB009E AOT 包的快捷首帧及 4×1 组件；E37 记录 0EB5D0BC debug 包和 44EE52A4 AOT 包的同比及总计布局；E38 记录 CC7B6ADA debug 包的常驻导航、浮动新增和紧凑弹层复验；E39 记录 62AE6B91 debug 包的“本月”、同比差额及放大总计文字复验。较早 APK 的其它结果仍不能自动推广到新构建未操作的场景。

## 自动化与构建

| 检查 | 已知结果 | 尚需完成 |
|---|---|---|
| 原 Web 测试 | 2026-09-17 本次源码：15 文件、38,600 用例通过；`vue-tsc --noEmit` 通过；新增 Web 用例覆盖有效货币保留规则 | 启用货币和多币种信用卡页面尚未在可写登录态浏览器实操 |
| Web 生产构建 | 2026-09-17 本次源码 `vite build` 通过，仅有既有构建警告 | 仍需部署后浏览器交互复验 |
| Go 回归 | 2026-09-17 使用 MinGW/CGO：`BUILD_PIPELINE=1 go test -count=1 -skip '^TestClientSyncPictureUploadSurvivesRetry$' ./...` 全部通过；新增 SQLite 已有交易表升级测试确认原始币种/金额列补默认值且历史金额不变。未跳过运行时业务断言完成，但该既有图片重试用例连续两次在 Windows `TempDir` 清理仍占用的 `ledger.db` 时失败 | CI 模式跳过在线数据源检查，不能表述为所有实时第三方汇率服务通过；Windows 文件句柄清理问题仍需独立处理 |
| 三数据库同步集成 | 同步独立审查重新运行 `go test -count=1 ./pkg/api`：SQLite 2.338s、PostgreSQL 3.914s、MySQL 3.762s 均通过，实际外部数据库只使用 `sync_test` | 不代表所有生产历史版本升级路径、所有数据库部署方式都已验证 |
| 三数据库已有数据升级 | [backend-upgrade-audit.md](evidence/backend-upgrade-audit.md)：实际升级函数、升级前已填账本、首次快照／Web 写入、转账与删除、关闭重开再升级均通过；SQLite 0.422s、PostgreSQL16 1.411s、MySQL8 2.587s | 升级前模型结构与本次迁移前一致；不包含每个历史发行备份、并发升级、断电／磁盘满与大规模性能 |
| Dart 金额／格式／同步／设置 | 当前源码 218 项全部通过；新增覆盖默认 CNY/USD，以及关闭配置后仍保留用户默认、已有账户/子账户和当前编辑币种 | 业务测试不等于 UI 场景；不与各作用域计数相加 |
| 本轮账户／对账业务 | `test/catalog_business_test.dart` 22 项通过：请求契约、债务符号、金额上限、日期边界、空日期延续、财年、账单周期、月末、币种与精确合计、信用额度、隐藏与缺汇率 | 业务已修正，真实设备跨币种账本对照待验 |
| 会话业务 | `test/session_presentation_test.dart` 12 项通过：11 个原 JS fixture + 原生 Android；API token rotation 与安全存储失败也有业务覆盖 | E24 已覆盖实际列表／单次和全部注销；API/MCP 专用设备显示仍待验 |
| 静态分析 | 当前源码 `flutter analyze --no-pub` 0 问题；本轮定位/移动业务相关 36 项通过；全量 217 项通过、1 项既有 locale 字节一致性检查因 `en.json` CRLF/LF 差异失败 | 该 locale 文件不在本轮修改范围，未为通过测试而改写用户现有变更；后续应由对应语言资源任务恢复原 Web 文件的逐字节一致性 |
| Android APK | 当前 debug：215,154,062 bytes，SHA-256 `12D98CBCE04062E76D2DDA2A8F066EB6784F0EDAE7BCF62A7A7CBC75DC113ACD`；API24/36 安装并完成 E43 定位名称、键盘高度和快捷入口复验。E37 AOT release 仍为 78,393,867 bytes、SHA-256 `44EE52A4ADCF3D6AB4B832270B780ABC3C18C496CA84D6E629801DDDF268F679` | 两个本地包均使用 debug key；正式分发需私有签名。当前源码未重新构建 release；实体设备和未列场景仍需验收 |
| 独立 CI | [flutter.yml](../../.github/workflows/flutter.yml) 已配置 Flutter 3.47.2、锁依赖、analyze、业务测试、APK artifact；YAML 解析和 8 步配置校验通过 | 尚无 GitHub Actions 实际运行记录 |

## 本轮发现并修复的差异

- 普通账户请求曾错误带入信用卡账单日／零额度、现有余额和时间，现已对齐`src/models/account.ts`。E12/E18验证创建返回、子账户和对账期末修正；其它账户类型／边界仍待验。
- 账户点击进入对应交易列表，并补充信用卡金额偏好、负债符号、子账户显隐、清理／迁移／对账／排序。E18/E26/E28已覆盖其中子账户／对账、金额显隐和同币种迁移，未覆盖动作仍按路由表待验。
- 对账补齐原日期范围、期末余额修正、标记截止、时间聚合、空日期余额延续和交易操作。原 mobile 使用条形余额列表，不要求桌面 OHLC 图。
- 标签补充分组过滤、组管理、拖动和名称自然排序；Android ICU 处理本地化排序。须验证不同语言、数字和重音排序，以及实际服务端持久化。
- 财年日期选择曾把 29–31 日钳到 28 日，现按具体月份限制；有效月末及禁止 2 月 29 日已有业务测试。
- 原 mobile 的换汇截断顺序因页面不同：账户总额逐账户截断，父账户／类别合计保留有理数求和后截断，统计先按原分组换汇，日历每日合计后截断。已分别修正并加入正负半分、混币种和信用卡共用额度业务测试。
- 会话列表补齐浏览器／系统信息和设备图标，按原mobile保留单列表与API顺序。E24已覆盖Android设备显示、当前保护和注销；API/MCP专用显示只有业务解析对照，设备待验。
- 交易附加动作、快速按钮、位置／图片偏好、图表点击、动画／滑动返回、应用锁保留编辑器等经过独立审查修正；仍须在最终 APK 逐项复验。

## 未完成的验收

以下仍然是交付门槛，不能因本文件有部分通过记录而勾选完成：

1. 按迁移表逐项执行全部 R01–R46、D01–D18，记录预期与实际行为、构建版本、截图；完整浅色／深色与原 mobile 对照。
2. 连续离线增删改、同交易多次修改顺序、响应丢失和服务端重启重试、初始化中断恢复、图片上传失败／退出恢复。
3. 手机与 Web 并发编辑、远端删除、关联账户／分类变更、清空账本代次、定时生成、批量写入，验证最终余额及统计一致。
4. 账户与子账户创建／修改／排序／隐藏／清理／迁移、信用卡共用额度、对账及不同币种换汇；真实 API 与本地值对照。
5. 全部语言资源实际显示、系统字号及小屏、历法、DST／跨日、数字输入；系统权限拒绝、相机、分享、多图片、文件保存取消。原 21 语言均 LTR，RTL 条件分支仅做源码审查。
6. 设置云同步全键的目标页面效果、缓存期限、受支持浏览器邮件完成页、未覆盖的 OIDC／2FA 故障分支、生物硬件、令牌过期／服务器与用户隔离组合；已通过项目见 E19–E26。
7. 服务器各条件开关和地图提供商／代理组合；真实 AI 模型仅在配置可用的测试环境另行验收。
8. 将已通过的 Flutter、Go、三数据库升级／同步及 Web 检查绑定到最终交付源码；补独立 CI 实际运行和最终 APK 安装记录。

### 安全／设置／系统剩余分支

已通过的 SMTP、认证门控、2FA 登录、会话注销、缓存保护与拍照流程见 E19–E26。剩余的是下列具体分支，并非这些模块全部未验：

- HTTPS／证书拒绝／旧同步协议升级提示；其它语言与注册币种；原邮件 desktop 页在受支持浏览器的成功显示、过期或发送失败、资料邮箱变更后的验证。
- 生物硬件成功／取消／锁定；PIN 更换／禁用错误路径；OAuth 关联已有密码账号、进程回收和超时；2FA 恢复码重生成设备失败路径；API/MCP 会话专用显示、令牌过期时待同步暂停与重新登录。
- 所有云设置在目标页面的逐键效果与失败恢复；未保存资料期间头像更换／删除；全部历法、DST、数字规则与语言；调色板／排序和其余偏好。
- 数据清理的设备密码错误／确认／账本代次冲突，导出失败设备提示，缓存期限／磁盘压力；图片权限拒绝／多图／大小上限／上传中断重试，剪贴板及 AI 自动附件偏好的所有组合。
- 真实 GPS、定位权限拒绝、地图初始化期间更新、每个地图提供商和代理组合；关于／许可／帮助等外部入口的完整设备操作。

## 后续记录模板

```text
验收 ID：Rxx / Dxx / Exx
构建：Git revision / APK SHA-256 / Flutter version
环境：Android API、设备／分辨率、语言／主题／字号、服务器前缀／配置
数据：独立测试账本、初始交易及余额（不记录令牌或密码）
步骤：操作顺序、故障注入、预期值
实际：成功／失败／待验、API／本地／Web 的最终值
证据：JSON、测试日志、前后截图
限制：本次未覆盖的分支，失败修复后的复验 ID
```
