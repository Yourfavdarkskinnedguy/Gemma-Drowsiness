// lib/services/gemma_service.dart

import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_gemma/flutter_gemma.dart';
import 'package:flutter_gemma/core/api/flutter_gemma.dart';
import 'package:path_provider/path_provider.dart';

enum DrowsinessContext { eyesClosed, general }


class GemmaOutput {
  final String risk;
  final String reason;
  final String action;
  final bool isFallback;

  const GemmaOutput({
    required this.risk,
    required this.reason,
    required this.action,
    this.isFallback = false,
  });

  factory GemmaOutput.fromJson(Map<String, dynamic> json) {
    final raw = (json['risk'] ?? 'LOW').toString().trim().toUpperCase();
    final risk = const {'HIGH', 'MEDIUM', 'LOW'}.contains(raw) ? raw : 'LOW';
    return GemmaOutput(
      risk: risk,
      reason: (json['reason'] ?? '').toString().trim(),
      action: (json['action'] ?? '').toString().trim(),
      isFallback: false,
    );
  }

  static GemmaOutput fallback([GemmaOutput? last]) => GemmaOutput(
        risk: last?.risk ?? 'LOW',
        reason: last?.reason ?? '',
        action: last?.action ?? '',
        isFallback: true,
      );
}

enum GemmaState { idle, checking, downloading, loading, ready, failed }

// ── Service ───────────────────────────────────────────────────────────────────

class GemmaService {
  GemmaService._();
  static final GemmaService instance = GemmaService._();

  final ValueNotifier<int> downloadReceivedBytes = ValueNotifier(0);
  final ValueNotifier<int> downloadTotalBytes = ValueNotifier(0);

  final ValueNotifier<GemmaState> state = ValueNotifier(GemmaState.idle);
  final ValueNotifier<double> downloadProgress = ValueNotifier(0.0);
  final ValueNotifier<String?> error = ValueNotifier(null);

  InferenceModel? _model;
  InferenceModelSession? _session;
  bool _initializing = false;
  bool _busy = false;

  // ── Model ─────────────────────────────────────────────────────────────────
  static const String _modelUrl =
      'https://huggingface.co/litert-community/gemma-4-E2B-it-litert-lm'
      '/resolve/main/gemma-4-E2B-it.litertlm';
  static const String _modelFileName = 'gemma-4-E2B-it.litertlm';

  static const int _maxTokens = 1024;
  static const double _temperature = 0.45;
  static const int _topK = 4;
  static const double _topP = 0.92;

  // ── Dio config ────────────────────────────────────────────────────────────
  static const int _maxAttempts = 5;
  static const Duration _connectTimeout = Duration(seconds: 30);
  static const Duration _baseRetryDelay = Duration(seconds: 3);

  bool get isReady =>
      state.value == GemmaState.ready && _model != null && _session != null;

  // ── Init ──────────────────────────────────────────────────────────────────

  Future<void> initialize() async {
    if (_initializing) return;
    if (state.value == GemmaState.ready ||
        state.value == GemmaState.downloading ||
        state.value == GemmaState.loading) return;

    _initializing = true;
    error.value = null;
    downloadProgress.value = 0.0;
    downloadReceivedBytes.value = 0;
    downloadTotalBytes.value = 0;

    try {
      await FlutterGemma.initialize();
      debugPrint('[GemmaService] ✓ FlutterGemma initialized');

      state.value = GemmaState.checking;
      final modelPath = await _ensureModelFile();

      state.value = GemmaState.loading;
      await FlutterGemma.installModel(
        modelType: ModelType.gemmaIt,
        fileType: ModelFileType.task,
      ).fromFile(modelPath).install();

      _model = await _loadModelWithFallback();

      await _openSession();
      await _warmUpSession();

      state.value = GemmaState.ready;
      error.value = null;
      debugPrint('[GemmaService] ✓ READY');
    } catch (e, st) {
      state.value = GemmaState.failed;
      error.value = e.toString();
      debugPrint('[GemmaService] ✗ Init failed: $e\n$st');
    } finally {
      _initializing = false;
    }
  }

  // ── Download (Dio + resume + retry) ───────────────────────────────────────

  Future<String> _ensureModelFile() async {
    final dir = await getApplicationDocumentsDirectory();
    final finalPath = '${dir.path}/$_modelFileName';
    final tmpPath = '$finalPath.tmp';

    if (await File(finalPath).exists()) {
      debugPrint('[GemmaService] Model already on disk');
      return finalPath;
    }

    state.value = GemmaState.downloading;

    await _downloadWithResume(
        url: _modelUrl, tmpPath: tmpPath, finalPath: finalPath);
    return finalPath;
  }

