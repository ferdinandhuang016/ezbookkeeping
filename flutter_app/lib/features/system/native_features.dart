import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show Factory, compute;
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../../core/cache_policy.dart';
import '../../ui/common.dart';
import 'amap_location.dart';
import 'map_contract.dart';
import 'recognition_contract.dart';

Future<RecordData?> recognizeTransaction(
  BuildContext context, {
  String? imagePath,
  bool clipboard = false,
  bool imageRecognition = false,
}) => Navigator.of(context).push<RecordData>(
  nativeRoute(
    context,
    builder: (_) => _RecognitionPage(
      imagePath: imagePath,
      clipboard: clipboard,
      imageRecognition: imageRecognition || imagePath != null,
    ),
  ),
);

class _RecognitionPage extends ConsumerStatefulWidget {
  const _RecognitionPage({
    this.imagePath,
    required this.clipboard,
    required this.imageRecognition,
  });
  final String? imagePath;
  final bool clipboard;
  final bool imageRecognition;
  @override
  ConsumerState<_RecognitionPage> createState() => _RecognitionState();
}

class _RecognitionState extends NativeState<_RecognitionPage> {
  String text = '';
  String? imagePath;
  bool loaded = false;
  CancelToken? cancel;
  RecordData? result;
  final preparedImages = <File>[];
  @override
  void initState() {
    super.initState();
    Future.microtask(
      () =>
          run(() async {
            if (widget.imagePath != null) {
              imagePath = await prepareImage(widget.imagePath!);
            }
            if (widget.clipboard) {
              text =
                  (await Clipboard.getData(Clipboard.kTextPlain))?.text ?? '';
              if (mounted) setState(() {});
            }
            loaded = true;
          }).then((_) async {
            if (!mounted) return;
            if (widget.clipboard &&
                app.settings['alwaysRequireConfirmationOfClipboardContentBeforeSubmission'] ==
                    false &&
                text.trim().isNotEmpty) {
              await recognize();
            }
          }),
    );
  }

  @override
  void dispose() {
    cancel?.cancel();
    for (final image in preparedImages) {
      unawaited(image.delete().catchError((_) => image));
    }
    super.dispose();
  }

  Future<void> pick(ImageSource source) async {
    await run(() async {
      final image = await ImagePicker().pickImage(source: source);
      if (image != null) {
        imagePath = await prepareImage(image.path);
        result = null;
      }
    });
  }

  Future<String> prepareImage(String path) async {
    final bytes = await compute(
      prepareRecognitionImage,
      await File(path).readAsBytes(),
    );
    final directory = await getTemporaryDirectory();
    final file = File(
      '${directory.path}/ai-recognition-${DateTime.now().microsecondsSinceEpoch}.jpg',
    );
    await file.writeAsBytes(bytes, flush: true);
    if (!mounted) {
      await file.delete();
      throw StateError('User Canceled');
    }
    preparedImages.add(file);
    return file.path;
  }

  Future<void> recognize() async {
    FocusManager.instance.primaryFocus?.unfocus();
    await run(() async {
      final image = widget.imageRecognition;
      if (app.config[image
              ? 'transactionFromAIImageRecognition'
              : 'transactionFromAITextRecognition'] !=
          true) {
        throw StateError(t('This feature is not enabled on the server'));
      }
      if (!image && text.trim().isEmpty) {
        throw StateError(t('Text cannot be blank'));
      }
      if (image && imagePath == null) return;
      cancel = CancelToken();
      result = null;
      final timeZone = app.api.timeZone;
      dynamic response;
      try {
        response = await app.api.post(
          image
              ? 'v1/llm/transactions/recognize_receipt_image.json'
              : 'v1/llm/transactions/recognize_text.json',
          image
              ? FormData.fromMap({
                  'image': await MultipartFile.fromFile(imagePath!),
                })
              : {'text': text},
          receiveTimeout: const Duration(minutes: 5),
          cancelToken: cancel,
        );
      } on DioException catch (error) {
        if (!CancelToken.isCancel(error)) rethrow;
        if (mounted) await inform(context, t('User Canceled'));
        return;
      } finally {
        cancel = null;
      }
      if (!mounted) return;
      result = recognizedTransaction(
        Map<String, dynamic>.from(response),
        timeZone,
      );
    });
  }

