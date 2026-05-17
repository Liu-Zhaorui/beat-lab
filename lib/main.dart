import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:record/record.dart';
import 'package:sound_generator/sound_generator.dart';
import 'package:sound_generator/waveTypes.dart';

void main() {
  runApp(const BeatPreviewApp());
}

class BeatPreviewApp extends StatelessWidget {
  const BeatPreviewApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Piano Beat Analyzer Preview',
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF35D0FF)),
        scaffoldBackgroundColor: const Color(0xFF0C1218),
      ),
      home: const PreviewHomePage(),
    );
  }
}

class AnalysisFrame {
  const AnalysisFrame({
    required this.f1,
    required this.f2,
    required this.beatHz,
    required this.intervalLabel,
    required this.harmonicPairLabel,
    required this.cents,
    required this.envelope,
    required this.beatDepth,
    required this.beatConfidence,
    required this.activeToneCount,
    required this.strength,
    required this.intervalLocked,
    required this.timestamp,
    this.beatRootPartialHz = 0,
    this.beatCrownPartialHz = 0,
    this.beatRootPartialSource = '',
    this.beatCrownPartialSource = '',
    this.note1Partials = const [],
    this.note2Partials = const [],
  });

  final double f1;
  final double f2;
  final double beatHz;
  final String intervalLabel;
  final String harmonicPairLabel;
  final double cents;
  final double envelope;
  final double beatDepth;
  final double beatConfidence;
  final int activeToneCount;
  final double strength;
  final bool intervalLocked;
  final int timestamp;
  final double beatRootPartialHz;
  final double beatCrownPartialHz;
  final String beatRootPartialSource;
  final String beatCrownPartialSource;
  final List<double> note1Partials;
  final List<double> note2Partials;

  static const empty = AnalysisFrame(
    f1: 0,
    f2: 0,
    beatHz: 0,
    intervalLabel: 'Unknown',
    harmonicPairLabel: '--',
    cents: 0,
    envelope: 0,
    beatDepth: 0,
    beatConfidence: 0,
    activeToneCount: 0,
    strength: 0,
    intervalLocked: false,
    timestamp: 0,
    beatRootPartialHz: 0,
    beatCrownPartialHz: 0,
    beatRootPartialSource: '',
    beatCrownPartialSource: '',
    note1Partials: [],
    note2Partials: [],
  );
}

class MicBeatAnalyzer {
  MicBeatAnalyzer({this.sampleRate = 44100, this.fftSize = 4096})
    : _cqtFrequencies = _buildCqtFrequencies() {
    _precomputeCqtKernels();
  }

  final int sampleRate;
  final int fftSize;
  final List<double> _cqtFrequencies;
  late final List<List<double>> _cqtKernelCos;
  late final List<List<double>> _cqtKernelSin;

  static const int _cqtBinsPerOctave = 24;
  static const double _cqtMinHz = 55.0;
  static const double _cqtMaxHz = 2500.0;

  final AudioRecorder _recorder = AudioRecorder();
  final StreamController<AnalysisFrame> _frames = StreamController.broadcast();

  StreamSubscription<Uint8List>? _sub;

  final List<double> _buffer = <double>[];
  double _envelopeSmooth = 0;
  double _f1Smooth = 0;
  double _f2Smooth = 0;
  double _beatSmooth = 0;
  double _strengthSmooth = 0;
  double _beatMixFast = 0;
  double _beatMixSlow = 0;
  double _beatDepthSmooth = 0;
  double _beatConfidenceSmooth = 0;
  double _noiseEnvelope = 0.004;

  double silenceGateOffset = 0.0045;
  int _silenceFrames = 0;
  int _stableIntervalFrames = 0;
  int _freqStableFrames = 0;
  double _candF1 = 0;
  double _candF2 = 0;
  double _lastBeatRootPartialHz = 0;
  double _lastBeatCrownPartialHz = 0;
  String _lastBeatRootPartialSource = '';
  String _lastBeatCrownPartialSource = '';
  List<double> _note1PartialSmooth = List<double>.filled(8, 0);
  List<double> _note2PartialSmooth = List<double>.filled(8, 0);
  String? _lastLockedIntervalKey;
  _IntervalSpec? _lockedInterval;

  Stream<AnalysisFrame> get frames => _frames.stream;

  Future<bool> start() async {
    final hasPermission = await _recorder.hasPermission();
    if (!hasPermission) return false;

    final stream = await _recorder.startStream(
      const RecordConfig(
        encoder: AudioEncoder.pcm16bits,
        sampleRate: 44100,
        numChannels: 1,
      ),
    );

    _sub?.cancel();
    _sub = stream.listen(_onAudioChunk, onError: (_) {});
    return true;
  }

  Future<void> stop() async {
    await _sub?.cancel();
    _sub = null;
    if (await _recorder.isRecording()) {
      await _recorder.stop();
    }
  }

  Future<void> dispose() async {
    await stop();
    await _recorder.dispose();
    await _frames.close();
  }

  void _onAudioChunk(Uint8List bytes) {
    if (bytes.lengthInBytes < 2) return;

    final byteData = ByteData.sublistView(bytes);
    var absAccum = 0.0;
    final sampleCount = bytes.lengthInBytes ~/ 2;

    for (var i = 0; i < sampleCount; i++) {
      final pcm = byteData.getInt16(i * 2, Endian.little);
      final v = pcm / 32768.0;
      absAccum += v.abs();
      _buffer.add(v);
    }

    final env = absAccum / sampleCount;
    _envelopeSmooth = 0.88 * _envelopeSmooth + 0.12 * env;

    while (_buffer.length >= fftSize) {
      final frame = _buffer.sublist(0, fftSize);
      _buffer.removeRange(0, fftSize ~/ 4); // 75% overlap
      _emitFrame(frame);
    }
  }

  bool _hasSoundActivity(double env, List<_Peak> peaks, double threshold) {
    if (env < _noiseEnvelope + silenceGateOffset) {
      return false;
    }
    if (peaks.length < 2) {
      return false;
    }
    final strongPeak = peaks.first.mag > threshold * 1.3;
    return strongPeak;
  }

  void _relaxToSilence() {
    _f1Smooth *= 0.88;
    _f2Smooth *= 0.88;
    _beatSmooth *= 0.84;
    _strengthSmooth *= 0.82;
    _beatDepthSmooth *= 0.8;
    _beatConfidenceSmooth *= 0.82;
    _beatMixFast *= 0.8;
    _beatMixSlow *= 0.9;
    if (_f1Smooth < 4) _f1Smooth = 0;
    if (_f2Smooth < 4) _f2Smooth = 0;
    if (_beatSmooth < 0.04) _beatSmooth = 0;
    if (_strengthSmooth < 0.02) _strengthSmooth = 0;
    if (_beatDepthSmooth < 0.02) _beatDepthSmooth = 0;
    if (_beatConfidenceSmooth < 0.02) _beatConfidenceSmooth = 0;
    _freqStableFrames = 0;
    _lastBeatRootPartialHz = 0;
    _lastBeatCrownPartialHz = 0;
    _lastBeatRootPartialSource = '';
    _lastBeatCrownPartialSource = '';
    _note1PartialSmooth = _note1PartialSmooth.map((v) => v * 0.78).toList();
    _note2PartialSmooth = _note2PartialSmooth.map((v) => v * 0.78).toList();
  }

  bool _isFreqPairStable(double f1, double f2) {
    if (f1 <= 0 || f2 <= 0) {
      _freqStableFrames = 0;
      _candF1 = f1;
      _candF2 = f2;
      return false;
    }

    if (_candF1 <= 0 || _candF2 <= 0) {
      _candF1 = f1;
      _candF2 = f2;
      _freqStableFrames = 1;
      return false;
    }

    final rel1 = (f1 - _candF1).abs() / _candF1;
    final rel2 = (f2 - _candF2).abs() / _candF2;
    final stableNow = rel1 < 0.008 && rel2 < 0.008;

    if (stableNow) {
      _candF1 = 0.75 * _candF1 + 0.25 * f1;
      _candF2 = 0.75 * _candF2 + 0.25 * f2;
      _freqStableFrames = (_freqStableFrames + 1).clamp(0, 1000);
    } else {
      _candF1 = f1;
      _candF2 = f2;
      _freqStableFrames = 1;
    }

    return _freqStableFrames >= 3;
  }

  // 音程类别辅助函数：三度/六度、四度/五度、同度/八度分为三类
  int _intervalClass(_IntervalSpec interval) {
    switch (interval.label) {
      case '大三度':
      case '小六度':
        return 1;
      case '纯四度':
      case '纯五度':
        return 2;
      case '同度':
      case '八度':
        return 3;
      default:
        return 0;
    }
  }

  void _updateIntervalLock(_IntervalSpec candidate) {
    if (!_isSupportedInterval(candidate)) {
      _stableIntervalFrames = (_stableIntervalFrames - 2).clamp(0, 1000);
      if (_stableIntervalFrames <= 0) {
        _lockedInterval = null;
      }
      return;
    }

    if (_lockedInterval == null) {
      _lockedInterval = candidate;
      _stableIntervalFrames = 1;
      return;
    }

    final sameNamed = _lockedInterval!.label == candidate.label;
    final closeSemitones =
        (_lockedInterval!.semitones - candidate.semitones).abs() <= 0.28;
    final sameClass =
        _intervalClass(_lockedInterval!) == _intervalClass(candidate);

    // 类别跳变惩罚：不同类别切换需要更多帧
    if (sameNamed || closeSemitones) {
      _stableIntervalFrames = (_stableIntervalFrames + 1).clamp(0, 1000);
    } else if (sameClass) {
      _stableIntervalFrames = (_stableIntervalFrames - 1).clamp(0, 1000);
      if (_stableIntervalFrames <= 0) {
        _lockedInterval = candidate;
        _stableIntervalFrames = 1;
      }
    } else {
      // 类别跳变，强惩罚，只有连续多帧支持才允许切换
      _stableIntervalFrames = (_stableIntervalFrames - 4).clamp(0, 1000);
      if (_stableIntervalFrames <= 0) {
        _lockedInterval = candidate;
        _stableIntervalFrames = 1;
      }
    }
  }

  double _rateLimit(double oldValue, double target, double maxStep) {
    if (oldValue <= 0) return target;
    final delta = target - oldValue;
    if (delta.abs() <= maxStep) return target;
    return oldValue + delta.sign * maxStep;
  }

  double _bandEnergyCqt(
    List<double> cqtSpectrum,
    double centerHz, {
    int halfWidthBins = 2,
  }) {
    if (centerHz <= 0 || cqtSpectrum.isEmpty) return 0;
    final center = _nearestCqtIndex(centerHz);
    final from = (center - halfWidthBins).clamp(0, cqtSpectrum.length - 1);
    final to = (center + halfWidthBins).clamp(0, cqtSpectrum.length - 1);
    var sum = 0.0;
    for (var i = from; i <= to; i++) {
      sum += cqtSpectrum[i];
    }
    return sum;
  }

