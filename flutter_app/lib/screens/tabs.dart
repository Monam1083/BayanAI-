import 'package:flutter/material.dart';

import '../format.dart';
import '../models.dart';
import '../services/shop_repository.dart';
import 'customer_detail_screen.dart';

const double _fabClearance = 180; // keeps the last row above the buttons

IconData actionIcon(CommandAction action) => switch (action) {
      CommandAction.credit => Icons.menu_book_outlined,
      CommandAction.payment => Icons.payments_outlined,
      CommandAction.sale => Icons.shopping_bag_outlined,
      CommandAction.restock => Icons.add_box_outlined,
    };

/// Money colours: red when a customer owes, green when settled or in credit.
Color balanceColor(BuildContext context, double balance) =>
    balance > 0 ? Colors.red.shade700 : Colors.green.shade700;

class CustomersTab extends StatelessWidget {
  const CustomersTab({
    super.key,
    required this.repository,
    required this.stream,
  });

  final ShopRepository repository;
  final Stream<List<Customer>> stream;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<Customer>>(
      stream: stream,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return _Message(
            icon: Icons.error_outline,
            text: 'Could not load customers.\n${snapshot.error}',
          );
        }
        final customers = snapshot.data;
        if (customers == null) {
          return const Center(child: CircularProgressIndicator());
        }
        if (customers.isEmpty) {
          return const _Message(
            icon: Icons.mic_none,
            text: 'No customers yet.\nTap the mic and say, for example:\n'
                '"Ahmad took 500 rupees of sugar on credit"',
          );
        }

        final owed = customers
            .where((c) => c.balance > 0)
            .fold<double>(0, (sum, c) => sum + c.balance);

        return ListView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, _fabClearance),
          children: [
            _SummaryCard(label: 'Total udhaar to collect', value: formatRs(owed)),
            const SizedBox(height: 8),
            for (final customer in customers)
              ListTile(
                leading: CircleAvatar(
                  child: Text(
                    customer.name.isEmpty
                        ? '?'
                        : customer.name[0].toUpperCase(),
                  ),
                ),
                title: Text(customer.name),
                subtitle: Text(
                  customer.balance > 0
                      ? 'Owes you'
                      : customer.balance < 0
                          ? 'You owe them'
                          : 'Settled',
                ),
                trailing: Text(
                  formatRs(customer.balance.abs()),
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 16,
                    color: balanceColor(context, customer.balance),
                  ),
                ),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => CustomerDetailScreen(
                      repository: repository,
                      customer: customer,
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

class StockTab extends StatelessWidget {
  const StockTab({super.key, required this.stream});

  final Stream<List<StockItem>> stream;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<StockItem>>(
      stream: stream,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return _Message(
            icon: Icons.error_outline,
            text: 'Could not load stock.\n${snapshot.error}',
          );
        }
        final items = snapshot.data;
        if (items == null) {
          return const Center(child: CircularProgressIndicator());
        }
        if (items.isEmpty) {
          return const _Message(
            icon: Icons.inventory_2_outlined,
            text: 'No stock yet.\nSay, for example:\n'
                '"Add 50 kilo rice to stock"',
          );
        }
        return ListView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, _fabClearance),
          children: [
            for (final item in items)
              ListTile(
                leading: const CircleAvatar(
                  child: Icon(Icons.inventory_2_outlined),
                ),
                title: Text(item.name),
                trailing: Text(
                  formatQty(item.quantity, item.unit),
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 16,
                    color: item.quantity <= 0 ? Colors.red.shade700 : null,
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

class HistoryTab extends StatelessWidget {
  const HistoryTab({super.key, required this.stream});

  final Stream<List<LedgerEntry>> stream;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<LedgerEntry>>(
      stream: stream,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return _Message(
            icon: Icons.error_outline,
            text: 'Could not load history.\n${snapshot.error}',
          );
        }
        final entries = snapshot.data;
        if (entries == null) {
          return const Center(child: CircularProgressIndicator());
        }
        if (entries.isEmpty) {
          return const _Message(
            icon: Icons.history,
            text: 'Nothing saved yet.',
          );
        }
        return ListView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, _fabClearance),
          children: [
            for (final entry in entries)
              ListTile(
                leading: CircleAvatar(child: Icon(actionIcon(entry.action))),
                title: Text(entry.title),
                subtitle: Text(entry.subtitle),
              ),
          ],
        );
      },
    );
  }
}

class _SummaryCard extends StatelessWidget {
  const _SummaryCard({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      color: theme.colorScheme.primaryContainer,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(label, style: theme.textTheme.titleMedium),
            Text(
              value,
              style: theme.textTheme.titleLarge
                  ?.copyWith(fontWeight: FontWeight.bold),
            ),
          ],
        ),
      ),
    );
  }
}

class _Message extends StatelessWidget {
  const _Message({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 48, color: Theme.of(context).colorScheme.outline),
            const SizedBox(height: 12),
            Text(text, textAlign: TextAlign.center),
          ],
        ),
      ),
    );
  }
}
