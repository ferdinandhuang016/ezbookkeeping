import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';

import '../../core/formatting.dart';
import '../../ui/common.dart';
import 'settings_support.dart';

DateTime fiscalYearPickerDate(int value) {
  final month = (value >> 8).clamp(1, 12);
  return DateTime(
    2025,
    month,
    (value & 255).clamp(1, DateTime(2025, month + 1, 0).day),
  );
}

RecordData preserveProfileEdits(
  RecordData current,
  RecordData original,
  RecordData refreshed,
) => {
  ...original,
  ...refreshed,
  for (final entry in current.entries)
    if (entry.value != original[entry.key]) entry.key: entry.value,
};

class ProfilePage extends ConsumerStatefulWidget {
  const ProfilePage({super.key});
  @override
  ConsumerState<ProfilePage> createState() => _ProfileState();
}

class _ProfileState extends SettingsState<ProfilePage> {
  late RecordData profile = {...app.user};
  RecordData original = {};
  List<RecordData> currencies = [];
  String password = '', confirmation = '';
  bool loaded = false;
  @override
  void initState() {
    super.initState();
    Future.microtask(
      () => run(() async {
        currencies = records(
          jsonDecode(
            await rootBundle.loadString('assets/reference/currencies.json'),
          ),
        );
        await load();
      }),
    );
  }

  Future<void> load() async {
    final result = await app.get('v1/users/profile/get.json');
    profile = Map<String, dynamic>.from(result);
    await app.updateUser(profile);
    original = {...profile};
    loaded = true;
  }

  Widget field(String key, String label, {bool secret = false}) => InputRow(
    t(label),
    value: string(profile[key]),
    secret: secret,
    onChanged: (v) => setState(() => profile[key] = v),
  );
  Widget choice(String key, String label, List<RecordData> items) => ItemRow(
    t(label),
    value: t(optionName(items, profile[key])),
    onTap: () async {
      final value = await choose<String>(context, t(label), {
        for (final item in items) string(item['id']): t(string(item['name'])),
      }, selected: string(profile[key]));
      if (value != null) {
        setState(
          () => profile[key] = items.firstWhere(
            (e) => string(e['id']) == value,
          )['id'],
        );
      }
    },
  );
  Widget enumChoice(
    String key,
    String label,
    String group, {
    bool languageDefault = true,
  }) => choice(
    key,
    label,
    settingOptions(group, defaultOption: languageDefault).map((item) {
      if (!const [
        'calendarDisplayType',
        'dateDisplayType',
        'longDateFormat',
        'shortDateFormat',
        'longTimeFormat',
        'shortTimeFormat',
        'fiscalYearFormat',
        'numeralSystem',
        'decimalSeparator',
        'digitGroupingSymbol',
        'digitGrouping',
      ].contains(key)) {
        return item;
      }
      final preview = app.formatter
          .copyWith(user: profile)
          .profileOptionPreview(
            key,
            number(item['id']),
            DateTime(2026, 9, 15, 13, 24, 56),
          );
      return {...item, 'name': '${t(string(item['name']))} · $preview'};
    }).toList(),
  );
  Future<void> save() async {
    await run(() async {
      if (string(profile['email']).trim().isEmpty ||
          string(profile['nickname']).trim().isEmpty) {
        throw StateError(t('Email address and nickname cannot be blank'));
      }
      if (password != confirmation) {
        throw StateError(t('Password and password confirmation do not match'));
      }
      final body = <String, dynamic>{
        for (final key in [
          'email',
          'nickname',
          'defaultAccountId',
          'useLastReconciledTime',
          'transactionEditScope',
          'language',
          'defaultCurrency',
          'firstDayOfWeek',
          'fiscalYearStart',
          'calendarDisplayType',
          'dateDisplayType',
          'longDateFormat',
          'shortDateFormat',
          'longTimeFormat',
          'shortTimeFormat',
          'fiscalYearFormat',
          'currencyDisplayType',
          'numeralSystem',
          'decimalSeparator',
          'digitGroupingSymbol',
          'digitGrouping',
          'coordinateDisplayType',
          'expenseAmountColor',
          'incomeAmountColor',
        ])
          if (profile[key] != original[key]) key: profile[key],
      };
      if (password.isNotEmpty) {
        body['password'] = password;
        if (profile['noPassword'] != true) {
          final old = await prompt(
            context,
            t(
              'Please enter your current password when modifying your password',
            ),
            secret: true,
          );
          if (old == null) return;
          body['oldPassword'] = old;
        }
      }
      if (body.isEmpty) throw StateError(t('Nothing has been modified'));
      // The existing profile API treats an omitted language as an empty one.
      body['language'] = string(profile['language']);
      await app.post('v1/users/profile/update.json', body);
      password = '';
      confirmation = '';
      await load();
      if (mounted) {
        await inform(context, t('Your profile has been successfully updated'));
      }
    });
  }

