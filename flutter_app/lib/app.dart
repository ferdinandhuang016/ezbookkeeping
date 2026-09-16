import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'core/app_controller.dart';
import 'core/formatting.dart';
import 'features/auth/auth_page.dart';
import 'features/mobile.dart';
import 'ui/quick_add_startup.dart';

class EzBookkeepingApp extends ConsumerStatefulWidget {
  const EzBookkeepingApp({super.key});
  @override
  ConsumerState<EzBookkeepingApp> createState() => _EzBookkeepingAppState();
}

class _EzBookkeepingAppState extends ConsumerState<EzBookkeepingApp> {
  late final GoRouter _router;
  late final AppController _controller;
  late final ValueNotifier<String> _routeRefresh;
  late final RootBackButtonDispatcher _backButtonDispatcher;
  final _rootNavigatorKey = GlobalKey<NavigatorState>();
  final _lockNavigatorKey = GlobalKey<NavigatorState>();
  @override
  void initState() {
    super.initState();
    final controller = _controller = ref.read(appControllerProvider);
    _routeRefresh = ValueNotifier(_redirectState);
    controller.addListener(_refreshRouting);
    _backButtonDispatcher = _LockBackButtonDispatcher(() => controller.locked);
    _router = GoRouter(
      navigatorKey: _rootNavigatorKey,
      refreshListenable: _routeRefresh,
      redirect: (context, state) {
        if (!controller.initialized) {
          final target = controller.pendingQuickAdd
              ? '/quick-add-start'
              : '/loading';
          return state.uri.path == target ? null : target;
        }
        if (!controller.authenticated) {
          return ['/login', '/signup'].contains(state.uri.path)
              ? null
              : '/login';
        }
        if (controller.locked) {
          // Keep the editor and its dialogs alive while an external picker or
          // another application is in front. The lock is an opaque overlay.
          return null;
        }
        if (controller.needsReauthentication &&
            !controller.reauthenticationDeferred) {
          return state.uri.path == '/login' ? null : '/login';
        }
        if (controller.hasSharedPictures &&
            ![
              '/transaction/add',
              '/transaction/edit',
            ].contains(state.uri.path)) {
          return '/transaction/add?shared=true';
        }
        final nativeRoute = controller.pendingNativeRoute;
        if (nativeRoute != null) {
          controller.takePendingNativeRoute();
          return state.uri.toString() == nativeRoute ? null : nativeRoute;
        }
        if ([
          '/login',
          '/signup',
          '/loading',
          '/quick-add-start',
          '/unlock',
        ].contains(state.uri.path)) {
          return '/';
        }
        return null;
      },
      routes: [
        for (final path in _paths)
          GoRoute(
            path: path,
            pageBuilder: (context, state) {
              final Widget child = switch (path) {
                '/loading' => Scaffold(
                  body: controller.nativeLaunchPrepared
                      ? const Center(child: CupertinoActivityIndicator())
                      : const SizedBox.shrink(),
                ),
                '/quick-add-start' => const QuickAddStartupPage(),
                '/login' => const AuthPage(),
                '/signup' => const AuthPage(signup: true),
                '/unlock' => const UnlockPage(),
                _ => mobilePage(path, state.uri.queryParameters),
              };
              return _NativePage(
                key: state.pageKey,
                child: child,
                controller: controller,
                instant:
                    path == '/quick-add-start' ||
                    state.uri.queryParameters['launcher'] == 'true',
              );
            },
          ),
      ],
    );
  }

  String get _redirectState =>
      '${_controller.initialized}:${_controller.authenticated}:'
      '${_controller.needsReauthentication}:${_controller.reauthenticationDeferred}:'
      '${_controller.hasSharedPictures}:${_controller.locked}:'
      '${_controller.nativeLaunchPrepared}:${_controller.pendingNativeRoute}';

