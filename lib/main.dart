// lib/main.dart

import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:camera/camera.dart';
import 'camera_screen.dart';
import 'services/gemma_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Driver Drowsiness AI',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark().copyWith(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepOrange),
      ),
      home: const _PermissionGate(),
    );
  }
}

class _PermissionGate extends StatefulWidget {
  const _PermissionGate();

  @override
  State<_PermissionGate> createState() => _PermissionGateState();
}

class _PermissionGateState extends State<_PermissionGate> {
  CameraDescription? _camera;
  PermissionStatus? _cameraStatus;

  @override
  void initState() {
    super.initState();
    _setup();
  }

  Future<void> _setup() async {
    final status = await Permission.camera.request();
    if (!mounted) return;
    setState(() => _cameraStatus = status);
    if (status.isGranted) {
      final cameras = await availableCameras();
      final front = cameras.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.front,
        orElse: () => cameras.first,
      );
      if (!mounted) return;
      setState(() => _camera = front);
      unawaited(GemmaService.instance.initialize());
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_cameraStatus == null) {
      return const Scaffold(
        backgroundColor: Color(0xFF07111F),
        body: Center(child: CircularProgressIndicator()),
      );
    }
    if (_cameraStatus!.isDenied || _cameraStatus!.isPermanentlyDenied) {
      return Scaffold(
        backgroundColor: const Color(0xFF07111F),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.camera_alt, size: 64, color: Colors.grey),
                const SizedBox(height: 16),
                Text(
                  _cameraStatus!.isPermanentlyDenied
                      ? 'Camera permission permanently denied.\nEnable it in Settings.'
                      : 'Camera permission is required.',
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white70),
                ),
                const SizedBox(height: 24),
                ElevatedButton(
                  onPressed: () async {
                    if (_cameraStatus!.isPermanentlyDenied) {
                      await openAppSettings();
                    } else {
                      await _setup();
                    }
                  },
                  child: Text(
                    _cameraStatus!.isPermanentlyDenied
                        ? 'Open Settings'
                        : 'Grant Permission',
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }
    if (_camera == null) {
      return const Scaffold(
        backgroundColor: Color(0xFF07111F),
        body: Center(child: CircularProgressIndicator()),
      );
    }

    return ValueListenableBuilder<GemmaState>(
      valueListenable: GemmaService.instance.state,
      builder: (context, state, _) {
        if (state == GemmaState.ready) {
          return CameraScreen(camera: _camera!);
        }
        return _ModelLoadingScreen(state: state);
      },
    );
  }
}

class _ModelLoadingScreen extends StatefulWidget {
  final GemmaState state;
  const _ModelLoadingScreen({required this.state});

  @override
  State<_ModelLoadingScreen> createState() => _ModelLoadingScreenState();
}

class _ModelLoadingScreenState extends State<_ModelLoadingScreen> {
  double _lastProgress = 0.0;
  int _lastMillis = 0;
  String _speedString = '-- MB/s';
  String _etaString = '--';
  Timer? _statsTimer;

  @override
  void dispose() {
    _statsTimer?.cancel();
    super.dispose();
  }