  Future<void> useResult() async {
    await run(() async {
      final data = {...result!};
      if (imagePath != null &&
          app.config['enableTransactionPictures'] == true &&
          app.settings['autoUploadTransactionPictureForAIRecognition'] ==
              true) {
        final picture = await app.stagePicture(imagePath!);
        data['pictures'] = [picture];
        data['pictureIds'] = [picture['pictureId']];
      }
      if (mounted) Navigator.pop(context, data);
    });
  }

  @override
  Widget buildPage(BuildContext context) => NativePage(
    title: t(
      widget.imageRecognition
          ? 'AI Image Recognition'
          : widget.clipboard
          ? 'AI Clipboard Text Recognition'
          : 'AI Text Recognition',
    ),
    busy: busy,
    children: [
      if (imagePath != null)
        Padding(
          padding: const EdgeInsets.all(16),
          child: GestureDetector(
            onTap: () => showNativeImage(context, imagePath!),
            child: Image.file(
              File(imagePath!),
              height: 240,
              fit: BoxFit.contain,
            ),
          ),
        ),
      Section(
        footer: t(
          !widget.imageRecognition
              ? 'Uploaded text and personal data will be sent to the large language model, please be aware of potential privacy risks.'
              : 'Uploaded image and personal data will be sent to the large language model, please be aware of potential privacy risks.',
        ),
        children: [
          if (!widget.imageRecognition)
            InputRow(
              t('Transaction Text'),
              value: text,
              lines: 6,
              readOnly: busy,
              onChanged: (v) => setState(() {
                text = v;
                result = null;
              }),
            ),
          if (!busy && !widget.imageRecognition)
            actionButton(t('Paste'), () async {
              final clipboard = await Clipboard.getData(Clipboard.kTextPlain);
              if (mounted && (clipboard?.text?.trim().isNotEmpty ?? false)) {
                setState(() {
                  text = clipboard!.text!;
                  result = null;
                });
              }
            }),
          if (!busy &&
              widget.imageRecognition &&
              app.config['transactionFromAIImageRecognition'] == true) ...[
            actionButton(t('Take Photo'), () => pick(ImageSource.camera)),
            actionButton(t('Choose Photo'), () => pick(ImageSource.gallery)),
          ],
          if (!busy && imagePath != null)
            actionButton(
              t('Remove Image'),
              () => setState(() {
                imagePath = null;
                result = null;
              }),
            ),
          if (!busy && (!widget.imageRecognition || imagePath != null))
            actionButton(t('Recognize'), recognize),
          if (busy && cancel != null)
            actionButton(t('Cancel Recognition'), () => cancel?.cancel()),
        ],
      ),
      if (result != null)
        Section(
          title: t('Recognition Result'),
          footer: t('Review the transaction before saving.'),
          children: [
            ItemRow(
              t('Type'),
              value: t(transactionType(number(result!['type']))),
            ),
            ItemRow(
              t('Amount'),
              value: amount(
                result!['sourceAmount'],
                string(
                  lookup(
                    flatten(app.accounts, 'subAccounts'),
                    result!['sourceAccountId'],
                  )['currency'],
                ),
              ),
            ),
            ItemRow(
              t('Account'),
              value: recordName(
                flatten(app.accounts, 'subAccounts'),
                result!['sourceAccountId'],
              ),
            ),
            ItemRow(
              t('Category'),
              value: recordName(
                flatten(app.categories, 'subCategories'),
                result!['categoryId'],
              ),
            ),
            if (number(result!['type']) == 4) ...[
              ItemRow(
                t('Destination Account'),
                value: recordName(
                  flatten(app.accounts, 'subAccounts'),
                  result!['destinationAccountId'],
                ),
              ),
              ItemRow(
                t('Destination Amount'),
                value: amount(
                  result!['destinationAmount'],
                  string(
                    lookup(
                      flatten(app.accounts, 'subAccounts'),
                      result!['destinationAccountId'],
                    )['currency'],
                  ),
                ),
              ),
            ],
            ItemRow(
              t('Time'),
              value: dateText(transactionDate(result!), time: true),
            ),
            if ((result!['tagIds'] as List? ?? []).isNotEmpty)
              ItemRow(
                t('Tags'),
                subtitle: (result!['tagIds'] as List)
                    .map((id) => recordName(app.tags, id))
                    .join(', '),
              ),
            ItemRow(t('Description'), subtitle: string(result!['comment'])),
            actionButton(t('Continue'), useResult),
          ],
        ),
    ],
  );
}