  Future<void> avatar() async {
    final action = await choose<String>(context, t('Avatar'), {
      'photo': t('Choose Photo'),
      'camera': t('Take Photo'),
      'remove': t('Remove Avatar'),
    });
    if (action == null) return;
    await run(() async {
      dynamic result;
      if (action == 'remove') {
        result = await app.post('v1/users/avatar/remove.json', {});
      } else {
        final image = await ImagePicker().pickImage(
          source: action == 'camera' ? ImageSource.camera : ImageSource.gallery,
          maxWidth: 512,
          maxHeight: 512,
          imageQuality: 90,
        );
        if (image == null) return;
        result = await app.api.post(
          'v1/users/avatar/update.json',
          FormData.fromMap({
            'avatar': await MultipartFile.fromFile(image.path),
          }),
        );
      }
      final refreshed = Map<String, dynamic>.from(result);
      profile = preserveProfileEdits(profile, original, refreshed);
      original = {...original, ...refreshed};
      await app.updateUser({...app.user, ...refreshed});
    });
  }

  Future<void> fiscalYear() async {
    final value = number(profile['fiscalYearStart']);
    final current = fiscalYearPickerDate(value);
    final result = await pickDate(
      context,
      t('Fiscal Year Start Date'),
      current,
      time: false,
    );
    if (result != null) {
      if (result.month == 2 && result.day == 29) {
        if (mounted) {
          await inform(context, t('Fiscal year cannot start on leap day'));
        }
        return;
      }
      setState(
        () => profile['fiscalYearStart'] = (result.month << 8) | result.day,
      );
    }
  }