  _BeatEnvelopeMetrics _computeBeatEnvelopeMetrics({
    required List<double> cqtSpectrum,
    required double f1,
    required double f2,
    required _IntervalSpec interval,
    required bool locked,
    required double cqtNoiseFloor,
  }) {
    if (!locked || f1 <= 0 || f2 <= 0) {
      _beatDepthSmooth *= 0.82;
      _beatConfidenceSmooth *= 0.84;
      return _BeatEnvelopeMetrics(
        depth: _beatDepthSmooth,
        confidence: _beatConfidenceSmooth,
      );
    }

    final low = math.min(f1, f2);
    final high = math.max(f1, f2);
    final targetLow = interval.m * low;
    final targetHigh = interval.n * high;

    final eLow = _bandEnergyCqt(cqtSpectrum, targetLow);
    final eHigh = _bandEnergyCqt(cqtSpectrum, targetHigh);
    final mix = eLow + eHigh;

    if (_beatMixFast <= 0) {
      _beatMixFast = mix;
      _beatMixSlow = mix;
    } else {
      _beatMixFast = 0.56 * _beatMixFast + 0.44 * mix;
      _beatMixSlow = 0.965 * _beatMixSlow + 0.035 * mix;
    }

    final mod = (_beatMixFast - _beatMixSlow).abs();
    final depthRaw = _beatMixSlow > 1e-9
        ? (mod / (_beatMixSlow + 1e-9)).clamp(0.0, 1.0)
        : 0.0;
    final balance =
        (2.0 *
                math.sqrt((eLow + 1e-9) * (eHigh + 1e-9)) /
                (eLow + eHigh + 1e-9))
            .clamp(0.0, 1.0);
    final snr = (mix / ((cqtNoiseFloor * 8.0) + 1e-9)).clamp(0.0, 1.0);
    final confRaw = (0.52 * balance + 0.28 * depthRaw + 0.20 * snr).clamp(
      0.0,
      1.0,
    );

    _beatDepthSmooth = _beatDepthSmooth <= 0
        ? depthRaw
        : 0.84 * _beatDepthSmooth + 0.16 * depthRaw;
    _beatConfidenceSmooth = _beatConfidenceSmooth <= 0
        ? confRaw
        : 0.86 * _beatConfidenceSmooth + 0.14 * confRaw;

    return _BeatEnvelopeMetrics(
      depth: _beatDepthSmooth,
      confidence: _beatConfidenceSmooth,
    );
  }

  void _emitFrame(List<double> frame) {
    final windowed = List<double>.generate(frame.length, (i) {
      final w = 0.5 - 0.5 * math.cos(2 * math.pi * i / (frame.length - 1));
      return frame[i] * w;
    });

    final cqtSpectrum = _constantQMagnitude(windowed);

    var cqtNoiseFloor = 0.0;
    for (final v in cqtSpectrum) {
      cqtNoiseFloor += v;
    }
    cqtNoiseFloor = cqtSpectrum.isEmpty
        ? 0.0
        : cqtNoiseFloor / cqtSpectrum.length;
    final threshold = cqtNoiseFloor * 1.9;

    final peaks = _extractCqtPeaks(cqtSpectrum, threshold);

    peaks.sort((a, b) => b.mag.compareTo(a.mag));

    if (_envelopeSmooth < _noiseEnvelope + 0.0025) {
      _noiseEnvelope = 0.995 * _noiseEnvelope + 0.005 * _envelopeSmooth;
    }

    final hasSound = _hasSoundActivity(_envelopeSmooth, peaks, threshold);
    if (!hasSound) {
      _silenceFrames++;
      if (_silenceFrames > 6) {
        _lockedInterval = null;
        _stableIntervalFrames = 0;
        _lastLockedIntervalKey = null;
      }
      _relaxToSilence();
      _frames.add(
        AnalysisFrame(
          f1: _f1Smooth,
          f2: _f2Smooth,
          beatHz: _beatSmooth,
          intervalLabel: _lockedInterval?.label ?? 'Unknown',
          harmonicPairLabel: _lockedInterval == null
              ? '--'
              : '${_lockedInterval!.m}:${_lockedInterval!.n}',
          cents: _f1Smooth > 0 ? _calcCents(_f1Smooth) : 0.0,
          envelope: _envelopeSmooth.clamp(0.0, 1.0),
          beatDepth: _beatDepthSmooth,
          beatConfidence: _beatConfidenceSmooth,
          activeToneCount: 0,
          strength: _strengthSmooth,
          intervalLocked: _lockedInterval != null && _stableIntervalFrames >= 4,
          timestamp: DateTime.now().millisecondsSinceEpoch,
          beatRootPartialHz: _lastBeatRootPartialHz,
          beatCrownPartialHz: _lastBeatCrownPartialHz,
          beatRootPartialSource: _lastBeatRootPartialSource,
          beatCrownPartialSource: _lastBeatCrownPartialSource,
          note1Partials: const [],
          note2Partials: const [],
        ),
      );
      return;
    }

    _silenceFrames = 0;

    // Harmonic series clustering
    final clusters = _clusterPeaksByHarmonics(peaks);
    final notes = <_NoteAnalysis>[];

    for (final cluster in clusters) {
      if (cluster.isEmpty) continue;
      final fundamental = _estimateFundamental(cluster);
      notes.add(_NoteAnalysis(fundamental: fundamental, partials: cluster));
    }

    // Sort notes by fundamental frequency
    notes.sort((a, b) => a.fundamental.compareTo(b.fundamental));

    double f1 = 0;
    double f2 = 0;
    List<double> note1Partials = [];
    List<double> note2Partials = [];

    if (notes.isNotEmpty) {
      f1 = notes[0].fundamental;
      note1Partials = notes[0].partials;
      if (notes.length > 1 && f1 > 0) {
        var bestScore = double.infinity;
        var bestF2 = 0.0;
        List<double> bestPartials = [];
        for (var i = 1; i < notes.length; i++) {
          final candidateF2 = notes[i].fundamental;
          final ratio = candidateF2 > 0 ? candidateF2 / f1 : 0.0;
          final tooClose = (candidateF2 - f1).abs() < 26;
          final nearHarmonic =
              ratio > 0 && (ratio - ratio.round()).abs() < 0.06;
          final farOutRatio = ratio <= 1.08 || ratio >= 2.2;
          if (!tooClose && !nearHarmonic && !farOutRatio) {
            final intervalEval = _bestSupportedIntervalByRatio(ratio);
            var score = intervalEval.$2;

            // Prefer temporal continuity when lock already exists.
            if (_lockedInterval != null &&
                _lockedInterval!.label == intervalEval.$1.label) {
              score -= 16.0;
            }

            // Slightly prefer candidates with richer harmonic evidence.
            score -= math.min(notes[i].partials.length, 8) * 1.2;

            if (score < bestScore) {
              bestScore = score;
              bestF2 = candidateF2;
              bestPartials = notes[i].partials;
            }
          }
        }

        // Keep only interval-consistent candidates.
        if (bestF2 > 0 && bestScore <= 110.0) {
          f2 = bestF2;
          note2Partials = bestPartials;
        }
      }
    }

    if (f1 > 0 && f2 > 0) {
      final resolved = _resolveOctaveAmbiguity(
        f1: f1,
        f2: f2,
        cqtSpectrum: cqtSpectrum,
        cqtNoiseFloor: cqtNoiseFloor,
      );
      f1 = resolved.$1;
      f2 = resolved.$2;

      if (f1 > f2) {
        final tf = f1;
        f1 = f2;
        f2 = tf;
        final tp = note1Partials;
        note1Partials = note2Partials;
        note2Partials = tp;
      }
    }

    if (!_isFreqPairStable(f1, f2)) {
      _frames.add(
        AnalysisFrame(
          f1: 0,
          f2: 0,
          beatHz: 0,
          intervalLabel: _lockedInterval?.label ?? 'Unknown',
          harmonicPairLabel: _lockedInterval == null
              ? '--'
              : '${_lockedInterval!.m}:${_lockedInterval!.n}',
          cents: 0,
          envelope: _envelopeSmooth.clamp(0.0, 1.0),
          beatDepth: 0,
          beatConfidence: 0,
          activeToneCount: 0,
          strength: 0,
          intervalLocked: false,
          timestamp: DateTime.now().millisecondsSinceEpoch,
          beatRootPartialHz: _lastBeatRootPartialHz,
          beatCrownPartialHz: _lastBeatCrownPartialHz,
          beatRootPartialSource: _lastBeatRootPartialSource,
          beatCrownPartialSource: _lastBeatCrownPartialSource,
          note1Partials: const [],
          note2Partials: const [],
        ),
      );
      return;
    }

    _f1Smooth = _smoothFreq(_f1Smooth, f1);
    _f2Smooth = _smoothFreq(_f2Smooth, f2);

    final measuredNote1Partials = _buildMeasuredPartialSeries(
      fundamental: _f1Smooth,
      seedPartials: note1Partials,
      smoothCache: _note1PartialSmooth,
      cqtSpectrum: cqtSpectrum,
      cqtNoiseFloor: cqtNoiseFloor,
      maxOrder: 8,
    );
    final measuredNote2Partials = _buildMeasuredPartialSeries(
      fundamental: _f2Smooth,
      seedPartials: note2Partials,
      smoothCache: _note2PartialSmooth,
      cqtSpectrum: cqtSpectrum,
      cqtNoiseFloor: cqtNoiseFloor,
      maxOrder: 8,
    );

    final intervalBeat = _computeIntervalBeat(
      _f1Smooth,
      _f2Smooth,
      measuredNote1Partials,
      measuredNote2Partials,
    );
    _updateIntervalLock(intervalBeat.interval);
    final locked = _lockedInterval != null && _stableIntervalFrames >= 4;
    final appliedInterval = locked ? _lockedInterval! : intervalBeat.interval;
    final currentLockedIntervalKey =
        '${appliedInterval.label}:${appliedInterval.m}:${appliedInterval.n}';
    final isNewLockedInterval =
        locked &&
        _lastLockedIntervalKey != null &&
        _lastLockedIntervalKey != currentLockedIntervalKey;

    final lockedBeat = _computeBeatFromPartials(
      _f1Smooth,
      _f2Smooth,
      appliedInterval,
      measuredNote1Partials,
      measuredNote2Partials,
      cqtSpectrum: cqtSpectrum,
      cqtNoiseFloor: cqtNoiseFloor,
      analysisFrame: frame,
    );
    if (isNewLockedInterval) {
      // On interval switch: jump directly to new beat value, then resume smoothing.
      _beatSmooth = lockedBeat;
      _f1Smooth = f1;
      _f2Smooth = f2;
    } else {
      final beatLimited = _rateLimit(_beatSmooth, lockedBeat, 0.24);
      _beatSmooth = _beatSmooth <= 0
          ? beatLimited
          : 0.92 * _beatSmooth + 0.08 * beatLimited;
    }
    final cents = _f1Smooth > 0 ? _calcCents(_f1Smooth) : 0.0;

    final active = [_f1Smooth, _f2Smooth].where((f) => f > 0).length;
    final beatMetrics = _computeBeatEnvelopeMetrics(
      cqtSpectrum: cqtSpectrum,
      f1: _f1Smooth,
      f2: _f2Smooth,
      interval: appliedInterval,
      locked: locked,
      cqtNoiseFloor: cqtNoiseFloor,
    );

    final strengthRaw = locked
        ? beatMetrics.depth
        : (_envelopeSmooth * 8.0).clamp(0.0, 1.0);
    _strengthSmooth = _strengthSmooth <= 0
        ? strengthRaw
        : 0.84 * _strengthSmooth + 0.16 * strengthRaw;

    final visualActive = locked && active >= 2;
    _lastLockedIntervalKey = locked ? currentLockedIntervalKey : null;

    _frames.add(
      AnalysisFrame(
        f1: visualActive ? _f1Smooth : 0,
        f2: visualActive ? _f2Smooth : 0,
        beatHz: visualActive ? _beatSmooth : 0,
        intervalLabel: appliedInterval.label,
        harmonicPairLabel: '${appliedInterval.m}:${appliedInterval.n}',
        cents: visualActive ? cents : 0,
        envelope: _envelopeSmooth.clamp(0.0, 1.0),
        beatDepth: visualActive ? beatMetrics.depth : 0,
        beatConfidence: visualActive ? beatMetrics.confidence : 0,
        activeToneCount: visualActive ? active : 0,
        strength: visualActive ? _strengthSmooth : 0,
        intervalLocked: visualActive,
        timestamp: DateTime.now().millisecondsSinceEpoch,
        beatRootPartialHz: visualActive ? _lastBeatRootPartialHz : 0,
        beatCrownPartialHz: visualActive ? _lastBeatCrownPartialHz : 0,
        beatRootPartialSource: visualActive ? _lastBeatRootPartialSource : '',
        beatCrownPartialSource: visualActive ? _lastBeatCrownPartialSource : '',
        note1Partials: visualActive ? measuredNote1Partials : const [],
        note2Partials: visualActive ? measuredNote2Partials : const [],
      ),
    );
  }