Future<void> showNativeImage(BuildContext context, String path) =>
    Navigator.of(context).push<void>(
      nativeRoute(
        context,
        builder: (_) => CupertinoPageScaffold(
          navigationBar: const CupertinoNavigationBar(),
          child: SafeArea(
            child: Center(
              child: InteractiveViewer(
                minScale: .5,
                maxScale: 5,
                child: Image.file(File(path)),
              ),
            ),
          ),
        ),
      ),
    );

Future<RecordData?> chooseLocation(
  BuildContext context, {
  RecordData? initial,
  String initialName = '',
  bool readOnly = false,
}) => Navigator.of(context).push<RecordData>(
  nativeRoute(
    context,
    builder: (_) => _LocationPage(
      initial: initial,
      initialName: initialName,
      readOnly: readOnly,
    ),
  ),
);

class _LocationPage extends ConsumerStatefulWidget {
  const _LocationPage({
    this.initial,
    required this.initialName,
    required this.readOnly,
  });
  final RecordData? initial;
  final String initialName;
  final bool readOnly;
  @override
  ConsumerState<_LocationPage> createState() => _LocationState();
}

class _LocationState extends NativeState<_LocationPage> {
  WebViewController? web;
  late RecordData coordinates = {...?widget.initial};
  String? mapError;
  bool injected = false;
  bool mapReady = false;
  bool clickEnabled = false;
  late final Uri mapUri = Uri.parse('${app.serverUrl}native-map');
  String latitude = '', longitude = '';
  late String locationName = widget.initialName;
  @override
  void initState() {
    super.initState();
    latitude = string(coordinates['latitude']);
    longitude = string(coordinates['longitude']);
    if (string(app.config['mapProvider']).isNotEmpty) {
      Future.microtask(() => run(initializeMap));
    }
  }

  bool allowed(String value) {
    return isNativeMapUrl(mapUri, value);
  }

  Future<void> initializeMap() async {
    final controller = WebViewController();
    web = controller;
    injected = false;
    mapReady = false;
    clickEnabled = false;
    mapError = null;
    await controller.setJavaScriptMode(JavaScriptMode.unrestricted);
    await controller.addJavaScriptChannel(
      'EbkMap',
      onMessageReceived: (message) async {
        if (!injected ||
            message.message.length > 1024 ||
            !allowed(await controller.currentUrl() ?? '')) {
          return;
        }
        try {
          final body = jsonDecode(message.message);
          if (body is! Map) return;
          if (body['type'] == 'ready') {
            if (mounted) setState(() => mapReady = true);
            return;
          }
          if (body['type'] == 'error') {
            if (mounted) setState(() => mapError = string(body['message']));
            return;
          }
          if (body['type'] != 'coordinate' || widget.readOnly) return;
          final location = mapLocation(body);
          if (location == null) return;
          if (mounted) {
            setState(() {
              coordinates = {
                'latitude': location['latitude'],
                'longitude': location['longitude'],
              };
              latitude = location['latitude'].toString();
              longitude = location['longitude'].toString();
              locationName = string(location['name']);
            });
          }
        } catch (_) {
          /* Reject malformed messages from the map. */
        }
      },
    );
    await controller.setNavigationDelegate(
      NavigationDelegate(
        onNavigationRequest: (request) =>
            allowed(request.url) && (!injected || !request.isMainFrame)
            ? NavigationDecision.navigate
            : NavigationDecision.prevent,
        onPageFinished: (url) async {
          if (injected ||
              !allowed(url) ||
              !allowed(await controller.currentUrl() ?? '')) {
            return;
          }
          injected = true;
          try {
            await controller.runJavaScript(
              'window.configureNativeMap(${jsonEncode({'token': app.api.token, 'language': app.api.language, 'coordinate': coordinates, 'readOnly': widget.readOnly, 'zoomIn': t('Zoom in'), 'zoomOut': t('Zoom out')})})',
            );
          } catch (_) {
            if (mounted) setState(() => mapError = t('Cannot Initialize Map'));
          }
        },
        onWebResourceError: (error) {
          if (error.isForMainFrame == true && mounted) {
            setState(() => mapError = error.description);
          }
        },
      ),
    );
    final expiration = number(app.settings['mapCacheExpiration'] ?? -1);
    final stamp = number(app.settings['nativeMapCacheUpdated']);
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final expired =
        canSetMapCacheExpiration(app.config) &&
        cacheExpired(expiration, stamp, now);
    if (expired) {
      await controller.clearCache();
      await app.setPreference('nativeMapCacheUpdated', now);
    }
    await controller.loadRequest(mapUri);
    if (mounted) setState(() {});
  }

