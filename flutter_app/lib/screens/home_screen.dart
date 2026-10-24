import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models.dart';
import '../services/ai_client.dart';
import '../services/shop_repository.dart';
import 'confirm_sheet.dart';
import 'tabs.dart';

/// 10.0.2.2 is how the Android emulator reaches the computer it runs on.
/// On a real phone, open Settings (top right) and enter your laptop's Wi-Fi
/// address, for example http://192.168.1.20:8000
const String _defaultAiUrl = 'http://10.0.2.2:8000';
const String _prefsKey = 'ai_service_url';

enum VoiceState { idle, recording, thinking }

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, required this.repository});

  final ShopRepository repository;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final AudioRecorder _recorder = AudioRecorder();

  // Streams are created once so the tabs do not re-subscribe on each rebuild.
  late final Stream<List<Customer>> _customers = widget.repository.customers();
  late final Stream<List<StockItem>> _items = widget.repository.items();
  late final Stream<List<LedgerEntry>> _history = widget.repository.history();

  AiClient _ai = AiClient(_defaultAiUrl);
  String _aiUrl = _defaultAiUrl;
  VoiceState _voice = VoiceState.idle;
  int _tab = 0;

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  @override
  void dispose() {
    _recorder.dispose();
    super.dispose();
  }

  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString(_prefsKey);
    if (saved != null && saved.isNotEmpty && mounted) {
      setState(() {
        _aiUrl = saved;
        _ai = AiClient(saved);
      });
    }
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  // ------------------------------------------------------------- voice flow

  Future<void> _toggleRecording() async {
    if (_voice == VoiceState.thinking) return;
    if (_voice == VoiceState.recording) {
      await _stopAndProcess();
      return;
    }

    try {
      if (!await _recorder.hasPermission()) {
        _toast('Microphone permission is needed to use your voice.');
        return;
      }
      final dir = await getTemporaryDirectory();
      final path =
          '${dir.path}/command_${DateTime.now().millisecondsSinceEpoch}.wav';
      // 16 kHz mono WAV is what Whisper works with internally.
      await _recorder.start(
        const RecordConfig(
          encoder: AudioEncoder.wav,
          sampleRate: 16000,
          numChannels: 1,
        ),
        path: path,
      );
      if (mounted) setState(() => _voice = VoiceState.recording);
    } catch (e) {
      _toast('Could not start recording: $e');
    }
  }

  Future<void> _stopAndProcess() async {
    String? path;
    try {
      path = await _recorder.stop();
    } catch (e) {
      _toast('Could not stop recording: $e');
    }
    if (path == null) {
      if (mounted) setState(() => _voice = VoiceState.idle);
      return;
    }

    if (mounted) setState(() => _voice = VoiceState.thinking);
    final file = File(path);
    try {
      final result = await _ai.voice(file);
      await _review(result);
    } on AiException catch (e) {
      _toast(e.message);
    } catch (e) {
      _toast('Something went wrong: $e');
    } finally {
      if (await file.exists()) await file.delete();
      if (mounted) setState(() => _voice = VoiceState.idle);
    }
  }

  Future<void> _typeCommand() async {
    // Not disposed on purpose: the dialog is still animating out when it
    // returns, and an unlistened controller is simply garbage collected.
    final controller = TextEditingController();
    final text = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Type a command'),
        content: TextField(
          controller: controller,
          autofocus: true,
          minLines: 1,
          maxLines: 3,
          decoration: const InputDecoration(
            hintText: 'Ahmad took 500 rupees of sugar on credit',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: const Text('Check'),
          ),
        ],
      ),
    );
    if (text == null || text.isEmpty) return;

    setState(() => _voice = VoiceState.thinking);
    try {
      final result = await _ai.text(text);
      await _review(result);
    } on AiException catch (e) {
      _toast(e.message);
    } finally {
      if (mounted) setState(() => _voice = VoiceState.idle);
    }
  }

  /// Shows what the AI understood and saves it only after the owner agrees.
  Future<void> _review(AiResult result) async {
    if (!mounted) return;
    if (result.transcript.isEmpty && result.commands.isEmpty) {
      _toast("I couldn't hear anything. Please try again.");
      return;
    }
    final confirmed = await showModalBottomSheet<ConfirmedCommands>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      builder: (_) => ConfirmSheet(ai: _ai, initial: result),
    );
    if (confirmed == null || confirmed.commands.isEmpty) return;
    await _save(confirmed);
  }

  Future<void> _save(ConfirmedCommands confirmed) async {
    final messages = <String>[];
    try {
      for (final command in confirmed.commands) {
        messages.add(
          await widget.repository
              .apply(command, transcript: confirmed.transcript),
        );
      }
      if (messages.length == 1) {
        _toast(messages.first);
      } else {
        final extras = messages.where((m) => m != 'Saved').toList();
        _toast(
          'Saved ${messages.length} entries'
          '${extras.isEmpty ? '' : '. ${extras.join('. ')}'}',
        );
      }
    } catch (e) {
      _toast('Could not save: $e');
    }
  }

  // --------------------------------------------------------------- settings

  Future<void> _openSettings() async {
    final controller = TextEditingController(text: _aiUrl);
    String? status;
    var testing = false;

    final newUrl = await showDialog<String>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setLocal) => AlertDialog(
          title: const Text('AI service'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: controller,
                keyboardType: TextInputType.url,
                decoration: const InputDecoration(
                  labelText: 'Address',
                  hintText: 'http://192.168.1.20:8000',
                ),
              ),
              if (status != null) ...[
                const SizedBox(height: 12),
                Text(status!),
              ],
            ],
          ),
          actions: [
            TextButton(
              onPressed: testing
                  ? null
                  : () async {
                      setLocal(() {
                        testing = true;
                        status = 'Testing...';
                      });
                      final message = await AiClient(controller.text).health();
                      setLocal(() {
                        testing = false;
                        status = message;
                      });
                    },
              child: const Text('Test'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, controller.text.trim()),
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );

    if (newUrl == null || newUrl.isEmpty) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefsKey, newUrl);
    if (!mounted) return;
    setState(() {
      _aiUrl = newUrl;
      _ai = AiClient(newUrl);
    });
    _toast('AI service address saved');
  }

  // ------------------------------------------------------------------ build

  @override
  Widget build(BuildContext context) {
    final recording = _voice == VoiceState.recording;
    final thinking = _voice == VoiceState.thinking;

    return Scaffold(
      appBar: AppBar(
        title: const Text('BayanAI'),
        actions: [
          IconButton(
            tooltip: 'AI service settings',
            icon: const Icon(Icons.settings_outlined),
            onPressed: _openSettings,
          ),
        ],
      ),
      body: IndexedStack(
        index: _tab,
        children: [
          CustomersTab(repository: widget.repository, stream: _customers),
          StockTab(stream: _items),
          HistoryTab(stream: _history),
        ],
      ),
      floatingActionButton: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          FloatingActionButton.small(
            heroTag: 'type',
            tooltip: 'Type a command',
            onPressed: _voice == VoiceState.idle ? _typeCommand : null,
            child: const Icon(Icons.keyboard_outlined),
          ),
          const SizedBox(height: 12),
          FloatingActionButton.extended(
            heroTag: 'mic',
            onPressed: thinking ? null : _toggleRecording,
            backgroundColor: recording ? Colors.red : null,
            foregroundColor: recording ? Colors.white : null,
            icon: thinking
                ? const SizedBox.square(
                    dimension: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Icon(recording ? Icons.stop : Icons.mic),
            label: Text(
              thinking
                  ? 'Thinking...'
                  : recording
                      ? 'Listening... tap to stop'
                      : 'Tap to speak',
            ),
          ),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: (index) => setState(() => _tab = index),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.menu_book_outlined),
            selectedIcon: Icon(Icons.menu_book),
            label: 'Khata',
          ),
          NavigationDestination(
            icon: Icon(Icons.inventory_2_outlined),
            selectedIcon: Icon(Icons.inventory_2),
            label: 'Stock',
          ),
          NavigationDestination(
            icon: Icon(Icons.history),
            label: 'History',
          ),
        ],
      ),
    );
  }
}
