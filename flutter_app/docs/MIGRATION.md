# Mobile → Flutter 迁移清单

范围基准：`src/router/mobile.ts` 的 46 个业务路由、`src/views/mobile/` 页面和 `src/components/mobile/` 弹层。桌面专属批量导入、自定义分析和雷达图不在范围内。所有表格中的“待验”均指尚未完成相同账本／语言／主题／视口下的 Android 操作验收；代码存在不等于验收通过。

## 阅读约定

- Flutter 文件名以下均相对 `flutter_app/lib/features/`；共用页面基础位于 `lib/ui/common.dart`，选择组件位于 `lib/ui/selection_sheets.dart`。
- 接口以下省略共同前缀 `/api/`。`S` 表示 `v1/sync/snapshot.json`、`v1/sync/changes.json`、`v1/sync/push.json`；查询使用本地数据库，联网时同步。
- `L` 表示本地加密设置／账本，`C` 表示 `v1/users/settings/cloud/get.json`、`update.json`、`disable.json`。这些设置同步接口与账本同步接口独立。
- 每个验收 ID 必须在 [ACCEPTANCE.md](ACCEPTANCE.md) 中记录环境、步骤和证据后才能判定通过。

## 46 个业务路由

| ID | 原路由／原页面 | Flutter 页面 | 接口／存储 | 必须操作的验收场景 | 状态 |
|---|---|---|---|---|---|
| R01 | `/` · HomePage | `overview/home.dart` · HomePage | S、L、汇率 latest | 默认两个组件、全部九组件、金额显隐、刷新、底部入口、长按模板／AI | E38 五页常驻底栏、中心首页、浮动新增及长按模板／AI通过；E45 中心首页改为无文字的放大图标、圆形不超出底栏通过（替代 E44 上凸样式）；E46 浮动新增长按震动通过；九组件编辑与紧凑首页/聚合通过；完整设置分支待验 |
| R02 | `/login` · LoginPage | `auth/auth_page.dart` · AuthPage | `authorize.json`、`2fa/*`、`oauth2/*`、`client/config.json` | 地址前缀、正常／错误登录、2FA／恢复码、忘记密码、验证邮件、OIDC、语言和品牌名称／图标 | API24/36登录、SMTP邮件、2FA/恢复码/取消、条件入口与本地OIDC通过；E49 保留原 Android 图标、首页英文名称可见，登录页与中文设备实操待验；其它故障组合待验 |
| R03 | `/signup` · SignupPage | AuthPage(signup) | `register.json` | 关闭注册、字段校验、21语言、159币种、星期、分类预设、激活提示 | API24原生注册、预设预览语言/默认币种/星期、激活提示通过；其它语言/币种分支待验 |
| R04 | `/unlock` · UnlockPage | UnlockPage | Android 安全存储／生物识别 | 错误／正确 PIN、进程重启、后台恢复、生物识别取消／失败 | API36 PIN 通过；API24 无生物硬件提示通过；其它生物识别待验 |
| R05 | `/transaction/list` · transactions/ListPage | `transactions/transactions.dart` · TransactionListPage | S、L | 月份切换、分页、全文／日期／账户／分类／标签／金额过滤、滑动删除、复制、编辑 | E38 一级详情常驻导航及单一浮动新增通过；E44 紧凑记录、长按复制／删除和复制预填通过；E46 长按震动通过；E47 详情滚动到底自动续载通过，图库共用逻辑但图片数据未实测；E13/E14/E29–E31 三视图、筛选和滑动部分通过；其余筛选待验 |
| R06 | `/transaction/filter/amount` · AmountFilterPage | TransactionFilterPage(amountOnly) | L | 六种金额关系、负数、整数上限、取消与清除 | E30：大于5.00应用返回3笔/59.34、反向范围拒绝、取消保留通过；其它关系/边界/清除待验 |
| R07 | `/transaction/add` · transactions/EditPage | TransactionEditPage | S、`v1/transaction/pictures/upload.json` | 收／支／转账金额及手续费、跨币种按交易日期换算、零金额提示、草稿、图片、位置、快速保存 | 旧版离线支出/跨币种转账及重启通过；E48 新表单字段 API36 可见，手续费余额规则有业务测试；E52 顶部相机按钮、底部来源选择、拍照与相册各附一张图片通过；E53 图片缩略图、放大、删除确认及离线保存重启通过；E54 顶部相机按钮移除，通过更多展开照片区并使用拍照／相册入口；服务端上传待验；E43 自动定位与金额键盘通过；E57 API36 快捷入口冷启动默认选中支出且键盘连续显示；E58 API36 312dp 键盘与启用币种先选通过；E59 键盘金额左侧代码切换 CNY／USD 且保留输入金额；E60 新增交易三个类型移除普通币种行，保留多币种信用卡的独立交易币种；E61 币种选项改为键盘内下拉框，重复点击可收起；其余分支待验 |
| R08 | `/transaction/edit` · transactions/EditPage | TransactionEditPage | S；余额调整用 `v1/transactions/modify.json` | 编辑时间范围、附件保留、离线连续修改、远端冲突、删除后编辑 | 离线转账连续编辑/删除、并发本地采用及返回详情通过；其余待验 |
| R09 | `/transaction/detail` · transactions/EditPage | TransactionEditPage | S、`v1/transactions/get.json` | 只读状态、编辑／删除、统一复制并重取当前时间／地点、原始与默认时区、图像预览 | E44 编辑 More 移除草稿／保存新建／模板化入口，统一复制预填及当前时间通过；保存后最新详情、相册进入和离线图片预览通过；E53 新缩略图已在待同步交易编辑页复验，已同步只读详情页待验；其它操作待验 |
| R10 | `/account/list` · accounts/ListPage | `catalogs/catalogs.dart` · AccountListPage | S、`v1/accounts/move.json`、hide/delete | 单／多子账户、资产与负债、隐藏、排序、信用卡两种余额、进入明细 | E38 一级账户常驻导航与返回首页通过；API24 双子账户/隐藏部分及 API36 转账双方余额通过；E42 三列资产摘要、紧凑账户行与深浅色通过；E46 账户行长按震动及进入排序页通过；完整待验 |
| R11 | `/account/add` · accounts/EditPage | AccountEditPage / SubAccountPage | `v1/accounts/add.json` | 分类、账户类型、图标／颜色／币种、初始余额与时间、子账户、信用卡属性 | API36 创建返回、API24 双子账户创建通过；信用卡等待验 |
| R12 | `/account/edit` · accounts/EditPage | AccountEditPage / SubAccountPage | `v1/accounts/modify.json`、hide/delete、sub_account/delete | 更名不覆盖旧余额、已有余额只读、隐藏／删除、子账户排序、最后对账时间；余额修正进入对账 | API24 子账户隐藏/对账部分通过；完整排序/修改待验 |
| R13 | `/account/reconciliation_statements` · ReconciliationStatementPage | ReconciliationPage | `v1/transactions/reconciliation_statements.json`、`v1/accounts/update/last_reconciled_time.json` | 日期预设／时区、收支与期初期末、走势聚合、更新期末余额、标记对账、记录操作 | API24 期末余额修正与返回自动刷新通过；其余待验 |
| R14 | `/account/move_all_transactions` · MoveAllTransactionsPage | MoveTransactionsPage | `v1/transactions/move/all.json` | 同币种目标、目标名称复核、待同步阻止、原账户／目标账户余额和网页一致 | API36同币种/目标名称校验/确认迁移及余额通过；待同步与并发待验 |
| R15 | `/statistic/transaction` · statistics/TransactionPage | `statistics/statistics.dart` · StatisticsPage | S、L、`v1/exchange_rates/latest.json` | 全部 mobile 数据类型、分类／趋势／资产、过滤、各图形、聚合、期间移动和点击明细 | E38 统计期间栏与常驻底栏叠放通过；E44 支出分类饼图缩小、下方明细及横屏无溢出通过；E47 支出分类下方明细滚动自动续载通过；E29 图表、下钻及月份标签部分通过；其余模式/组合/暗色完整对照待验 |
| R16 | `/statistic/settings` · statistics/SettingsPage | StatisticsSettingsPage | L、C | 图表、时间范围、排序、时区、账户／分类排除、关键字匹配模式实际生效 | E33 默认排序改名后新页生效并恢复；其它设置效果待验 |
| R17 | `/settings/textsize` · TextSizeSettingsPage | `settings/preferences.dart` · TextSizePage | L、C | 0–6字号枚举、预览／保存／返回、系统大字体叠加 | API24最大字号预览/保存/首页/重启保持/恢复默认通过；完整七档与系统字体组合待验 |
| R18 | `/settings/filter/account` · AccountFilterSettingsPage | FilterSettingsPage(account) | L、C | 主／子账户、隐藏、搜索、全选／反选、首页／总额／统计上下文 | 分组/搜索/取消及 More 全不选设备通过；其它上下文待验 |
| R19 | `/settings/filter/category` · CategoryFilterSettingsPage | FilterSettingsPage(category) | L、C | 父／子分类、类型限制、隐藏、搜索、上下文和排除语义 | 分组与父级联动设备通过；完整上下文待验 |
| R20 | `/settings/filter/tag` · TransactionTagFilterSettingsPage | FilterSettingsPage(tag) | L、C | 分组、包含／排除／默认三态，组内 AND／OR、组间 AND、无标签条件 | 业务测试通过；完整设备操作待验 |
| R21 | `/settings/preferences` · PreferencesSettingsPage | PreferencesPage | L、C | 下方全部偏好表逐项更改后进入目标页面验证 | API24首页/账户金额显示、12小时及日历部分效果通过；E40 验证启用货币默认值、编辑保存及账户新建列表过滤；其余偏好待验 |
| R22 | `/settings/overview_layout` · LayoutEditorPage | `overview/home.dart` · OverviewLayoutPage | L、C | 九种组件添加／删除／排序／重置，逐组件尺寸和设置 | 九组件保存、复制/删除/重排/重启、剪贴板导入导出/高度/未保存确认及最终包紧凑组件通过；其余设置待验 |
| R23 | `/settings/chart_color_scheme` · ChartColorSchemeSettingsPage | ChartColorsPage | L、C | 单色修改、增删／排序、导入／复制／重置、图表应用 | API24 HSV/Hex、非法/合法导入、30色、重复/跨屏拖动、复制、重置与持久化通过；图表逐模式应用待验 |
| R24 | `/settings/account_category_display_order` · AccountCategoryDisplayOrderSettingsPage | AccountOrderPage | L、C | 拖动、取消、保存、重置、账户列表顺序 | API24 跨屏拖动、保存/返回取消、重置与重启持久化通过 |
| R25 | `/settings/sync` · ApplicationCloudSyncSettingsPage | CloudSettingsPage | C | 选择相关键、手动上传／下载、自动更新、禁用、跨客户端格式兼容 | 全部47键真实HTTP往返/局部/禁用通过；完整设备效果待验 |
| R26 | `/settings/browser_caches` · BrowserCacheSettingPage | `settings/data_settings.dart` · CacheSettingsPage | 本地缓存／WebView cache | 各缓存期限、单项／全清理，不删除账本、待同步及待上传图片 | API36离线全清理保留账本/队列/图片及最终包页面/过期入口通过；单项实际清理与压力待验 |
| R27 | `/settings` · SettingsPage | `settings/mobile_settings.dart` · SettingsPage | L、C | 条件入口、主题／时区／动画／滑动返回、退出待同步保护、打开桌面版 | E38 一级设置常驻导航及代表性紧凑操作菜单通过；API24/36主题/入口部分、待同步退出取消保留通过；全部设置效果待验 |
| R28 | `/app_lock` · ApplicationLockPage | `settings/security.dart` · AppLockPage | Android 安全存储／生物识别 | PIN两次确认、启用／更换／禁用、生物识别、重启锁定 | API36 PIN通过；API24无生物硬件失败保留通过；其它待验 |
| R29 | `/exchange_rates` · exchangerates/ListPage | ExchangeRatesPage | `v1/exchange_rates/latest.json` | 筛选、排序、改变基准与金额、数据源、自定义汇率删除 | 最终包基准1.00、服务商汇率列表与刷新入口通过；筛选/排序/删除待验 |
| R30 | `/exchange_rates/update` · exchangerates/UpdatePage | ExchangeRatesEditPage | `v1/exchange_rates/user_custom/update.json` | 正数边界、四位输入、服务端存储精度／截断与基准换算、默认币种、取消／保存 | 定点/截断/边界业务与HTTP通过；设备待验 |
| R31 | `/about` · AboutPage | AboutPage / ProjectLicensePage | config、打包的许可和贡献者 | 前后端版本、诊断、官网／帮助／问题、项目与第三方许可、品牌名称 | DBC30 版本、官网/帮助/许可/服务商及完整许可页面通过；E49 品牌文案已更新，设备上关于页待复验；外链目标设备组合待验 |
| R32 | `/user/profile` · UserProfilePage | `settings/profile.dart` · ProfilePage | `v1/users/profile/get.json`、update、avatar、verify_email | 资料、密码、头像、默认账户、编辑范围、全部语言地区格式和预览 | 格式/头像HTTP、未保存字段业务、API24格式效果及最新语言保留修复通过；其余资料分支待验 |
| R33 | `/user/data/management` · DataManagementPage | DataManagementPage | `v1/data/statistics.json`、`export.csv/tsv`、`clear/*` | 数量、CSV／TSV Android保存、取消、密码确认清理、待同步保护／账本代次 | API36 CSV/TSV保存/取消/返回锁通过；清理HTTP通过；完整设备待验 |
| R34 | `/user/2fa` · TwoFactorAuthPage | TwoFactorPage | `v1/users/2fa/*` | 状态、二维码／密钥、确认后新令牌、恢复码展示／复制／重置、关闭 | HTTP完整链路及API24启用/复制/关闭通过；其它设备分支待验 |
| R35 | `/user/sessions` · SessionListPage | SessionsPage / presentSession | `v1/tokens/list.json`、revoke、revoke_all | 当前设备不可注销、单会话滑动注销、注销其他全部、时间、浏览器与设备类型、API/MCP会话 | API24/36单会话注销、全部注销取消/确认、当前保护/禁用与Android显示通过；API/MCP设备显示待验 |
| R36 | `/category/all` · categories/AllPage | CategoryAllPage | S | 收入／支出／转账分类入口 | E33 最终包三类入口通过 |
| R37 | `/category/list` · categories/ListPage | CatalogListPage(categories) | `v1/transaction/categories/*` | 两级导航、排序／取消、显示隐藏、编辑／删除、空分类预设入口 | E33 列表与全部菜单入口通过；实际隐藏/删除/排序持久化待验 |
| R38 | `/category/add` · categories/EditPage | CategoryEditPage | `v1/transaction/categories/add.json` | 父／子类别、预填图标／颜色、名称／备注、取消 | API24 父分类新增通过；其它分支待验 |
| R39 | `/category/edit` · categories/EditPage | CategoryEditPage | `v1/transaction/categories/modify.json` | 父级迁移、名称／图标／颜色／备注、已有交易限制 | E33 编辑字段与草稿放弃通过；提交/父级迁移/已有交易限制待验 |
| R40 | `/category/preset` · categories/PresetPage | CategoryPresetPage | `v1/transaction/categories/add_batch.json` | 原三类预设、父／子独立选择、反选、重复跳过 | E33 语言与父子选择界面通过；批量提交/重复跳过待验 |
| R41 | `/tag/list` · tags/ListPage | CatalogListPage(tags) / TagEditPage | `v1/transaction/tags/*` | 增删改、分组过滤、移组、隐藏、拖动／名称排序、取消 | API24 分组标签创建/使用通过；排序/移组等待验 |
| R42 | `/tag/group/list` · tags/GroupListPage | CatalogListPage(groups) | `v1/transaction/tags/groups/*` | 增删改、默认组、拖动／取消，删组保留标签 | API24 新分组及标签引用通过；排序/删除等待验 |
| R43 | `/template/list` · templates/ListPage | CatalogListPage(templates) | `v1/transaction/templates/*` | 普通模板增删改、排序／隐藏、应用模板记账 | API24 新建/编辑/应用预填/删除通过；排序/隐藏待验 |
| R44 | `/schedule/list` · templates/ListPage | CatalogListPage(schedules) | `v1/transaction/templates/*` | 功能关闭、启用／停用、排序、服务器执行时按当日汇率换算跨币种转账并计入手续费，不在离线生成 | 旧版 API24 每周计划创建/删除通过；新版汇率执行与其它频率待验 |
| R45 | `/template/add` · transactions/EditPage | TransactionEditPage / SchedulePage | `v1/transaction/templates/add.json` | 普通／定时模板、转账金额及手续费、所有频率、开始／结束日期、时区、字段校验 | 旧版 API24 普通/每周模板部分通过；新版转账模板保存与全部配置待验 |
| R46 | `/template/edit` · transactions/EditPage | TransactionEditPage / SchedulePage | `v1/transaction/templates/modify.json`、delete | 修改、删除、复制、隐藏资料和无效关联处理 | API24 普通模板编辑通过；定时编辑等待验 |