  List<List<double>> _clusterPeaksByHarmonics(List<_Peak> peaks) {
    if (peaks.isEmpty) return [];

    final clusters = <List<double>>[];
    final assigned = <int>{};

    // For each unassigned peak, start a new cluster
    for (var i = 0; i < peaks.length; i++) {
      if (assigned.contains(i)) continue;

      final cluster = <double>[peaks[i].freq];
      assigned.add(i);

      // Find all peaks that form harmonic relationships with this one
      final fundamental = peaks[i].freq;

      for (var j = i + 1; j < peaks.length; j++) {
        if (assigned.contains(j)) continue;

        final peakFreq = peaks[j].freq;
        final ratio = peakFreq / fundamental;

        // Check if this peak is a harmonic of the fundamental
        // Allow ~8% tolerance for detuning
        final harmonicOrder = (ratio + 0.5).floor();
        if (harmonicOrder >= 2 && harmonicOrder <= 8) {
          final expectedFreq = fundamental * harmonicOrder;
          final error = (peakFreq - expectedFreq).abs() / expectedFreq;

          if (error < 0.08) {
            cluster.add(peakFreq);
            assigned.add(j);
          }
        }
      }

      clusters.add(cluster);
    }

    return clusters;
  }

  double _estimateFundamental(List<double> partials) {
    if (partials.isEmpty) return 0;
    if (partials.length == 1) return partials[0];

    // Sort partials
    final sorted = List<double>.from(partials)..sort();

    // Use the lowest frequency as fundamental estimate
    // (it's most likely to be the actual fundamental)
    return sorted[0];
  }

  double _smoothFreq(double old, double next) {
    if (next <= 0) return old * 0.92;
    if (old <= 0) return next;
    return 0.78 * old + 0.22 * next;
  }

  double _calcCents(double f) {
    final midi = 69 + 12 * (math.log(f / 440) / math.ln2);
    final nearest = midi.roundToDouble();
    return (midi - nearest) * 100;
  }

  List<double> _buildMeasuredPartialSeries({
    required double fundamental,
    required List<double> seedPartials,
    required List<double> smoothCache,
    required List<double> cqtSpectrum,
    required double cqtNoiseFloor,
    int maxOrder = 8,
  }) {
    if (fundamental <= 0) {
      return List<double>.filled(maxOrder, 0);
    }

    if (smoothCache.length != maxOrder) {
      smoothCache
        ..clear()
        ..addAll(List<double>.filled(maxOrder, 0));
    }

    final ordered = List<double>.filled(maxOrder, 0);
    for (var order = 1; order <= maxOrder; order++) {
      final targetHz = fundamental * order;
      final fromSeed = _nearestPartial(
        targetHz,
        seedPartials,
        maxRelativeError: 0.14,
      );
      final fromSpectrum = _detectHarmonicFrequency(
        cqtSpectrum: cqtSpectrum,
        cqtNoiseFloor: cqtNoiseFloor,
        targetHz: targetHz,
        searchWidthRatio: 0.14,
        snrMultiplier: 1.1,
      );

      double resolved = fromSpectrum ?? fromSeed ?? 0;
      if (resolved <= 0) {
        resolved = _estimateMissingPartial(order, ordered, fundamental);
      }
      if (resolved <= 0) {
        resolved = targetHz;
      }

      final old = smoothCache[order - 1];
      final smoothed = old <= 0 ? resolved : (0.82 * old + 0.18 * resolved);
      smoothCache[order - 1] = smoothed;
      ordered[order - 1] = smoothed;
    }
    return ordered;
  }

  double _estimateMissingPartial(
    int order,
    List<double> ordered,
    double fundamental,
  ) {
    final idx = order - 1;

    int prevIdx = -1;
    for (var i = idx - 1; i >= 0; i--) {
      if (ordered[i] > 0) {
        prevIdx = i;
        break;
      }
    }

    int nextIdx = -1;
    for (var i = idx + 1; i < ordered.length; i++) {
      if (ordered[i] > 0) {
        nextIdx = i;
        break;
      }
    }

    if (prevIdx >= 0 && nextIdx >= 0) {
      final x0 = prevIdx + 1.0;
      final y0 = ordered[prevIdx];
      final x1 = nextIdx + 1.0;
      final y1 = ordered[nextIdx];
      final t = (order - x0) / (x1 - x0);
      return y0 + (y1 - y0) * t;
    }
    if (prevIdx >= 0) {
      final prevOrder = prevIdx + 1.0;
      return ordered[prevIdx] * (order / prevOrder);
    }
    if (nextIdx >= 0) {
      final nextOrder = nextIdx + 1.0;
      return ordered[nextIdx] * (order / nextOrder);
    }
    return fundamental * order;
  }

  (double, double) _resolveOctaveAmbiguity({
    required double f1,
    required double f2,
    required List<double> cqtSpectrum,
    required double cqtNoiseFloor,
  }) {
    const scales = <double>[0.5, 1.0, 2.0];
    final rawLow = math.min(f1, f2);
    final rawHigh = math.max(f1, f2);
    final rawRatio = rawHigh / rawLow;
    var bestF1 = f1;
    var bestF2 = f2;
    var bestScore = double.infinity;

    for (final s1 in scales) {
      for (final s2 in scales) {
        final cand1 = f1 * s1;
        final cand2 = f2 * s2;
        if (cand1 < 40 || cand2 < 40 || cand1 > 2200 || cand2 > 2200) {
          continue;
        }

        final low = math.min(cand1, cand2);
        final high = math.max(cand1, cand2);
        final ratio = high / low;
        final interval = _bestInterval(ratio);
        if (!_isSupportedInterval(interval)) {
          continue;
        }

        final centsErr = (1200 * (math.log(ratio / interval.ratio) / math.ln2))
            .abs();
        final ratioDriftCents = (1200 * (math.log(ratio / rawRatio) / math.ln2))
            .abs();
        final pitchDriftCents =
            (1200 * (math.log(cand1 / f1) / math.ln2)).abs() +
            (1200 * (math.log(cand2 / f2) / math.ln2)).abs();
        final targetLow = low * interval.m;
        final targetHigh = high * interval.n;

        final detLow = _detectHarmonicFrequency(
          cqtSpectrum: cqtSpectrum,
          cqtNoiseFloor: cqtNoiseFloor,
          targetHz: targetLow,
          searchWidthRatio: 0.16,
          snrMultiplier: 1.05,
        );
        final detHigh = _detectHarmonicFrequency(
          cqtSpectrum: cqtSpectrum,
          cqtNoiseFloor: cqtNoiseFloor,
          targetHz: targetHigh,
          searchWidthRatio: 0.16,
          snrMultiplier: 1.05,
        );

        final eLow = _bandEnergyCqt(cqtSpectrum, targetLow);
        final eHigh = _bandEnergyCqt(cqtSpectrum, targetHigh);
        final snrLike = (eLow + eHigh) / (cqtNoiseFloor * 6.0 + 1e-9);

        final missPenalty =
            (detLow == null ? 70.0 : 0.0) + (detHigh == null ? 70.0 : 0.0);
        final snrPenalty = snrLike > 0 ? (30.0 / snrLike) : 120.0;

        final beat = ((detLow ?? targetLow) - (detHigh ?? targetHigh)).abs();
        final beatPenalty = beat > 1.2 ? (beat - 1.2) * 6.0 : 0.0;

        final octavePenalty = (s1 == 1.0 ? 0.0 : 2.0) + (s2 == 1.0 ? 0.0 : 2.0);
        final ratioDriftPenalty = ratioDriftCents * 1.1;
        final pitchDriftPenalty = pitchDriftCents * 0.22;

        // Avoid globally shifting both notes by the same octave,
        // which keeps ratio but breaks absolute pitch (common in M3 failures).
        final sameDirectionOctavePenalty = (s1 == s2 && s1 != 1.0) ? 42.0 : 0.0;

        final score =
            centsErr +
            missPenalty +
            snrPenalty +
            beatPenalty +
            octavePenalty +
            ratioDriftPenalty +
            pitchDriftPenalty +
            sameDirectionOctavePenalty;
        if (score < bestScore) {
          bestScore = score;
          bestF1 = cand1;
          bestF2 = cand2;
        }
      }
    }

    return (bestF1, bestF2);
  }

