import 'dart:convert';

import 'package:flutter/material.dart' show LicensePage, SelectableText;
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../ui/common.dart';
import 'settings_support.dart';
import 'preferences.dart';
import 'profile.dart';
import 'security.dart';
import 'data_settings.dart';

Widget settingsPage(String route, Map<String, String> query) => switch (route) {
  '/settings' => const SettingsPage(),
  '/settings/preferences' => const PreferencesPage(),
  '/settings/textsize' => const TextSizePage(),
  '/settings/chart_color_scheme' => const ChartColorsPage(),
  '/settings/account_category_display_order' => const AccountOrderPage(),
  '/settings/filter/account' ||
  '/settings/filter/category' ||
  '/settings/filter/tag' => FilterSettingsPage(
    kind: route.split('/').last,
    query: query,
  ),
  '/settings/sync' => const CloudSettingsPage(),
  '/settings/browser_caches' => const CacheSettingsPage(),
  '/user/profile' => const ProfilePage(),
  '/user/data/management' => const DataManagementPage(),
  '/user/2fa' => const TwoFactorPage(),
  '/user/sessions' => const SessionsPage(),
  '/app_lock' => const AppLockPage(),
  '/exchange_rates' => const ExchangeRatesPage(),
  '/exchange_rates/update' => ExchangeRatesEditPage(
    currency: query['currency'],
  ),
  '/about' => const AboutPage(),
  _ => throw ArgumentError.value(route, 'route'),
};

class SettingsPage extends ConsumerStatefulWidget {
  const SettingsPage({super.key});
  @override
  ConsumerState<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends SettingsState<SettingsPage> {
  Future<void> logout() async {
    if (!await confirm(context, t('Are you sure you want to log out?'))) return;
    await run(() async {
      if (app.pendingCount > 0) {
        await app.refresh();
        if (app.pendingCount > 0) {
          if (!mounted ||
              !await confirm(
                context,
                t('Discard pending transactions?'),
                message: t(
                  'Pending changes on this device will be permanently lost.',
                ),
                destructive: true,
              )) {
            return;
          }
          await app.logout(discardPending: true);
        } else {
          await app.logout();
        }
      } else {
        await app.logout();
      }
      if (mounted) context.go('/');
    });
  }

  @override
  Widget buildPage(BuildContext context) => NativePage(
    title: t('Settings'),
    busy: busy,
    children: [
      Section(
        title: string(app.user['nickname']),
        children: [
          link('User Profile', '/user/profile'),
          link('Transaction Categories', '/category/all'),
          link('Transaction Tags', '/tag/list'),
          link('Transaction Templates', '/template/list'),
          if (app.config['enableScheduledTransaction'] == true)
            link('Scheduled Transactions', '/schedule/list'),
          link('Data Management', '/user/data/management'),
          if (app.config['enableTwoFactor'] == true)
            link('Two-Factor Authentication', '/user/2fa'),
          link('Device & Sessions', '/user/sessions'),
          actionButton(t('Log Out'), logout),
        ],
      ),
      Section(
        title: t('Application'),
        children: [
          option('theme', 'Theme', [
            {'id': 'auto', 'name': 'System Default'},
            {'id': 'light', 'name': 'Light'},
            {'id': 'dark', 'name': 'Dark'},
          ]),
          link('Text Size', '/settings/textsize'),
          option('timeZone', 'Timezone', [
            {'id': '', 'name': 'System Default'},
            ...records(settingsReference['timezones']).map(
              (e) => {
                'id': e['timezoneName'],
                'name': '${t(string(e['displayName']))} (${e['timezoneName']})',
              },
            ),
          ]),
          link('Application Lock', '/app_lock'),
          link('Exchange Rates Data', '/exchange_rates'),
          link('Preferences', '/settings/preferences'),
          link('Statistics Settings', '/statistic/settings'),
          link('Settings Sync', '/settings/sync'),
          toggle('swipeBack', 'Enable Swipe Back'),
          toggle('animate', 'Enable Animation'),
          link('App Cache Management', '/settings/browser_caches'),
          ItemRow(
            t('Switch to Desktop Version'),
            onTap: () => run(() async {
              await launchUrl(
                Uri.parse('${app.serverUrl}desktop'),
                mode: LaunchMode.externalApplication,
              );
            }),
          ),
          link('About', '/about'),
        ],
      ),
    ],
  );
}

String documentationUrl(String language) =>
    language.replaceAll('_', '-').startsWith('zh')
    ? 'https://ezbookkeeping.mayswind.net/zh_Hans/faq/'
    : 'https://ezbookkeeping.mayswind.net/faq/';

const mapProviderWebsites = {
  'openstreetmap': 'https://www.openstreetmap.org',
  'openstreetmap-humanitarian': 'https://www.hotosm.org',
  'opentopomap': 'https://opentopomap.org',
  'opnvkarte': 'https://memomaps.de',
  'cyclosm': 'https://github.com/cyclosm/cyclosm-cartocss-style',
  'cartodb': 'https://carto.com',
  'tomtom': 'https://tomtom.com',
  'tianditu': 'https://www.tianditu.gov.cn',
  'googlemap': 'https://maps.google.com',
  'baidumap': 'https://map.baidu.com',
  'amap': 'https://www.amap.com',
};

class AboutPage extends ConsumerStatefulWidget {
  const AboutPage({super.key});
  @override
  ConsumerState<AboutPage> createState() => _AboutState();
}

class _AboutState extends NativeState<AboutPage> {
  int versionClicks = 0;
  static const version = 'Flutter 1.0.0 (1)';
  Future<void> open(String url) async {
    final uri = externalWebUri(url);
    if (uri != null) await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  Future<void> more() async {
    final action = await showCupertinoModalPopup<String>(
      context: context,
      builder: (sheet) => CupertinoActionSheet(
        actions: [
          CupertinoActionSheetAction(
            onPressed: () => Navigator.pop(sheet, 'cache'),
            child: Text(t('App Cache Management')),
          ),
          CupertinoActionSheetAction(
            onPressed: () => Navigator.pop(sheet, 'diagnosis'),
            child: Text(t('Show Diagnosis Information')),
          ),
        ],
        cancelButton: CupertinoActionSheetAction(
          onPressed: () => Navigator.pop(sheet),
          isDefaultAction: true,
          child: Text(t('Cancel')),
        ),
      ),
    );
    if (!mounted) return;
    if (action == 'cache') {
      await context.push('/settings/browser_caches');
    } else if (action == 'diagnosis') {
      final information = const JsonEncoder.withIndent('  ').convert({
        'app': version,
        'server': app.serverUrl,
        'serverVersion': app.config['serverVersion'],
        'syncProtocolVersion': app.config['syncProtocolVersion'],
        'initialSyncComplete': app.initialSyncComplete,
        'pendingCount': app.pendingCount,
        'language': app.languageTag,
        'timeZone': app.settings['timeZone'],
        'mapProvider': app.config['mapProvider'],
      });
      await showCupertinoSheet<void>(
        context: context,
        showDragHandle: true,
        scrollableBuilder: (sheet, controller) => NativePage(
          title: t('Diagnosis Information'),
          back: false,
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              iconButton(CupertinoIcons.doc_on_doc, t('Copy'), () async {
                await Clipboard.setData(ClipboardData(text: information));
                if (sheet.mounted) settingsNotice(sheet, t('Data copied'));
              }),
              iconButton(
                CupertinoIcons.xmark,
                t('Close'),
                () => Navigator.pop(sheet),
              ),
            ],
          ),
          children: [
            Padding(
              padding: const EdgeInsets.all(20),
              child: SelectableText(information),
            ),
          ],
        ),
      );
    }
  }