  Future<void> locate() async {
    await run(() async {
      if (!await Geolocator.isLocationServiceEnabled()) {
        throw StateError(t('Location service is disabled'));
      }
      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.deniedForever) {
        if (mounted &&
            await confirm(
              context,
              t('Location permission is disabled. Open app settings?'),
            )) {
          await Geolocator.openAppSettings();
        }
        return;
      }
      if (permission == LocationPermission.denied) {
        throw StateError(t('Location permission denied'));
      }
      if (!mounted) return;
      final position = await getAmapCurrentLocation(context, app);
      coordinates = {
        'latitude': position['latitude'],
        'longitude': position['longitude'],
      };
      latitude = position['latitude'].toString();
      longitude = position['longitude'].toString();
      locationName = string(position['name']);
      if (web != null && injected && allowed(await web!.currentUrl() ?? '')) {
        await web!.runJavaScript(
          'window.setNativeCoordinate(${jsonEncode(coordinates)})',
        );
      }
    });
  }

  Future<void> save() async {
    final lat = double.tryParse(app.formatter.normalizeAmountInput(latitude)),
        lon = double.tryParse(app.formatter.normalizeAmountInput(longitude));
    if (lat == null ||
        lon == null ||
        !lat.isFinite ||
        !lon.isFinite ||
        lat.abs() > 90 ||
        lon.abs() > 180) {
      await inform(context, t('Invalid coordinates'));
      return;
    }
    Navigator.pop(context, {
      'latitude': lat,
      'longitude': lon,
      if (locationName.isNotEmpty) 'name': locationName,
    });
  }

  @override
  Widget buildPage(BuildContext context) => NativePage(
    title: t('Geographic Location'),
    busy: busy,
    trailing: widget.readOnly
        ? null
        : iconButton(CupertinoIcons.check_mark, t('Save'), save),
    children: [
      if (web != null &&
          !widget.readOnly &&
          !['amap', 'baidumap'].contains(app.config['mapProvider']))
        Section(
          children: [
            toggleRow(
              t('Enable Click to Set Location'),
              clickEnabled,
              (value) => run(() async {
                if (web != null &&
                    injected &&
                    allowed(await web!.currentUrl() ?? '')) {
                  await web!.runJavaScript(
                    'window.setNativeClickEnabled(${jsonEncode(value)})',
                  );
                  setState(() => clickEnabled = value);
                }
              }),
            ),
          ],
        ),
      if (web != null)
        SizedBox(
          height: 400,
          child: Stack(
            children: [
              Positioned.fill(
                child: WebViewWidget(
                  controller: web!,
                  gestureRecognizers: {
                    Factory<OneSequenceGestureRecognizer>(
                      EagerGestureRecognizer.new,
                    ),
                  },
                ),
              ),
              if (!mapReady && mapError == null)
                const Positioned.fill(
                  child: ColoredBox(
                    color: CupertinoColors.systemGroupedBackground,
                    child: Center(child: CupertinoActivityIndicator()),
                  ),
                ),
            ],
          ),
        ),
      if (mapError != null) ...[
        emptyState(t(mapError!)),
        actionButton(t('Retry'), () => run(initializeMap)),
      ],
      Section(
        children: [
          if (coordinates.isNotEmpty)
            ItemRow(
              t('Geographic Location'),
              subtitle: [
                if (locationName.isNotEmpty) locationName,
                formatNativeCoordinate(
                  coordinates,
                  number(app.user['coordinateDisplayType']),
                ),
              ].join('\n'),
            ),
          InputRow(
            t('Latitude'),
            value: latitude,
            readOnly: widget.readOnly,
            keyboard: const TextInputType.numberWithOptions(
              decimal: true,
              signed: true,
            ),
            onChanged: (v) => setState(() {
              latitude = v;
              locationName = '';
            }),
          ),
          InputRow(
            t('Longitude'),
            value: longitude,
            readOnly: widget.readOnly,
            keyboard: const TextInputType.numberWithOptions(
              decimal: true,
              signed: true,
            ),
            onChanged: (v) => setState(() {
              longitude = v;
              locationName = '';
            }),
          ),
          if (!widget.readOnly)
            actionButton(t('Update Geographic Location'), locate),
        ],
      ),
    ],
  );
}