  _IntervalBeat _computeIntervalBeat(
    double f1,
    double f2,
    List<double> note1Partials,
    List<double> note2Partials,
  ) {
    if (f1 <= 0 || f2 <= 0) {
      return const _IntervalBeat(interval: _unknownInterval, beatHz: 0);
    }

    final root = math.min(f1, f2);
    final crown = math.max(f1, f2);
    final ratio = crown / root;
    final interval = _bestInterval(ratio);
    if (!_isSupportedInterval(interval)) {
      return const _IntervalBeat(interval: _unknownInterval, beatHz: 0);
    }
    final beatHz = _computeBeatFromPartials(
      f1,
      f2,
      interval,
      note1Partials,
      note2Partials,
    );
    return _IntervalBeat(interval: interval, beatHz: beatHz);
  }

  double _computeBeatFromPartials(
    double f1,
    double f2,
    _IntervalSpec interval,
    List<double> note1Partials,
    List<double> note2Partials, {
    List<double>? cqtSpectrum,
    double? cqtNoiseFloor,
    List<double>? analysisFrame,
  }) {
    if (f1 <= 0 || f2 <= 0) return 0;
    if (interval.m <= 0 || interval.n <= 0) return 0;

    final lowIsFirst = f1 <= f2;
    final low = lowIsFirst ? f1 : f2;
    final high = lowIsFirst ? f2 : f1;
    final lowPartials = lowIsFirst ? note1Partials : note2Partials;
    final highPartials = lowIsFirst ? note2Partials : note1Partials;

    final targetLow = interval.m * low;
    final targetHigh = interval.n * high;

    final measuredLowByOrder = _partialAtOrder(lowPartials, interval.m);
    final measuredHighByOrder = _partialAtOrder(highPartials, interval.n);

    final targetGap = (targetLow - targetHigh).abs();
    final avoidBandHz = math.max(0.08, targetGap * 0.45);

    final nearbyLow = (cqtSpectrum != null && cqtNoiseFloor != null)
        ? _detectHarmonicFrequency(
            cqtSpectrum: cqtSpectrum,
            cqtNoiseFloor: cqtNoiseFloor,
            targetHz: targetLow,
            searchWidthRatio: 0.15,
            snrMultiplier: 1.08,
          )
        : null;
    final nearbyHigh = (cqtSpectrum != null && cqtNoiseFloor != null)
        ? _detectHarmonicFrequency(
            cqtSpectrum: cqtSpectrum,
            cqtNoiseFloor: cqtNoiseFloor,
            targetHz: targetHigh,
            searchWidthRatio: 0.15,
            snrMultiplier: 1.08,
            avoidHz: nearbyLow,
            avoidBandHz: avoidBandHz,
          )
        : null;

    final nearestLow = _nearestPartial(targetLow, lowPartials);
    final nearestHigh = _nearestPartial(targetHigh, highPartials);

    var measuredLow =
        measuredLowByOrder ?? nearbyLow ?? nearestLow ?? targetLow;
    var measuredHigh =
        measuredHighByOrder ?? nearbyHigh ?? nearestHigh ?? targetHigh;

    var sourceLow = measuredLowByOrder != null
        ? '实测阶次'
        : (nearbyLow != null ? '邻峰搜索' : (nearestLow != null ? '近邻泛音' : '理论兜底'));
    var sourceHigh = measuredHighByOrder != null
        ? '实测阶次'
        : (nearbyHigh != null
              ? '邻峰搜索'
              : (nearestHigh != null ? '近邻泛音' : '理论兜底'));

    if (analysisFrame != null && analysisFrame.isNotEmpty) {
      final fineLow = _detectFineFrequency(
        analysisFrame,
        targetLow,
        searchHz: 2.2,
        stepHz: 0.05,
      );
      final fineHigh = _detectFineFrequency(
        analysisFrame,
        targetHigh,
        searchHz: 2.2,
        stepHz: 0.05,
        avoidHz: fineLow,
        avoidBandHz: 0.10,
      );

      if (fineLow != null) {
        measuredLow = fineLow;
        sourceLow = '细化搜索';
      }
      if (fineHigh != null) {
        measuredHigh = fineHigh;
        sourceHigh = '细化搜索';
      }

      if ((measuredLow - measuredHigh).abs() < 0.02) {
        final rescueLow = _detectFineFrequency(
          analysisFrame,
          targetLow,
          searchHz: 3.0,
          stepHz: 0.04,
        );
        final rescueHigh = _detectFineFrequency(
          analysisFrame,
          targetHigh,
          searchHz: 3.0,
          stepHz: 0.04,
          avoidHz: rescueLow,
          avoidBandHz: 0.08,
        );
        if (rescueLow != null && rescueHigh != null) {
          measuredLow = rescueLow;
          measuredHigh = rescueHigh;
          sourceLow = '细化搜索';
          sourceHigh = '细化搜索';
        }
      }
    }

    final rootMeasured = lowIsFirst ? measuredLow : measuredHigh;
    final crownMeasured = lowIsFirst ? measuredHigh : measuredLow;
    final rootSource = lowIsFirst ? sourceLow : sourceHigh;
    final crownSource = lowIsFirst ? sourceHigh : sourceLow;
    _lastBeatRootPartialHz = rootMeasured;
    _lastBeatCrownPartialHz = crownMeasured;
    _lastBeatRootPartialSource = rootSource;
    _lastBeatCrownPartialSource = crownSource;

    final measuredBeat = (measuredLow - measuredHigh).abs();
    final formulaBeat = low * (interval.m - interval.n * (high / low)).abs();

    final strictMeasured =
        measuredLowByOrder != null && measuredHighByOrder != null;
    final measuredWeight = strictMeasured ? 0.93 : 0.78;
    final blended =
        measuredWeight * measuredBeat + (1.0 - measuredWeight) * formulaBeat;
    if (blended.isNaN || blended.isInfinite) {
      return formulaBeat.clamp(0.0, 18.0);
    }

    // Piano tuning beat rates for these intervals are usually relatively low.
    return blended.clamp(0.0, 18.0);
  }

  double? _detectFineFrequency(
    List<double> samples,
    double targetHz, {
    double searchHz = 2.0,
    double stepHz = 0.05,
    double? avoidHz,
    double avoidBandHz = 0.10,
  }) {
    if (samples.isEmpty || targetHz <= 0 || stepHz <= 0) {
      return null;
    }

    final minHz = (targetHz - searchHz).clamp(40.0, sampleRate / 2.0 - 20.0);
    final maxHz = (targetHz + searchHz).clamp(40.0, sampleRate / 2.0 - 20.0);
    if (maxHz <= minHz) return null;

    var bestHz = 0.0;
    var bestMag = 0.0;

    for (var f = minHz; f <= maxHz; f += stepHz) {
      if (avoidHz != null && (f - avoidHz).abs() < avoidBandHz) {
        continue;
      }

      final theta = 2 * math.pi * f / sampleRate;
      final cosT = math.cos(theta);
      final sinT = math.sin(theta);
      var oscCos = 1.0;
      var oscSin = 0.0;
      var re = 0.0;
      var im = 0.0;

      for (var i = 0; i < samples.length; i++) {
        final x = samples[i];
        re += x * oscCos;
        im -= x * oscSin;

        final nextCos = oscCos * cosT - oscSin * sinT;
        final nextSin = oscSin * cosT + oscCos * sinT;
        oscCos = nextCos;
        oscSin = nextSin;
      }

      final mag = math.sqrt(re * re + im * im);
      if (mag > bestMag) {
        bestMag = mag;
        bestHz = f;
      }
    }

    if (bestMag <= 0 || bestHz <= 0) {
      return null;
    }
    return bestHz;
  }

  double? _partialAtOrder(List<double> orderedPartials, int order) {
    if (order <= 0 || order > orderedPartials.length) {
      return null;
    }
    final value = orderedPartials[order - 1];
    return value > 0 ? value : null;
  }

  double? _detectHarmonicFrequency({
    required List<double> cqtSpectrum,
    required double cqtNoiseFloor,
    required double targetHz,
    double searchWidthRatio = 0.10,
    double snrMultiplier = 1.1,
    double? avoidHz,
    double avoidBandHz = 0.12,
  }) {
    if (targetHz <= 0 || cqtSpectrum.length < 3) return null;

    final center = _nearestCqtIndex(targetHz);
    final halfWindow = math.max(
      2,
      (_cqtBinsPerOctave * searchWidthRatio).round(),
    );
    final from = (center - halfWindow).clamp(1, cqtSpectrum.length - 2);
    final to = (center + halfWindow).clamp(1, cqtSpectrum.length - 2);
    if (to <= from) return null;

    var bestIdx = -1;
    var bestMag = 0.0;
    for (var i = from; i <= to; i++) {
      final f = _cqtFrequencies[i];
      if (avoidHz != null && (f - avoidHz).abs() < avoidBandHz) {
        continue;
      }
      final mag = cqtSpectrum[i];
      if (mag > bestMag) {
        bestMag = mag;
        bestIdx = i;
      }
    }

    if (bestIdx <= 0 || bestIdx >= cqtSpectrum.length - 1) {
      return null;
    }
    if (bestMag < cqtNoiseFloor * snrMultiplier) {
      return null;
    }

    final y0 = cqtSpectrum[bestIdx - 1];
    final y1 = cqtSpectrum[bestIdx];
    final y2 = cqtSpectrum[bestIdx + 1];
    final denom = 2 * y1 - y0 - y2;
    final delta = denom.abs() > 1e-9 ? 0.5 * (y2 - y0) / denom : 0.0;

    final refined = bestIdx + delta.clamp(-0.5, 0.5);
    final low =
        _cqtFrequencies[(bestIdx - 1).clamp(0, _cqtFrequencies.length - 1)];
    final high =
        _cqtFrequencies[(bestIdx + 1).clamp(0, _cqtFrequencies.length - 1)];
    final t = (refined - (bestIdx - 1)) / 2.0;
    final detectedHz = low * math.pow(high / low, t);

    final relErr = (detectedHz - targetHz).abs() / targetHz;
    if (relErr > 0.14) {
      return null;
    }
    return detectedHz;
  }

  int _nearestCqtIndex(double hz) {
    if (_cqtFrequencies.isEmpty || hz <= _cqtFrequencies.first) {
      return 0;
    }
    if (hz >= _cqtFrequencies.last) {
      return _cqtFrequencies.length - 1;
    }

    final ratio = hz / _cqtMinHz;
    final idx = (_cqtBinsPerOctave * (math.log(ratio) / math.ln2)).round();
    return idx.clamp(0, _cqtFrequencies.length - 1);
  }

