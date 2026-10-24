import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

/// Recorded audio as bytes, plus a filename the AI service can use to
/// recognise the format.
class RecordedAudio {
  const RecordedAudio(this.bytes, this.filename);
  final Uint8List bytes;
  final String filename;
}

/// Records the microphone on Android AND web.
///
/// Mobile: records a 16 kHz mono WAV in a temp file, reads it, deletes it.
/// Web: path_provider does not exist in browsers, so no temp file is used.
///      The browser records WebM/Opus and returns a blob: URL, which is
///      downloaded into bytes.
class VoiceRecorder {
  final AudioRecorder _recorder = AudioRecorder();

  /// Returns false if the microphone permission was refused.
  Future<bool> start() async {
    if (!await _recorder.hasPermission()) return false;

    var path = '';
    if (!kIsWeb) {
      final dir = await getTemporaryDirectory();
      path = '${dir.path}/command_${DateTime.now().millisecondsSinceEpoch}.wav';
    }

    await _recorder.start(
      kIsWeb
          ? const RecordConfig(encoder: AudioEncoder.opus)
          : const RecordConfig(
              encoder: AudioEncoder.wav,
              sampleRate: 16000,
              numChannels: 1,
            ),
      path: path,
    );
    return true;
  }

  /// Stops recording. Returns null if nothing was recorded.
  Future<RecordedAudio?> stop() async {
    final result = await _recorder.stop();
    if (result == null || result.isEmpty) return null;

    if (kIsWeb) {
      // On web, `result` is a blob: URL, not a file path.
      final bytes = await http.readBytes(Uri.parse(result));
      return RecordedAudio(bytes, 'command.webm');
    }

    final file = File(result);
    final bytes = await file.readAsBytes();
    try {
      await file.delete();
    } on Exception {
      // Leftover temp file is harmless.
    }
    return RecordedAudio(bytes, 'command.wav');
  }

  /// Stops and throws the recording away.
  Future<void> cancel() => _recorder.cancel();

  Future<bool> isRecording() => _recorder.isRecording();

  Future<void> dispose() => _recorder.dispose();
}