  Future<void> _downloadWithResume({
    required String url,
    required String tmpPath,
    required String finalPath,
  }) async {
    final dio = Dio(BaseOptions(
      connectTimeout: _connectTimeout,
      receiveTimeout: Duration.zero,
      followRedirects: true,
      maxRedirects: 5,
    ));

    int attempt = 0;
    while (true) {
      attempt++;
      debugPrint('[GemmaService] Download attempt $attempt/$_maxAttempts');
      final tmpFile = File(tmpPath);
      final resumeBytes =
          await tmpFile.exists() ? await tmpFile.length() : 0;

      try {
        int totalBytes = 0;
        try {
          final head = await dio.head(url);
          final cl = head.headers.value('content-length');
          if (cl != null) totalBytes = int.parse(cl);
        } catch (_) {}

        final resp = await dio.get<ResponseBody>(
          url,
          options: Options(
            responseType: ResponseType.stream,
            headers:
                resumeBytes > 0 ? {'Range': 'bytes=$resumeBytes-'} : null,
          ),
        );
        final contentLen =
            int.tryParse(resp.headers.value('content-length') ?? '') ?? 0;
        final knownTotal =
            totalBytes > 0 ? totalBytes : resumeBytes + contentLen;
        downloadTotalBytes.value = knownTotal;

        final raf = await tmpFile.open(
            mode: resumeBytes > 0 ? FileMode.append : FileMode.write);
        int recv = resumeBytes;
        DateTime lastLog = DateTime.now();

        await for (final chunk in resp.data!.stream) {
          await raf.writeFrom(chunk);
          recv += chunk.length;
          downloadReceivedBytes.value = recv;
          downloadTotalBytes.value = knownTotal;
          if (knownTotal > 0) {
            downloadProgress.value = (recv / knownTotal).clamp(0.0, 1.0);
            if (DateTime.now().difference(lastLog).inSeconds >= 2) {
              lastLog = DateTime.now();
              debugPrint(
                  '[GemmaService] ${(recv / knownTotal * 100).toStringAsFixed(1)}%  '
                  '${_fmt(recv)} / ${_fmt(knownTotal)}');
            }
          }
        }
        await raf.close();
        await tmpFile.rename(finalPath);
        downloadProgress.value = 1.0;
        debugPrint(
            '[GemmaService] ✓ Download complete: ${_fmt(await File(finalPath).length())}');
        return;
      } on DioException catch (e) {
        if (attempt >= _maxAttempts) {
          throw Exception('Download failed: ${e.message}');
        }
        await Future.delayed(
            _baseRetryDelay * pow(2, attempt - 1).toInt());
      } catch (e) {
        if (attempt >= _maxAttempts) rethrow;
        await Future.delayed(
            _baseRetryDelay * pow(2, attempt - 1).toInt());
      }
    }
  }

  static String _fmt(int b) {
    if (b < 1 << 10) return '${b}B';
    if (b < 1 << 20) return '${(b / (1 << 10)).toStringAsFixed(1)}KB';
    if (b < 1 << 30) return '${(b / (1 << 20)).toStringAsFixed(1)}MB';
    return '${(b / (1 << 30)).toStringAsFixed(2)}GB';
  }

  // ── GPU → CPU fallback model loading ────────────────────────────────────────
  Future<InferenceModel> _loadModelWithFallback() async {
    try {
      debugPrint('[GemmaService] Loading model — trying GPU backend…');
      final model = await FlutterGemma.getActiveModel(
        maxTokens: _maxTokens,
        preferredBackend: PreferredBackend.gpu,
      );
      debugPrint(
          '[GemmaService] ✓ Model loaded on GPU (maxTokens=$_maxTokens)');
      return model;
    } catch (e) {
      debugPrint(
          '[GemmaService] ⚠ GPU backend failed ($e) — falling back to CPU');
    }

    debugPrint('[GemmaService] Loading model — CPU backend…');
    final model = await FlutterGemma.getActiveModel(
      maxTokens: _maxTokens,
      preferredBackend: PreferredBackend.cpu,
    );
    debugPrint(
        '[GemmaService] ✓ Model loaded on CPU (maxTokens=$_maxTokens)');
    return model;
  }