## 弹层、组件与原生能力

| ID | 原页面／弹层 | Flutter 对应 | API／存储 | 验收场景 |
|---|---|---|---|---|
| D01 | NumberPadSheet、AmountFilterPage | `amountPad` / Money / BookkeepingFormatter | L | 四则运算、清零／退格、负数、除零、精度／溢出、本地数字与小数符号 |
| D02 | ListItemSelectionSheet/Popup、TwoColumnListItemSelectionSheet | `choose` / 原生选择弹层 | L | 当前选择、取消、搜索、超长列表、原层级和触达方式 |
| D03 | TreeViewSelectionSheet | `selectMany` / FilterSettingsPage | S、L | 两级部分选择、父级联动、隐藏父级子项、全空、全选 |
| D04 | TransactionTagSelectionSheet | 标签选择及标签筛选组件 | S、L | 标签分组、最多10个、隐藏项、AND／OR与排除组合 |
| D05 | Date/DateTime/Month/DateRange/MonthRangeSelectionSheet | `pickDate` / TransactionFilterPage / BookkeepingFormatter | L | 星期起始、四类历法、日期与时间、区间预设、DST与年／财年边界 |
| D06 | FiscalYearStartSelectionSheet | ProfilePage.fiscalYear | profile/update | 月末、2月29禁止、格式预览、保存往返不改变原日期 |
| D07 | IconSelectionSheet / ColorSelectionSheet | `selection_sheets.dart` / `reference_icons.dart` | 原字体、`v1/custom_icons/*` | 287原图标、颜色、自定义图标条件启用、上传／删除／缓存 |
| D08 | ScheduleFrequencySheet | SchedulePage | templates add/modify | 每天／每N天／每周／每月／每年，日期范围、禁用、服务器生成 |
| D09 | Password/Passcode/PinCodeInputSheet | prompt / AuthPage / AppLockPage | 认证接口、安全存储 | 遮挡、输入类型、错误／取消／重试、返回键先关键盘 |
| D10 | WidgetSettingsPopup / LayoutEditorPage | OverviewLayoutPage / 组件设置 | L、C | 高度、日期范围、可见行数、账户／分类筛选、保存／取消／重置 |
| D11 | 九种 overview/widgets | `overview/home.dart` | S、L、汇率 | 月支出／期间收支／净收入储蓄率／资产／支出进度／分类排行／账户余额／交易日历／最近交易 |
| D12 | PieChart / TrendsBarChart / AccountBalanceTrendsBarChart | fl_chart 与原生余额条形列表 | S、对账 API | 金额／百分比、负数／零、颜色、图例隐藏、点击筛选、聚合与时区 |
| D13 | AITextRecognitionSheet / AIImageRecognitionSheet | `system/native_features.dart` | `v1/llm/transactions/recognize_text.json`、recognize_receipt_image | 输入／剪贴板／拍照／选图、确认、取消请求、错误重试、识别后复核；E55 长按“识图记账”快捷项注册和禁用提示通过；E56 文字／图片识别改为提交后立即打开可编辑草稿，后台成功回填且不覆盖手改字段，离页后继续并可从长按新增菜单找回；完成态设备验收待启用 AI 的隔离服务 |
| D14 | MapSheet | LocationPage + 同源 `/native-map` | 原地图提供商与代理 | 冷加载提示／慢加载重试、只读／点选、GPS／权限拒绝、坐标转换／显示、拒绝外域导航与非法桥消息；E43 API24/36 自动定位地点名称回填通过 |
| D15 | ImageBox / 图片浏览器 | PicturePage / showNativeImage | 图片 upload、picture download、本地图片 | 拍照／选图／接收分享、上传质量、预览缩放、取消／删除、离线持久及重试；E52 顶部相机入口和两种来源附图通过；E53 缩略图、放大、删除确认及离线重启通过；E54 顶部入口移除，更多菜单仍可展开照片区；服务端上传待验 |
| D16 | OIDC 浏览器流程 | 系统浏览器 + app_links | oauth2/native start/exchange、oauth2/authorize | 成功、取消、错误verifier、超时、重复兑换、回调不含登录令牌 |
| D17 | InformationSheet / 通知／确认／loading | inform / confirm / NativePage | L、认证刷新 | 后端通知、错误翻译、取消／重试、长任务加载、动画／返回设置 |
| D18 | 浏览器导出／切换桌面／剪贴板 | FilePicker / url_launcher / Clipboard | export、服务器desktop | 文件保存成功与取消、正确前缀、剪贴板被拒、外部返回仍锁定 |

