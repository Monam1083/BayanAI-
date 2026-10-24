import 'package:flutter/material.dart';

import '../format.dart';
import '../models.dart';
import '../services/ai_client.dart';

/// What the sheet hands back when the shopkeeper taps Save.
class ConfirmedCommands {
  ConfirmedCommands(this.commands, this.transcript);

  final List<ParsedCommand> commands;
  final String transcript;
}

/// Shows what the AI understood. Nothing is written to the database until the
/// shopkeeper taps Save, and the heard text can be corrected and re-checked.
class ConfirmSheet extends StatefulWidget {
  const ConfirmSheet({super.key, required this.ai, required this.initial});

  final AiClient ai;
  final AiResult initial;

  @override
  State<ConfirmSheet> createState() => _ConfirmSheetState();
}

class _ConfirmSheetState extends State<ConfirmSheet> {
  late final TextEditingController _text =
      TextEditingController(text: widget.initial.transcript);
  late List<ParsedCommand> _commands = List.of(widget.initial.commands);
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  bool get _canSave =>
      !_busy &&
      _commands.isNotEmpty &&
      _commands.every((command) => command.validate() == null);

  Future<void> _recheck() async {
    final text = _text.text.trim();
    if (text.isEmpty) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final result = await widget.ai.text(text);
      if (!mounted) return;
      setState(() => _commands = List.of(result.commands));
    } on AiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: EdgeInsets.fromLTRB(
        16,
        0,
        16,
        16 + MediaQuery.viewInsetsOf(context).bottom,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Check before saving', style: theme.textTheme.titleLarge),
            const SizedBox(height: 12),
            TextField(
              controller: _text,
              minLines: 1,
              maxLines: 3,
              decoration: InputDecoration(
                labelText: 'What I heard',
                border: const OutlineInputBorder(),
                suffixIcon: IconButton(
                  tooltip: 'Check again',
                  icon: const Icon(Icons.refresh),
                  onPressed: _busy ? null : _recheck,
                ),
              ),
            ),
            const SizedBox(height: 8),
            if (_busy) const LinearProgressIndicator(),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Text(
                  _error!,
                  style: TextStyle(color: theme.colorScheme.error),
                ),
              ),
            if (_commands.isEmpty && !_busy)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 16),
                child: Text(
                  'No shop command found. Fix the text above and tap the '
                  'refresh icon.',
                ),
              ),
            for (var i = 0; i < _commands.length; i++)
              _CommandCard(
                command: _commands[i],
                onRemove: () => setState(() => _commands.removeAt(i)),
              ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('Cancel'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton(
                    onPressed: _canSave
                        ? () => Navigator.pop(
                              context,
                              ConfirmedCommands(
                                List.of(_commands),
                                _text.text.trim(),
                              ),
                            )
                        : null,
                    child: Text(
                      _commands.length > 1
                          ? 'Save ${_commands.length}'
                          : 'Save',
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _CommandCard extends StatelessWidget {
  const _CommandCard({required this.command, required this.onRemove});

  final ParsedCommand command;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final problem = command.validate();
    final lines = <String>[
      if (command.customer != null) 'Customer: ${command.customer}',
      if (command.item != null) 'Item: ${command.item}',
      if (command.quantity != null)
        'Quantity: ${formatQty(command.quantity, command.unit)}',
      if (command.amount != null) 'Amount: ${formatRs(command.amount!)}',
    ];

    return Card(
      color: problem == null ? null : theme.colorScheme.errorContainer,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 4, 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    command.action.label,
                    style: theme.textTheme.titleMedium
                        ?.copyWith(fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 4),
                  for (final line in lines) Text(line),
                  if (problem != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Text(
                        problem,
                        style: TextStyle(
                          color: theme.colorScheme.error,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                ],
              ),
            ),
            IconButton(
              tooltip: 'Remove',
              icon: const Icon(Icons.close),
              onPressed: onRemove,
            ),
          ],
        ),
      ),
    );
  }
}
