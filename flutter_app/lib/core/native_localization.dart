import 'package:flutter/services.dart';
import 'package:local_auth/local_auth.dart';

import 'api_client.dart';

/// Presentation-only conversion. The original exception remains available to
/// callers for retry, authentication and diagnostic handling.
String localizedErrorText(Object error, String Function(String) translate) {
  String messageText(String message) {
    var unwrapped = message;
    const wrappers = ['Bad state: ', 'FormatException: ', 'Exception: '];
    while (wrappers.any(unwrapped.startsWith)) {
      final prefix = wrappers.firstWhere(unwrapped.startsWith);
      unwrapped = unwrapped.substring(prefix.length);
    }
    return translate(unwrapped);
  }

  if (error is ApiException) return translate(error.message);
  if (error is StateError) return messageText(error.message);
  if (error is FormatException) {
    final prefix = error.message.isEmpty
        ? 'FormatException'
        : 'FormatException: ${error.message}';
    final suffix = error.toString().substring(prefix.length);
    final message = error.message.isEmpty ? 'An error occurred' : error.message;
    return '${messageText(message)}$suffix';
  }
  if (error is LocalAuthException) {
    final heading = translate(switch (error.code) {
      LocalAuthExceptionCode.userCanceled ||
      LocalAuthExceptionCode.systemCanceled => 'Authorization cancelled',
      LocalAuthExceptionCode.temporaryLockout ||
      LocalAuthExceptionCode.biometricLockout =>
        'Too many attempts. Please wait before trying again',
      _ => 'Biometric authentication is unavailable or was canceled',
    });
    final details = [
      if (error.description?.isNotEmpty == true) translate(error.description!),
      if (error.details != null) error.details.toString(),
    ].where((value) => value != heading).toList();
    return details.isEmpty ? heading : '$heading\n${details.join('\n')}';
  }
  if (error is PlatformException) {
    final message = error.message?.trim();
    final heading = translate(switch (error.code.toLowerCase()) {
      'camera_access_denied' ||
      'photo_access_denied' ||
      'read_external_storage_denied' ||
      'permission_denied' => 'Permission denied',
      'notavailable' ||
      'not_available' ||
      'notenrolled' ||
      'no_biometrics_enrolled' ||
      'no_biometrics_available' =>
        'Biometric authentication is unavailable or was canceled',
      'lockedout' ||
      'permanentlylockedout' ||
      'temporary_lockout' ||
      'biometric_lockout' =>
        'Too many attempts. Please wait before trying again',
      _ => 'An error occurred',
    });
    // Preserve unfamiliar platform messages and codes instead of replacing the
    // underlying cause with a generic failure.
    final detail = message == null || message.isEmpty
        ? error.code
        : translate(message);
    return [
      heading,
      if (detail != heading) detail,
      if (error.details != null) error.details.toString(),
    ].join('\n');
  }
  // Persisted errors may have been serialized before the UI receives them.
  return messageText(error.toString());
}
