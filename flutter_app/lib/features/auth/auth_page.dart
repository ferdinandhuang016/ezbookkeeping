import 'dart:convert';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/app_controller.dart';
import '../../core/api_client.dart';
import '../../core/onboarding.dart';
import '../../ui/common.dart'
    show choose, Section, ItemRow, NativePage, recordIcon;

class AuthPage extends ConsumerStatefulWidget {
  const AuthPage({super.key, this.signup = false});
  final bool signup;
  @override
  ConsumerState<AuthPage> createState() => _AuthPageState();
}

class _AuthPageState extends ConsumerState<AuthPage> {
  final _server = TextEditingController();
  final _username = TextEditingController();
  final _password = TextEditingController();
  final _confirmation = TextEditingController();
  final _email = TextEditingController();
  final _nickname = TextEditingController();
  final _code = TextEditingController();
  final _form = GlobalKey<FormState>();
  bool _busy = false;
  bool _recovery = false;
  String? _error;
  String _currency = 'USD';
  int _firstDayOfWeek = 0;
  bool _usePresetCategories = false;
  Map<String, dynamic> _presets = {};
  List<Map<String, dynamic>> _languages = [];
  List<Map<String, dynamic>> _currencies = [];
  @override
  void initState() {
    super.initState();
    final controller = ref.read(appControllerProvider);
    _currency = controller.formatter.defaultCurrency;
    _firstDayOfWeek = controller.formatter.firstDayOfWeek;
    _loadReferences();
    _server.text = controller.serverUrl;
    if (_server.text.isEmpty) {
      controller.lastServer().then((value) {
        if (mounted) _server.text = value ?? '';
      });
    }
  }

  Future<void> _loadReferences() async {
    final values = await Future.wait([
      rootBundle.loadString('assets/reference/settings.json'),
      rootBundle.loadString('assets/reference/category_presets.json'),
      rootBundle.loadString('assets/reference/currencies.json'),
    ]);
    if (!mounted) return;
    setState(() {
      _languages = (jsonDecode(values[0])['languages'] as List)
          .cast<Map>()
          .map((v) => Map<String, dynamic>.from(v))
          .toList();
      _presets = Map<String, dynamic>.from(jsonDecode(values[1]));
      _currencies = (jsonDecode(values[2]) as List)
          .cast<Map>()
          .map((v) => Map<String, dynamic>.from(v))
          .toList();
    });
  }

  @override
  void dispose() {
    for (final field in [
      _server,
      _username,
      _password,
      _confirmation,
      _email,
      _nickname,
      _code,
    ]) {
      field.dispose();
    }
    super.dispose();
  }

