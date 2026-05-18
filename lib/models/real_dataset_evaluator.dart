// lib/evaluation/real_dataset_evaluator.dart
import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'package:path_provider/path_provider.dart';
import '../services/gemma_service.dart';
import '../camera_screen.dart' show DrowsinessContext;

class RealDatasetEvaluator {
  final GemmaService gemmaService;
  final FaceDetector faceDetector;

  // How many new images to process each time the button is pressed
  static const int _batchSize = 4;

  // Asset folders – adjust if your structure is different
  static const String drowsyAssetPath = 'assets/test_images/drowsy/';
  static const String nonDrowsyAssetPath = 'assets/test_images/non_drowsy/';

  RealDatasetEvaluator({
    required this.gemmaService,
    required this.faceDetector,
  });

  // ── public trigger ────────────────────────────────────────────────────────
  Future<void> runEvaluation() async {
    final dir = await getApplicationDocumentsDirectory();
    final resultsFile = File('${dir.path}/evaluation_results.json');
    final progressFile = File('${dir.path}/evaluation_progress.json');

    // Load previous results and progress
    List<Map<String, dynamic>> allResults = [];
    Set<String> processedFiles = {};
    if (await resultsFile.exists()) {
      allResults = List<Map<String, dynamic>>.from(
        jsonDecode(await resultsFile.readAsString()),
      );
    }
    if (await progressFile.exists()) {
      processedFiles = Set<String>.from(
        jsonDecode(await progressFile.readAsString()),
      );
    }

    print('🚀 Continuing Real Dataset Evaluation…');
    print('   Already processed: ${processedFiles.length} images');
    print('   This batch will add up to $_batchSize more.');

    int newCount = 0;

    // Process drowsy images
    newCount += await _processCategory(
      assetPath: drowsyAssetPath,
      label: 'Drowsy',
      expectedRisk: 'HIGH',
      allResults: allResults,
      processedFiles: processedFiles,
      maxNew: _batchSize - newCount,
    );

    // Process non‑drowsy images
    if (newCount < _batchSize) {
      newCount += await _processCategory(
        assetPath: nonDrowsyAssetPath,
        label: 'Non Drowsy',
        expectedRisk: 'LOW',   // MEDIUM is also accepted as correct
        allResults: allResults,
        processedFiles: processedFiles,
        maxNew: _batchSize - newCount,
      );
    }

    // Save updated results and progress
    await resultsFile.writeAsString(const JsonEncoder.withIndent('  ').convert(allResults));
    await progressFile.writeAsString(jsonEncode(processedFiles.toList()));

    print('📊 Progress saved. Total images evaluated so far: ${allResults.length}');

    if (newCount == 0 && processedFiles.length >= _countTotalAssets()) {
      print('✅ ALL IMAGES HAVE BEEN PROCESSED!');
      _printFinalSummary(allResults);
    } else {
      print('👉 Press the button again after restarting the app to continue.');
    }
  }

  // ── category processor ────────────────────────────────────────────────────
  Future<int> _processCategory({
    required String assetPath,
    required String label,
    required String expectedRisk,
    required List<Map<String, dynamic>> allResults,
    required Set<String> processedFiles,
    required int maxNew,
  }) async {
    if (maxNew <= 0) return 0;

    final manifest = await AssetManifest.loadFromAssetBundle(rootBundle);
    final files = manifest.listAssets().where((path) =>
        path.startsWith(assetPath) &&
        (path.endsWith('.jpg') || path.endsWith('.png'))).toList();

    int processed = 0;
    for (var assetKey in files) {
      final fileName = assetKey.split('/').last;
      if (processedFiles.contains(fileName)) continue;

      try {
        final data = await rootBundle.load(assetKey);
        final tempFile = File('${Directory.systemTemp.path}/$fileName');
        await tempFile.writeAsBytes(data.buffer.asUint8List());

        final inputImage = InputImage.fromFile(tempFile);
        final faces = await faceDetector.processImage(inputImage);

        if (faces.isEmpty) {
          print('⚠️ No face in $fileName, skipping.');
          processedFiles.add(fileName);       // mark as processed so we don't stall
          await tempFile.delete();
          continue;
        }

        final face = faces.first;
        final avgEyeOpen = ((face.leftEyeOpenProbability ?? 0) +
                          (face.rightEyeOpenProbability ?? 0)) / 2;
        final ecr = _computeECR(avgEyeOpen);

        final output = await gemmaService.analyze(
          ecr: ecr,
          perclos: 0.0,    // static image limitation
          context: DrowsinessContext.general,
          lastResult: GemmaOutput(risk: 'LOW', reason: '', action: '', isFallback: true),
        );

        bool isCorrect = false;
        if (label == 'Drowsy' && output.risk == expectedRisk) {
          isCorrect = true;
        } else if (label == 'Non Drowsy' &&
                  (output.risk == 'LOW' || output.risk == 'MEDIUM')) {
          isCorrect = true;
        }

        allResults.add({
          'file_name': fileName,
          'expected_label': label,
          'ecr': ecr,
          'gemma_risk': output.risk,
          'gemma_reason': output.reason,
          'gemma_action': output.action,
          'is_correct': isCorrect,
        });

        processedFiles.add(fileName);
        await tempFile.delete();

        processed++;
        if (processed >= maxNew) break;
      } catch (e) {
        print('❌ Error on $fileName: $e');
        processedFiles.add(fileName);    // avoid repeated failures
      }
    }
    return processed;
  }

  // ── helpers ───────────────────────────────────────────────────────────────
  double _baselineOpen = 0.55;
  double _ecmEma = -1.0;
  static const double _EMA_ALPHA = 0.35;

  double _computeECR(double avgOpen) {
    if (avgOpen > 0.5) {
      _baselineOpen = _baselineOpen * 0.92 + avgOpen * 0.08;
    }
    _ecmEma = _ecmEma < 0
        ? avgOpen
        : _EMA_ALPHA * avgOpen + (1 - _EMA_ALPHA) * _ecmEma;
    final rel = (_ecmEma / _baselineOpen.clamp(0.3, 1.0)).clamp(0.0, 1.0);
    return (1.0 - rel).clamp(0.0, 1.0);
  }

  int _countTotalAssets() {
    // Approximate – you can hardcode the total number of images if known.
    // The evaluator stops automatically when no new unprocessed images remain.
    return 9999;   // will be caught by `newCount == 0` logic
  }

  void _printFinalSummary(List<Map<String, dynamic>> results) {
    int correct = results.where((r) => r['is_correct'] == true).length;
    double accuracy = (results.isNotEmpty) ? (correct / results.length) * 100 : 0;
    print('══════════════════════════════════════');
    print('   FINAL EVALUATION SUMMARY');
    print('══════════════════════════════════════');
    print('Total Images: ${results.length}');
    print('Correct Predictions: $correct');
    print('Accuracy: ${accuracy.toStringAsFixed(1)}%');
    print('══════════════════════════════════════');
  }
}