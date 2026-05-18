// lib/services/constants.dart

import 'package:flutter/painting.dart'; // for Duration

const List<String> kFallbackAudioAssets = [
  'audio/fallback/alert_1.mp3',
  'audio/fallback/alert_2.mp3',
  'audio/fallback/alert_3.mp3',
];

const int kMaxFps = 15;
const Duration kMinFrameInterval = Duration(microseconds: 1000000 ~/ kMaxFps); // ~66 ms

const int kStableFrames = 3;
const int kDecayFrames = 5;

const Duration kGemmaCooldown = Duration(seconds: 5);

const List<String> kAnalyzingMessages = [
  'Monitoring driver…',
  'Detecting fatigue…',
  'Analyzing alertness…',
];

const int kPerclosWindow = 30;

const List<String> kHighActions = [
  'Pull over and rest immediately.',
  'Stop the vehicle as soon as it is safe.',
  'You are too tired to drive — pull over now.',
  'Find a safe place to stop immediately.',
];

const List<String> kMediumActions = [
  'Consider taking a short break soon.',
  'Stay alert — find a place to rest if you feel tired.',
  'Your alertness is dropping — take a break when you can.',
];