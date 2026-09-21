/// Reads the recent-history lists the SDK's collectors attach to an
/// incident's context. `route_collector.dart` and `log_collector.dart` both
/// wrap their list in a Map (`{'history': [...]}` / `{'entries': [...]}`);
/// three call sites each re-guessed that shape and two of them guessed
/// wrong. One reader, one place to fix it next time.
library;

/// Pulls the raw entries out of `incident.context['routes']` or
/// `incident.context['logs']`.
///
/// Accepts the real collector shape (a Map with the list under `history` or
/// `entries`), a bare List (what synthetic test contexts pass), or neither
/// (returns empty). Entries are returned raw — each caller formats them for
/// its own medium.
List<dynamic> recentEntries(Object? raw) {
  if (raw is Map) {
    final nested = raw['history'] ?? raw['entries'];
    return nested is List ? nested : const [];
  }
  if (raw is List) return raw;
  return const [];
}