  // ── Session ─────────────────────────────────────────────────────────────────
  Future<void> _openSession() async {
    if (_model == null) throw StateError('Model not loaded');
    await _session?.close();
    final seed = DateTime.now().millisecondsSinceEpoch % 99991;
    _session = await _model!.createSession(
      temperature: _temperature,
      randomSeed: seed,
      topK: _topK,
      topP: _topP,
    );
    debugPrint('[GemmaService] ✓ Session ready (seed=$seed)');
  }

  Future<void> _recoverSession() async {
    debugPrint('[GemmaService] Recovering session after error…');
    try {
      await _session?.close();
      _session = null;
      if (_model != null) {
        await _openSession();
        debugPrint('[GemmaService] ✓ Session recovered');
      } else {
        state.value = GemmaState.failed;
      }
    } catch (e) {
      state.value = GemmaState.failed;
      error.value = e.toString();
      debugPrint('[GemmaService] ✗ Session recovery failed: $e');
    }
  }

  Future<void> _warmUpSession() async {
    if (_session == null) return;
    try {
      debugPrint('[GemmaService] Warming up session…');
      await _session!.addQueryChunk(
        Message.text(text: 'Warmup', isUser: true),
      );
      final _ = await _session!.getResponse();
      debugPrint('[GemmaService] ✓ Session warm-up complete');
    } catch (e) {
      debugPrint('[GemmaService] ⚠ Warm-up failed (non‑fatal): $e');
    }
  }

  // ── Inference ─────────────────────────────────────────────────────────────

  Future<GemmaOutput> analyze({
    required double ecr,
    required double perclos,
    required DrowsinessContext context,
    GemmaOutput? lastResult,
  }) async {
    if (!isReady || _session == null) return GemmaOutput.fallback(lastResult);
    if (_busy) return GemmaOutput.fallback(lastResult);

    _busy = true;
    final sw = Stopwatch()..start();

    try {
      final prompt =
          _buildPrompt(ecr: ecr, perclos: perclos, context: context);
      debugPrint('[GemmaService] → ECR=${ecr.toStringAsFixed(2)} '
          'PERCLOS=${perclos.toStringAsFixed(0)}% ctx=$context');

      await _session!.addQueryChunk(
          Message.text(text: prompt, isUser: true));
      final raw = await _session!.getResponse();
      sw.stop();
      debugPrint('[GemmaService] ← (${sw.elapsedMilliseconds}ms) "$raw"');

      return _parse(raw);
    } catch (e, st) {
      sw.stop();
      debugPrint('[GemmaService] Error: $e\n$st');
      await _recoverSession();
      return GemmaOutput.fallback(lastResult);
    } finally {
      _busy = false;
    }
  }

  String _buildPrompt({
    required double ecr,
    required double perclos,
    required DrowsinessContext context,
  }) {
    final risk = _classify(ecr, perclos);
    final ctx = switch (context) {
      DrowsinessContext.eyesClosed => 'eyes closing',
      DrowsinessContext.general => 'fatigue signs',
    };
    return 'Driver safety. Risk=$risk. $ctx. '
        'Reply ONE JSON line with a friendly, human-like tone – sometimes add a light, funny wake-up line '
        'but the action must be a clear safety instruction. No numbers. Keep it under 8 words.'
        '{"risk":"$risk","reason":"...","action":"..."}';
  }

  String _classify(double ecr, double perclos) {
    if (perclos > 40 || ecr > 0.8) return 'HIGH';
    if (perclos > 20 || ecr > 0.65) return 'MEDIUM';
    return 'LOW';
  }

  GemmaOutput _parse(String raw) {
    try {
      final s = raw.indexOf('{');
      final e = raw.lastIndexOf('}');
      if (s == -1 || e <= s) return GemmaOutput.fallback();

      final output = GemmaOutput.fromJson(
          jsonDecode(raw.substring(s, e + 1)) as Map<String, dynamic>);

      final lr = output.reason.toLowerCase();
      if (lr.contains('%') ||
          lr.contains('ecr') ||
          lr.contains('perclos')) {
        debugPrint('[GemmaService] Rejected metric recitation');
        return GemmaOutput.fallback();
      }
      // No minimum length checks – accept any valid JSON response.
      // The camera_screen code further filters on action.isNotEmpty.
      return output;
    } catch (e) {
      debugPrint('[GemmaService] Parse error: $e');
      return GemmaOutput.fallback();
    }
  }

  Future<void> retry() async {
    state.value = GemmaState.idle;
    downloadProgress.value = 0.0;
    error.value = null;
    await initialize();
  }

  void dispose() {
    _session?.close();
    _model?.close();
    state.dispose();
    downloadProgress.dispose();
    error.dispose();
  }
}