  @override
  Widget buildPage(BuildContext context) {
    final rates = app.settings['cachedExchangeRates'];
    final provider = string(app.config['mapProvider']);
    return NativePage(
      title: t('About'),
      trailing: versionClicks >= 5
          ? iconButton(CupertinoIcons.ellipsis, t('More'), more)
          : null,
      children: [
        Section(
          title: t('global.app.title'),
          children: [
            ItemRow(
              t('Version'),
              value: version,
              onTap: () async {
                setState(() => versionClicks++);
                await inform(
                  context,
                  '${t('Frontend Version')}: $version\n${t('Backend Version')}: ${string(app.config['serverVersion'])}',
                );
              },
            ),
            ItemRow(
              t('Official Website'),
              onTap: () => open('https://github.com/mayswind/ezbookkeeping'),
            ),
            ItemRow(
              t('Report Issue'),
              onTap: () =>
                  open('https://github.com/mayswind/ezbookkeeping/issues'),
            ),
            ItemRow(
              t('Getting help'),
              onTap: () => open(documentationUrl(app.languageTag)),
            ),
            ItemRow(
              t('License'),
              onTap: () => showCupertinoSheet<void>(
                context: context,
                showDragHandle: true,
                scrollableBuilder: (_, controller) =>
                    const ProjectLicensePage(),
              ),
            ),
          ],
        ),
        if (rates is Map &&
            rates.isNotEmpty &&
            rates['dataSource'] != 'user_custom')
          Section(
            title: t('Exchange Rates Data'),
            children: [
              ItemRow(
                t('Provider'),
                value: string(rates['dataSource']),
                onTap: externalWebUri(rates['referenceUrl']) == null
                    ? null
                    : () => open(string(rates['referenceUrl'])),
              ),
            ],
          ),
        if (provider.isNotEmpty)
          Section(
            title: t('Map'),
            children: [
              ItemRow(
                t('Provider'),
                value: t('mapprovider.$provider'),
                onTap: mapProviderWebsites[provider] == null
                    ? null
                    : () => open(mapProviderWebsites[provider]!),
              ),
            ],
          ),
      ],
    );
  }
}

