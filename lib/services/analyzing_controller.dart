// lib/services/analyzing_controller.dart

import 'dart:async';
import 'constants.dart';

class AnalyzingController {
  int step = 0;
  Timer? _timer;
  final void Function(String message) onUpdate;

  AnalyzingController({required this.onUpdate});

  void start() {
    stop();
    step = 0;
    onUpdate(kAnalyzingMessages[0]);

    _timer = Timer.periodic(const Duration(milliseconds: 1800), (_) {
      step = (step + 1) % kAnalyzingMessages.length;
      onUpdate(kAnalyzingMessages[step]);
    });
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }
}