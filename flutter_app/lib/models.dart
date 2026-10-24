import 'package:cloud_firestore/cloud_firestore.dart';

import 'format.dart';

/// What the shopkeeper wants to do. These names are also the values the AI
/// service returns in its JSON, so do not rename them without changing
/// ai_service/parsing.py too.
enum CommandAction { credit, payment, sale, restock }

extension CommandActionLabel on CommandAction {
  String get label => switch (this) {
        CommandAction.credit => 'Udhaar (credit given)',
        CommandAction.payment => 'Payment received',
        CommandAction.sale => 'Sale',
        CommandAction.restock => 'Stock added',
      };
}

CommandAction? parseAction(String? value) {
  for (final action in CommandAction.values) {
    if (action.name == value) return action;
  }
  return null;
}

String? _cleanString(Object? value) {
  if (value == null) return null;
  final text = value.toString().trim();
  return text.isEmpty ? null : text;
}

double? _toDouble(Object? value) {
  if (value == null) return null;
  if (value is num) return value.toDouble();
  return double.tryParse(value.toString().replaceAll(',', '').trim());
}

/// One command understood by the AI, before it is saved.
class ParsedCommand {
  ParsedCommand({
    required this.action,
    this.customer,
    this.item,
    this.quantity,
    this.unit,
    this.amount,
  });

  final CommandAction action;
  final String? customer;
  final String? item;
  final double? quantity;
  final String? unit;
  final double? amount;

  factory ParsedCommand.fromJson(Map<String, dynamic> json) {
    final action = parseAction(json['action'] as String?);
    if (action == null) {
      throw FormatException('Unknown action: ${json['action']}');
    }
    return ParsedCommand(
      action: action,
      customer: _cleanString(json['customer']),
      item: _cleanString(json['item']),
      quantity: _toDouble(json['quantity']),
      unit: _cleanString(json['unit']),
      amount: _toDouble(json['amount']),
    );
  }

  /// A short problem description, or null when the command can be saved.
  String? validate() {
    switch (action) {
      case CommandAction.credit:
      case CommandAction.payment:
        if (customer == null) return 'Customer name is missing';
        if (amount == null || amount! <= 0) return 'Amount is missing';
      case CommandAction.sale:
      case CommandAction.restock:
        if (item == null) return 'Item is missing';
        if (quantity == null || quantity! <= 0) return 'Quantity is missing';
    }
    return null;
  }
}

class AiResult {
  AiResult({required this.transcript, required this.commands});

  final String transcript;
  final List<ParsedCommand> commands;
}

class Customer {
  Customer({required this.id, required this.name, required this.balance});

  final String id;
  final String name;

  /// Rupees the customer owes the shop. Negative means the shop owes them.
  final double balance;

  factory Customer.fromDoc(QueryDocumentSnapshot<Map<String, dynamic>> doc) {
    final data = doc.data();
    return Customer(
      id: doc.id,
      name: (data['name'] as String?) ?? 'Unknown',
      balance: (data['balance'] as num?)?.toDouble() ?? 0,
    );
  }
}

class StockItem {
  StockItem({
    required this.id,
    required this.name,
    required this.quantity,
    required this.unit,
  });

  final String id;
  final String name;
  final double quantity;
  final String unit;

  factory StockItem.fromDoc(QueryDocumentSnapshot<Map<String, dynamic>> doc) {
    final data = doc.data();
    return StockItem(
      id: doc.id,
      name: (data['name'] as String?) ?? 'Unknown',
      quantity: (data['quantity'] as num?)?.toDouble() ?? 0,
      unit: (data['unit'] as String?) ?? 'pcs',
    );
  }
}

/// One saved line in the history.
class LedgerEntry {
  LedgerEntry({
    required this.id,
    required this.action,
    this.customerName,
    this.itemName,
    this.quantity,
    this.unit,
    this.amount,
    this.createdAt,
  });

  final String id;
  final CommandAction action;
  final String? customerName;
  final String? itemName;
  final double? quantity;
  final String? unit;
  final double? amount;
  final DateTime? createdAt;

  factory LedgerEntry.fromDoc(QueryDocumentSnapshot<Map<String, dynamic>> doc) {
    final data = doc.data();
    return LedgerEntry(
      id: doc.id,
      action: parseAction(data['action'] as String?) ?? CommandAction.sale,
      customerName: data['customerName'] as String?,
      itemName: data['itemName'] as String?,
      quantity: (data['quantity'] as num?)?.toDouble(),
      unit: data['unit'] as String?,
      amount: (data['amount'] as num?)?.toDouble(),
      createdAt: (data['createdAt'] as Timestamp?)?.toDate(),
    );
  }

  String get _goods => [
        if (quantity != null) formatQty(quantity, unit),
        if (itemName != null) itemName!,
      ].join(' ');

  String get title {
    final who = customerName ?? 'Customer';
    final rupees = amount == null ? '' : formatRs(amount!);
    switch (action) {
      case CommandAction.credit:
        return '$who took on credit: $rupees';
      case CommandAction.payment:
        return '$who paid $rupees';
      case CommandAction.sale:
        return rupees.isEmpty ? 'Sold $_goods' : 'Sold $_goods for $rupees';
      case CommandAction.restock:
        return 'Added $_goods to stock';
    }
  }

  String get subtitle {
    final parts = <String>[];
    if (action == CommandAction.credit && _goods.isNotEmpty) parts.add(_goods);
    parts.add(formatWhen(createdAt));
    return parts.join(' · ');
  }
}
