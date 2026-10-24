import 'package:intl/intl.dart';

final NumberFormat _number = NumberFormat('#,##0.##');

/// "Rs 1,500"
String formatRs(double value) => 'Rs ${_number.format(value)}';

/// "1,500" or "2.5"
String formatNum(double value) => _number.format(value);

/// "2 kg", "10", or "" when there is no quantity.
String formatQty(double? quantity, String? unit) {
  if (quantity == null) return '';
  final unitPart = (unit == null || unit.isEmpty) ? '' : ' $unit';
  return '${formatNum(quantity)}$unitPart';
}

String formatWhen(DateTime? when) {
  if (when == null) return 'just now';
  return DateFormat('d MMM, h:mm a').format(when);
}

/// "ahmad ali" -> "Ahmad Ali"
String titleCase(String input) {
  return input
      .trim()
      .split(RegExp(r'\s+'))
      .where((w) => w.isNotEmpty)
      .map((w) => w[0].toUpperCase() + w.substring(1).toLowerCase())
      .join(' ');
}