  @override
  Widget buildPage(BuildContext context) => NativePage(
    title: t('User Profile'),
    busy: busy,
    trailing: iconButton(CupertinoIcons.check_mark, t('Save'), save),
    children: [
      Section(
        children: [
          ItemRow(t('Username'), value: string(profile['username'])),
          ItemRow(t('Avatar'), onTap: avatar),
          field('email', 'Email Address'),
          if (app.config['enableUserVerifyEmail'] == true)
            ItemRow(
              t('Email Verification'),
              value: t(
                profile['emailVerified'] == true ? 'Verified' : 'Unverified',
              ),
              onTap: profile['emailVerified'] == true
                  ? null
                  : () => run(() async {
                      await app.post('v1/users/verify_email/resend.json', {});
                    }, success: true),
            ),
          field('nickname', 'Nickname'),
          if (app.config['enableInternalAuth'] != false) ...[
            InputRow(
              t('Password'),
              value: password,
              secret: true,
              onChanged: (v) => setState(() => password = v),
            ),
            InputRow(
              t('Confirm Password'),
              value: confirmation,
              secret: true,
              onChanged: (v) => setState(() => confirmation = v),
            ),
          ],
        ],
      ),
      Section(
        title: t('Language & Region'),
        children: [
          choice(
            'language',
            'Language',
            records(settingsReference['languages']),
          ),
          choice(
            'defaultCurrency',
            'Default Currency',
            currencies
                .map(
                  (e) => {
                    'id': e['code'],
                    'name': '${e['code']} · ${t(string(e['name']))}',
                  },
                )
                .toList(),
          ),
          enumChoice(
            'firstDayOfWeek',
            'First Day of Week',
            'WeekDay',
            languageDefault: false,
          ),
          ItemRow(
            t('Fiscal Year Start Date'),
            value:
                '${number(profile['fiscalYearStart']) >> 8}-${number(profile['fiscalYearStart']) & 255}',
            onTap: fiscalYear,
          ),
          enumChoice(
            'calendarDisplayType',
            'Calendar Display Type',
            'CalendarDisplayType',
          ),
          enumChoice('dateDisplayType', 'Date Display Type', 'DateDisplayType'),
          enumChoice('longDateFormat', 'Long Date Format', 'LongDateFormat'),
          enumChoice('shortDateFormat', 'Short Date Format', 'ShortDateFormat'),
          enumChoice('longTimeFormat', 'Long Time Format', 'LongTimeFormat'),
          enumChoice('shortTimeFormat', 'Short Time Format', 'ShortTimeFormat'),
          enumChoice(
            'fiscalYearFormat',
            'Fiscal Year Format',
            'FiscalYearFormat',
          ),
          choice(
            'currencyDisplayType',
            'Currency Display Mode',
            currencyDisplayOptions(app.formatter.copyWith(user: profile)),
          ),
          enumChoice('numeralSystem', 'Numeral System', 'NumeralSystem'),
          enumChoice(
            'decimalSeparator',
            'Decimal Separator',
            'DecimalSeparator',
          ),
          enumChoice(
            'digitGroupingSymbol',
            'Digit Grouping Symbol',
            'DigitGroupingSymbol',
          ),
          enumChoice('digitGrouping', 'Digit Grouping', 'DigitGroupingType'),
          enumChoice(
            'coordinateDisplayType',
            'Geographic Location Format',
            'CoordinateDisplayType',
          ),
        ],
      ),
      Section(
        title: t('Extend'),
        children: [
          choice(
            'defaultAccountId',
            'Default Account',
            leafAccounts(app)
                .map((e) => {'id': e['id'], 'name': e['name']})
                .toList(),
          ),
          ItemRow(
            t('Use Last Reconciled Time'),
            trailing: CupertinoSwitch(
              value: profile['useLastReconciledTime'] == true,
              activeTrackColor: brand,
              onChanged: number(profile['transactionEditScope']) == 7
                  ? null
                  : (v) => setState(() => profile['useLastReconciledTime'] = v),
            ),
          ),
          choice(
            'transactionEditScope',
            'Editable Transaction Range',
            settingOptions('TransactionEditScopeType')
                .where(
                  (item) =>
                      item['needLastReconciledTime'] != true ||
                      profile['useLastReconciledTime'] == true ||
                      number(profile['transactionEditScope']) == 7,
                )
                .toList(),
          ),
          choice('expenseAmountColor', 'Expense Amount Color', colorOptions),
          choice('incomeAmountColor', 'Income Amount Color', colorOptions),
        ],
      ),
      actionButton(
        t('Reset'),
        () => setState(() {
          profile = {...original};
          password = '';
          confirmation = '';
        }),
      ),
    ],
  );
}

const colorOptions = <RecordData>[
  {'id': 0, 'name': 'Default'},
  {'id': 1, 'name': 'Green'},
  {'id': 2, 'name': 'Red'},
  {'id': 3, 'name': 'Yellow'},
  {'id': 4, 'name': 'Text Color'},
];
List<RecordData> currencyDisplayOptions(BookkeepingFormatter formatter) => [
  {'id': 0, 'name': 'Language Default'},
  for (var mode = 1; mode <= 11; mode++)
    {
      'id': mode,
      'name': formatter
          .copyWith(user: {...formatter.user, 'currencyDisplayType': mode})
          .amount(12345),
    },
];