## 偏好必须验证实际效果

| 设置组 | 原键／行为 |
|---|---|
| 通用 | theme、fontSize、timeZone、swipeBack、animate、showAccountBalance、accountCategoryOrders、chartColors、autoUpdateExchangeRatesData、enabledCurrencies（默认 CNY/USD，默认币种及已有账户币种始终有效） |
| 首页 | mobileOverviewPageLayout、showAmountInHomePage、timezoneUsedForStatisticsInHomePage、overviewAccountFilterInHomePage、overviewTransactionCategoryFilterInHomePage；九组件独立设置 |
| 明细 | showTotalAmountInTransactionListPage、showTagInTransactionListPage、defaultKeywordMatchModeInTransactionListPage |
| 记账 | quickSaveButtonStyleInMobileTransactionListPage、quickAddButtonActionInMobileTransactionEditPage、autoSaveTransactionDraft（三态）、autoGetCurrentGeoLocation、alwaysShowTransactionPicturesInMobileTransactionEditPage、transactionPictureQuality |
| AI | alwaysRequireConfirmationOfClipboardContentBeforeSubmission、autoUploadTransactionPictureForAIRecognition |
| 账户 | totalAmountExcludeAccountIds、hideCategoriesWithoutAccounts、defaultCreditCardAmountDisplayTypeInMobile、reconciliationStatementPageDefaultDateRangeTypeInMobile |
| 统计 | statistics 内 defaultChartDataType／defaultTimezoneType／defaultKeywordMatchMode／defaultSortingType／账户与分类排除／三分析类型默认图形与范围 |
| 汇率／缓存 | currencySortByInExchangeRatesPage、按日期查询并显示历史汇率、汇率缓存期限、地图缓存期限、图片缓存清理（原 mobile 无图片缓存期限设置） |
| 用户格式 | 语言、默认币种、周起始、财年起始、历法／日期显示、长短日期／时间、财年格式、币种位置、数字体系、分组方式／符号、小数分隔、坐标格式、收支颜色 |

