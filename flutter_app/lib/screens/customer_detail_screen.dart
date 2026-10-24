import 'package:flutter/material.dart';

import '../format.dart';
import '../models.dart';
import '../services/shop_repository.dart';
import 'tabs.dart';

/// One customer's balance and everything that happened on their khata.
class CustomerDetailScreen extends StatefulWidget {
  const CustomerDetailScreen({
    super.key,
    required this.repository,
    required this.customer,
  });

  final ShopRepository repository;
  final Customer customer;

  @override
  State<CustomerDetailScreen> createState() => _CustomerDetailScreenState();
}

class _CustomerDetailScreenState extends State<CustomerDetailScreen> {
  // Created once so the screen does not re-subscribe on every rebuild.
  late final Stream<List<LedgerEntry>> _history =
      widget.repository.customerHistory(widget.customer.id);
  late final Stream<List<Customer>> _customers = widget.repository.customers();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(widget.customer.name)),
      body: Column(
        children: [
          StreamBuilder<List<Customer>>(
            stream: _customers,
            builder: (context, snapshot) {
              final current = snapshot.data
                      ?.where((c) => c.id == widget.customer.id)
                      .firstOrNull ??
                  widget.customer;
              return Container(
                width: double.infinity,
                color: theme.colorScheme.primaryContainer,
                padding: const EdgeInsets.all(20),
                child: Column(
                  children: [
                    Text(
                      current.balance > 0
                          ? 'Owes you'
                          : current.balance < 0
                              ? 'You owe them'
                              : 'Settled',
                      style: theme.textTheme.titleMedium,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      formatRs(current.balance.abs()),
                      style: theme.textTheme.headlineMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                        color: balanceColor(context, current.balance),
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
          Expanded(
            child: StreamBuilder<List<LedgerEntry>>(
              stream: _history,
              builder: (context, snapshot) {
                if (snapshot.hasError) {
                  return Center(child: Text('Error: ${snapshot.error}'));
                }
                final entries = snapshot.data;
                if (entries == null) {
                  return const Center(child: CircularProgressIndicator());
                }
                if (entries.isEmpty) {
                  return const Center(child: Text('No entries yet.'));
                }
                return ListView(
                  children: [
                    for (final entry in entries)
                      ListTile(
                        leading:
                            CircleAvatar(child: Icon(actionIcon(entry.action))),
                        title: Text(entry.title),
                        subtitle: Text(entry.subtitle),
                      ),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