  void _refreshRouting() {
    // Ordinary ledger notifications must not enqueue a stale route parse just
    // before a successful editor save pops its page. Only redirects need one.
    if (_controller.pendingNativeRoute != null) {
      _rootNavigatorKey.currentState?.popUntil((route) => route.isFirst);
    }
    _routeRefresh.value = _redirectState;
  }

  @override
  void dispose() {
    _controller.removeListener(_refreshRouting);
    _router.dispose();
    _routeRefresh.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = ref.watch(appControllerProvider);
    final themeMode = switch (c.settings['theme']) {
      'dark' => ThemeMode.dark,
      'light' => ThemeMode.light,
      _ => ThemeMode.system,
    };
    return MaterialApp.router(
      title: c.t('global.app.title'),
      debugShowCheckedModeBanner: false,
      routerDelegate: _router.routerDelegate,
      routeInformationParser: _router.routeInformationParser,
      routeInformationProvider: _router.routeInformationProvider,
      backButtonDispatcher: _backButtonDispatcher,
      theme: _theme(Brightness.light),
      darkTheme: _theme(Brightness.dark),
      themeMode: themeMode,
      locale: c.locale,
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      supportedLocales: const [
        Locale('en'),
        Locale('de'),
        Locale('el'),
        Locale('es'),
        Locale('fr'),
        Locale('it'),
        Locale('ja'),
        Locale('kn'),
        Locale('ko'),
        Locale('nl'),
        Locale('pt', 'BR'),
        Locale('ro'),
        Locale('ru'),
        Locale('sl'),
        Locale('ta'),
        Locale('th'),
        Locale('tr'),
        Locale('uk'),
        Locale('vi'),
        Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hans'),
        Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hant'),
      ],
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(
          textScaler: BookkeepingTextScaler(
            system: MediaQuery.textScalerOf(context),
            fontSizeType: (c.settings['fontSize'] as num? ?? 1).toInt(),
          ),
        ),
        child: DefaultTextStyle(
          style: CupertinoTheme.of(context).textTheme.textStyle.copyWith(
            inherit: false,
            color: CupertinoColors.label.resolveFrom(context),
            fontSize: 17,
            decoration: TextDecoration.none,
          ),
          child: Stack(
            fit: StackFit.expand,
            children: [
              ExcludeFocus(
                excluding: c.locked,
                child: ExcludeSemantics(
                  excluding: c.locked,
                  child: IgnorePointer(
                    ignoring: c.locked,
                    child: TickerMode(enabled: !c.locked, child: child!),
                  ),
                ),
              ),
              if (c.serverNotification != null && !c.locked)
                Align(
                  alignment: Alignment.topCenter,
                  child: SafeArea(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Material(
                        elevation: 8,
                        borderRadius: BorderRadius.circular(16),
                        color: Theme.of(context).colorScheme.surface,
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(16, 8, 8, 16),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Image.asset(
                                    'assets/logo.png',
                                    width: 24,
                                    height: 24,
                                  ),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: Text(c.t('global.app.title')),
                                  ),
                                  IconButton(
                                    tooltip: c.t('Close'),
                                    onPressed: c.dismissServerNotification,
                                    icon: const Icon(
                                      CupertinoIcons.xmark,
                                      size: 18,
                                    ),
                                  ),
                                ],
                              ),
                              ConstrainedBox(
                                constraints: const BoxConstraints(
                                  maxHeight: 180,
                                ),
                                child: SingleChildScrollView(
                                  child: Text(c.serverNotification!),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              if (c.locked)
                Navigator(
                  key: _lockNavigatorKey,
                  onGenerateRoute: (_) => CupertinoPageRoute<void>(
                    builder: (_) =>
                        const PopScope(canPop: false, child: UnlockPage()),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  ThemeData _theme(Brightness brightness) {
    const primary = Color(0xffd43f3f);
    final dark = brightness == Brightness.dark;
    final surface = dark ? const Color(0xff1c1c1e) : Colors.white;
    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      platform: TargetPlatform.iOS,
      cupertinoOverrideTheme: CupertinoThemeData(
        primaryColor: primary,
        brightness: brightness,
        barBackgroundColor: surface,
      ),
      colorScheme: ColorScheme.fromSeed(
        seedColor: primary,
        brightness: brightness,
        primary: primary,
        surface: surface,
      ),
      scaffoldBackgroundColor: dark ? Colors.black : const Color(0xffefeff4),
      appBarTheme: AppBarTheme(
        centerTitle: true,
        toolbarHeight: 60,
        backgroundColor: surface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        titleTextStyle: TextStyle(
          fontSize: 17,
          fontWeight: FontWeight.w600,
          color: dark ? Colors.white : Colors.black,
        ),
        iconTheme: const IconThemeData(color: primary),
      ),
      cardTheme: CardThemeData(
        color: surface,
        elevation: 0,
        margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size.fromHeight(44),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        ),
      ),
      dividerTheme: DividerThemeData(
        color: dark ? const Color(0xff38383a) : const Color(0xffc8c7cc),
        thickness: 0.5,
        space: 0.5,
      ),
      navigationBarTheme: NavigationBarThemeData(
        height: 64,
        backgroundColor: surface,
        indicatorColor: Colors.transparent,
      ),
    );
  }
}

class _LockBackButtonDispatcher extends RootBackButtonDispatcher {
  _LockBackButtonDispatcher(this.isLocked);
  final bool Function() isLocked;

  @override
  Future<bool> didPopRoute() {
    if (isLocked()) {
      FocusManager.instance.primaryFocus?.unfocus();
      return Future.value(true);
    }
    return super.didPopRoute();
  }
}

class _NativePage extends Page<void> {
  const _NativePage({
    super.key,
    required this.child,
    required this.controller,
    required this.instant,
  });
  final Widget child;
  final AppController controller;
  final bool instant;
  @override
  Route<void> createRoute(BuildContext context) => _NativeRoute(page: this);
}

class _NativeRoute extends CupertinoPageRoute<void> {
  _NativeRoute({required _NativePage page})
    : super(settings: page, builder: (_) => page.child);
  _NativePage get page => settings as _NativePage;
  @override
  Widget buildContent(BuildContext context) => page.child;
  @override
  bool get popGestureEnabled =>
      page.controller.settings['swipeBack'] != false && super.popGestureEnabled;
  @override
  Duration get transitionDuration =>
      !page.instant && page.controller.settings['animate'] != false
      ? super.transitionDuration
      : Duration.zero;
  @override
  Duration get reverseTransitionDuration =>
      page.instant ? Duration.zero : super.reverseTransitionDuration;
}

const _paths = [
  '/loading',
  '/quick-add-start',
  '/login',
  '/signup',
  '/unlock',
  '/',
  '/transaction/list',
  '/transaction/filter/amount',
  '/transaction/add',
  '/transaction/edit',
  '/transaction/detail',
  '/account/list',
  '/account/add',
  '/account/edit',
  '/account/reconciliation_statements',
  '/account/move_all_transactions',
  '/statistic/transaction',
  '/statistic/settings',
  '/settings/textsize',
  '/settings/filter/account',
  '/settings/filter/category',
  '/settings/filter/tag',
  '/settings/preferences',
  '/settings/overview_layout',
  '/settings/chart_color_scheme',
  '/settings/account_category_display_order',
  '/settings/sync',
  '/settings/browser_caches',
  '/settings',
  '/app_lock',
  '/exchange_rates',
  '/exchange_rates/update',
  '/about',
  '/user/profile',
  '/user/data/management',
  '/user/2fa',
  '/user/sessions',
  '/category/all',
  '/category/list',
  '/category/add',
  '/category/edit',
  '/category/preset',
  '/tag/list',
  '/tag/group/list',
  '/template/list',
  '/schedule/list',
  '/template/add',
  '/template/edit',
];
