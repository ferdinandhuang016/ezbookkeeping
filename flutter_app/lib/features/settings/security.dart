import 'dart:convert';

import 'package:flutter/material.dart'
    show SelectableText, Dismissible, DismissDirection, Icons;
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../ui/common.dart';
import 'session_presentation.dart';

class TwoFactorPage extends ConsumerStatefulWidget {
  const TwoFactorPage({super.key});
  @override
  ConsumerState<TwoFactorPage> createState() => _TwoFactorState();
}

class _TwoFactorState extends NativeState<TwoFactorPage> {
  bool? enabled;
  RecordData? enrollment;
  String passcode = '';
  List<String>? codes;
  @override
  void initState() {
    super.initState();
    Future.microtask(() => run(load));
  }

  Future<void> load() async {
    final result = await app.get('v1/users/2fa/status.json');
    enabled = result['enable'] == true;
  }

  Future<void> enable() async {
    await run(() async {
      enrollment = Map<String, dynamic>.from(
        await app.post('v1/users/2fa/enable/request.json', {}),
      );
      passcode = '';
    });
  }

  Future<void> confirmEnable() async {
    await run(() async {
      final result = await app.post('v1/users/2fa/enable/confirm.json', {
        'secret': enrollment!['secret'],
        'passcode': passcode,
      });
      codes = (result['recoveryCodes'] as List).cast<String>();
      await app.updateSessionToken(string(result['token']));
      enrollment = null;
      enabled = true;
    });
  }

  Future<void> operation(bool disable) async {
    final password = await prompt(
      context,
      t(
        disable
            ? 'Your current password is required to disable two-factor authentication.'
            : 'Your current password is required to regenerate backup codes for two-factor authentication. If you regenerate backup codes, the previous ones will become invalid.',
      ),
      secret: true,
    );
    if (password == null) return;
    await run(() async {
      final result = await app.post(
        disable
            ? 'v1/users/2fa/disable.json'
            : 'v1/users/2fa/recovery/regenerate.json',
        {'password': password},
      );
      if (disable) {
        enabled = false;
        codes = null;
      } else {
        codes = (result['recoveryCodes'] as List).cast<String>();
      }
    });
  }

  @override
  Widget buildPage(BuildContext context) => NativePage(
    title: t('Two-Factor Authentication'),
    busy: busy,
    children: [
      Section(
        children: [
          ItemRow(
            t('Status'),
            value: t(
              enabled == null
                  ? 'Unknown'
                  : enabled!
                  ? 'Enabled'
                  : 'Disabled',
            ),
          ),
          if (enabled == false && enrollment == null)
            actionButton(t('Enable'), enable),
          if (enabled == true) ...[
            actionButton(t('Regenerate Backup Codes'), () => operation(false)),
            actionButton(
              t('Disable'),
              () => operation(true),
              destructive: true,
            ),
          ],
        ],
      ),
      if (enrollment != null)
        Section(
          footer: t(
            'Please use a two-factor authentication app to scan the qrcode below and enter the current passcode.',
          ),
          children: [
            Center(
              child: _EnrollmentQr(
                data: string(enrollment!['qrcode']),
                secret: string(enrollment!['secret']),
                username: string(app.user['username']),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(16),
              child: SelectableText(string(enrollment!['secret'])),
            ),
            InputRow(
              t('Passcode'),
              value: passcode,
              keyboard: TextInputType.number,
              onChanged: (v) => setState(() => passcode = v),
            ),
            actionButton(t('Confirm'), confirmEnable),
            actionButton(t('Cancel'), () => setState(() => enrollment = null)),
          ],
        ),
      if (codes != null)
        Section(
          title: t('Backup Code'),
          footer: t(
            'Please copy these backup codes to safe place, the following backup codes will be displayed only once. If these codes were lost, you can regenerate them at any time.',
          ),
          children: [
            Padding(
              padding: const EdgeInsets.all(20),
              child: SelectableText(
                codes!.join('\n'),
                style: const TextStyle(fontFamily: 'monospace', height: 1.8),
              ),
            ),
            actionButton(t('Copy'), () async {
              await Clipboard.setData(ClipboardData(text: codes!.join('\n')));
              if (context.mounted) {
                await inform(context, t('Backup codes copied'));
              }
            }),
            actionButton(t('Done'), () => setState(() => codes = null)),
          ],
        ),
    ],
  );
}

class _EnrollmentQr extends StatelessWidget {
  const _EnrollmentQr({
    required this.data,
    required this.secret,
    required this.username,
  });
  final String data, secret, username;
  @override
  Widget build(BuildContext context) {
    if (data.startsWith('data:image/png;base64,')) {
      return Image.memory(
        base64Decode(data.split(',').last),
        width: 240,
        height: 240,
      );
    }
    final url = data.startsWith('otpauth:')
        ? data
        : Uri(
            scheme: 'otpauth',
            host: 'totp',
            path: '/ezBookkeeping:$username',
            queryParameters: {'secret': secret, 'issuer': 'ezBookkeeping'},
          ).toString();
    return Container(
      color: CupertinoColors.white,
      padding: const EdgeInsets.all(8),
      child: QrImageView(data: url, size: 240),
    );
  }
}

class SessionsPage extends ConsumerStatefulWidget {
  const SessionsPage({super.key});
  @override
  ConsumerState<SessionsPage> createState() => _SessionsState();
}

class _SessionsState extends NativeState<SessionsPage> {
  List<RecordData> sessions = [];
  @override
  void initState() {
    super.initState();
    Future.microtask(() => run(load));
  }

