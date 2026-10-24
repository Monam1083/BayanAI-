import 'package:cloud_firestore/cloud_firestore.dart';

import '../format.dart';
import '../fuzzy.dart';
import '../models.dart';

/// All reads and writes for one shop. Data lives under `shops/{uid}/...` so the
/// Firestore rules can limit each signed-in user to their own shop.
class ShopRepository {
  ShopRepository(this.uid) : _db = FirebaseFirestore.instance;

  final String uid;
  final FirebaseFirestore _db;

  CollectionReference<Map<String, dynamic>> _col(String name) =>
      _db.collection('shops').doc(uid).collection(name);

  // ---------------------------------------------------------------- streams

  /// Customers who owe the most come first.
  Stream<List<Customer>> customers() => _col('customers')
      .orderBy('balance', descending: true)
      .snapshots()
      .map((snap) => snap.docs.map(Customer.fromDoc).toList());

  Stream<List<StockItem>> items() => _col('items')
      .orderBy('name')
      .snapshots()
      .map((snap) => snap.docs.map(StockItem.fromDoc).toList());

  Stream<List<LedgerEntry>> history() => _col('transactions')
      .orderBy('createdAt', descending: true)
      .limit(100)
      .snapshots()
      .map((snap) => snap.docs.map(LedgerEntry.fromDoc).toList());

  /// Sorted on the device so no composite Firestore index is needed.
  Stream<List<LedgerEntry>> customerHistory(String customerId) =>
      _col('transactions')
          .where('customerId', isEqualTo: customerId)
          .snapshots()
          .map((snap) {
        final entries = snap.docs.map(LedgerEntry.fromDoc).toList();
        entries.sort((a, b) {
          final left = a.createdAt ?? DateTime.now();
          final right = b.createdAt ?? DateTime.now();
          return right.compareTo(left);
        });
        return entries;
      });

  // ------------------------------------------------------------------ write

  /// Saves one confirmed command and returns a short message for the user.
  ///
  /// Balances and stock use FieldValue.increment, so two phones (or two quick
  /// commands) can never overwrite each other's numbers. Everything for one
  /// command goes into a single batch: either all of it is saved or none.
  Future<String> apply(ParsedCommand command, {String? transcript}) async {
    final problem = command.validate();
    if (problem != null) throw StateError(problem);

    final batch = _db.batch();
    final notes = <String>[];
    String? customerId;
    String? customerName;
    String? itemName;

    // Customer balance (credit adds to what they owe, payment subtracts).
    if (command.action == CommandAction.credit ||
        command.action == CommandAction.payment) {
      final snap = await _col('customers').get();
      final known = snap.docs.map(Customer.fromDoc).toList();
      final match =
          bestMatch<Customer>(command.customer!, known, (c) => c.name);

      final delta = command.action == CommandAction.credit
          ? command.amount!
          : -command.amount!;

      if (match != null) {
        customerId = match.id;
        customerName = match.name;
        batch.update(
          _col('customers').doc(match.id),
          {'balance': FieldValue.increment(delta)},
        );
      } else {
        final ref = _col('customers').doc();
        customerId = ref.id;
        customerName = titleCase(command.customer!);
        batch.set(ref, {
          'name': customerName,
          'balance': delta,
          'createdAt': FieldValue.serverTimestamp(),
        });
        notes.add('New customer "$customerName" added');
      }
    }

    // Stock (sale and credit take stock out, restock puts it in).
    final touchesStock = command.item != null &&
        command.quantity != null &&
        command.action != CommandAction.payment;

    if (touchesStock) {
      final snap = await _col('items').get();
      final known = snap.docs.map(StockItem.fromDoc).toList();
      final match = bestMatch<StockItem>(command.item!, known, (i) => i.name);

      final restock = command.action == CommandAction.restock;
      final delta = restock ? command.quantity! : -command.quantity!;

      if (match != null) {
        itemName = match.name;
        batch.update(
          _col('items').doc(match.id),
          {'quantity': FieldValue.increment(delta)},
        );
        if (match.quantity + delta < 0) {
          notes.add('${match.name} stock is now negative, please check it');
        }
      } else if (restock) {
        final ref = _col('items').doc();
        itemName = titleCase(command.item!);
        batch.set(ref, {
          'name': itemName,
          'quantity': delta,
          'unit': command.unit ?? 'pcs',
          'createdAt': FieldValue.serverTimestamp(),
        });
        notes.add('New stock item "$itemName" added');
      } else {
        itemName = titleCase(command.item!);
        notes.add('"$itemName" is not in your stock list, stock not changed');
      }
    } else if (command.item != null) {
      itemName = titleCase(command.item!);
      if (command.action == CommandAction.credit) {
        notes.add('No quantity heard, stock not changed');
      }
    }

    // History line.
    batch.set(_col('transactions').doc(), {
      'action': command.action.name,
      'customerId': customerId,
      'customerName': customerName,
      'itemName': itemName,
      'quantity': command.quantity,
      'unit': command.unit,
      'amount': command.amount,
      'transcript': transcript,
      'createdAt': FieldValue.serverTimestamp(),
    });

    await _commit(batch);
    return notes.isEmpty ? 'Saved' : 'Saved. ${notes.join('. ')}';
  }

  /// Firestore keeps the write in its local cache and syncs it later when the
  /// phone is offline, but commit() only completes once the server has
  /// answered. Waiting a few seconds keeps the app responsive on a bad
  /// connection; real errors that arrive in time (for example permission
  /// denied) are still thrown.
  Future<void> _commit(WriteBatch batch) {
    return batch.commit().timeout(
          const Duration(seconds: 4),
          onTimeout: () {},
        );
  }
}
