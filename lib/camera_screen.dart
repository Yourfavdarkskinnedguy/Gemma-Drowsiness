// lib/camera_screen.dart

import 'dart:async';
import 'dart:io';
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'models/audio_source.dart';
import 'models/phase.dart';
import 'services/audio_manager.dart';
import 'services/constants.dart';
import 'services/risk_detector.dart';
import 'services/face_detection_service.dart';
import 'services/analyzing_controller.dart';
import 'services/fallback_audio_player.dart';
import 'services/gemma_service.dart';

class CameraScreen extends StatefulWidget {
  final CameraDescription camera;
  const CameraScreen({super.key, required this.camera});

  @override
  State<CameraScreen> createState() => _CameraScreenState();
}

class _CameraScreenState extends State<CameraScreen>
    with WidgetsBindingObserver {
  CameraController? _controller;
  late final FaceDetectionService _faceService;
  late final AudioManager _audioManager;
  late final RiskDetector _riskDetector;
  late final AnalyzingController _analyzingCtrl;

  double _ecr = 0.0;
  double _perclos = 0.0;
  bool _faceDetected = false;

  bool _processingFrame = false;
  bool _processingInference = false;

  DateTime _lastFrameProcessed = DateTime.fromMillisecondsSinceEpoch(0);

  DateTime _lastGemmaCall = DateTime.fromMillisecondsSinceEpoch(0);

  String _displayRisk = 'LOW';
  Phase _phase = Phase.idle;
  String _reason = '';
  String _action = '';

  int _highActionIdx = 0;
  int _mediumActionIdx = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    final fallbackPlayer = FallbackAudioPlayer(assets: kFallbackAudioAssets);
    unawaited(fallbackPlayer.initialize());

    _audioManager = AudioManager(fallbackPlayer: fallbackPlayer);
    unawaited(_audioManager.initializeTts());

    _riskDetector = RiskDetector();
    _faceService = FaceDetectionService();
    _analyzingCtrl = AnalyzingController(
      onUpdate: (msg) {
        if (mounted && _phase == Phase.analyzing) {
          setState(() => _reason = msg);
        }
      },
    );

    _initCamera();
  }

  @override
  void dispose() {
    _analyzingCtrl.stop();
    WidgetsBinding.instance.removeObserver(this);
    _audioManager.dispose();
    _controller?.stopImageStream();
    _controller?.dispose();
    _faceService.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState appState) {
    final c = _controller;
    if (c == null || !c.value.isInitialized) return;
    if (appState == AppLifecycleState.inactive) {
      c.stopImageStream();
      _audioManager.stopAllAudio(immediate: true);
    } else if (appState == AppLifecycleState.resumed &&
        !c.value.isStreamingImages) {
      c.startImageStream(_processFrame);
    }
  }

  static ImageFormatGroup get platformImageFormat =>
      Platform.isAndroid ? ImageFormatGroup.yuv420 : ImageFormatGroup.bgra8888;

  Future<void> _initCamera() async {
    try {
      _controller = CameraController(
        widget.camera,
        ResolutionPreset.low,
        enableAudio: false,
        imageFormatGroup: platformImageFormat,
      );
      await _controller!.initialize();
      if (!mounted) return;
      await _controller!.startImageStream(_processFrame);
      if (mounted) setState(() {});
    } catch (e) {
      debugPrint('[CameraScreen] Camera init failed: $e');
    }
  }

  Future<void> _processFrame(CameraImage image) async {
    final now = DateTime.now();
    if (now.difference(_lastFrameProcessed) < kMinFrameInterval) return;
    if (_processingFrame) return;

    _lastFrameProcessed = now;
    _processingFrame = true;

    try {
      final face = await _faceService.detectFace(image, widget.camera.sensorOrientation);
      if (!mounted) return;

      if (!face.detected) {
        if (_faceDetected) {
          debugPrint('[CameraScreen] Face lost — resetting state');
          _resetState();
        }
        return;
      }

      final result = _riskDetector.process(face.avg);
      _ecr = result.ecr;
      _perclos = result.perclos;
      final smoothed = result.risk;
      final isHighTransition = result.isHigh;
      final isMedTransition = result.isMed;

      if (mounted) {
        setState(() {
          _faceDetected = true;
          _displayRisk = smoothed;
        });
        _audioManager.setRisk(smoothed);
      }

      if (isHighTransition) {
        _showFallback('HIGH', _nextHighAction());
        unawaited(_fireHaptic(isHigh: true));
        _audioManager.triggerFallbackAudio();
      } else if (smoothed == 'LOW') {
        // Check if anything is still active
        final anythingActive = _audioManager.isGemmaActive ||
            _phase != Phase.idle; // fallback loop flag handled by audio manager
        if (anythingActive) {
          _audioManager.stopAllAudio(immediate: false);
          if (mounted && _phase != Phase.idle) {
            setState(() {
              _phase = Phase.idle;
              _reason = '';
              _action = '';
            });
            _analyzingCtrl.stop();
          }
        }
      }

      if (isMedTransition) {
        _audioManager.stopAllAudio(immediate: false);
        _showFallback('MEDIUM', _nextMediumAction());
        unawaited(_fireHaptic(isHigh: false));
      }

      if (isHighTransition &&
          !_processingInference &&
          GemmaService.instance.isReady &&
          now.difference(_lastGemmaCall) >= kGemmaCooldown) {
        _lastGemmaCall = now;
        _processingInference = true;
        _analyzingCtrl.start();
        unawaited(_runGemma(_ecr, _perclos));
      }
    } catch (e, st) {
      debugPrint('[CameraScreen] Frame pipeline error: $e\n$st');
    } finally {
      _processingFrame = false;
    }
  }

  Future<void> _runGemma(double ecr, double perclos) async {
    try {
      final ctx = ecr > 0.65 || perclos > 25
          ? DrowsinessContext.eyesClosed
          : DrowsinessContext.general;

      final output = await GemmaService.instance.analyze(
        ecr: ecr,
        perclos: perclos,
        context: ctx,
        lastResult: GemmaOutput(
          risk: _displayRisk,
          reason: _reason,
          action: _action,
          isFallback: true,
        ),
      );

      if (!mounted) return;
      _analyzingCtrl.stop();

      final actionToSpeak = output.action.trim();
      final isValidResponse = !output.isFallback && actionToSpeak.isNotEmpty;

      if (isValidResponse) {
        debugPrint('[CameraScreen] Gemma valid response — taking audio ownership\n'
            '  reason: "${output.reason}"\n'
            '  action: "$actionToSpeak"');

        if (_audioManager.isGemmaActive) {
          debugPrint('[CameraScreen] Gemma already active – updating action text only');
          _audioManager.updateTtsAction(actionToSpeak);
          if (mounted) {
            setState(() {
              _phase = Phase.enriched;
              _reason = output.reason;
              _action = actionToSpeak;
            });
          }
          return;
        }

        _audioManager.claimGemmaOwnership();

        if (!mounted) return;
        setState(() {
          _phase = Phase.enriched;
          _reason = output.reason;
          _action = actionToSpeak;
        });
        _audioManager.updateTtsAction(actionToSpeak);

        if (_displayRisk == 'HIGH') {
          _audioManager.startGemmaTtsLoop(actionToSpeak);
        } else {
          debugPrint('[CameraScreen] Risk no longer HIGH — releasing audio ownership');
          _audioManager.stopAllAudio(immediate: false);
        }
      } else {
        if (mounted) setState(() => _phase = Phase.fallback);
        debugPrint('[CameraScreen] Gemma returned fallback — audio unchanged');
      }
    } catch (e, st) {
      debugPrint('[CameraScreen] Gemma inference error: $e\n$st');
      if (mounted) setState(() => _phase = Phase.fallback);
    } finally {
      _processingInference = false;
    }
  }

  void _resetState() {
    _audioManager.stopAllAudio(immediate: false);
    _analyzingCtrl.stop();
    _riskDetector.reset();
    if (mounted) {
      setState(() {
        _faceDetected = false;
        _ecr = 0.0;
        _perclos = 0.0;
        _displayRisk = 'LOW';
        _phase = Phase.idle;
        _reason = '';
        _action = '';
      });
    }
  }

  String _nextHighAction() {
    final s = kHighActions[_highActionIdx % kHighActions.length];
    _highActionIdx++;
    return s;
  }

  String _nextMediumAction() {
    final s = kMediumActions[_mediumActionIdx % kMediumActions.length];
    _mediumActionIdx++;
    return s;
  }

  void _showFallback(String risk, String action) {
    if (!mounted) return;
    setState(() {
      _phase = Phase.fallback;
      _reason = risk == 'HIGH'
          ? 'Strong signs of driver fatigue detected'
          : 'Early fatigue signs detected';
      _action = action;
    });
  }

  Future<void> _fireHaptic({required bool isHigh}) async {
    if (isHigh) {
      for (int i = 0; i < 3; i++) {
        try { await HapticFeedback.heavyImpact(); } catch (_) {}
        await Future.delayed(const Duration(milliseconds: 180));
      }
    } else {
      try { await HapticFeedback.mediumImpact(); } catch (_) {}
    }
  }

  // ── UI (unchanged from the original – same as before) ───────────────────
  @override
  Widget build(BuildContext context) {
    final ctrl = _controller;
    if (ctrl == null || !ctrl.value.isInitialized) {
      return const Scaffold(
        backgroundColor: Color(0xFF07111F),
        body: Center(child: CircularProgressIndicator()),
      );
    }

    final riskColor = switch (_displayRisk) {
      'HIGH' => const Color(0xFFFF4D4D),
      'MEDIUM' => const Color(0xFFFFB020),
      _ => const Color(0xFF30D158),
    };

    final isAnalyzing = _phase == Phase.analyzing;
    final showDangerOverlay = _displayRisk == 'HIGH';

    return Scaffold(
      backgroundColor: const Color(0xFF07111F),
      body: Stack(
        children: [
          Container(
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Color(0xFF0D1626),
                  Color(0xFF07111F),
                  Color(0xFF040A12),
                ],
              ),
            ),
          ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
              child: Column(
                children: [
                  _buildTopBar(riskColor),
                  const SizedBox(height: 14),
                  Expanded(
                    child: Center(
                      child: Container(
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(28),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withOpacity(0.35),
                              blurRadius: 24,
                              offset: const Offset(0, 16),
                            ),
                          ],
                        ),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(28),
                          child: Stack(
                            children: [
                              Positioned.fill(
                                child: ClipRect(
                                  child: FittedBox(
                                    fit: BoxFit.cover,
                                    alignment: Alignment.center,
                                    child: SizedBox(
                                      width: ctrl.value.previewSize?.height ?? 1,
                                      height: ctrl.value.previewSize?.width ?? 1,
                                      child: CameraPreview(ctrl),
                                    ),
                                  ),
                                ),
                              ),
                              Positioned.fill(
                                child: IgnorePointer(
                                  child: Container(
                                    decoration: BoxDecoration(
                                      gradient: LinearGradient(
                                        begin: Alignment.topCenter,
                                        end: Alignment.bottomCenter,
                                        colors: [
                                          Colors.black.withOpacity(0.06),
                                          Colors.transparent,
                                          Colors.black.withOpacity(0.18),
                                        ],
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                              AnimatedOpacity(
                                opacity: showDangerOverlay ? 1.0 : 0.0,
                                duration: const Duration(milliseconds: 220),
                                child: IgnorePointer(
                                  child: Container(
                                    decoration: BoxDecoration(
                                      color: Colors.red.withOpacity(0.22),
                                    ),
                                    child: Center(
                                      child: Container(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 18,
                                          vertical: 14,
                                        ),
                                        decoration: BoxDecoration(
                                          color: Colors.black.withOpacity(0.32),
                                          borderRadius: BorderRadius.circular(18),
                                          border: Border.all(
                                            color: Colors.redAccent.withOpacity(0.8),
                                            width: 1.4,
                                          ),
                                        ),
                                        child: Column(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            Icon(
                                              Icons.warning_rounded,
                                              size: 48,
                                              color: Colors.redAccent.withOpacity(0.95),
                                            ),
                                            const SizedBox(height: 8),
                                            const Text(
                                              'DANGER',
                                              style: TextStyle(
                                                color: Colors.white,
                                                fontSize: 18,
                                                fontWeight: FontWeight.w900,
                                                letterSpacing: 1.8,
                                              ),
                                            ),
                                            const SizedBox(height: 4),
                                            const Text(
                                              'Driver fatigue detected',
                                              style: TextStyle(
                                                color: Colors.white70,
                                                fontSize: 13,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                              Positioned(
                                left: 14,
                                right: 14,
                                bottom: 14,
                                child: _buildPreviewFooter(
                                  riskColor: riskColor,
                                  isAnalyzing: isAnalyzing,
                                ),
                              ),
                              Positioned(
                                left: 14,
                                top: 14,
                                child: _buildRiskPill(riskColor),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 14),
                  _buildInfoCard(riskColor, isAnalyzing),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }


  Widget _buildTopBar(Color riskColor) {
    return Row(
      children: [
        Container(
          width: 46, height: 46,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(15),
            gradient: const LinearGradient(
              begin: Alignment.topLeft, end: Alignment.bottomRight,
              colors: [Color(0xFF1E2A44), Color(0xFF11192B)],
            ),
            border: Border.all(color: Colors.white.withOpacity(0.06)),
          ),
          child: const Icon(Icons.visibility_rounded, color: Colors.white, size: 24),
        ),
        const SizedBox(width: 12),
        const Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Gemma-Drowsiness', style: TextStyle(color: Colors.white, fontSize: 24, fontWeight: FontWeight.w900, letterSpacing: 0.2)),
              SizedBox(height: 3),
              Text('Real-time drowsiness monitoring with Gemma', style: TextStyle(color: Colors.white54, fontSize: 12.5)),
            ],
          ),
        ),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: riskColor.withOpacity(0.12),
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: riskColor.withOpacity(0.35)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                _displayRisk == 'HIGH' ? Icons.priority_high_rounded
                    : _displayRisk == 'MEDIUM' ? Icons.report_problem_rounded
                    : Icons.verified_rounded,
                size: 16, color: riskColor,
              ),
              const SizedBox(width: 6),
              Text(
                switch (_displayRisk) { 'HIGH' => 'Danger', 'MEDIUM' => 'Caution', _ => 'Safe' },
                style: TextStyle(color: riskColor, fontSize: 12, fontWeight: FontWeight.w800),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildRiskPill(Color riskColor) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 250),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.black.withOpacity(0.38),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: riskColor.withOpacity(0.65)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _RiskDot(risk: _displayRisk, color: riskColor),
          const SizedBox(width: 8),
          Text(
            switch (_displayRisk) { 'HIGH' => 'DANGER', 'MEDIUM' => 'CAUTION', _ => 'ALERT' },
            style: TextStyle(color: riskColor, fontSize: 13, fontWeight: FontWeight.w900, letterSpacing: 1.2),
          ),
        ],
      ),
    );
  }

  Widget _buildPreviewFooter({required Color riskColor, required bool isAnalyzing}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: Colors.black.withOpacity(0.42),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.white.withOpacity(0.08)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (_reason.isNotEmpty)
                  AnimatedSwitcher(
                    duration: const Duration(milliseconds: 250),
                    child: Text(_reason, key: ValueKey(_reason),
                      style: TextStyle(
                        color: isAnalyzing ? Colors.white54 : Colors.white,
                        fontSize: 13.5, height: 1.25,
                        fontStyle: isAnalyzing ? FontStyle.italic : FontStyle.normal,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                if (_action.isNotEmpty) ...[
                  const SizedBox(height: 7),
                  AnimatedSwitcher(
                    duration: const Duration(milliseconds: 250),
                    child: Container(
                      key: ValueKey(_action),
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
                      decoration: BoxDecoration(
                        color: riskColor.withOpacity(0.14),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: riskColor.withOpacity(0.35)),
                      ),
                      child: Text(_action, style: TextStyle(color: riskColor, fontSize: 12.5, fontWeight: FontWeight.w800)),
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 10),
          if (_processingInference || isAnalyzing)
            SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2.2, color: riskColor.withOpacity(0.75)))
          else
            Icon(_displayRisk == 'HIGH' ? Icons.warning_rounded : Icons.auto_awesome_rounded,
                color: riskColor.withOpacity(0.9), size: 20),
        ],
      ),
    );
  }

  Widget _buildInfoCard(Color riskColor, bool isAnalyzing) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
      decoration: BoxDecoration(
        color: const Color(0xFF111A2B).withOpacity(0.92),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: Colors.white.withOpacity(0.06)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              _RiskDot(risk: _displayRisk, color: riskColor),
              const SizedBox(width: 10),
              Text(
                switch (_displayRisk) { 'HIGH' => 'DANGER', 'MEDIUM' => 'CAUTION', _ => 'MONITORING' },
                style: TextStyle(color: riskColor, fontSize: 18, fontWeight: FontWeight.w900, letterSpacing: 0.8),
              ),
              if (isAnalyzing) ...[
                const SizedBox(width: 10),
                SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: riskColor.withOpacity(0.7))),
              ],
              const SizedBox(width: 10),
              // Audio source badge (debug)
              if (_audioManager.isGemmaActive)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                  decoration: BoxDecoration(color: Colors.white.withOpacity(0.06), borderRadius: BorderRadius.circular(6)),
                  child: const Text('🤖 Gemma', style: TextStyle(color: Colors.white38, fontSize: 10)),
                )
              else if (_audioManager.isGemmaActive == false) // fallback active? Could add but not essential
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                  decoration: BoxDecoration(color: Colors.white.withOpacity(0.06), borderRadius: BorderRadius.circular(6)),
                  child: const Text('🔊 Audio', style: TextStyle(color: Colors.white38, fontSize: 10)),
                ),
            ],
          ),
          const SizedBox(height: 10),
          Text('ECR ${_ecr.toStringAsFixed(2)}   •   PERCLOS ${_perclos.toStringAsFixed(0)}%',
              style: const TextStyle(color: Colors.white60, fontSize: 12, fontFamily: 'monospace')),
          const SizedBox(height: 8),
          Text('Camera and face detection stay live on-device.',
              style: TextStyle(color: Colors.white.withOpacity(0.35), fontSize: 11.5, height: 1.35)),
          if (!GemmaService.instance.isReady)
            const Padding(padding: EdgeInsets.only(top: 6), child: Text('AI model loading…', style: TextStyle(color: Colors.white24, fontSize: 10.5))),
          if (!_faceDetected)
            const Padding(padding: EdgeInsets.only(top: 6), child: Text('No face detected', style: TextStyle(color: Colors.redAccent, fontSize: 11))),
        ],
      ),
    );
  }
}

class _RiskDot extends StatefulWidget {
  final String risk;
  final Color color;
  const _RiskDot({required this.risk, required this.color});
  @override
  State<_RiskDot> createState() => _RiskDotState();
}

class _RiskDotState extends State<_RiskDot> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 650),
  )..repeat(reverse: true);

  late final Animation<double> _s = Tween(begin: 0.8, end: 1.4).animate(
    CurvedAnimation(parent: _c, curve: Curves.easeInOut),
  );

  @override
  void dispose() { _c.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) {
    final dot = Container(
      width: 14, height: 14,
      decoration: BoxDecoration(
        color: widget.color,
        shape: BoxShape.circle,
        boxShadow: widget.risk == 'HIGH'
            ? [BoxShadow(color: widget.color.withOpacity(0.65), blurRadius: 10, spreadRadius: 3)]
            : null,
      ),
    );
    return widget.risk == 'HIGH' ? ScaleTransition(scale: _s, child: dot) : dot;
  }
}