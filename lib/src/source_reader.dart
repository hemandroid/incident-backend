/// Maps a symbolicated stack frame back to the source it came from, so a
/// ticket can show the lines that broke rather than only describing them.
///
/// Entirely optional: with no source root configured — or one that does not
/// hold the file a frame names — every lookup returns null and the pipeline
/// behaves exactly as it did before.
library;

import 'dart:io';

/// A seam so tests exercise frame matching without a real checkout on disk.
abstract class SourceFileSystem {
  /// Lines of the file at [path], or null if it is missing or unreadable.
  List<String>? readLines(String path);
}

class _IoSourceFileSystem implements SourceFileSystem {
  const _IoSourceFileSystem();

  @override
  List<String>? readLines(String path) {
    try {
      return File(path).readAsLinesSync();
    } catch (_) {
      return null;
    }
  }
}

/// A numbered window of source around a crash site.
class SourceExcerpt {
  const SourceExcerpt({
    required this.path,
    required this.line,
    required this.numberedLines,
  });

  /// Relative to the source root: an absolute path would put the build
  /// machine's home directory into a Jira ticket.
  final String path;

  final int line;

  /// One `  12 | <code>` per line, so the model and the reader can both point
  /// at a specific line without counting.
  final String numberedLines;
}

/// Frame shape: `#1  Some.method (/abs/path/file.dart:234:34)`. The column is
/// optional — not every frame carries one — and the path may contain spaces,
/// so only parentheses delimit it.
final RegExp _frame = RegExp(r'\(([^()]+\.dart):(\d+)(?::\d+)?\)');

class SourceReader {
  SourceReader(
    String? sourceDir, {
    SourceFileSystem? fileSystem,
    int radius = 12,
  })  : _root = _canonicalRoot(sourceDir),
        _fs = fileSystem ?? const _IoSourceFileSystem(),
        _radius = radius;

  /// Null when no usable source root is configured. Always ends in `/` so the
  /// containment check below cannot let `/srcevil` pass for `/src`.
  final String? _root;

  final SourceFileSystem _fs;
  final int _radius;

  /// [_radius] bounds the window in LINES; a generated or minified file can
  /// still pack thousands of characters into one of them. This bounds the
  /// rendered window's total size, following the same convention as
  /// GroqAnalyzer's `_maxStackTraceChars`/`_maxCodeChars`.
  static const int _maxWindowChars = 3000;

  /// The first frame resolving to a readable file inside the source root, or
  /// null. Deliberately not the top frame: that is usually framework or SDK
  /// code, and a ticket quoting Flutter's own source helps nobody.
  ///
  /// Assumes the frames' absolute paths and the source root describe the same
  /// checkout; a backend running somewhere else than the build simply finds
  /// nothing and degrades to prose.
  SourceExcerpt? excerptFor(String symbolicatedTrace) {
    final root = _root;
    if (root == null) return null;
    try {
      for (final match in _frame.allMatches(symbolicatedTrace)) {
        final resolved = _resolveInside(root, match.group(1)!);
        if (resolved == null) continue;
        final lines = _fs.readLines(resolved);
        if (lines == null || lines.isEmpty) continue;
        // tryParse, not parse: a frame carrying a number too large for an int
        // would otherwise abort the loop and hide the real frame behind it.
        final line = int.tryParse(match.group(2)!);
        if (line == null || line < 1 || line > lines.length) continue;
        return SourceExcerpt(
          path: resolved.substring(root.length),
          line: line,
          numberedLines: _window(lines, line),
        );
      }
    } catch (_) {
      // Source is a nicety; a ticket without it still beats no ticket.
    }
    return null;
  }

  /// A stack frame is attacker-influenced — anyone holding the ingest token
  /// chooses these strings. Containment is checked on the normalised form, so
  /// `../../../etc/passwd` resolves back out of the root and is refused; a
  /// substring test on the raw text would not catch it.
  ///
  /// Relative candidates are refused outright rather than joined onto the
  /// root. Symbolicated application frames are always absolute, while SDK
  /// frames are relative (`third_party/dart/sdk/...`) — joining those onto a
  /// repo that vendors the SDK would make containment pass and quote
  /// `ListBase.singleWhere` instead of the app's own code.
  static String? _resolveInside(String root, String candidate) {
    if (!candidate.startsWith('/')) return null;
    final normalized = _normalize(candidate);
    return normalized != null && normalized.startsWith(root) ? normalized : null;
  }

  static String? _normalize(String raw) {
    try {
      // Directory.current is read here, inside the catch: an unlinked working
      // directory throws, and this runs in a constructor before the server
      // binds its listener.
      final absolute = raw.startsWith('/') ? raw : '${Directory.current.path}/$raw';
      return Uri.file(absolute).normalizePath().toFilePath();
    } catch (_) {
      return null;
    }
  }

  static String? _canonicalRoot(String? dir) {
    final trimmed = dir?.trim();
    if (trimmed == null || trimmed.isEmpty) return null;
    final normalized = _normalize(trimmed);
    if (normalized == null) return null;
    return normalized.endsWith('/') ? normalized : '$normalized/';
  }

  String _window(List<String> lines, int line) {
    final start = line - _radius < 1 ? 1 : line - _radius;
    final end =
        line + _radius > lines.length ? lines.length : line + _radius;
    final width = end.toString().length;
    final buffer = StringBuffer();
    for (var i = start; i <= end; i++) {
      buffer.writeln('${i.toString().padLeft(width)} | ${lines[i - 1]}');
    }
    final text = buffer.toString().trimRight();
    return text.length <= _maxWindowChars
        ? text
        : '${text.substring(0, _maxWindowChars)}\n...(truncated)';
  }
}
