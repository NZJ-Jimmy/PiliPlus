import 'dart:async';
import 'dart:io';

import 'package:PiliPlus/http/browser_ua.dart';
import 'package:PiliPlus/http/constants.dart';
import 'package:PiliPlus/plugin/pl_player/models/data_source.dart';
import 'package:flutter/services.dart';

class IOSPipRestoreState {
  const IOSPipRestoreState({
    required this.wasActive,
    required this.position,
    required this.isPlaying,
  });

  final bool wasActive;
  final Duration position;
  final bool isPlaying;

  factory IOSPipRestoreState.fromMap(Map<dynamic, dynamic> map) {
    final positionMs = switch (map['positionMs']) {
      int value => value,
      String value => int.tryParse(value) ?? 0,
      num value => value.toInt(),
      _ => 0,
    };
    return IOSPipRestoreState(
      wasActive: map['wasActive'] == true,
      position: Duration(milliseconds: positionMs),
      isPlaying: map['isPlaying'] == true,
    );
  }
}

abstract final class IOSPipService {
  static const MethodChannel _channel = MethodChannel('PiliPlus.iOSPiP');
  static final StreamController<IOSPipRestoreState> _restoreController =
      StreamController<IOSPipRestoreState>.broadcast();

  static bool _initialized = false;
  static bool? _availableCache;
  static String? _preparedSignature;

  static void ensureInitialized() {
    if (_initialized) {
      return;
    }
    _initialized = true;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'onPipStop' && call.arguments is Map) {
        _restoreController.add(
          IOSPipRestoreState.fromMap(call.arguments as Map),
        );
      }
    });
  }

  static Stream<IOSPipRestoreState> get onPipStop {
    ensureInitialized();
    return _restoreController.stream;
  }

  static Future<bool> get isAvailable async {
    if (!Platform.isIOS) {
      return false;
    }
    if (_availableCache != null) {
      return _availableCache!;
    }
    ensureInitialized();
    _availableCache =
        (await _channel.invokeMethod<bool>('isAvailable')) ?? false;
    return _availableCache!;
  }

  static Map<String, dynamic> _enterArgs({
    required DataSource dataSource,
    required Duration position,
    required bool isPlaying,
    required double playbackSpeed,
  }) {
    return {
      'videoUrl': _normalizeSource(dataSource.videoSource),
      'audioUrl': switch (dataSource.audioSource) {
        final String source when source.isNotEmpty => _normalizeSource(source),
        _ => null,
      },
      'positionMs': position.inMilliseconds,
      'playWhenReady': isPlaying,
      'playbackSpeed': playbackSpeed,
      'headers': const {
        'User-Agent': BrowserUa.pc,
        'Referer': HttpString.baseUrl,
      },
    };
  }

  static String _signatureOf(DataSource dataSource) {
    final audio = dataSource.audioSource ?? '';
    return '${_normalizeSource(dataSource.videoSource)}|$audio';
  }

  static Future<bool> prepare(DataSource dataSource) async {
    if (!Platform.isIOS) {
      return false;
    }
    if (!await isAvailable) {
      return false;
    }
    ensureInitialized();
    final signature = _signatureOf(dataSource);
    if (_preparedSignature == signature) {
      return true;
    }
    final ok =
        (await _channel.invokeMethod<bool>(
          'prepare',
          _enterArgs(
            dataSource: dataSource,
            position: Duration.zero,
            isPlaying: false,
            playbackSpeed: 1,
          ),
        )) ??
        false;
    if (ok) {
      _preparedSignature = signature;
    }
    return ok;
  }

  static Future<bool> enter({
    required DataSource dataSource,
    required Duration position,
    required bool isPlaying,
    required double playbackSpeed,
  }) async {
    if (!Platform.isIOS) {
      return false;
    }
    ensureInitialized();
    return (await _channel.invokeMethod<bool>(
          'enter',
          _enterArgs(
            dataSource: dataSource,
            position: position,
            isPlaying: isPlaying,
            playbackSpeed: playbackSpeed,
          ),
        )) ??
        false;
  }

  static Future<IOSPipRestoreState?> restore() async {
    if (!Platform.isIOS) {
      return null;
    }
    ensureInitialized();
    final result = await _channel.invokeMapMethod<dynamic, dynamic>('restore');
    if (result == null) {
      return null;
    }
    return IOSPipRestoreState.fromMap(result);
  }

  static String _normalizeSource(String source) {
    if (source.startsWith('http://') ||
        source.startsWith('https://') ||
        source.startsWith('file://')) {
      return source;
    }
    return Uri.file(source).toString();
  }
}