class ProjectLicensePage extends ConsumerStatefulWidget {
  const ProjectLicensePage({super.key});
  @override
  ConsumerState<ProjectLicensePage> createState() => _ProjectLicenseState();
}

class _ProjectLicenseState extends NativeState<ProjectLicensePage> {
  String license = '';
  RecordData contributors = {};
  List<RecordData> licenses = [];
  @override
  void initState() {
    super.initState();
    Future.microtask(
      () => run(() async {
        license = await rootBundle.loadString('assets/reference/LICENSE.txt');
        contributors = jsonDecode(
          await rootBundle.loadString('assets/reference/contributors.json'),
        );
        licenses = records(
          jsonDecode(
            await rootBundle.loadString('assets/reference/web_licenses.json'),
          ),
        );
        await loadSettingsReference();
      }),
    );
  }

  Widget text(String value, {bool bold = false}) => SelectableText(
    value,
    style: TextStyle(
      fontSize: 14,
      fontWeight: bold ? FontWeight.w600 : FontWeight.w400,
    ),
  );
  Widget link(String title, String url) => CupertinoButton(
    padding: EdgeInsets.zero,
    minimumSize: const Size(0, 28),
    onPressed: () =>
        launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication),
    child: Text(title, style: const TextStyle(fontSize: 14)),
  );
  Widget contributor(String name) =>
      link('@$name', 'https://github.com/${Uri.encodeComponent(name)}');
  Widget table(List<List<Widget>> rows) => Table(
    border: TableBorder.all(
      color: CupertinoColors.separator.resolveFrom(context),
      width: .5,
    ),
    defaultVerticalAlignment: TableCellVerticalAlignment.middle,
    columnWidths: rows.first.length == 3
        ? const {
            0: FlexColumnWidth(.7),
            1: FlexColumnWidth(1.2),
            2: FlexColumnWidth(2),
          }
        : null,
    children: [
      for (final row in rows)
        TableRow(
          children: [
            for (final child in row)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                child: child,
              ),
          ],
        ),
    ],
  );
  Widget gap() => const SizedBox(height: 16);
  @override
  Widget buildPage(BuildContext context) => NativePage(
    title: t('License'),
    busy: busy,
    back: false,
    trailing: iconButton(
      CupertinoIcons.xmark,
      t('Close'),
      () => Navigator.pop(context),
    ),
    children: [
      Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            text(license),
            gap(),
            Container(
              height: .5,
              color: CupertinoColors.separator.resolveFrom(context),
            ),
            gap(),
            text(
              "ezBookkeeping's codebase and localization translation rely on contributions from the community. The following people have contributed to ezBookkeeping:",
            ),
            gap(),
            text('Project Maintainer', bold: true),
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: contributor('mayswind'),
            ),
            gap(),
            text('Code Contributors', bold: true),
            const SizedBox(height: 8),
            table([
              [text('Contributor', bold: true)],
              for (final name in contributors['code'] as List? ?? [])
                [
                  Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: contributor(string(name)),
                  ),
                ],
            ]),
            gap(),
            text('Translation Contributors', bold: true),
            const SizedBox(height: 8),
            table([
              [
                text('Tag', bold: true),
                text('Language', bold: true),
                text('Contributors', bold: true),
              ],
              for (final language in records(settingsReference['languages']))
                [
                  text(string(language['id'])),
                  text(string(language['name'])),
                  (contributors['translators']?[language['id']] as List? ?? [])
                          .isEmpty
                      ? text('/')
                      : Wrap(
                          spacing: 5,
                          children: [
                            for (final name
                                in contributors['translators'][language['id']]
                                    as List)
                              contributor(string(name)),
                          ],
                        ),
                ],
            ]),
            gap(),
            text(
              'ezBookkeeping also contains additional third party software and illustration.\nAll the third party software / illustration included or linked is redistributed under the terms and conditions of their original licenses.',
            ),
            gap(),
            for (final item in licenses) ...[
              text(string(item['name']), bold: true),
              if (string(item['copyright']).isNotEmpty)
                text(string(item['copyright'])),
              if (string(item['licenseUrl']).isNotEmpty) ...[
                text(
                  '${string(item['license']).isEmpty ? 'License' : item['license']}: ${item['licenseUrl']}',
                ),
              ],
              if (string(item['url']).isNotEmpty) text(string(item['url'])),
              gap(),
            ],
            ItemRow(
              'Flutter / Dart',
              onTap: () => Navigator.push(
                context,
                nativeRoute(
                  context,
                  builder: (_) =>
                      const LicensePage(applicationName: 'ezBookkeeping'),
                ),
              ),
            ),
          ],
        ),
      ),
    ],
  );
}
