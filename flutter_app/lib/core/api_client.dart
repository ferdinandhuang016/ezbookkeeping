import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:timezone/data/latest.dart' as time_data;
import 'package:timezone/timezone.dart' as tz;

typedef JsonMap = Map<String, dynamic>;

class ApiException implements Exception {
  const ApiException(this.message, {this.code, this.status, this.context});
  final String message;
  final int? code;
  final int? status;
  final JsonMap? context;
  bool get unauthorized =>
      status == 401 || const [202001, 202002, 202003].contains(code);
  @override
  String toString() => message;
}

/// Keep the deployment prefix: resolving `/api` would accidentally discard it.
String normalizeServerUrl(String value) {
  final uri = Uri.tryParse(value.trim());
  if (uri == null ||
      !const ['http', 'https'].contains(uri.scheme) ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty ||
      uri.hasQuery ||
      uri.hasFragment) {
    throw const FormatException(
      'Enter an HTTP or HTTPS server address without credentials, query or fragment',
    );
  }
  return '${uri.toString().replaceFirst(RegExp(r'/+$'), '')}/';
}

class ApiClient {
  ApiClient(String serverUrl, {Dio? transport})
    : serverUrl = normalizeServerUrl(serverUrl),
      dio = transport ?? Dio() {
    time_data.initializeTimeZones();
    dio.options = BaseOptions(
      baseUrl: '${this.serverUrl}api/',
      connectTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(seconds: 60),
      followRedirects: false,
      headers: {
        'Accept': 'application/json',
        'User-Agent': Platform.isAndroid
            ? 'DangguiExpense/1.0.0 (Linux; Android; Mobile) Flutter'
            : 'DangguiExpense/1.0.0 (${Platform.operatingSystem}) Flutter',
      },
    );
  }
  final String serverUrl;
  final Dio dio;
  final Set<Future<dynamic>> _activeRequests = {};
  Future<JsonMap>? _sessionRefresh;
  String? token;
  String language = Platform.localeName.replaceAll('_', '-');
  String timeZoneName = 'UTC';
  tz.Location get timeZone {
    try {
      return tz.getLocation(timeZoneName);
    } catch (_) {
      return tz.UTC;
    }
  }

  DateTime localDate(DateTime instant) => tz.TZDateTime.from(instant, timeZone);

  Options get options => Options(
    headers: {
      if (token != null) 'Authorization': 'Bearer $token',
      'Accept-Language': language,
      'X-Timezone-Offset': localDate(DateTime.now()).timeZoneOffset.inMinutes
          .toString(),
      'X-Timezone-Name': timeZoneName,
    },
  );

  String relativePath(String path) =>
      path.replaceFirst(RegExp(r'^/?api/'), '').replaceFirst(RegExp(r'^/'), '');

  Future<JsonMap> clientConfiguration() async {
    const upgrade =
        'Upgrade the server to a version supporting native synchronization protocol 1';
    dynamic result;
    try {
      result = await get('client/config.json');
    } on ApiException catch (e) {
      if (e.status == 404) throw StateError(upgrade);
      rethrow;
    }
    if (result is! Map || result['syncProtocolVersion'] != 1) {
      throw StateError(upgrade);
    }
    return Map<String, dynamic>.from(result);
  }

  Future<dynamic> get(String path, {JsonMap? query}) => _request(
    () => dio.get<dynamic>(
      relativePath(path),
      queryParameters: query,
      options: options,
    ),
  );
  Future<dynamic> post(
    String path,
    dynamic data, {
    CancelToken? cancelToken,
    Duration? receiveTimeout,
  }) => _request(
    () => dio.post<dynamic>(
      relativePath(path),
      data: data,
      options: options.copyWith(receiveTimeout: receiveTimeout),
      cancelToken: cancelToken,
    ),
  );
  Future<List<int>> download(String path, {JsonMap? query}) async =>
      List<int>.from(
        await authenticatedRequest<dynamic>(
          () => _unwrap(
            () => dio.get<dynamic>(
              relativePath(path),
              queryParameters: query,
              options: options.copyWith(
                responseType: ResponseType.bytes,
                receiveTimeout: const Duration(minutes: 5),
              ),
            ),
            download: true,
          ),
        ),
      );
  Future<T> authenticatedRequest<T>(Future<T> Function() send) async {
    if (_sessionRefresh != null) await _sessionRefresh;
    final pending = send();
    _activeRequests.add(pending);
    try {
      return await pending;
    } finally {
      _activeRequests.remove(pending);
    }
  }

  Future<dynamic> _request(Future<Response<dynamic>> Function() call) =>
      authenticatedRequest(() => _unwrap(call));

  Future<JsonMap> refreshSession({
    required Future<void> Function(String) saveToken,
  }) =>
      _sessionRefresh ??= _refreshSession(saveToken)
          .whenComplete(() => _sessionRefresh = null);

  Future<JsonMap> _refreshSession(
    Future<void> Function(String) saveToken,
  ) async {
    // Finish requests carrying the old token before rotating it. New requests
    // wait above until the replacement is durably stored and ready to use.
    await Future.wait(
      _activeRequests.toList().map((request) async {
        try {
          await request;
        } catch (_) {
          /* The caller receives its own error. */
        }
      }),
    );
    final result = Map<String, dynamic>.from(
      await _unwrap(
        () => dio.post<dynamic>(
          'v1/tokens/refresh.json',
          data: <String, dynamic>{},
          options: options,
        ),
      ),
    );
    final newToken = result['newToken'];
    if (newToken is String && newToken.isNotEmpty) {
      await saveToken(newToken);
      token = newToken;
      final oldTokenId = result['oldTokenId'];
      if (oldTokenId is String && oldTokenId.isNotEmpty) {
        try {
          await _unwrap(
            () => dio.post<dynamic>(
              'v1/tokens/revoke.json',
              data: {'tokenId': oldTokenId},
              options: options,
            ),
          );
        } catch (_) {
          /* A failed revocation must not discard the new session. */
        }
      }
    }
    return result;
  }

  dynamic _responseData(Response<dynamic>? response) {
    final data = response?.data;
    if (data is List<int> &&
        (response?.headers.value('content-type') ?? '').contains('json')) {
      try {
        return jsonDecode(utf8.decode(data));
      } on FormatException {
        return null;
      }
    }
    return data;
  }

  Future<dynamic> _unwrap(
    Future<Response<dynamic>> Function() call, {
    bool download = false,
  }) async {
    try {
      final response = await call();
      final data = _responseData(response);
      if (download && data is List<int>) return data;
      if (data is! Map || data['success'] != true) {
        throw ApiException(
          data is Map
              ? (data['errorMessage'] ?? 'Invalid server response').toString()
              : 'Invalid server response',
          code: data is Map ? data['errorCode'] as int? : null,
          status: response.statusCode,
          context: data is Map && data['context'] is Map
              ? JsonMap.from(data['context'])
              : null,
        );
      }
      return data['result'];
    } on DioException catch (e) {
      if (CancelToken.isCancel(e)) rethrow;
      final data = _responseData(e.response);
      throw ApiException(
        data is Map
            ? (data['errorMessage'] ?? e.message).toString()
            : (e.type == DioExceptionType.badCertificate
                  ? 'The server certificate is not trusted'
                  : 'Cannot connect to the server'),
        code: data is Map ? data['errorCode'] as int? : null,
        status: e.response?.statusCode,
        context: data is Map && data['context'] is Map
            ? JsonMap.from(data['context'])
            : null,
      );
    }
  }
}