  double? _nearestPartial(
    double target,
    List<double> partials, {
    double maxRelativeError = 0.1,
  }) {
    if (partials.isEmpty) return null;
    var best = partials.first;
    var bestErr = (best - target).abs() / target;
    for (final p in partials.skip(1)) {
      final err = (p - target).abs() / target;
      if (err < bestErr) {
        bestErr = err;
        best = p;
      }
    }
    if (bestErr > maxRelativeError) {
      return null;
    }
    return best;
  }

  _IntervalSpec _bestInterval(double ratio) {
    final semitones = 12 * (math.log(ratio) / math.ln2);
    _IntervalSpec? closestNamed;
    var bestDistance = double.infinity;

    for (final interval in _namedIntervals) {
      final semitoneDistance = (semitones - interval.semitones).abs();
      final ratioCents = (1200 * (math.log(ratio / interval.ratio) / math.ln2))
          .abs();
      var distance = semitoneDistance * 100 + ratioCents * 0.65;

      // Hysteresis: when an interval is locked, avoid switching too easily.
      if (_lockedInterval != null && _lockedInterval!.label == interval.label) {
        distance -= 16;
      }

      if (distance < bestDistance) {
        bestDistance = distance;
        closestNamed = interval;
      }
    }

    if (closestNamed != null && bestDistance <= 78) {
      return closestNamed;
    }
    return _unknownInterval;
  }

  (_IntervalSpec, double) _bestSupportedIntervalByRatio(double ratio) {
    _IntervalSpec best = _namedIntervals.first;
    var bestCents = double.infinity;
    for (final interval in _namedIntervals) {
      final cents = (1200 * (math.log(ratio / interval.ratio) / math.ln2))
          .abs();
      if (cents < bestCents) {
        bestCents = cents;
        best = interval;
      }
    }
    return (best, bestCents);
  }

  bool _isSupportedInterval(_IntervalSpec interval) {
    return interval.label != _unknownInterval.label;
  }

  static const _IntervalSpec _unknownInterval = _IntervalSpec(
    label: '非目标音程',
    semitones: 0,
    ratio: 0,
    m: 0,
    n: 0,
  );

  static const List<_IntervalSpec> _namedIntervals = [
    _IntervalSpec(label: '同度', semitones: 0, ratio: 1.0, m: 1, n: 1),
    _IntervalSpec(label: '大三度', semitones: 4, ratio: 5 / 4, m: 5, n: 4),
    _IntervalSpec(label: '纯四度', semitones: 5, ratio: 4 / 3, m: 4, n: 3),
    _IntervalSpec(label: '纯五度', semitones: 7, ratio: 3 / 2, m: 3, n: 2),
    _IntervalSpec(label: '小六度', semitones: 8, ratio: 8 / 5, m: 8, n: 5),
    _IntervalSpec(label: '八度', semitones: 12, ratio: 2.0, m: 2, n: 1),
  ];

  static List<double> _buildCqtFrequencies() {
    final freqs = <double>[];
    final step = 1.0 / _cqtBinsPerOctave;
    var k = 0;
    while (true) {
      final f = _cqtMinHz * math.pow(2.0, k * step);
      final value = f.toDouble();
      if (value > _cqtMaxHz) break;
      freqs.add(value);
      k++;
    }
    return freqs;
  }

  void _precomputeCqtKernels() {
    final cosKernels = <List<double>>[];
    final sinKernels = <List<double>>[];

    final q = 1.0 / (math.pow(2.0, 1.0 / _cqtBinsPerOctave) - 1.0);
    for (final f in _cqtFrequencies) {
      var kernelLen = (q * sampleRate / f).round();
      kernelLen = kernelLen.clamp(48, fftSize);

      final cosKernel = List<double>.filled(kernelLen, 0.0);
      final sinKernel = List<double>.filled(kernelLen, 0.0);

      for (var n = 0; n < kernelLen; n++) {
        final win = 0.5 - 0.5 * math.cos(2 * math.pi * n / (kernelLen - 1));
        final phase = 2 * math.pi * f * n / sampleRate;
        final scale = win / kernelLen;
        cosKernel[n] = math.cos(phase) * scale;
        sinKernel[n] = math.sin(phase) * scale;
      }

      cosKernels.add(cosKernel);
      sinKernels.add(sinKernel);
    }

    _cqtKernelCos = cosKernels;
    _cqtKernelSin = sinKernels;
  }

  List<double> _constantQMagnitude(List<double> windowed) {
    if (windowed.isEmpty || _cqtFrequencies.isEmpty) {
      return const [];
    }

    final mags = List<double>.filled(_cqtFrequencies.length, 0);
    for (var i = 0; i < _cqtFrequencies.length; i++) {
      final cosKernel = _cqtKernelCos[i];
      final sinKernel = _cqtKernelSin[i];
      var re = 0.0;
      var im = 0.0;

      final limit = math.min(windowed.length, cosKernel.length);
      for (var t = 0; t < limit; t++) {
        final x = windowed[t];
        re += x * cosKernel[t];
        im -= x * sinKernel[t];
      }

      mags[i] = math.sqrt(re * re + im * im);
    }
    return mags;
  }

  List<_Peak> _extractCqtPeaks(List<double> cqtSpectrum, double threshold) {
    final peaks = <_Peak>[];
    if (cqtSpectrum.length < 3) {
      return peaks;
    }

    for (var i = 1; i < cqtSpectrum.length - 1; i++) {
      final y1 = cqtSpectrum[i];
      if (y1 < threshold) continue;
      final y0 = cqtSpectrum[i - 1];
      final y2 = cqtSpectrum[i + 1];
      if (!(y1 > y0 && y1 > y2)) continue;

      final denom = 2 * y1 - y0 - y2;
      final delta = denom.abs() > 1e-9 ? 0.5 * (y2 - y0) / denom : 0.0;
      final refined = i + delta.clamp(-0.5, 0.5);
      final low = _cqtFrequencies[i - 1];
      final high = _cqtFrequencies[i + 1];
      final t = (refined - (i - 1)) / 2.0;
      final refinedFreq = low * math.pow(high / low, t);
      peaks.add(_Peak(freq: refinedFreq, mag: y1));
    }
    return peaks;
  }
}

class _Peak {
  _Peak({required this.freq, required this.mag});

  final double freq;
  final double mag;
}

class _NoteAnalysis {
  _NoteAnalysis({required this.fundamental, required this.partials});

  final double fundamental;
  final List<double> partials;
}

class _IntervalSpec {
  const _IntervalSpec({
    required this.label,
    required this.semitones,
    required this.ratio,
    required this.m,
    required this.n,
  });

  final String label;
  final double semitones;
  final double ratio;
  final int m;
  final int n;
}

class _IntervalBeat {
  const _IntervalBeat({required this.interval, required this.beatHz});

  final _IntervalSpec interval;
  final double beatHz;
}

class _BeatEnvelopeMetrics {
  const _BeatEnvelopeMetrics({required this.depth, required this.confidence});

  final double depth;
  final double confidence;
}

class PreviewHomePage extends StatefulWidget {
  const PreviewHomePage({super.key});

  @override
  State<PreviewHomePage> createState() => _PreviewHomePageState();
}

