String localizedServerContent(Object? content, String languageTag) {
  if (content is! Map) return '';
  final localized = content[languageTag];
  if (localized is String) return localized;
  return content['default'] is String ? content['default'] as String : '';
}

Map<String, dynamic> emailActionRequest(String email, {String? password}) {
  if (email.trim().isEmpty) {
    throw const FormatException('Email address cannot be blank');
  }
  if (password != null && password.isEmpty) {
    throw const FormatException('Current password cannot be blank');
  }
  return {'email': email.trim(), 'password': ?password};
}

String oauthProviderName(Map<String, dynamic> config, String languageTag) {
  if (config['oauth2Provider'] == 'oidc') {
    return localizedServerContent(
      config['oauth2CustomDisplayNames'],
      languageTag,
    );
  }
  return const {
        'nextcloud': 'Nextcloud',
        'gitea': 'Gitea',
        'github': 'GitHub',
      }[config['oauth2Provider']] ??
      '';
}

/// Maps the original presets to the existing registration API schema.
List<Map<String, dynamic>> registrationCategories(
  Map<String, dynamic> presets,
  String Function(String) translate,
) => [
  for (final entry in presets.entries)
    for (final category in entry.value as List)
      {
        'name': translate('category.${category['name']}'),
        'type': int.parse(entry.key),
        'icon': category['categoryIconId'],
        'iconType': 0,
        'color': category['color'],
        'subCategories': [
          for (final sub in category['subCategories'] as List)
            {
              'name': translate('category.${sub['name']}'),
              'type': int.parse(entry.key),
              'icon': sub['categoryIconId'],
              'iconType': 0,
              'color': sub['color'],
            },
        ],
      },
];

Map<String, dynamic> registrationRequest({
  required String username,
  required String password,
  required String confirmation,
  required String email,
  required String nickname,
  required String language,
  required String currency,
  required int firstDayOfWeek,
  required List<Map<String, dynamic>> categories,
}) {
  if (username.trim().isEmpty) {
    throw const FormatException('Username cannot be blank');
  }
  if (email.trim().isEmpty) {
    throw const FormatException('Email address cannot be blank');
  }
  if (nickname.trim().isEmpty) {
    throw const FormatException('Nickname cannot be blank');
  }
  if (currency.isEmpty) {
    throw const FormatException('Default currency cannot be blank');
  }
  if (password.length < 6 || password.length > 128) {
    throw const FormatException('Your password, at least 6 characters');
  }
  if (password != confirmation) {
    throw const FormatException(
      'Password and password confirmation do not match',
    );
  }
  if (firstDayOfWeek < 0 || firstDayOfWeek > 6) {
    throw const FormatException('Invalid first day of week');
  }
  return {
    'username': username.trim(),
    'password': password,
    'email': email.trim(),
    'nickname': nickname.trim(),
    'language': language,
    'defaultCurrency': currency,
    'firstDayOfWeek': firstDayOfWeek,
    'categories': categories,
  };
}