  Future<void> _run(Future<void> Function() action) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
    } catch (e) {
      if (mounted) {
        final c = ref.read(appControllerProvider);
        final email = e is ApiException && e.code == 201020
            ? (e.context?['email'])
            : null;
        if (c.config['enableUserVerifyEmail'] == true &&
            email is String &&
            email.isNotEmpty) {
          await _emailAction(
            'verify_email/resend.json',
            'Verify your email',
            password: true,
            verifiedEmail: email,
            hint: c.t(
              (e as ApiException).context?['hasValidEmailVerifyToken'] == true
                  ? 'format.misc.accountActivationAndResendValidationEmailTip'
                  : 'format.misc.resendValidationEmailTip',
              parameters: {'email': email},
            ),
          );
        } else {
          setState(() => _error = c.errorText(e));
        }
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _field(
    String label,
    TextEditingController controller, {
    bool password = false,
    TextInputType? keyboard,
    bool required = true,
    List<String>? autofill,
  }) {
    final c = ref.read(appControllerProvider);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: TextFormField(
        controller: controller,
        obscureText: password,
        keyboardType: keyboard,
        autocorrect: false,
        enableSuggestions: !password,
        autofillHints: autofill,
        decoration: InputDecoration(
          labelText: c.t(label),
          floatingLabelBehavior: FloatingLabelBehavior.always,
          labelStyle: const TextStyle(fontSize: 13),
          hintText: c.t(
            password
                ? 'Your password'
                : label == 'Username'
                ? 'Your username or email'
                : label,
          ),
          border: InputBorder.none,
        ),
        style: const TextStyle(fontSize: 16),
        validator: (value) => required && (value?.trim().isEmpty ?? true)
            ? c.t('This field is required')
            : null,
      ),
    );
  }

  Future<void> _submit() async {
    if (!_form.currentState!.validate()) return;
    await _run(() async {
      final c = ref.read(appControllerProvider);
      if (c.needsTwoFactor) {
        await c.completeTwoFactor(_code.text.trim(), recovery: _recovery);
        return;
      }
      if (c.needsOAuthVerification) {
        await c.completeOAuth(
          password: _password.text,
          passcode: _code.text.isEmpty ? null : _code.text,
        );
        return;
      }
      if (c.serverUrl.isEmpty || _server.text.trim() != c.serverUrl) {
        await c.connect(_server.text);
      }
      if (widget.signup) {
        final result = await c.register(
          registrationRequest(
            username: _username.text,
            password: _password.text,
            confirmation: _confirmation.text,
            email: _email.text,
            nickname: _nickname.text,
            language: c.languageTag,
            currency: _currency,
            firstDayOfWeek: _firstDayOfWeek,
            categories: _usePresetCategories ? _localizedPresets(c) : [],
          ),
        );
        if (!mounted) return;
        if (!c.authenticated) {
          await showCupertinoDialog<void>(
            context: context,
            builder: (ctx) => CupertinoAlertDialog(
              content: Text(
                c.t(
                  result['needVerifyEmail'] == true
                      ? 'You have been successfully registered. An account activation link has been sent to your email address, please activate your account first.'
                      : 'You have been successfully registered',
                ),
              ),
              actions: [
                CupertinoDialogAction(
                  onPressed: () => Navigator.pop(ctx),
                  child: Text(c.t('OK')),
                ),
              ],
            ),
          );
          if (mounted) context.go('/login');
        } else if (_usePresetCategories &&
            result['presetCategoriesSaved'] == false) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                c.t(
                  'You have been successfully registered, but there was an failure when adding preset categories. You can re-add preset categories in settings page anytime.',
                ),
              ),
            ),
          );
        }
      } else {
        await c.login(_username.text.trim(), _password.text);
      }
    });
  }

  List<Map<String, dynamic>> _localizedPresets(AppController c) =>
      registrationCategories(_presets, c.t);

  Future<void> _language() async {
    final c = ref.read(appControllerProvider);
    final value = await choose<String>(
      context,
      '${c.t('Language')} / Language',
      {
        for (final language in _languages)
          '${language['id']}': '${language['name']}',
      },
      selected: c.languageTag,
    );
    if (value == null) return;
    final currencyWasDefault = _currency == c.formatter.defaultCurrency;
    final weekWasDefault = _firstDayOfWeek == c.formatter.firstDayOfWeek;
    await c.setPreference('language', value);
    if (!mounted) return;
    setState(() {
      if (currencyWasDefault) _currency = c.formatter.defaultCurrency;
      if (weekWasDefault) _firstDayOfWeek = c.formatter.firstDayOfWeek;
    });
  }

  Future<void> _presetPreview() async {
    final accepted = await Navigator.of(context).push<bool>(
      CupertinoPageRoute(
        builder: (ctx) => Consumer(
          builder: (ctx, ref, _) {
            final c = ref.watch(appControllerProvider);
            return NativePage(
              title: c.t('Preset Categories'),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CupertinoButton(
                    padding: EdgeInsets.zero,
                    onPressed: () async {
                      final action = await choose<String>(ctx, c.t('More'), {
                        'language': c.t('Change Language'),
                      });
                      if (action == 'language' && ctx.mounted) {
                        await _language();
                      }
                    },
                    child: Icon(
                      CupertinoIcons.ellipsis,
                      semanticLabel: c.t('More'),
                    ),
                  ),
                  CupertinoButton(
                    padding: EdgeInsets.zero,
                    onPressed: () => Navigator.pop(ctx, !_usePresetCategories),
                    child: Text(
                      c.t(_usePresetCategories ? 'Disable' : 'Enable'),
                    ),
                  ),
                ],
              ),
              children: [
                for (final type in [1, 2, 3])
                  Section(
                    title: c.t(
                      {
                        1: 'Income Categories',
                        2: 'Expense Categories',
                        3: 'Transfer Categories',
                      }[type]!,
                    ),
                    children: [
                      for (final category in _localizedPresets(
                        c,
                      ).where((item) => item['type'] == type))
                        Material(
                          color: Colors.transparent,
                          child: ExpansionTile(
                            leading: recordIcon(category),
                            title: Text('${category['name']}'),
                            children: [
                              for (final sub
                                  in category['subCategories'] as List)
                                ItemRow(
                                  '${sub['name']}',
                                  leading: recordIcon(
                                    Map<String, dynamic>.from(sub),
                                  ),
                                ),
                            ],
                          ),
                        ),
                    ],
                  ),
              ],
            );
          },
        ),
      ),
    );
    if (accepted != null && mounted) {
      setState(() => _usePresetCategories = accepted);
    }
  }

  Widget _button(AppController c, {bool verifying = false}) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
    child: SizedBox(
      width: double.infinity,
      child: CupertinoButton.filled(
        borderRadius: BorderRadius.circular(14),
        padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
        onPressed: _busy ? null : _submit,
        child: _busy
            ? const CupertinoActivityIndicator(color: Colors.white)
            : Text(
                c.t(
                  verifying
                      ? 'Verify'
                      : widget.signup
                      ? 'Sign Up'
                      : 'Log In',
                ),
                style: const TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w600,
                ),
              ),
      ),
    ),
  );

  Widget _divider() => const Divider(height: 1, indent: 16, endIndent: 16);

  Widget _credentials(AppController c, {bool verifying = false}) => Column(
    children: [
      if (!verifying && c.serverUrl.isEmpty) ...[
        _field(
          'Server address',
          _server,
          keyboard: TextInputType.url,
          autofill: [AutofillHints.url],
        ),
        CupertinoButton(
          padding: const EdgeInsets.symmetric(vertical: 8),
          onPressed: _busy ? null : () => _run(() => c.connect(_server.text)),
          child: Text(c.t('Connect')),
        ),
        _divider(),
      ],
      if (!verifying && c.config['enableInternalAuth'] != false)
        _field('Username', _username, autofill: [AutofillHints.username]),
      if (!c.needsTwoFactor &&
          (verifying || c.config['enableInternalAuth'] != false)) ...[
        _divider(),
        _field(
          'Password',
          _password,
          password: true,
          autofill: [
            widget.signup ? AutofillHints.newPassword : AutofillHints.password,
          ],
        ),
      ],
      if (widget.signup) ...[
        _divider(),
        _field('Confirm Password', _confirmation, password: true),
        _divider(),
        _field(
          'E-mail',
          _email,
          keyboard: TextInputType.emailAddress,
          autofill: [AutofillHints.email],
        ),
        _divider(),
        _field('Nickname', _nickname),
      ],
      if (verifying)
        _field(
          _recovery ? 'Recovery Code' : 'Passcode',
          _code,
          keyboard: _recovery ? TextInputType.text : TextInputType.number,
          required: c.needsTwoFactor,
        ),
    ],
  );

  Widget _errorMessage(AppController c) => _error == null && c.error == null
      ? const SizedBox.shrink()
      : Padding(
          padding: const EdgeInsets.all(16),
          child: Text(
            c.errorText(_error ?? c.error!),
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        );

  Widget _footer(AppController c) {
    final language = _languages
        .where((item) => item['id'] == c.languageTag)
        .firstOrNull;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Wrap(
            alignment: WrapAlignment.center,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              CupertinoButton(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                minimumSize: const Size(0, 32),
                onPressed: _busy ? null : _language,
                child: Text(
                  '${language?['name'] ?? c.languageTag}',
                  style: const TextStyle(fontSize: 14),
                ),
              ),
              if (c.serverUrl.isNotEmpty)
                CupertinoButton(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                  minimumSize: const Size(0, 32),
                  onPressed: _busy ? null : _serverDialog,
                  child: Semantics(
                    label: c.t('Server address'),
                    child: const Icon(CupertinoIcons.settings, size: 18),
                  ),
                ),
            ],
          ),
          Wrap(
            alignment: WrapAlignment.center,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(
                '${c.t('global.app.title')} ',
                style: const TextStyle(
                  fontSize: 13,
                  color: CupertinoColors.secondaryLabel,
                ),
              ),
              CupertinoButton(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                minimumSize: const Size(0, 24),
                onPressed: () => launchUrl(
                  Uri.parse('https://github.com/mayswind/ezbookkeeping'),
                  mode: LaunchMode.externalApplication,
                ),
                child: const Text(
                  'Source code',
                  style: TextStyle(fontSize: 13),
                ),
              ),
              Text(
                '${c.config['serverVersion'] ?? ''}',
                style: const TextStyle(
                  fontSize: 13,
                  color: CupertinoColors.secondaryLabel,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _serverDialog() async {
    final c = ref.read(appControllerProvider);
    final input = TextEditingController(text: c.serverUrl);
    final accept = await showCupertinoDialog<bool>(
      context: context,
      builder: (ctx) => CupertinoAlertDialog(
        title: Text(c.t('Server address')),
        content: Padding(
          padding: const EdgeInsets.only(top: 16),
          child: CupertinoTextField(
            controller: input,
            keyboardType: TextInputType.url,
            autocorrect: false,
          ),
        ),
        actions: [
          CupertinoDialogAction(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(c.t('Cancel')),
          ),
          CupertinoDialogAction(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(c.t('Connect')),
          ),
        ],
      ),
    );
    if (accept == true) {
      _server.text = input.text;
      await _run(() => c.connect(input.text));
    }
    input.dispose();
  }

  Future<void> _cancelVerification() async {
    _code.clear();
    _recovery = false;
    await _run(ref.read(appControllerProvider).cancelAuthentication);
  }

  @override
  Widget build(BuildContext context) {
    final c = ref.watch(appControllerProvider),
        verifying = c.needsTwoFactor || c.needsOAuthVerification;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final tips = localizedServerContent(
      c.config['loginPageTips'],
      c.languageTag,
    );
    final provider = oauthProviderName(c.config, c.languageTag);
    final oauthLabel = provider.isNotEmpty
        ? c.t(
            'format.misc.loginWithCustomProvider',
            parameters: {'name': provider},
          )
        : c.t(
            c.config['oauth2Provider'] == 'oidc'
                ? 'Log in with Connect ID'
                : 'Log in with OAuth 2.0',
          );
    final page = widget.signup
        ? ListView(
            padding: const EdgeInsets.symmetric(vertical: 16),
            children: [
              Card(
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: _credentials(c),
                ),
              ),
              Section(
                children: [
                  ItemRow(
                    c.t('Language'),
                    value:
                        _languages
                            .where((v) => v['id'] == c.languageTag)
                            .firstOrNull?['name']
                            ?.toString() ??
                        c.languageTag,
                    onTap: _language,
                  ),
                  ItemRow(
                    c.t('Default Currency'),
                    value: '${c.t('currency.name.$_currency')} $_currency',
                    onTap: () async {
                      final result = await choose<String>(
                        context,
                        c.t('Default Currency'),
                        {
                          for (final currency in _currencies)
                            '${currency['code']}':
                                '${c.t('currency.name.${currency['code']}')} ${currency['code']}',
                        },
                        selected: _currency,
                      );
                      if (result != null && mounted) {
                        setState(() => _currency = result);
                      }
                    },
                  ),
                  ItemRow(
                    c.t('First Day of Week'),
                    value: c.t(
                      [
                        'Sunday',
                        'Monday',
                        'Tuesday',
                        'Wednesday',
                        'Thursday',
                        'Friday',
                        'Saturday',
                      ][_firstDayOfWeek],
                    ),
                    onTap: () async {
                      final result = await choose<int>(
                        context,
                        c.t('First Day of Week'),
                        {
                          for (var day = 0; day < 7; day++)
                            day: c.t(
                              [
                                'Sunday',
                                'Monday',
                                'Tuesday',
                                'Wednesday',
                                'Thursday',
                                'Friday',
                                'Saturday',
                              ][day],
                            ),
                        },
                        selected: _firstDayOfWeek,
                      );
                      if (result != null && mounted) {
                        setState(() => _firstDayOfWeek = result);
                      }
                    },
                  ),
                ],
              ),
              Section(
                children: [
                  ItemRow(
                    c.t('Use preset transaction categories'),
                    onTap: _presetPreview,
                    trailing: CupertinoSwitch(
                      value: _usePresetCategories,
                      onChanged: (value) =>
                          setState(() => _usePresetCategories = value),
                    ),
                  ),
                ],
              ),
              _errorMessage(c),
              _button(c),
            ],
          )
        : LayoutBuilder(
            builder: (context, bounds) {
              final fixedFooter = bounds.maxHeight >= 630;
              return Stack(
                children: [
                  Positioned.fill(
                    child: CustomPaint(painter: _LoginBackground(dark)),
                  ),
                  SingleChildScrollView(
                    padding: EdgeInsets.only(
                      top: (bounds.maxHeight * .208).clamp(24, 180),
                      bottom: fixedFooter ? 100 : 12,
                    ),
                    child: Column(
                      children: [
                        Container(
                          width: 76,
                          height: 76,
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(12),
                            boxShadow: [
                              BoxShadow(
                                color: const Color(0xffd43f3f)
                                    .withValues(alpha: .2),
                                blurRadius: 28,
                                offset: const Offset(0, 12),
                              ),
                            ],
                          ),
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(12),
                            child: Image.asset(
                              'assets/logo.png',
                              width: 76,
                              height: 76,
                            ),
                          ),
                        ),
                        Padding(
                          padding: const EdgeInsets.only(top: 10, bottom: 24),
                          child: Text(
                            c.t('global.app.title'),
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                              fontSize: 28,
                              fontWeight: FontWeight.w600,
                              height: 1.3,
                            ),
                          ),
                        ),
                        if (tips.isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
                            child: Text(
                              tips,
                              style: TextStyle(
                                fontSize: 14,
                                color: CupertinoColors.secondaryLabel
                                    .resolveFrom(context),
                              ),
                            ),
                          ),
                        Container(
                          margin: const EdgeInsets.symmetric(horizontal: 16),
                          padding: const EdgeInsets.only(top: 8, bottom: 16),
                          decoration: BoxDecoration(
                            color: dark
                                ? const Color(0xff1c1c1e).withValues(alpha: .55)
                                : Colors.white.withValues(alpha: .8),
                            border: Border.all(
                              color: const Color(0xffd43f3f)
                                  .withValues(alpha: .18),
                            ),
                            borderRadius: BorderRadius.circular(24),
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black.withValues(alpha: .06),
                                blurRadius: 24,
                                offset: const Offset(0, 8),
                              ),
                            ],
                          ),
                          child: Column(
                            children: [
                              _credentials(c, verifying: verifying),
                              if (!verifying)
                                Padding(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 16,
                                    vertical: 4,
                                  ),
                                  child: Wrap(
                                    alignment: WrapAlignment.spaceBetween,
                                    spacing: 16,
                                    runSpacing: 4,
                                    children: [
                                      CupertinoButton(
                                        padding: EdgeInsets.zero,
                                        minimumSize: const Size(0, 32),
                                        onPressed: c.serverUrl.isEmpty
                                            ? null
                                            : () => launchUrl(
                                                Uri.parse(
                                                  '${c.serverUrl}desktop/',
                                                ),
                                                mode: LaunchMode
                                                    .externalApplication,
                                              ),
                                        child: Text(
                                          c.t('Switch to Desktop Version'),
                                          style: const TextStyle(fontSize: 12),
                                        ),
                                      ),
                                      if (c.config['enableUserForgetPassword'] !=
                                          false)
                                        CupertinoButton(
                                          padding: EdgeInsets.zero,
                                          minimumSize: const Size(0, 32),
                                          onPressed: _busy
                                              ? null
                                              : () => _emailAction(
                                                  'forget_password/request.json',
                                                  'Forget Password?',
                                                ),
                                          child: Text(
                                            c.t('Forget Password?'),
                                            style: const TextStyle(
                                              fontSize: 12,
                                            ),
                                          ),
                                        ),
                                    ],
                                  ),
                                ),
                              _errorMessage(c),
                              if (verifying ||
                                  c.config['enableInternalAuth'] != false)
                                _button(c, verifying: verifying),
                              if (c.needsTwoFactor)
                                CupertinoButton(
                                  onPressed: () =>
                                      setState(() => _recovery = !_recovery),
                                  child: Text(
                                    c.t(
                                      _recovery
                                          ? 'Use a passcode'
                                          : 'Use a recovery code',
                                    ),
                                  ),
                                ),
                              if (verifying)
                                CupertinoButton(
                                  onPressed: _busy ? null : _cancelVerification,
                                  child: Text(c.t('Cancel')),
                                ),
                              if (c.authenticated && c.needsReauthentication)
                                CupertinoButton(
                                  onPressed: c.continueOffline,
                                  child: Text(c.t('Continue offline')),
                                ),
                              if (!verifying) ...[
                                if (c.config['enableOAuth2Login'] == true)
                                  Padding(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 16,
                                      vertical: 8,
                                    ),
                                    child: SizedBox(
                                      width: double.infinity,
                                      child: OutlinedButton(
                                        onPressed: _busy
                                            ? null
                                            : () => _run(c.startOAuth),
                                        style: OutlinedButton.styleFrom(
                                          shape: RoundedRectangleBorder(
                                            borderRadius: BorderRadius.circular(
                                              14,
                                            ),
                                          ),
                                        ),
                                        child: Text(oauthLabel),
                                      ),
                                    ),
                                  ),
                                if (c.config['enableUserRegister'] != false)
                                  Padding(
                                    padding: const EdgeInsets.only(top: 8),
                                    child: Wrap(
                                      alignment: WrapAlignment.center,
                                      crossAxisAlignment:
                                          WrapCrossAlignment.center,
                                      children: [
                                        Text(
                                          c.t("Don't have an account?"),
                                          style: const TextStyle(
                                            fontSize: 13,
                                            color:
                                                CupertinoColors.secondaryLabel,
                                          ),
                                        ),
                                        CupertinoButton(
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 4,
                                          ),
                                          minimumSize: const Size(0, 32),
                                          onPressed: _busy
                                              ? null
                                              : () => context.push('/signup'),
                                          child: Text(
                                            c.t('Create an account'),
                                            style: const TextStyle(
                                              fontSize: 13,
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                if (c.config['enableUserVerifyEmail'] == true &&
                                    (_error != null || c.error != null))
                                  CupertinoButton(
                                    onPressed: _busy
                                        ? null
                                        : () => _emailAction(
                                            'verify_email/resend.json',
                                            'Resend verification email',
                                            password: true,
                                          ),
                                    child: Text(
                                      c.t('Resend verification email'),
                                    ),
                                  ),
                              ],
                            ],
                          ),
                        ),
                        if (!fixedFooter) _footer(c),
                      ],
                    ),
                  ),
                  if (fixedFooter)
                    Align(alignment: Alignment.bottomCenter, child: _footer(c)),
                ],
              );
            },
          );
    return PopScope(
      canPop: !verifying,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop && verifying && !_busy) _cancelVerification();
      },
      child: Scaffold(
        backgroundColor: widget.signup
            ? null
            : dark
            ? Colors.black
            : Colors.white,
        appBar: widget.signup
            ? AppBar(
                title: Text(c.t('Sign Up')),
                actions: [
                  CupertinoButton(
                    onPressed: _busy ? null : _submit,
                    child: const Icon(CupertinoIcons.check_mark),
                  ),
                ],
              )
            : null,
        body: SafeArea(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 520),
              child: AutofillGroup(
                child: Form(key: _form, child: page),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _emailAction(
    String path,
    String title, {
    bool password = false,
    String? verifiedEmail,
    String? hint,
  }) async {
    final c = ref.read(appControllerProvider);
    final email = TextEditingController(text: verifiedEmail);
    final secret = TextEditingController();
    var sending = false;
    String? error;
    final accepted = await showCupertinoModalPopup<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, update) {
          Future<void> send() async {
            update(() {
              sending = true;
              error = null;
            });
            try {
              final body = emailActionRequest(
                email.text,
                password: password ? secret.text : null,
              );
              if (c.serverUrl.isEmpty) await c.connect(_server.text);
              await c.post(path, body);
              if (ctx.mounted) Navigator.pop(ctx, true);
            } catch (failure) {
              if (ctx.mounted) update(() => error = c.errorText(failure));
            } finally {
              if (ctx.mounted) update(() => sending = false);
            }
          }

          final media = MediaQuery.of(ctx);
          return PopScope(
            canPop: !sending,
            child: Padding(
              padding: EdgeInsets.only(bottom: media.viewInsets.bottom),
              child: CupertinoPopupSurface(
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                    maxHeight:
                        media.size.height -
                        media.viewInsets.bottom -
                        media.padding.top,
                  ),
                  child: SafeArea(
                    top: false,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        CupertinoNavigationBar(
                          automaticallyImplyLeading: false,
                          middle: Text(
                            c.t(title),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          leading: CupertinoButton(
                            padding: EdgeInsets.zero,
                            onPressed: sending
                                ? null
                                : () => Navigator.pop(ctx, false),
                            child: Text(c.t('Cancel')),
                          ),
                          trailing: CupertinoButton(
                            padding: EdgeInsets.zero,
                            onPressed: sending ? null : send,
                            child: sending
                                ? const CupertinoActivityIndicator()
                                : Text(c.t('Send')),
                          ),
                        ),
                        Flexible(
                          child: SingleChildScrollView(
                            padding: const EdgeInsets.all(20),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                if (hint != null)
                                  Padding(
                                    padding: const EdgeInsets.only(bottom: 16),
                                    child: Text(hint),
                                  ),
                                if (verifiedEmail == null)
                                  CupertinoTextField(
                                    controller: email,
                                    keyboardType: TextInputType.emailAddress,
                                    placeholder: c.t('E-mail'),
                                    enabled: !sending,
                                    padding: const EdgeInsets.all(12),
                                  ),
                                if (password)
                                  Padding(
                                    padding: const EdgeInsets.only(top: 12),
                                    child: CupertinoTextField(
                                      controller: secret,
                                      obscureText: true,
                                      placeholder: c.t('Password'),
                                      enabled: !sending,
                                      padding: const EdgeInsets.all(12),
                                    ),
                                  ),
                                if (error != null)
                                  Padding(
                                    padding: const EdgeInsets.only(top: 16),
                                    child: Text(
                                      error!,
                                      style: const TextStyle(
                                        color: CupertinoColors.destructiveRed,
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
    if (accepted == true && mounted) {
      await showCupertinoDialog<void>(
        context: context,
        builder: (ctx) => CupertinoAlertDialog(
          content: Text(
            c.t(
              password
                  ? 'Validation email has been sent'
                  : 'Password reset email has been sent',
            ),
          ),
          actions: [
            CupertinoDialogAction(
              onPressed: () => Navigator.pop(ctx),
              child: Text(c.t('OK')),
            ),
          ],
        ),
      );
    }
    email.dispose();
    secret.dispose();
  }
}

class UnlockPage extends ConsumerStatefulWidget {
  const UnlockPage({super.key});
  @override
  ConsumerState<UnlockPage> createState() => _UnlockPageState();
}

class _UnlockPageState extends ConsumerState<UnlockPage> {
  final _pin = TextEditingController();
  String? _error;
  bool _busy = false;
  @override
  void dispose() {
    _pin.dispose();
    super.dispose();
  }

  Future<void> _unlock({bool biometric = false}) async {
    setState(() => _busy = true);
    try {
      final ok = await ref
          .read(appControllerProvider)
          .unlock(pin: biometric ? null : _pin.text, biometric: biometric);
      if (!ok && mounted) setState(() => _error = 'Incorrect PIN');
    } catch (e) {
      if (mounted) {
        setState(() => _error = ref.read(appControllerProvider).errorText(e));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = ref.watch(appControllerProvider);
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 380),
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(CupertinoIcons.lock, size: 64),
                  const SizedBox(height: 24),
                  Text(
                    c.t('Unlock'),
                    style: Theme.of(context).textTheme.headlineMedium,
                  ),
                  TextField(
                    controller: _pin,
                    obscureText: true,
                    keyboardType: TextInputType.number,
                    autofocus: true,
                    maxLength: 12,
                    decoration: const InputDecoration(
                      labelText: 'PIN',
                      counterText: '',
                    ),
                    onSubmitted: (_) => _unlock(),
                  ),
                  if (_error != null)
                    Text(
                      c.t(_error!),
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  const SizedBox(height: 16),
                  FilledButton(
                    onPressed: _busy ? null : _unlock,
                    child: Text(c.t('Unlock')),
                  ),
                  if (c.settings['applicationLockWebAuthn'] == true)
                    TextButton(
                      onPressed: _busy ? null : () => _unlock(biometric: true),
                      child: Text(c.t('Use biometrics')),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _LoginBackground extends CustomPainter {
  const _LoginBackground(this.dark);
  final bool dark;
  @override
  void paint(Canvas canvas, Size size) {
    const brand = Color(0xffd43f3f);
    void glow(
      Offset center,
      double radius,
      List<double> opacity,
      List<double> stops,
    ) {
      final paint = Paint()
        ..shader = RadialGradient(
          colors: opacity.map((a) => brand.withValues(alpha: a)).toList(),
          stops: stops,
        ).createShader(Rect.fromCircle(center: center, radius: radius));
      canvas.drawCircle(center, radius, paint);
    }

    glow(
      Offset(size.width * .5, size.height * .16),
      360,
      dark ? [.16, .06, 0] : [.06, .02, 0],
      [0, .5, 1],
    );
    glow(
      Offset(size.width - 18, -18),
      110,
      dark ? [.12, .12, 0] : [.08, .08, 0],
      [0, 104 / 110, 1],
    );
    glow(
      Offset(9, size.height + 11),
      85,
      dark ? [.08, .08, 0] : [.05, .05, 0],
      [0, 80 / 85, 1],
    );
  }

  @override
  bool shouldRepaint(_LoginBackground oldDelegate) => dark != oldDelegate.dark;
}