class _PreviewHomePageState extends State<PreviewHomePage>
    with SingleTickerProviderStateMixin {
  static const int _maxHistoryLength = 200;
  static const double _captureMinEnvelope = 0.012;
  static const double _captureMinConfidence = 0.15;

  late final AnimationController _ticker;
  late final MicBeatAnalyzer _analyzer;

  AnalysisFrame _liveFrame = AnalysisFrame.empty;
  AnalysisFrame _lockedDisplayFrame = AnalysisFrame.empty;
  final List<double> _beatDepthHistory = [];
  StreamSubscription<AnalysisFrame>? _analysisSub;
  bool _running = false;
  bool _hasDetectedInterval = false;
  int _lockStreak = 0;
  String _pendingLockKey = '';
  String _status = 'Idle';
  int _navIndex = 0;
  double _silenceGateOffset = 0.0045;
  int _concertPitchHz = 440;
  int _lastAppliedForkHz = 440;
  bool _forkPlaying = false;
  bool _forkEngineReady = false;
  StreamSubscription<bool>? _forkPlayingSub;

  bool get _supportsForkGenerator =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS);

  @override
  void initState() {
    super.initState();
    _ticker = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1600),
    )..repeat();
    _initForkEngine();
    _analyzer = MicBeatAnalyzer();
    _startMic();
  }

  Future<void> _initForkEngine() async {
    if (!_supportsForkGenerator) {
      setState(() {
        _forkEngineReady = false;
        _forkPlaying = false;
      });
      return;
    }

    try {
      final ready = await SoundGenerator.init(44100);
      if (!mounted) return;

      if (!ready) {
        setState(() {
          _forkEngineReady = false;
          _forkPlaying = false;
        });
        return;
      }

      SoundGenerator.setWaveType(waveTypes.SINUSOIDAL);
      SoundGenerator.setVolume(0.8);
      // Keep phase continuity when changing frequency to avoid audible hiccups.
      SoundGenerator.setCleanStart(false);
      SoundGenerator.setFrequency(_concertPitchHz.toDouble());
      _lastAppliedForkHz = _concertPitchHz;

      _forkPlayingSub?.cancel();
      _forkPlayingSub = SoundGenerator.onIsPlayingChanged.listen((isPlaying) {
        if (!mounted) return;
        setState(() => _forkPlaying = isPlaying);
      });

      setState(() => _forkEngineReady = true);
    } on MissingPluginException {
      if (!mounted) return;
      setState(() {
        _forkEngineReady = false;
        _forkPlaying = false;
      });
    } on PlatformException {
      if (!mounted) return;
      setState(() {
        _forkEngineReady = false;
        _forkPlaying = false;
      });
    }
  }

  Future<void> _toggleTuningForkTone() async {
    if (!_supportsForkGenerator) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('音叉持续振荡器仅支持 Android/iOS')));
      return;
    }

    if (!_forkEngineReady) {
      await _initForkEngine();
      if (!_forkEngineReady) return;
    }

    try {
      if (_forkPlaying) {
        SoundGenerator.stop();
        if (!mounted) return;
        setState(() => _forkPlaying = false);
        return;
      }

      if (_lastAppliedForkHz != _concertPitchHz) {
        SoundGenerator.setFrequency(_concertPitchHz.toDouble());
        _lastAppliedForkHz = _concertPitchHz;
      }
      SoundGenerator.play();
      if (!mounted) return;
      setState(() => _forkPlaying = true);
    } on MissingPluginException {
      if (!mounted) return;
      setState(() {
        _forkEngineReady = false;
        _forkPlaying = false;
      });
    } on PlatformException {
      if (!mounted) return;
      setState(() {
        _forkEngineReady = false;
        _forkPlaying = false;
      });
    }
  }

  void _previewConcertPitch(int valueHz) {
    if (valueHz == _concertPitchHz) return;
    setState(() => _concertPitchHz = valueHz);
  }

  void _commitConcertPitch(int valueHz) {
    if (valueHz != _concertPitchHz) {
      setState(() => _concertPitchHz = valueHz);
    }
    if (_forkEngineReady && valueHz != _lastAppliedForkHz) {
      try {
        SoundGenerator.setFrequency(valueHz.toDouble());
        _lastAppliedForkHz = valueHz;
      } on MissingPluginException {
        setState(() {
          _forkEngineReady = false;
          _forkPlaying = false;
        });
      } on PlatformException {
        setState(() {
          _forkEngineReady = false;
          _forkPlaying = false;
        });
      }
    }
  }

  Future<void> _startMic() async {
    setState(() => _status = 'Requesting mic...');
    final ok = await _analyzer.start();
    if (!mounted) return;

    if (!ok) {
      setState(() {
        _running = false;
        _status = 'Mic permission denied';
      });
      return;
    }

    _analysisSub?.cancel();
    _analysisSub = _analyzer.frames.listen((next) {
      if (!mounted) return;
      setState(() {
        _running = true;
        _status = 'Listening';
        _liveFrame = next;

        if (next.intervalLocked) {
          final lockKey = '${next.intervalLabel}:${next.harmonicPairLabel}';
          final isNewInterval = lockKey != _pendingLockKey;
          final qualityOk =
              next.harmonicPairLabel != '--' &&
              next.activeToneCount >= 2 &&
              next.f1 > 0 &&
              next.f2 > 0 &&
              next.envelope >= _captureMinEnvelope &&
              next.beatConfidence >= _captureMinConfidence;

          if (isNewInterval && qualityOk) {
            _lockedDisplayFrame = next;
            _hasDetectedInterval = true;
            _pendingLockKey = lockKey;
            _lockStreak = 1;
          } else if (!isNewInterval) {
            _lockStreak = (_lockStreak + 1).clamp(0, 1000);
          }
        } else {
          _lockStreak = 0;
          _pendingLockKey = '';
        }
        _beatDepthHistory.add(
          next.intervalLocked ? next.beatDepth.clamp(0.0, 1.0) : 0.0,
        );
        if (_beatDepthHistory.length > _maxHistoryLength) {
          _beatDepthHistory.removeAt(0);
        }
      });
    });
  }

  Future<void> _stopMic() async {
    await _analysisSub?.cancel();
    _analysisSub = null;
    await _analyzer.stop();
    if (!mounted) return;
    setState(() {
      _running = false;
      _status = 'Stopped';
    });
  }

  @override
  void dispose() {
    _analysisSub?.cancel();
    _analyzer.dispose();
    _forkPlayingSub?.cancel();
    if (_forkEngineReady) {
      try {
        SoundGenerator.stop();
        SoundGenerator.release();
      } on MissingPluginException {
        // Plugin can be unavailable on unsupported platforms.
      } on PlatformException {
        // Ignore release failures while disposing.
      }
    }
    _ticker.dispose();
    super.dispose();
  }

  String _noteNameFromHz(double hz) {
    if (hz <= 0 || hz.isNaN || hz.isInfinite) {
      return '--';
    }
    const names = <String>[
      'C',
      'C#',
      'D',
      'D#',
      'E',
      'F',
      'F#',
      'G',
      'G#',
      'A',
      'A#',
      'B',
    ];
    final midi = (69 + 12 * (math.log(hz / 440.0) / math.ln2)).round();
    final note = names[midi % 12];
    final octave = (midi ~/ 12) - 1;
    return '$note$octave';
  }

  @override
  Widget build(BuildContext context) {
    final t = _ticker.value;
    final showDemo = !_hasDetectedInterval;
    final hasLiveInterval = _liveFrame.intervalLocked;
    final demoFrame = AnalysisFrame(
      f1: 440.0,
      f2: 660.0,
      beatHz: 1.0,
      intervalLabel: 'Perfect Fifth',
      harmonicPairLabel: '3:2',
      cents: 0.0,
      envelope: 0.2,
      beatDepth: 0.35,
      beatConfidence: 0.6,
      activeToneCount: 2,
      strength: 0.45,
      intervalLocked: true,
      timestamp: DateTime.now().millisecondsSinceEpoch,
      note1Partials: const [440.0, 880.0, 1320.0],
      note2Partials: const [660.0, 1320.0],
    );
    final shownFrame = _hasDetectedInterval
        ? _lockedDisplayFrame
        : (hasLiveInterval ? _liveFrame : demoFrame);
    final displayBeat = shownFrame.beatHz;
    final freq1 = shownFrame.f1 > 0 ? shownFrame.f1.toStringAsFixed(2) : '--';
    final freq2 = shownFrame.f2 > 0 ? shownFrame.f2.toStringAsFixed(2) : '--';
    final note1 = _noteNameFromHz(shownFrame.f1);
    final note2 = _noteNameFromHz(shownFrame.f2);

    return Scaffold(
      backgroundColor: const Color(0xFFFDFEFF),
      floatingActionButtonLocation: FloatingActionButtonLocation.centerDocked,
      floatingActionButton: Transform.translate(
        offset: const Offset(0, -4),
        child: _TuningForkControl(
          valueHz: _concertPitchHz,
          isPlaying: _forkPlaying,
          enabled: true,
          onChanged: _previewConcertPitch,
          onChangeEnd: _commitConcertPitch,
          onTapFork: _toggleTuningForkTone,
        ),
      ),
      bottomNavigationBar: Container(
        decoration: const BoxDecoration(
          color: Color(0xFFFDFEFF),
          border: Border(top: BorderSide(color: Color(0xFFE5E8EF))),
        ),
        child: SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 48, vertical: 8),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                _BottomNavItem(
                  icon: Icons.graphic_eq,
                  label: 'Visualizer',
                  color: const Color(0xFFFF3FA4),
                  selected: _navIndex == 0,
                  onTap: () => setState(() => _navIndex = 0),
                ),
                _BottomNavItem(
                  icon: Icons.info_outline,
                  label: 'Info',
                  color: const Color(0xFF00CFFF),
                  selected: _navIndex == 1,
                  onTap: () async {
                    setState(() => _navIndex = 1);
                    await Navigator.of(context).push(
                      MaterialPageRoute<void>(builder: (_) => const InfoPage()),
                    );
                    if (!mounted) return;
                    setState(() => _navIndex = 0);
                  },
                ),
              ],
            ),
          ),
        ),
      ),
      body: Stack(
        children: [
          Container(
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  Color(0xFFFFFFFF),
                  Color(0xFFF8F4FF),
                  Color(0xFFFFFAF1),
                ],
              ),
            ),
          ),
          const Positioned(
            top: -60,
            left: -30,
            child: _Blob(size: 210, color: Color(0x33FF3FA4)),
          ),
          const Positioned(
            top: 90,
            right: -24,
            child: _Blob(size: 150, color: Color(0x3300CFFF)),
          ),
          const Positioned(
            bottom: 170,
            left: -30,
            child: _Blob(size: 170, color: Color(0x33FFD400)),
          ),
          const Positioned(
            bottom: 130,
            right: -36,
            child: _Blob(size: 180, color: Color(0x3367D300)),
          ),
          SafeArea(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      const Expanded(
                        child: Text(
                          'BEAT LAB',
                          style: TextStyle(
                            fontSize: 24,
                            fontWeight: FontWeight.w900,
                            letterSpacing: 0.3,
                            color: Color(0xFF24263A),
                          ),
                        ),
                      ),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 8,
                        ),
                        decoration: BoxDecoration(
                          color: _running
                              ? const Color(0xFFE9FFEF)
                              : const Color(0xFFFFF1F6),
                          borderRadius: BorderRadius.circular(999),
                          border: Border.all(
                            color: _running
                                ? const Color(0xFF67D300)
                                : const Color(0xFFFF3FA4),
                          ),
                        ),
                        child: Text(
                          _status,
                          style: const TextStyle(fontWeight: FontWeight.w700),
                        ),
                      ),
                      const SizedBox(width: 8),
                      DecoratedBox(
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(14),
                          gradient: const LinearGradient(
                            colors: [Color(0xFFFF3FA4), Color(0xFFFF8A00)],
                          ),
                        ),
                        child: ElevatedButton.icon(
                          onPressed: _running ? _stopMic : _startMic,
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.transparent,
                            shadowColor: Colors.transparent,
                            foregroundColor: Colors.white,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(14),
                            ),
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 10,
                            ),
                            textStyle: const TextStyle(
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                          icon: Icon(
                            _running ? Icons.mic_off : Icons.mic,
                            size: 18,
                          ),
                          label: Text(_running ? '停止' : '开始'),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  _DopamineCard(
                    child: Column(
                      children: [
                        const Text(
                          '拍频BEAT',
                          style: TextStyle(
                            fontSize: 24,
                            fontWeight: FontWeight.w900,
                            letterSpacing: 0.3,
                            color: Color(0xFF24263A),
                          ),
                        ),
                        const SizedBox(height: 8),
                        ShaderMask(
                          blendMode: BlendMode.srcIn,
                          shaderCallback: (bounds) => const LinearGradient(
                            colors: [
                              Color(0xFFFF3FA4),
                              Color(0xFF00CFFF),
                              Color(0xFFFFD400),
                              Color(0xFFFF8A00),
                            ],
                          ).createShader(bounds),
                          child: Text(
                            '${displayBeat.toStringAsFixed(2)} Hz',
                            style: const TextStyle(
                              fontSize: 36,
                              height: 1.05,
                              fontWeight: FontWeight.w900,
                              letterSpacing: 0.6,
                            ),
                          ),
                        ),
                        const SizedBox(height: 8),
                        _BeatPulseOrb(
                          t: t,
                          beatHz: displayBeat,
                          active:
                              !_hasDetectedInterval ||
                              _liveFrame.intervalLocked,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                  _DopamineCard(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const SizedBox(height: 12),
                        Center(
                          child: Wrap(
                            alignment: WrapAlignment.center,
                            runAlignment: WrapAlignment.center,
                            spacing: 8,
                            runSpacing: 8,
                            children: [
                              _NeonValuePill(
                                label: '根音Root',
                                value: '$freq1 Hz\n$note1',
                                gradient: const [
                                  Color(0xFFFF3FA4),
                                  Color(0xFFFF8A00),
                                ],
                              ),
                              _NeonValuePill(
                                label: '冠音Crown',
                                value: '$freq2 Hz\n$note2',
                                gradient: const [
                                  Color(0xFF00CFFF),
                                  Color(0xFF67D300),
                                ],
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 12),
                        Center(
                          child: _NeonValuePill(
                            label: '音程',
                            value: _hasDetectedInterval
                                ? '${shownFrame.intervalLabel} (${shownFrame.harmonicPairLabel})'
                                : (showDemo ? '未知' : '未知'),
                            gradient: const [
                              Color(0xFFFFD400),
                              Color(0xFFFF8A00),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 14),
                  _DopamineCard(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            const Icon(
                              Icons.tune,
                              color: Color(0xFF00CFFF),
                              size: 20,
                            ),
                            const SizedBox(width: 8),
                            const Text(
                              '静音门限 Silence Gate',
                              style: TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.w800,
                                color: Color(0xFF2A3150),
                              ),
                            ),
                            const Spacer(),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 10,
                                vertical: 4,
                              ),
                              decoration: BoxDecoration(
                                color: const Color(0xFFFFF4E0),
                                borderRadius: BorderRadius.circular(999),
                                border: Border.all(
                                  color: const Color(0xFFFF8A00),
                                  width: 1.2,
                                ),
                              ),
                              child: Text(
                                _silenceGateOffset < 0.001
                                    ? '${(_silenceGateOffset * 10000).toStringAsFixed(1)}×0.1‰'
                                    : '${(_silenceGateOffset * 1000).toStringAsFixed(1)}‰',
                                style: const TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w700,
                                  color: Color(0xFFCC6600),
                                ),
                              ),
                            ),
                          ],
                        ),
                        Slider(
                          value: _silenceGateOffset,
                          min: 0.0,
                          max: 0.020,
                          divisions: 40,
                          activeColor: const Color(0xFFFF8A00),
                          inactiveColor: const Color(0xFFFFE0B2),
                          onChanged: (v) {
                            setState(() {
                              _silenceGateOffset = v;
                              _analyzer.silenceGateOffset = v;
                            });
                          },
                        ),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: const [
                            Text(
                              '灵敏',
                              style: TextStyle(
                                fontSize: 14,
                                color: Color(0xFF9AA4C0),
                              ),
                            ),
                            Text(
                              '← 向左滑动提高灵敏度',
                              style: TextStyle(
                                fontSize: 14,
                                color: Color(0xFF9AA4C0),
                              ),
                            ),
                            Text(
                              '降噪',
                              style: TextStyle(
                                fontSize: 14,
                                color: Color(0xFF9AA4C0),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 14),
                  _DopamineCard(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          '拍音强度 Beat Depth',
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w800,
                            color: Color(0xFF2A3150),
                          ),
                        ),
                        const SizedBox(height: 12),
                        SizedBox(
                          height: 220,
                          child: _BeatDepthChart(history: _beatDepthHistory),
                        ),
                        const SizedBox(height: 8),
                        const Text(
                          '曲线的起伏代表拍音的强弱变化。',
                          style: TextStyle(
                            fontSize: 12,
                            color: Color(0xFF7A809E),
                          ),
                        ),
                      ],
                    ),
                  ),

                  const SizedBox(height: 14),
                  _DopamineCard(
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Icon(
                          Icons.auto_awesome,
                          color: Color(0xFF00CFFF),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            hasLiveInterval
                                ? 'Harmonics used: ${shownFrame.harmonicPairLabel.split(':').first}rd harmonic of root & ${shownFrame.harmonicPairLabel.split(':').last}nd of crown. Live confidence ${(100 * shownFrame.beatConfidence).toStringAsFixed(0)}%.'
                                : (showDemo
                                      ? 'Harmonics used: 3rd harmonic of root & 2nd of crown. Live confidence ${(100 * demoFrame.beatConfidence).toStringAsFixed(0)}%.'
                                      : 'Harmonics used: ${shownFrame.harmonicPairLabel.split(':').first}rd harmonic of root & ${shownFrame.harmonicPairLabel.split(':').last}nd of crown. Last lock confidence ${(100 * shownFrame.beatConfidence).toStringAsFixed(0)}%.'),
                            style: const TextStyle(
                              fontSize: 14,
                              height: 1.4,
                              color: Color(0xFF3B3F58),
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _TuningForkControl extends StatefulWidget {
  const _TuningForkControl({
    required this.valueHz,
    required this.isPlaying,
    required this.enabled,
    required this.onChanged,
    required this.onChangeEnd,
    required this.onTapFork,
  });

  final int valueHz;
  final bool isPlaying;
  final bool enabled;
  final ValueChanged<int> onChanged;
  final ValueChanged<int> onChangeEnd;
  final VoidCallback onTapFork;

  @override
  State<_TuningForkControl> createState() => _TuningForkControlState();
}

class _TuningForkControlState extends State<_TuningForkControl> {
  static const int _minHz = 430;
  static const int _maxHz = 450;

  late final PageController _hzPageController;
  late int _selectedHz;

  @override
  void initState() {
    super.initState();
    _selectedHz = widget.valueHz.clamp(_minHz, _maxHz);
    _hzPageController = PageController(
      initialPage: _selectedHz - _minHz,
      viewportFraction: 0.26,
    );
  }

  @override
  void didUpdateWidget(covariant _TuningForkControl oldWidget) {
    super.didUpdateWidget(oldWidget);
    final nextHz = widget.valueHz.clamp(_minHz, _maxHz);
    if (nextHz != _selectedHz) {
      _selectedHz = nextHz;
      if (_hzPageController.hasClients) {
        _hzPageController.jumpToPage(_selectedHz - _minHz);
      }
    }
  }

  @override
  void dispose() {
    _hzPageController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 132,
      height: 148,
      child: Stack(
        alignment: Alignment.center,
        children: [
          Positioned(
            top: -2,
            child: SizedBox(
              width: 116,
              height: 88,
              child: ClipPath(
                clipper: _HalfArcClipper(),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: widget.enabled
                        ? const Color.fromARGB(68, 21, 21, 21)
                        : const Color.fromARGB(51, 29, 28, 28),
                    border: Border.all(
                      color: const Color(0x55CBD6F0),
                      width: 1,
                    ),
                  ),
                  child: CupertinoTheme(
                    data: const CupertinoThemeData(
                      textTheme: CupertinoTextThemeData(
                        pickerTextStyle: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: Color(0xFF2E3A68),
                        ),
                      ),
                    ),
                    child: IgnorePointer(
                      ignoring: !widget.enabled,
                      child: NotificationListener<ScrollEndNotification>(
                        onNotification: (_) {
                          widget.onChangeEnd(_selectedHz);
                          return false;
                        },
                        child: Transform.translate(
                          offset: const Offset(0, 16),
                          child: Stack(
                            alignment: Alignment.center,
                            children: [
                              Positioned.fill(
                                child: ScrollConfiguration(
                                  behavior: const MaterialScrollBehavior()
                                      .copyWith(
                                        dragDevices: {
                                          PointerDeviceKind.touch,
                                          PointerDeviceKind.mouse,
                                          PointerDeviceKind.trackpad,
                                          PointerDeviceKind.stylus,
                                        },
                                      ),
                                  child: AnimatedBuilder(
                                    animation: _hzPageController,
                                    builder: (context, _) {
                                      final currentPage =
                                          _hzPageController.hasClients
                                          ? (_hzPageController.page ??
                                                _hzPageController.initialPage
                                                    .toDouble())
                                          : (_selectedHz - _minHz).toDouble();

                                      return PageView.builder(
                                        controller: _hzPageController,
                                        itemCount: _maxHz - _minHz + 1,
                                        onPageChanged: (index) {
                                          final hz = _minHz + index;
                                          if (hz == _selectedHz) return;
                                          _selectedHz = hz;
                                          HapticFeedback.selectionClick();
                                          widget.onChanged(hz);
                                        },
                                        itemBuilder: (context, index) {
                                          final hz = _minHz + index;
                                          final selected = hz == widget.valueHz;
                                          final delta = (index - currentPage)
                                              .abs();
                                          final arcYOffset = math.min(
                                            18.0,
                                            delta * delta * 7.0,
                                          );
                                          final scale = (1.0 - delta * 0.18)
                                              .clamp(0.74, 1.0);
                                          final opacity = (1.0 - delta * 0.35)
                                              .clamp(0.35, 1.0);

                                          return Center(
                                            child: Transform.translate(
                                              offset: Offset(0, arcYOffset),
                                              child: Transform.scale(
                                                scale: scale,
                                                child: Opacity(
                                                  opacity: opacity,
                                                  child: AnimatedDefaultTextStyle(
                                                    duration: const Duration(
                                                      milliseconds: 120,
                                                    ),
                                                    style: TextStyle(
                                                      fontSize: selected
                                                          ? 16
                                                          : 12,
                                                      fontWeight: selected
                                                          ? FontWeight.w800
                                                          : FontWeight.w500,
                                                      color: widget.enabled
                                                          ? (selected
                                                                ? const Color(
                                                                    0xFF22305E,
                                                                  )
                                                                : const Color(
                                                                    0xFF6E789A,
                                                                  ))
                                                          : const Color(
                                                              0xFF8B93AF,
                                                            ),
                                                    ),
                                                    child: Text('$hz'),
                                                  ),
                                                ),
                                              ),
                                            ),
                                          );
                                        },
                                      );
                                    },
                                  ),
                                ),
                              ),
                              IgnorePointer(
                                child: Container(
                                  width: 34,
                                  height: 28,
                                  decoration: BoxDecoration(
                                    color: widget.enabled
                                        ? const Color(0x1AFFFFFF)
                                        : const Color(0x14D9DCE6),
                                    borderRadius: BorderRadius.circular(10),
                                    border: Border.all(
                                      color: const Color(0x66CBD6F0),
                                      width: 1,
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
          Positioned(
            bottom: 0,
            child: GestureDetector(
              onTap: widget.enabled ? widget.onTapFork : null,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 220),
                curve: Curves.easeOutCubic,
                width: 78,
                height: 78,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: widget.isPlaying
                        ? const [Color(0xFF1ED760), Color(0xFF00B46E)]
                        : const [Color(0xFFFF8A00), Color(0xFFFF3FA4)],
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: widget.enabled
                          ? (widget.isPlaying
                                ? const Color(0x661ED760)
                                : const Color(0x33FF8A00))
                          : const Color(0x22000000),
                      blurRadius: widget.isPlaying ? 24 : 12,
                      offset: const Offset(0, 8),
                    ),
                  ],
                ),
                child: Icon(
                  CupertinoIcons.tuningfork,
                  size: 44,
                  color: widget.enabled
                      ? Colors.white
                      : const Color(0x66FFFFFF),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _HalfArcClipper extends CustomClipper<Path> {
  @override
  Path getClip(Size size) {
    return Path()
      ..moveTo(0, size.height)
      ..quadraticBezierTo(size.width / 2, 0, size.width, size.height)
      ..close();
  }

  @override
  bool shouldReclip(covariant CustomClipper<Path> oldClipper) => false;
}

class _DopamineCard extends StatelessWidget {
  const _DopamineCard({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xCCFFFFFF),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: const Color(0x66FFFFFF), width: 1.4),
        boxShadow: const [
          BoxShadow(
            color: Color(0x22000000),
            blurRadius: 22,
            offset: Offset(0, 12),
          ),
        ],
      ),
      padding: const EdgeInsets.all(16),
      child: child,
    );
  }
}

class _NeonValuePill extends StatelessWidget {
  const _NeonValuePill({
    required this.label,
    required this.value,
    required this.gradient,
  });

  final String label;
  final String value;
  final List<Color> gradient;

  @override
  Widget build(BuildContext context) {
    final accent = gradient.isNotEmpty
        ? gradient.first
        : const Color(0xFF00CFFF);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 48, vertical: 6),
      decoration: BoxDecoration(
        color: const Color(0xF8FFFFFF),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: const Color(0x1A000000)),
        boxShadow: const [
          BoxShadow(
            color: Color(0x0F000000),
            blurRadius: 10,
            offset: Offset(0, 3),
          ),
        ],
      ),
      child: IntrinsicWidth(
        child: Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Container(
              width: 4,
              height: 34,
              decoration: BoxDecoration(
                color: accent.withValues(alpha: 0.9),
                borderRadius: BorderRadius.circular(999),
              ),
            ),
            const SizedBox(width: 10),
            Flexible(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label.toUpperCase(),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.6,
                      color: Color(0xFF76819A),
                    ),
                  ),
                  const SizedBox(height: 1),
                  Text(
                    value,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                      height: 1.15,
                      color: Color(0xFF1E2233),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _BeatPulseOrb extends StatelessWidget {
  const _BeatPulseOrb({
    required this.t,
    required this.beatHz,
    required this.active,
  });

  final double t;
  final double beatHz;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final hz = active ? beatHz.clamp(0.2, 10.0) : 0.0;
    final pulse = active ? 0.5 + 0.5 * math.sin(2 * math.pi * hz * t) : 0.1;
    final size = 86 + pulse * 46;

    return SizedBox(
      width: 170,
      height: 130,
      child: Center(
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          width: size,
          height: size,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: const SweepGradient(
              colors: [
                Color(0xFFFF3FA4),
                Color(0xFF00CFFF),
                Color(0xFF67D300),
                Color(0xFFFFD400),
                Color(0xFFFF8A00),
                Color(0xFFFF3FA4),
              ],
            ),
            boxShadow: [
              BoxShadow(
                color: const Color(0x55FF3FA4),
                blurRadius: 22 + pulse * 24,
                spreadRadius: 1 + pulse * 2,
              ),
            ],
          ),
          child: Center(
            child: Container(
              width: size * 0.56,
              height: size * 0.56,
              decoration: const BoxDecoration(
                shape: BoxShape.circle,
                color: Color(0xFFFDFEFF),
              ),
              child: const Icon(
                Icons.music_note_rounded,
                color: Color(0xFFFF3FA4),
                size: 28,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _BottomNavItem extends StatelessWidget {
  const _BottomNavItem({
    required this.icon,
    required this.label,
    required this.color,
    required this.selected,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final Color color;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(14),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              color: selected ? color : const Color(0xFF9AA4C0),
              size: 24,
            ),
            const SizedBox(height: 2),
            Text(
              label,
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w700,
                color: selected ? color : const Color(0xFF9AA4C0),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Blob extends StatelessWidget {
  const _Blob({required this.size, required this.color});

  final double size;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(shape: BoxShape.circle, color: color),
    );
  }
}

class InfoPage extends StatelessWidget {
  const InfoPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFFDFEFF),
      appBar: AppBar(
        backgroundColor: const Color(0xFFFDFEFF),
        surfaceTintColor: Colors.transparent,
        title: const Text('BEAT LAB Info'),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: const [
          _InfoSectionCard(
            title: 'Overview',
            content:
                'BEAT LAB is an innovative app designed for piano tuner & music acoustics researcher. It collects dual tone signals through a microphone and uses constant Q-transform (CQT) and harmonic cluster clustering algorithms to accurately identify the fundamental frequencies of root and crown tones, determine intervals (such as pure fifth, third, etc.), and extract beat frequency and its intensity envelope in real time. The application has a built-in adjustable tuning fork generator (430-450 Hz) that supports listening and watching at the same time. Dynamic circular pulses, beat depth curves, and neon colored information cards make the tuning process intuitive and enjoyable. Its core algorithms include CQT spectrum analysis, harmonic order tracking, interval locking and confidence evaluation, frequency domain refinement search, etc., which can maintain stability in noisy environments. Whether you are a professional tuning lawyer or an enthusiast interested in harmony, BEAT LAB can transform previously obscure clapping phenomena into clear visual and auditory feedback, helping you complete tuning work faster and more accurately.',
          ),
          SizedBox(height: 10),
          _InfoSectionCard(
            title: 'Key Features',
            content:
                '1) Real-time beat-frequency visualizer for piano interval tuning\n2) Interactive tuning fork for generating sine wave tones\n3) Vibrant visual feedback for enhanced user experience',
          ),
          SizedBox(height: 10),
          _InfoSectionCard(
            title: 'Technical Details',
            content:
                'The app leverages advanced DSP techniques, including:\n- Real-time PCM audio capture\n- FFT spectrum analysis with parabolic interpolation\n- Harmonic-aware interval detection\n- Beat-depth envelope extraction for strength visualization',
          ),
          SizedBox(height: 10),
          _InfoSectionCard(
            title: 'Development Tools',
            content:
                '- Flutter SDK for cross-platform development\n- VS Code for efficient coding\n- Hot Reload for rapid iteration\n- flutter analyze for static code checks',
          ),
          SizedBox(height: 10),
          _InfoSectionCard(title: 'Developer', content: 'Liu Zhaorui (刘兆蕤)'),
        ],
      ),
    );
  }
}

class _InfoSectionCard extends StatelessWidget {
  const _InfoSectionCard({required this.title, required this.content});

  final String title;
  final String content;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xCCFFFFFF),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: const Color(0xFFE4E8F2)),
      ),
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w900,
              color: Color(0xFF2A3150),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            content,
            style: const TextStyle(
              fontSize: 14,
              height: 1.45,
              color: Color(0xFF3A4266),
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

class _BeatDepthChart extends StatelessWidget {
  final List<double> history;

  // fftSize=4096, 75% overlap => hopSize=1024, sampleRate=44100
  static const double _framesPerSecond = 44100.0 / 1024.0; // ≈43.1

  const _BeatDepthChart({required this.history});

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        return CustomPaint(
          painter: _BeatDepthPainter(
            data: history,
            width: constraints.maxWidth,
            height: constraints.maxHeight,
            framesPerSecond: _framesPerSecond,
          ),
        );
      },
    );
  }
}

class _BeatDepthPainter extends CustomPainter {
  final List<double> data;
  final double width;
  final double height;
  final double framesPerSecond;

  static const double _xAxisHeight = 20.0;

  _BeatDepthPainter({
    required this.data,
    required this.width,
    required this.height,
    required this.framesPerSecond,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final chartH = height - _xAxisHeight;

    if (data.isEmpty) {
      _drawEmptyMessage(canvas, size, chartH);
      _drawTimeAxis(canvas, 0, 0, chartH);
      return;
    }

    final n = data.length;
    final stepX = width / (n > 1 ? n - 1 : 1);

    final paintLine = Paint()
      ..color = const Color(0xFFFF3FA4)
      ..strokeWidth = 2.5
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;

    final paintFill = Paint()
      ..color = const Color(0x33FF3FA4)
      ..style = PaintingStyle.fill;

    final path = Path();
    final fillPath = Path();

    final firstY = chartH - (data[0] * chartH).clamp(0.0, chartH);
    path.moveTo(0, firstY);
    fillPath.moveTo(0, chartH);
    fillPath.lineTo(0, firstY);

    for (int i = 1; i < n; i++) {
      final x = i * stepX;
      final y = chartH - (data[i] * chartH).clamp(0.0, chartH);
      path.lineTo(x, y);
      fillPath.lineTo(x, y);
    }

    fillPath.lineTo(width, chartH);
    fillPath.close();

    canvas.drawPath(fillPath, paintFill);
    canvas.drawPath(path, paintLine);

    // 水平网格线
    final gridPaint = Paint()
      ..color = const Color(0x40A0A0C0)
      ..strokeWidth = 0.8;
    for (double y = 0; y <= chartH; y += chartH / 4) {
      canvas.drawLine(Offset(0, y), Offset(width, y), gridPaint);
    }

    _drawTimeAxis(canvas, n, stepX, chartH);
  }

  void _drawTimeAxis(Canvas canvas, int n, double stepX, double chartH) {
    final axisPaint = Paint()
      ..color = const Color(0x70A0A0C0)
      ..strokeWidth = 0.8;

    // 分隔线
    canvas.drawLine(Offset(0, chartH), Offset(width, chartH), axisPaint);

    // 右端"现在"标签
    _drawLabel(canvas, '现在', width, chartH + 3, alignRight: true);

    if (n <= 1) return;

    // 每1秒一个刻度，从右向左
    final maxSec = (n / framesPerSecond).floor();
    for (int sec = 1; sec <= maxSec; sec++) {
      final frameOffset = (sec * framesPerSecond).round();
      if (frameOffset >= n) break;
      final x = (n - 1 - frameOffset) * stepX;

      // 刻度竖线
      canvas.drawLine(Offset(x, chartH), Offset(x, chartH + 4), axisPaint);

      // 时间标签
      _drawLabel(canvas, '-${sec}s', x, chartH + 3, alignRight: false);
    }
  }

  void _drawLabel(
    Canvas canvas,
    String text,
    double x,
    double y, {
    bool alignRight = false,
  }) {
    final tp = TextPainter(
      text: TextSpan(
        text: text,
        style: const TextStyle(
          color: Color(0xFF9AA4C0),
          fontSize: 10,
          fontWeight: FontWeight.w500,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();

    final dx = alignRight
        ? (x - tp.width).clamp(0.0, width - tp.width)
        : (x - tp.width / 2).clamp(0.0, width - tp.width);
    tp.paint(canvas, Offset(dx, y));
  }

  void _drawEmptyMessage(Canvas canvas, Size size, double chartH) {
    final tp = TextPainter(
      text: const TextSpan(
        text: '等待拍音数据...',
        style: TextStyle(color: Color(0xFF9AA4C0), fontSize: 14),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(
      canvas,
      Offset((size.width - tp.width) / 2, (chartH - tp.height) / 2),
    );
  }

  @override
  bool shouldRepaint(covariant _BeatDepthPainter oldDelegate) {
    return oldDelegate.data != data ||
        oldDelegate.width != width ||
        oldDelegate.height != height;
  }
}
