// lib/services/fallback_audio_player.dart
//
// Serialized audio clip player for fallback drowsiness alerts.
//
// ── Design contract 
// 1. playRandomAlert() suspends until the clip finishes OR stop() is called.
// 2. stop() is synchronous, safe from dispose() and audio takeover code.
// 3. _safeComplete() prevents double-completion.
// 4. Call initialize() once before playback; dispose() on widget dispose.
// ─────────────────────────────────────────────────────────────────────────────

import 'dart:async';
import 'dart:math';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';

class FallbackAudioPlayer {
  FallbackAudioPlayer({required List<String> assets})
      : _assets = List.unmodifiable(assets);

  final List<String> _assets;
  final _random = Random();
  final _player = AudioPlayer();

  Completer<void>? _playCompleter;
  StreamSubscription<void>? _completeSub;

  bool _initialized = false;
  bool _disposed = false;

  bool get isInitialized => _initialized && !_disposed;

  Future<void> initialize() async {
    if (_initialized || _disposed) return;

    _completeSub = _player.onPlayerComplete.listen((_) {
      _safeComplete();
      debugPrint('[FallbackAudioPlayer] Clip completed naturally');
    });

    try {
      await _player.setVolume(1.0);
      await _player.setReleaseMode(ReleaseMode.stop);
    } catch (e) {
      debugPrint('[FallbackAudioPlayer] Pre-warm warning (non-fatal): $e');
    }

    _initialized = true;
    debugPrint('[FallbackAudioPlayer] Initialized — '
        '${_assets.length} clip(s) in pool');
  }

  Future<void> playRandomAlert() async {
    if (_disposed || !_initialized || _assets.isEmpty) return;

    // Resolve any stale completer from the previous cycle.
    _safeComplete();

    // **Await** the player stop to ensure it is fully idle before starting.
    try {
      await _player.stop();
    } catch (_) {}

    if (_disposed) return;

    _playCompleter = Completer<void>();
    final path = _assets[_random.nextInt(_assets.length)];
    debugPrint('[FallbackAudioPlayer] Playing: $path');

    try {
      await _player.play(AssetSource(path));
      await _playCompleter!.future;
      debugPrint('[FallbackAudioPlayer] Playback finished for: $path');
    } catch (e) {
      debugPrint('[FallbackAudioPlayer] Playback error: $e');
    } finally {
      _safeComplete();
    }
  }

  void stop() {
    debugPrint('[FallbackAudioPlayer] stop() called');
    _safeComplete();
    _player.stop();
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    debugPrint('[FallbackAudioPlayer] Disposing');
    _safeComplete();
    _completeSub?.cancel();
    _player.dispose();
  }

  void _safeComplete() {
    final c = _playCompleter;
    _playCompleter = null;
    if (c != null && !c.isCompleted) {
      c.complete();
    }
  }
}