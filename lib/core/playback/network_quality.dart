import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// ClearCut: what "Auto" quality means — the best quality this device's
/// connection can keep playing without stalling.
///
/// Before this, Auto simply took the highest quality, so on a slow or mobile
/// connection playback started at 1080p and buffered constantly.
///
/// Two inputs, best first:
///  1. throughput actually MEASURED while streaming (mpv's `cache-speed`
///     samples, see [recordThroughput]) — real numbers for this network;
///  2. Android's own estimate of the active network's downstream bandwidth
///     (`NetworkCapabilities.linkDownstreamBandwidthKbps`), read natively.
/// With neither known, [maxHeight] is null and Auto keeps its old behaviour
/// (highest), so nothing gets worse on a device that reports nothing.
class NetworkQuality {
  NetworkQuality._();
  static final NetworkQuality instance = NetworkQuality._();

  static const MethodChannel _channel = MethodChannel('clearcut/network');

  /// Exponential moving average of measured download speed, bits/second.
  double? _measuredBps;
  DateTime? _measuredAt;

  /// Android's estimate of the active network, bits/second.
  int? _osBps;
  bool _metered = false;

  /// Measured speeds older than this no longer describe the current network
  /// (the user may have moved from Wi-Fi to mobile data).
  static const Duration _measuredTtl = Duration(minutes: 20);

  /// Refreshes Android's estimate. Cheap; call when playback is about to
  /// start and at app launch. Never throws.
  Future<void> refresh() async {
    if (!Platform.isAndroid) return;
    try {
      final r = await _channel.invokeMapMethod<String, dynamic>('estimate');
      final kbps = (r?['downKbps'] as num?)?.toInt() ?? 0;
      _osBps = kbps > 0 ? kbps * 1000 : null;
      _metered = r?['metered'] == true;
    } catch (e) {
      debugPrint('[netq] estimate unavailable: $e');
    }
  }

  /// Feeds one throughput sample (bytes/second) observed while streaming.
  /// Zero samples (buffer full, paused) say nothing about the network.
  void recordThroughput(double bytesPerSecond) {
    if (bytesPerSecond <= 0) return;
    final bps = bytesPerSecond * 8;
    final prev = _measuredBps;
    final fresh =
        _measuredAt != null &&
        DateTime.now().difference(_measuredAt!) < _measuredTtl;
    // Weighted toward the recent past, but one burst can't swing it.
    _measuredBps = (prev == null || !fresh) ? bps : prev * 0.7 + bps * 0.3;
    _measuredAt = DateTime.now();
  }

  /// Best current estimate of usable bandwidth, bits/second, or null.
  double? get bandwidthBps {
    final measured = _measuredBps;
    if (measured != null &&
        _measuredAt != null &&
        DateTime.now().difference(_measuredAt!) < _measuredTtl) {
      return measured;
    }
    final os = _osBps;
    if (os == null) return null;
    // Android reports link capacity, which real throughput rarely reaches.
    return os * (_metered ? 0.5 : 0.6);
  }

  /// Highest stream bitrate (bits/second) worth asking for: a safety margin
  /// under the bandwidth so the buffer keeps growing. Null when unknown.
  int? get maxBitrate {
    final b = bandwidthBps;
    return b == null ? null : (b * 0.75).round();
  }

  /// Tallest video (px) the connection comfortably sustains, or null when
  /// unknown. Typical web-video bitrates: 1080p ≈ 5 Mbps, 720p ≈ 2.8 Mbps,
  /// 480p ≈ 1.4 Mbps, 360p ≈ 0.8 Mbps.
  int? get maxHeight {
    final b = maxBitrate;
    if (b == null) return null;
    if (b >= 9000000) return 2160;
    if (b >= 5000000) return 1080;
    if (b >= 2800000) return 720;
    if (b >= 1400000) return 480;
    return 360;
  }
}
