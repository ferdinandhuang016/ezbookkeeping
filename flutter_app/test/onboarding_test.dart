import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ezbookkeeping/core/formatting.dart';
import 'package:ezbookkeeping/core/onboarding.dart';

void main() {
  test(
    'email actions validate before transport and retain original password',
    () {
      expect(emailActionRequest(' fixture@example.test '), {
        'email': 'fixture@example.test',
      });
      expect(
        emailActionRequest(' fixture@example.test ', password: ' secret '),
        {'email': 'fixture@example.test', 'password': ' secret '},
      );
      expect(() => emailActionRequest(' '), throwsFormatException);
      expect(
        () => emailActionRequest('fixture@example.test', password: ''),
        throwsFormatException,
      );
    },
  );
  test(
    'server tips and OIDC names follow the exact locale then default contract',
    () {
      const content = {'default': 'Default', 'zh-Hans': '简体', 'de': ''};
      expect(localizedServerContent(content, 'zh-Hans'), '简体');
      expect(localizedServerContent(content, 'zh-Hant'), 'Default');
      expect(localizedServerContent(content, 'de'), '');
      expect(
        localizedServerContent({'fr': 4, 'default': 'Default'}, 'fr'),
        'Default',
      );
      expect(localizedServerContent(null, 'en'), '');
      expect(
        oauthProviderName({
          'oauth2Provider': 'oidc',
          'oauth2CustomDisplayNames': content,
        }, 'zh-Hans'),
        '简体',
      );
      expect(oauthProviderName({'oauth2Provider': 'oidc'}, 'en'), '');
      expect(
        oauthProviderName({'oauth2Provider': 'nextcloud'}, 'en'),
        'Nextcloud',
      );
      expect(oauthProviderName({'oauth2Provider': 'gitea'}, 'en'), 'Gitea');
      expect(oauthProviderName({'oauth2Provider': 'github'}, 'en'), 'GitHub');
      expect(oauthProviderName({'oauth2Provider': 'other'}, 'en'), '');
      final locales = Directory('assets/locales')
          .listSync()
          .whereType<File>()
          .where((file) => file.path.endsWith('.json'));
      expect(locales.length, 21);
      for (final file in locales) {
        final messages = jsonDecode(file.readAsStringSync());
        for (final key in [
          'Cancel',
          'Log in with Connect ID',
          'Log in with OAuth 2.0',
          'format.misc.loginWithCustomProvider',
          'token is expired',
          'Change Language',
          'Verify your email',
          'format.misc.accountActivationAndResendValidationEmailTip',
          'format.misc.resendValidationEmailTip',
          'Validation email has been sent',
          'Password reset email has been sent',
        ]) {
          final Object? value =
              messages[key] ??
              messages['error']?[key] ??
              key
                  .split('.')
                  .fold<Object?>(
                    messages,
                    (node, part) => node is Map ? node[part] : null,
                  );
          expect(value, isA<String>(), reason: '${file.path}: $key');
        }
      }
    },
  );
  Map<String, dynamic> request({
    String password = 'abcdef',
    String confirmation = 'abcdef',
    String nickname = 'Tester',
    int firstDay = 1,
  }) => registrationRequest(
    username: ' native-test ',
    password: password,
    confirmation: confirmation,
    email: ' tester@example.test ',
    nickname: nickname,
    language: 'zh-Hans',
    currency: 'CNY',
    firstDayOfWeek: firstDay,
    categories: [],
  );
  test('registration payload preserves selected locale/currency/week and empty preset list', () {
    expect(request(), {
      'username': 'native-test',
      'password': 'abcdef',
      'email': 'tester@example.test',
      'nickname': 'Tester',
      'language': 'zh-Hans',
      'defaultCurrency': 'CNY',
      'firstDayOfWeek': 1,
      'categories': [],
    });
    expect(() => request(password: '12345'), throwsFormatException);
    expect(() => request(confirmation: 'different'), throwsFormatException);
    expect(() => request(nickname: ' '), throwsFormatException);
    expect(() => request(firstDay: 7), throwsFormatException);
  });
  test('registration includes all original 17 parent and 63 child presets in the chosen language', () {
    final presets = jsonDecode(
      File('assets/reference/category_presets.json').readAsStringSync(),
    ) as Map<String, dynamic>;
    final messages = jsonDecode(
      File('assets/locales/zh_Hans.json').readAsStringSync(),
    );
    final result = registrationCategories(
      presets,
      (key) => translateMessage(messages, {}, key),
    );
    expect(result.length, 17);
    expect(result.expand((v) => v['subCategories'] as List).length, 63);
    expect(result.first['name'], '职业收入');
    expect(result.first['icon'], '2000');
    expect(result.first['iconType'], 0);
    expect(result.first['type'], 1);
    expect(result.where((v) => v['type'] == 2).length, 11);
    expect(result.where((v) => v['type'] == 3).length, 3);
    expect(result.first['subCategories'][0], {
      'name': '工资收入',
      'type': 1,
      'icon': '2010',
      'iconType': 0,
      'color': 'ff6b22',
    });
    expect(presets['1'][0].containsKey('icon'), isFalse);
  });
}
