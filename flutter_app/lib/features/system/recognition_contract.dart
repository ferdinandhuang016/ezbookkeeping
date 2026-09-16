import 'dart:typed_data';

import 'package:image/image.dart' as image;
import 'package:timezone/timezone.dart' as tz;

/// Matches src/components/mobile/AIImageRecognitionSheet.vue and HD720P:
/// apply EXIF orientation, fit within 1280 pixels, then encode JPEG quality 80.
/// Image codecs: https://pub.dev/documentation/image/4.10.1/image/image-library.html
Uint8List prepareRecognitionImage(Uint8List bytes) {
  image.Image? decoded;
  try {
    decoded = image.decodeImage(bytes);
  } catch (_) {
    throw const FormatException('Unable to load image');
  }
  if (decoded == null) throw const FormatException('Unable to load image');
  var picture = image.bakeOrientation(decoded);
  final longest = picture.width > picture.height
      ? picture.width
      : picture.height;
  if (longest > 1280) {
    picture = image.copyResize(
      picture,
      width: (picture.width * 1280 / longest).floor().clamp(1, 1280),
      height: (picture.height * 1280 / longest).floor().clamp(1, 1280),
      interpolation: image.Interpolation.linear,
    );
  }
  picture.exif = image.ExifData();
  return image.encodeJpg(picture, quality: 80);
}

Map<String, dynamic> recognizedTransaction(
  Map<String, dynamic> response,
  tz.Location timeZone, {
  DateTime? now,
}) {
  final timestamp = response['time'] as num?;
  final instant = timestamp == null || timestamp <= 0
      ? now ?? DateTime.now()
      : DateTime.fromMillisecondsSinceEpoch(
          timestamp.toInt() * 1000,
          isUtc: true,
        );
  return {
    ...response,
    'time': instant.millisecondsSinceEpoch ~/ 1000,
    'timeZone': timeZone.name,
    'utcOffset': tz.TZDateTime.from(instant, timeZone).timeZoneOffset.inMinutes,
  };
}