## 服务器条件功能

| 配置字段 | 必须验证 |
|---|---|
| enableInternalAuth / enableOAuth2Login | 密码登录关闭、仅OIDC、二者同时启用；已保存账号的重新认证 |
| enableUserRegister / enableUserForgetPassword / enableUserVerifyEmail | 对应入口隐藏／显示、注册激活、重发验证邮件 |
| enableTwoFactor | 设置入口、正常2FA和恢复码登录 |
| enableTransactionPictures / maxTransactionPictureFileSize | 新图入口与大小限制，已有图片仍能查看；离线持久与失败重试 |
| enableUserCustomIcon | 原图标仍可选，自定义图标入口和上传限制 |
| enableScheduledTransaction | 定时入口隐藏／显示；不在离线端生成 |
| enableDataExport | 导出入口，CSV／TSV保存 |
| transactionFromAITextRecognition / transactionFromAIImageRecognition | 各入口与剪贴板偏好独立，识别失败不丢编辑内容 |
| mapProvider / provider options / proxy | 每种已配置提供商、无地图仅GPS、同源桥、路径前缀 |
| loginPageTips / oauth2CustomDisplayNames | 登录提示与本地化OIDC名称 |

## Android 桌面入口扩展

| 原生入口 | Flutter 目标／数据 | 验收场景 | 状态 |
|---|---|---|---|
| API25+ 应用图标长按“记一笔” | `/transaction/add`；继续经过登录、重新认证和应用锁重定向 | 冷启动、已运行、锁定时点击，Activity 重建不得重复打开 | E34：API36 长按显示并进入应用锁；API24 深链冷／热启动进入编辑器；E43：旧版 API24/36 首帧与正式编辑器共用 352dp 金额键盘几何；E51：API36 从后台设置子页通过静态快捷项 Intent 进入时旧页未闪现；E57：API36 冷启动占位与正式表单均选中支出且键盘连续显示；E58：API36 新版 312dp 键盘与数字顺序通过；E59：API36 从金额键盘左侧代码切换币种并保留金额；E60：API36 三个交易类型移除表单普通币种行；E61：API36 币种代码下方下拉框重复点击展开／收起；新版 API24／实体 Launcher 待验 |
| 1×1“记一笔”组件 | `/transaction/add`；与快捷入口共用原生命令 | 桌面添加、点击、锁定、API24/36 尺寸 | E34：两平台注册/添加通过；API24 点击进入编辑器，API36 锁定门控通过 |
| 4×1“本月概要”组件 | 本地有效交易；首页统计时区；默认币种换汇；收入、支出、收入减支出 | 三 Tab、截至今日的上年同期同比、方向与红绿颜色、同比增减金额、总计三等分、无基期、待同步交易、退出清空、明暗主题；主体进入首页 | E36：4×1、无品牌文字、主体进入首页及 Tab 原地切换；E37：同比截止日、四种收入／支出涨跌样式、总计三等分及 API36 深色中文标签通过；E39：固定“本月”、同比增减金额、放大总计标签与金额，并通过 API24/36 |
| 外部“当归记账”入口 | 原生 `OPEN_HOME` 动作打开账本首页 | 已运行时从账户页、新增交易页切回首页；冷启动、应用锁、API24/实体机 | E50：API36 从“当归之家”入口将账户页与空白新增交易页切回首页；其余场景待验 |