  void _startStatsTimer() {
    _statsTimer?.cancel();
    _statsTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      _updateStats();
    });
    _updateStats(); // immediate first calculation
  }

  void _updateStats() {
    final svc = GemmaService.instance;
    final int received = svc.downloadReceivedBytes.value;
    final int total = svc.downloadTotalBytes.value;
    final double progress = svc.downloadProgress.value;

    if (total <= 0 || progress <= 0.0 || progress >= 1.0) {
      if (mounted) {
        setState(() {
          _speedString = '-- MB/s';
          _etaString = '--';
        });
      }
      return;
    }

    final int remaining = total - received;
    final int now = DateTime.now().millisecondsSinceEpoch;

    double speedBytesPerSec = 0.0;
    if (_lastMillis > 0 && progress > _lastProgress) {
      final double dProgress = progress - _lastProgress;
      final double dt = (now - _lastMillis) / 1000.0;
      if (dt > 0.25) {
        final double bytesAdvanced = dProgress * total;
        speedBytesPerSec = bytesAdvanced / dt;
      }
    }

    _lastProgress = progress;
    _lastMillis = now;

    String speedStr;
    if (speedBytesPerSec >= 1e6) {
      speedStr = '${(speedBytesPerSec / 1e6).toStringAsFixed(1)} MB/s';
    } else if (speedBytesPerSec >= 1e3) {
      speedStr = '${(speedBytesPerSec / 1e3).toStringAsFixed(0)} KB/s';
    } else if (speedBytesPerSec > 0) {
      speedStr = '${speedBytesPerSec.toStringAsFixed(0)} B/s';
    } else {
      speedStr = 'calculating…';
    }

    String etaStr;
    if (speedBytesPerSec > 0 && remaining > 0) {
      final double secs = remaining / speedBytesPerSec;
      if (secs > 3600) {
        etaStr = '> ${(secs / 3600).ceil()} h left';
      } else if (secs > 60) {
        etaStr = '~ ${(secs / 60).ceil()} min left';
      } else {
        etaStr = '~ ${secs.ceil()} s left';
      }
    } else {
      etaStr = '--';
    }

    if (mounted) {
      setState(() {
        _speedString = speedStr;
        _etaString = etaStr;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.state;

    // Start the timer when we first see the downloading state
    if (state == GemmaState.downloading && _statsTimer == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _startStatsTimer();
      });
    }

    // Stop the timer if we leave the downloading state
    if (state != GemmaState.downloading && _statsTimer != null) {
      _statsTimer?.cancel();
      _statsTimer = null;
    }

    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.memory, size: 64, color: Colors.deepOrange),
                const SizedBox(height: 24),

                if (state == GemmaState.downloading) ...[
                  const Text(
                    'Downloading AI Model…',
                    style: TextStyle(color: Colors.white, fontSize: 18),
                  ),
                  const SizedBox(height: 24),

                  Card(
                    color: Colors.white.withOpacity(0.05),
                    elevation: 0,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                      side: BorderSide(color: Colors.white.withOpacity(0.1)),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.all(20),
                      child: Column(
                        children: [
                          ValueListenableBuilder<double>(
                            valueListenable:
                                GemmaService.instance.downloadProgress,
                            builder: (_, progress, __) {
                              final percent =
                                  (progress * 100).toStringAsFixed(1);
                              return Column(
                                children: [
                                  ClipRRect(
                                    borderRadius: BorderRadius.circular(8),
                                    child: LinearProgressIndicator(
                                      value: progress,
                                      minHeight: 12,
                                      backgroundColor:
                                          Colors.white.withOpacity(0.1),
                                      valueColor:
                                          const AlwaysStoppedAnimation<Color>(
                                              Colors.deepOrange),
                                    ),
                                  ),
                                  const SizedBox(height: 12),
                                  Text(
                                    '$percent%',
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 28,
                                      fontWeight: FontWeight.w800,
                                    ),
                                  ),
                                ],
                              );
                            },
                          ),
                          const SizedBox(height: 16),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                            children: [
                              _StatItem(
                                icon: Icons.speed,
                                label: 'Speed',
                                value: _speedString,
                              ),
                              _StatItem(
                                icon: Icons.timer_outlined,
                                label: 'Remaining',
                                value: _etaString,
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                ]

                else if (state == GemmaState.loading ||
                    state == GemmaState.checking) ...[
                  const CircularProgressIndicator(),
                  const SizedBox(height: 16),
                  Text(
                    state == GemmaState.loading
                        ? 'Loading model...'
                        : 'Preparing...',
                    style: const TextStyle(color: Colors.white),
                  ),
                ]

                else if (state == GemmaState.failed) ...[
                  const Icon(Icons.error, color: Colors.red, size: 48),
                  const SizedBox(height: 16),
                  ValueListenableBuilder<String?>(
                    valueListenable: GemmaService.instance.error,
                    builder: (_, err, __) {
                      return Text(
                        err ?? 'Unknown error',
                        style: const TextStyle(color: Colors.red),
                        textAlign: TextAlign.center,
                      );
                    },
                  ),
                  const SizedBox(height: 24),
                  ElevatedButton(
                    onPressed: () => GemmaService.instance.retry(),
                    child: const Text('Retry'),
                  ),
                ]

                else ...[
                  const CircularProgressIndicator(),
                ],

                const SizedBox(height: 32),
                const Text(
                  'Runs fully offline after setup',
                  style: TextStyle(color: Colors.white30),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ── Reusable stat display ────────────────────────────────────────────────────
class _StatItem extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  const _StatItem({
    required this.icon,
    required this.label,
    required this.value,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Icon(icon, color: Colors.white38, size: 20),
        const SizedBox(height: 6),
        Text(
          label,
          style: const TextStyle(color: Colors.white38, fontSize: 11),
        ),
        const SizedBox(height: 2),
        Text(
          value,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 14,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }
}