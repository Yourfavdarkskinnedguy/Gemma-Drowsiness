// lib/services/risk_detector.dart

import 'dart:collection';

class RiskDetector {
  String _pendingRisk = 'LOW';
  int _pendingCount = 0;
  int _decayCount = 0;
  String _smoothedRisk = 'LOW';
  String _prevSmoothed = 'LOW';

  final Queue<bool> _closureHistory = Queue<bool>();
  double _baselineOpen = 0.55;
  double _ecmEma = -1.0;
  static const double _emaAlpha = 0.35;

  double ecr = 0.0;
  double perclos = 0.0;

  /// Process one frame. Returns (ecr, perclos, risk, isHighTransition, isMedTransition).
  ({double ecr, double perclos, String risk, bool isHigh, bool isMed}) process(double avgOpen) {
    ecr = _computeECR(avgOpen);
    perclos = _computePERCLOS(avgOpen);
    final instant = _instantRisk(ecr, perclos);
    final smoothed = _smooth(instant);

    final isHighTransition = smoothed == 'HIGH' && _prevSmoothed != 'HIGH';
    final isMedTransition = smoothed == 'MEDIUM' && _prevSmoothed == 'LOW';

    _prevSmoothed = smoothed;
    return (ecr: ecr, perclos: perclos, risk: smoothed, isHigh: isHighTransition, isMed: isMedTransition);
  }

  void reset() {
    _closureHistory.clear();
    _ecmEma = -1.0;
    _baselineOpen = 0.55;
    _pendingRisk = 'LOW';
    _pendingCount = 0;
    _decayCount = 0;
    _smoothedRisk = 'LOW';
    _prevSmoothed = 'LOW';
    ecr = 0.0;
    perclos = 0.0;
  }

  String _instantRisk(double ecr, double perclos) {
    if (perclos > 40 || ecr > 0.8) return 'HIGH';
    if (perclos > 20 || ecr > 0.65) return 'MEDIUM';
    return 'LOW';
  }

  String _smooth(String raw) {
    if (raw == _pendingRisk) {
      _pendingCount++;
    } else {
      _pendingRisk = raw;
      _pendingCount = 1;
    }

    if (raw == 'LOW') {
      _decayCount++;
      if (_decayCount >= 5 /* kDecayFrames */) _smoothedRisk = 'LOW';
    } else {
      _decayCount = 0;
    }

    if (_pendingCount >= 3 /* kStableFrames */) _smoothedRisk = raw;
    return _smoothedRisk;
  }

  double _computeECR(double avgOpen) {
    if (avgOpen > 0.5) {
      _baselineOpen = _baselineOpen * 0.92 + avgOpen * 0.08;
    }
    _ecmEma = _ecmEma < 0
        ? avgOpen
        : _emaAlpha * avgOpen + (1 - _emaAlpha) * _ecmEma;

    final rel = (_ecmEma / _baselineOpen.clamp(0.3, 1.0)).clamp(0.0, 1.0);
    return (1.0 - rel).clamp(0.0, 1.0);
  }

  double _computePERCLOS(double avgOpen) {
    _closureHistory.addLast(_ecmEma < 0.35);
    if (_closureHistory.length > 30 /* kPerclosWindow */) {
      _closureHistory.removeFirst();
    }
    if (_closureHistory.isEmpty) return 0.0;
    return (_closureHistory.where((c) => c).length / _closureHistory.length) * 100.0;
  }
}