  Future<void> load() async {
    sessions = records(await app.get('v1/tokens/list.json'));
  }

  Future<bool> revoke(RecordData session) async {
    if (!await confirm(
      context,
      t('Are you sure you want to logout from this session?'),
    )) {
      return false;
    }
    return run(() async {
      await app.post('v1/tokens/revoke.json', {'tokenId': session['tokenId']});
      sessions.removeWhere((e) => e['tokenId'] == session['tokenId']);
    });
  }

  Future<void> revokeAll() async {
    if (sessions.length < 2) return;
    if (!await confirm(
      context,
      t('Are you sure you want to logout all other sessions?'),
    )) {
      return;
    }
    await run(() async {
      await app.post('v1/tokens/revoke_all.json', {});
      await load();
    }, success: true);
  }

  Widget sessionRow(RecordData item) {
    final presentation = presentSession(item);
    final icon = switch (presentation.device) {
      SessionDevice.phone ||
      SessionDevice.wearable => CupertinoIcons.device_phone_portrait,
      SessionDevice.tablet => Icons.tablet_mac,
      SessionDevice.tv => CupertinoIcons.tv,
      SessionDevice.api => CupertinoIcons.chevron_left_slash_chevron_right,
      SessionDevice.mcp => CupertinoIcons.sparkles,
      SessionDevice.desktop => CupertinoIcons.device_desktop,
    };
    return Dismissible(
      key: ValueKey(item['tokenId']),
      direction: item['isCurrent'] == true
          ? DismissDirection.none
          : DismissDirection.endToStart,
      confirmDismiss: (_) => revoke(item),
      background: Container(
        color: CupertinoColors.destructiveRed,
        alignment: AlignmentDirectional.centerEnd,
        padding: const EdgeInsets.all(16),
        child: Text(t('Log Out')),
      ),
      child: ItemRow(
        t(presentation.name),
        subtitle: t(presentation.details),
        value: number(item['lastSeen']) > 0
            ? dateText(
                DateTime.fromMillisecondsSinceEpoch(
                  number(item['lastSeen']) * 1000,
                ),
                time: true,
              )
            : '-',
        leading: Icon(icon),
        onTap: item['isCurrent'] == true ? null : () => revoke(item),
      ),
    );
  }

  @override
  Widget buildPage(BuildContext context) => NativePage(
    title: t('Device & Sessions'),
    busy: busy,
    onRefresh: () async {
      await run(load);
    },
    trailing: iconButton(
      CupertinoIcons.arrow_right_square,
      t('Logout All'),
      sessions.length < 2 ? null : revokeAll,
    ),
    children: [
      Section(children: [for (final item in sessions) sessionRow(item)]),
    ],
  );
}

class AppLockPage extends ConsumerStatefulWidget {
  const AppLockPage({super.key});
  @override
  ConsumerState<AppLockPage> createState() => _AppLockState();
}

class _AppLockState extends NativeState<AppLockPage> {
  String pin = '', confirmation = '';
  late bool biometric = app.settings['applicationLockWebAuthn'] == true;
  Future<void> save() async {
    await run(() async {
      if (pin != confirmation) throw StateError(t('PIN codes do not match'));
      if (app.settings['applicationLock'] == true) {
        final old = await prompt(context, t('Current PIN'), secret: true);
        if (old == null) return;
        if (!await app.unlock(pin: old)) {
          throw StateError(t('Incorrect PIN code'));
        }
      }
      await app.configureLock(pin, biometrics: biometric);
      pin = '';
      confirmation = '';
    }, success: true);
  }

  Future<void> disable() async {
    final value = await prompt(context, t('Current PIN'), secret: true);
    if (value != null) await run(() => app.disableLock(value), success: true);
  }

  @override
  Widget buildPage(BuildContext context) => NativePage(
    title: t('Application Lock'),
    busy: busy,
    children: [
      Section(
        children: [
          ItemRow(
            t('Status'),
            value: t(
              app.settings['applicationLock'] == true ? 'Enabled' : 'Disabled',
            ),
          ),
          InputRow(
            t('PIN (6–12 digits)'),
            value: pin,
            secret: true,
            keyboard: TextInputType.number,
            onChanged: (v) => setState(() => pin = v),
          ),
          InputRow(
            t('Confirm PIN'),
            value: confirmation,
            secret: true,
            keyboard: TextInputType.number,
            onChanged: (v) => setState(() => confirmation = v),
          ),
          toggleRow(
            t('Unlock with Biometrics'),
            biometric,
            (v) => setState(() => biometric = v),
          ),
          actionButton(t('Save'), save),
          if (app.settings['applicationLock'] == true)
            actionButton(t('Disable'), disable, destructive: true),
        ],
      ),
    ],
  );
}
