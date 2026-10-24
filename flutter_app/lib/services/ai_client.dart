import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../models.dart';

class AiException implements Exception {
  AiException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// Talks to the open-source AI service in /ai_service (Whisper + Ollama).
class AiClient {
  AiClient(String baseUrl)
      : baseUrl = baseUrl.trim().replaceAll(RegExp(r'/+$'), '');

  final String baseUrl;

  /// Uploads a recording; the service transcribes it and extracts commands.
  Future<AiResult> voice(File audio) async {
    try {
      final request =
          http.MultipartRequest('POST', Uri.parse('$baseUrl/voice'))
            ..files.add(await http.MultipartFile.fromPath(
              'audio',
              audio.path,
              filename: 'command.wav',
            ));
      final streamed = await request.send().timeout(
            const Duration(seconds: 120),
          );
      final response = await http.Response.fromStream(streamed);
      return _handle(response);
    } on AiException {
      rethrow;
    } on SocketException {
      throw AiException(_unreachable);
    } on http.ClientException {
      throw AiException(_unreachable);
    } on FormatException catch (e) {
      throw AiException('The AI service address looks wrong: ${e.message}');
    } on Exception catch (e) {
      throw AiException(_describe(e));
    }
  }

  /// Same extraction, but from typed (or corrected) text. No audio involved.
  Future<AiResult> text(String text) async {
    try {
      final response = await http
          .post(
            Uri.parse('$baseUrl/parse'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({'text': text}),
          )
          .timeout(const Duration(seconds: 60));
      return _handle(response);
    } on AiException {
      rethrow;
    } on SocketException {
      throw AiException(_unreachable);
    } on http.ClientException {
      throw AiException(_unreachable);
    } on FormatException catch (e) {
      throw AiException('The AI service address looks wrong: ${e.message}');
    } on Exception catch (e) {
      throw AiException(_describe(e));
    }
  }

  /// Used by the Settings "Test" button. Always returns a message to show.
  Future<String> health() async {
    try {
      final response = await http
          .get(Uri.parse('$baseUrl/health'))
          .timeout(const Duration(seconds: 6));
      if (response.statusCode != 200) {
        return 'The service answered with error ${response.statusCode}.';
      }
      final data = jsonDecode(utf8.decode(response.bodyBytes));
      if (data is Map && data['ollama'] == true) {
        return 'Connected. The AI service and Ollama are ready.';
      }
      final hint = data is Map ? data['hint'] : null;
      return 'Connected to the service. '
          '${hint is String && hint.isNotEmpty ? hint : 'Ollama is not ready.'}';
    } on Exception {
      return _unreachable;
    }
  }

  String get _unreachable =>
      'Cannot reach the AI service at $baseUrl. Check that it is running, '
      'that the phone is on the same Wi-Fi, and the address in Settings.';

  String _describe(Exception e) {
    final text = e.toString();
    if (text.contains('TimeoutException')) {
      return 'The AI service took too long to answer. Try again, or use a '
          'smaller model.';
    }
    return 'Something went wrong talking to the AI service: $text';
  }

  AiResult _handle(http.Response response) {
    // Decode bytes as UTF-8 ourselves so Urdu text is never garbled.
    final body = utf8.decode(response.bodyBytes);
    Object? decoded;
    try {
      decoded = jsonDecode(body);
    } on FormatException {
      decoded = null;
    }

    if (response.statusCode != 200) {
      var detail = 'AI service error (${response.statusCode})';
      if (decoded is Map && decoded['detail'] is String) {
        detail = decoded['detail'] as String;
      }
      throw AiException(detail);
    }
    if (decoded is! Map<String, dynamic>) {
      throw AiException('The AI service sent an answer the app cannot read.');
    }

    final transcript = (decoded['transcript'] as String?) ?? '';
    final raw = decoded['commands'];
    final commands = <ParsedCommand>[];
    if (raw is List) {
      for (final entry in raw) {
        if (entry is Map<String, dynamic>) {
          try {
            commands.add(ParsedCommand.fromJson(entry));
          } on FormatException {
            // Skip a command with an unknown action instead of failing all.
          }
        }
      }
    }
    return AiResult(transcript: transcript, commands: commands);
  }
}
