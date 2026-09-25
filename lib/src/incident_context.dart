/// Reads the recent-history lists the SDK's collectors attach to an
/// incident's context. `route_collector.dart`, `log_collector.dart` and
/// `network_collector.dart` each wrap their list in a Map (`{'history':
/// [...]}` / `{'entries': [...]}` / `{'requests': [...]}`);
/// three call sites each re-guessed that shape and two of them guessed
/// wrong. One reader, one place to fix it next time.
library;

/// Pulls the raw entries out of `incident.context['routes']`,
/// `incident.context['logs']` or `incident.context['network']`.
///
/// Accepts the real collector shape (a Map with the list under `history` or
/// `entries`), a bare List (what synthetic test contexts pass), or neither
/// (returns empty). Entries are returned raw — each caller formats them for
/// its own medium.
List<dynamic> recentEntries(Object? raw) {
  if (raw is Map) {
    final nested = raw['history'] ?? raw['entries'] ?? raw['requests'];
    return nested is List ? nested : const [];
  }
  if (raw is List) return raw;
  return const [];
}

/// One network-collector entry as a single line, shared by the ticket and the
/// prompt so both say the same thing: `GET <url> -> 200 in 312 ms`, or
/// `-> failed: <error>` when the request never got a status. The collector
/// has already redacted the URL and headers on the device.
String renderRequest(Object? entry) {
  if (entry is! Map) return entry.toString();
  final error = entry['error'];
  final outcome =
      error != null ? 'failed: $error' : '${entry['statusCode'] ?? 'no status'}';
  final ms = entry['durationMs'];
  return '${entry['method']} ${entry['url']} -> $outcome'
      '${ms == null ? '' : ' in $ms ms'}';
}
