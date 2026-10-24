/// Lower-cases, strips punctuation and collapses spaces. Keeps Latin letters,
/// digits and the Arabic/Urdu block so both scripts survive.
String normalizeName(String input) {
  return input
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9؀-ۿ ]'), '')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
}

/// Classic edit distance (insert, delete, substitute) using two rows.
int levenshtein(String a, String b) {
  if (a == b) return 0;
  if (a.isEmpty) return b.length;
  if (b.isEmpty) return a.length;

  var previous = List<int>.generate(b.length + 1, (i) => i);
  var current = List<int>.filled(b.length + 1, 0);

  for (var i = 1; i <= a.length; i++) {
    current[0] = i;
    for (var j = 1; j <= b.length; j++) {
      final cost = a.codeUnitAt(i - 1) == b.codeUnitAt(j - 1) ? 0 : 1;
      var best = current[j - 1] + 1;
      if (previous[j] + 1 < best) best = previous[j] + 1;
      if (previous[j - 1] + cost < best) best = previous[j - 1] + cost;
      current[j] = best;
    }
    final swap = previous;
    previous = current;
    current = swap;
  }
  return previous[b.length];
}

/// Finds the candidate whose name is closest to [query].
///
/// An exact (normalised) match always wins. Otherwise the closest candidate is
/// returned only if its edit distance is at most [maxRatio] of the longer
/// name, so "Ahmed" matches "Ahmad" but "Ali" does not match "Ahmad".
T? bestMatch<T>(
  String query,
  Iterable<T> candidates,
  String Function(T) nameOf, {
  double maxRatio = 0.34,
}) {
  final wanted = normalizeName(query);
  if (wanted.isEmpty) return null;

  T? best;
  var bestDistance = 1 << 30;
  for (final candidate in candidates) {
    final name = normalizeName(nameOf(candidate));
    if (name == wanted) return candidate;
    final distance = levenshtein(wanted, name);
    final longest = wanted.length > name.length ? wanted.length : name.length;
    if (longest == 0) continue;
    if (distance / longest <= maxRatio && distance < bestDistance) {
      best = candidate;
      bestDistance = distance;
    }
  }
  return best;
}
