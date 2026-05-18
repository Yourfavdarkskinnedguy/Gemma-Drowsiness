// lib/services/audio_manager.dart

import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_tts/flutter_tts.dart';
import '../models/audio_source.dart';
import 'fallback_audio_player.dart';

class AudioManager {
  final FallbackAudioPlayer _fallbackPlayer;
  final FlutterTts _tts = FlutterTts();

  AudioSource _audioSource = AudioSource.none;
  bool _fallbackLoopActive = false;
  bool _gemmaLoopActive = false;

  String _currentRisk = 'LOW';
  String _ttsAction = '';

  bool _ttsReady = false;
  bool _ttsActive = false;
  Completer<void>? _ttsCompleter;

  static const int _kMaxTtsRetries = 3;
  static const Duration _kTtsRetryDelay = Duration(milliseconds: 500);

  AudioManager({required FallbackAudioPlayer fallbackPlayer})
      : _fallbackPlayer = fallbackPlayer;

  // ── Initialization ──────────────────────────────────────────────────────

  Future<void> initializeTts() async {
    try {
      await _tts.setLanguage('en-US');
      await _tts.setSpeechRate(0.50);
      await _tts.setVolume(1.0);
      await _tts.setPitch(1.0);

      _tts.setStartHandler(() {
        _ttsActive = true;
        debugPrint('[AudioManager] TTS ▶ started');
      });
      _tts.setCompletionHandler(() {
        _ttsActive = false;
        _resolveTtsCompleter();
        debugPrint('[AudioManager] TTS ■ completed naturally');
      });
      _tts.setErrorHandler((error) {
        _ttsActive = false;
        _resolveTtsCompleter(error);
        debugPrint('[AudioManager] TTS ✗ error: $error');
      });
      _tts.setCancelHandler(() {
        _ttsActive = false;
        _resolveTtsCompleter();
        debugPrint('[AudioManager] TTS ✗ cancelled');
      });

      _ttsReady = true;
      debugPrint('[AudioManager] TTS initialized');
    } catch (e) {
      debugPrint('[AudioManager] TTS init failed: $e');
    }
  }

  void dispose() {
    stopAllAudio(immediate: true);
    _tts.stop();
    _fallbackPlayer.dispose();
  }

  // ── Risk update ─────────────────────────────────────────────────────────

  void setRisk(String risk) => _currentRisk = risk;

  // ── Audio control ───────────────────────────────────────────────────────

  void stopAllAudio({bool immediate = true}) {
    debugPrint('[AudioManager] stopAllAudio(immediate: $immediate) '
        '— was: $_audioSource  fallbackLoop=$_fallbackLoopActive  gemmaLoop=$_gemmaLoopActive');

    _fallbackLoopActive = false;
    _gemmaLoopActive = false;

    if (immediate) {
      _fallbackPlayer.stop();
      // Do NOT manually complete _ttsCompleter – callbacks handle it.
      _ttsActive = false;
    }

    _audioSource = AudioSource.none;
  }

  void triggerFallbackAudio() {
    if (_audioSource.index >= AudioSource.fallbackAudio.index) {
      debugPrint('[AudioManager] Fallback audio skipped — $_audioSource already active');
      return;
    }
    if (!_fallbackPlayer.isInitialized) {
      debugPrint('[AudioManager] Fallback player not initialized — skipping');
      return;
    }
    if (_fallbackLoopActive) {
      debugPrint('[AudioManager] Fallback audio loop already running');
      return;
    }

    _audioSource = AudioSource.fallbackAudio;
    _startFallbackAudioLoop();
    debugPrint('[AudioManager] Fallback audio loop started');
  }

  void claimGemmaOwnership() {
    debugPrint('[AudioManager] Gemma claiming ownership');
    _audioSource = AudioSource.gemma;
    _fallbackLoopActive = false;
    _fallbackPlayer.stop();
  }

  void startGemmaTtsLoop(String action) {
    _ttsAction = action;
    if (_audioSource != AudioSource.gemma || _currentRisk != 'HIGH') return;
    _startGemmaTtsLoop();
  }

  void updateTtsAction(String action) {
    _ttsAction = action;
  }

  bool get isGemmaActive => _audioSource == AudioSource.gemma;

  // ── Private loops ───────────────────────────────────────────────────────

  void _startFallbackAudioLoop() {
    if (_fallbackLoopActive) return;
    _fallbackLoopActive = true;

    Future.doWhile(() async {
      if (!_fallbackLoopActive) {
        debugPrint('[AudioManager] Fallback loop: stopped externally, exiting');
        return false;
      }
      if (_currentRisk != 'HIGH') {
        _fallbackLoopActive = false;
        debugPrint('[AudioManager] Fallback loop: risk not HIGH, exiting');
        return false;
      }
      if (_audioSource != AudioSource.fallbackAudio) {
        _fallbackLoopActive = false;
        debugPrint('[AudioManager] Fallback loop: yielding to $_audioSource');
        return false;
      }

      await _fallbackPlayer.playRandomAlert();

      if (_fallbackLoopActive && _currentRisk == 'HIGH') {
        await Future.delayed(const Duration(seconds: 1));
      }

      final shouldContinue = _fallbackLoopActive &&
          _currentRisk == 'HIGH' &&
          _audioSource == AudioSource.fallbackAudio;

      if (!shouldContinue) _fallbackLoopActive = false;
      return shouldContinue;
    });
  }

  void _startGemmaTtsLoop() {
    if (_gemmaLoopActive) return;
    _gemmaLoopActive = true;

    debugPrint('[AudioManager] Gemma TTS loop started — action: "$_ttsAction"');

    int consecutiveFailures = 0;

    Future.doWhile(() async {
      if (!_gemmaLoopActive ||
          _currentRisk != 'HIGH' ||
          _audioSource != AudioSource.gemma) {
        _gemmaLoopActive = false;
        debugPrint('[AudioManager] Gemma TTS loop: exit condition met');
        return false;
      }

      if (_ttsReady && _ttsAction.isNotEmpty) {
        _ttsActive = true;
        _ttsCompleter = Completer<void>();

        try {
          debugPrint('[AudioManager] Gemma TTS ▶ speaking: "$_ttsAction"');
          await _tts.speak(_ttsAction);
          await _ttsCompleter!.future;
          consecutiveFailures = 0;
        } catch (e) {
          consecutiveFailures++;
          debugPrint('[AudioManager] Gemma TTS error '
              '($consecutiveFailures/$_kMaxTtsRetries): $e');

          if (consecutiveFailures >= _kMaxTtsRetries) {
            debugPrint('[AudioManager] TTS failed repeatedly — '
                'releasing audio ownership');
            _gemmaLoopActive = false;
            _audioSource = AudioSource.none;
            return false;
          }

          await Future.delayed(_kTtsRetryDelay);
        } finally {
          _ttsCompleter = null;
          _ttsActive = false;
        }
      } else {
        await Future.delayed(const Duration(milliseconds: 500));
      }

      final shouldContinue = _gemmaLoopActive &&
          _currentRisk == 'HIGH' &&
          _audioSource == AudioSource.gemma;

      if (!shouldContinue) _gemmaLoopActive = false;
      return shouldContinue;
    });
  }

  void _resolveTtsCompleter([Object? error]) {
    final c = _ttsCompleter;
    _ttsCompleter = null;
    if (c == null || c.isCompleted) return;
    if (error == null) {
      c.complete();
    } else {
      c.completeError(error);
    }
  }
}