## 完成门槛

46 路由与 D01–D18 每项都应有操作记录；不能把某个模块的一次登录或编译通过推广为所有行为通过。2026-09-15 的独立源码审查发现交易编辑附加动作、部分偏好实际生效、账户／对账动作和图表交互需要修正并复验。新增原生提示需纳入全部21语言；语言补充完成后仍须实际显示验收。后续修复必须更新 [验收记录](ACCEPTANCE.md) 和证据；当前总体验收未通过。核心动作的补充细节见 [CORE_UI_ACCEPTANCE.md](CORE_UI_ACCEPTANCE.md)。

## 2026-09-15 本轮证据更新

已把实际 API24/36 操作映射到上表，详见 [ACCEPTANCE.md](ACCEPTANCE.md) 的 E11–E34。并发冲突 JSON 中旧 `editorReturnNeedsFix` 由独立导航复验关闭；统计月份标签与滑动样式的旧待验字段分别由 E29/E30 中带 SHA 的复验关闭，不改写旧证据。DBC30 已覆盖 More、Home、导航图标、汇率、配色/排序、缓存与关于；9394604B 包覆盖 Home、统计、汇率、缓存、图片和应用锁，当前 27BADBBB 包在其上增加并验收 Android 桌面入口。截图采自不同迭代 APK，E31 与 E34 分别绑定其记录的构建。

本轮发现并修复：跨服务器临时认证凭证、登录配置文案、AI文字/图片模式混合、识别结果键盘抢焦点、AI及导出错误响应解包、禁用2FA后旧恢复码留存，以及原邮箱未验证上下文提示、注册预设预览内语言入口和地图初始化期间GPS更新丢失。修复有业务测试；AI模式/错误/键盘已由E19复验，邮箱/预设语言由E22、认证门控/2FA由E23、会话由E24复验。地图初始化期间真实GPS变化仍待设备复验，不以源码修复标记全量通过。

认证门控（内部/OIDC、注册、忘记密码、邮箱验证、两步验证）和英／简中自定义提示已通过E23的隔离服务器设备验收。媒体、AI、导出、定时及地图提供商的全部开关组合仍需按表逐项验证。安全／设置／系统剩余具体分支见验收记录对应小节。


