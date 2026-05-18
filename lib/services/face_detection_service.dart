// lib/services/face_detection_service.dart

import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:camera/camera.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import '../models/face_result.dart';

class FaceDetectionService {
  late final FaceDetector _faceDetector;

  FaceDetectionService() {
    _faceDetector = FaceDetector(
      options: FaceDetectorOptions(
        performanceMode: FaceDetectorMode.fast,
        enableClassification: true,
        enableTracking: false,
        enableLandmarks: false,
        minFaceSize: 0.15,
      ),
    );
  }

  void dispose() {
    _faceDetector.close();
  }

  Future<FaceResult> detectFace(CameraImage image, int sensorOrientation) async {
    try {
      final img = _buildInputImage(image, sensorOrientation);
      if (img == null) return const FaceResult(avg: 0, detected: false);

      final faces = await _faceDetector.processImage(img);
      if (faces.isEmpty) return const FaceResult(avg: 0, detected: false);

      final f = faces.first;
      final l = f.leftEyeOpenProbability ?? 0.0;
      final r = f.rightEyeOpenProbability ?? 0.0;

      return FaceResult(avg: (l + r) / 2.0, detected: true);
    } catch (_) {
      return const FaceResult(avg: 0, detected: false);
    }
  }

  InputImage? _buildInputImage(CameraImage image, int sensorOrientation) {
    if (Platform.isAndroid && image.format.group == ImageFormatGroup.yuv420) {
      return InputImage.fromBytes(
        bytes: _yuv420toNV21(image),
        metadata: InputImageMetadata(
          size: ui.Size(image.width.toDouble(), image.height.toDouble()),
          rotation: _rotation(sensorOrientation),
          format: InputImageFormat.nv21,
          bytesPerRow: image.width,
        ),
      );
    }

    if (Platform.isIOS && image.format.group == ImageFormatGroup.bgra8888) {
      final plane = image.planes.first;
      return InputImage.fromBytes(
        bytes: plane.bytes,
        metadata: InputImageMetadata(
          size: ui.Size(image.width.toDouble(), image.height.toDouble()),
          rotation: _rotation(sensorOrientation),
          format: InputImageFormat.bgra8888,
          bytesPerRow: plane.bytesPerRow,
        ),
      );
    }

    return null;
  }

  Uint8List _yuv420toNV21(CameraImage img) {
    final w = img.width, h = img.height;
    final yP = img.planes[0], uP = img.planes[1], vP = img.planes[2];
    final out = Uint8List(w * h + w * h ~/ 2);
    int i = 0;

    for (int r = 0; r < h; r++) {
      final b = r * yP.bytesPerRow;
      for (int c = 0; c < w; c++) {
        out[i++] = yP.bytes[b + c * (yP.bytesPerPixel ?? 1)];
      }
    }

    for (int r = 0; r < h ~/ 2; r++) {
      final ub = r * uP.bytesPerRow, vb = r * vP.bytesPerRow;
      for (int c = 0; c < w ~/ 2; c++) {
        out[i++] = vP.bytes[vb + c * (vP.bytesPerPixel ?? 1)];
        out[i++] = uP.bytes[ub + c * (uP.bytesPerPixel ?? 1)];
      }
    }

    return out;
  }

  InputImageRotation _rotation(int d) => switch (d) {
        90 => InputImageRotation.rotation90deg,
        180 => InputImageRotation.rotation180deg,
        270 => InputImageRotation.rotation270deg,
        _ => InputImageRotation.rotation0deg,
      };
}