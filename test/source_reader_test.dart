import 'package:incident_backend/src/source_reader.dart';
import 'package:test/test.dart';

/// In-memory checkout. Records every path it was asked for, so a test can
/// assert a rejected path was never even read.
class _FakeSourceFileSystem implements SourceFileSystem {
  _FakeSourceFileSystem(this.files);

  final Map<String, List<String>> files;
  final List<String> requested = [];

  @override
  List<String>? readLines(String path) {
    requested.add(path);
    return files[path];
  }
}

List<String> _numberedFile(int count) =>
    [for (var i = 1; i <= count; i++) 'line $i'];

/// The top two frames are stdlib and framework code, as they are in a real
/// symbolicated Flutter trace; only the third is the app's own.
const _trace = '''
#0      ListBase.singleWhere (third_party/dart/sdk/lib/collection/list.dart:156:11)
#1      _InkResponseState.handleTap (/opt/flutter/packages/flutter/lib/src/material/ink_well.dart:1224:21)
#2      _OrdersScreenState.build.<anonymous closure> (/repo/lib/store/screens.dart:234:34)
''';

void main() {
  group('SourceReader.excerptFor', () {
    test('picks the first frame inside the source root, not the top frame', () {
      final fs = _FakeSourceFileSystem({
        '/opt/flutter/packages/flutter/lib/src/material/ink_well.dart':
            _numberedFile(2000),
        '/repo/lib/store/screens.dart': _numberedFile(300),
      });

      final excerpt =
          SourceReader('/repo', fileSystem: fs).excerptFor(_trace);

      expect(excerpt, isNotNull);
      expect(excerpt!.path, 'lib/store/screens.dart');
      expect(excerpt.line, 234);
      expect(excerpt.numberedLines, contains('234 | line 234'));
      expect(excerpt.numberedLines, contains('222 | line 222'));
      expect(excerpt.numberedLines, contains('246 | line 246'));
      expect(excerpt.numberedLines, isNot(contains('line 221')));
      expect(excerpt.numberedLines, isNot(contains('line 247')));
      expect(
        fs.requested,
        isNot(contains(
            '/opt/flutter/packages/flutter/lib/src/material/ink_well.dart')),
        reason: 'a frame outside the root is refused before it is read',
      );
    });

    test('a frame escaping the source root is refused and never read', () {
      final fs = _FakeSourceFileSystem({
        '/etc/passwd.dart': ['root:x:0:0'],
      });

      final excerpt = SourceReader('/repo', fileSystem: fs)
          .excerptFor('#0      x (/repo/../../../etc/passwd.dart:1:1)');

      expect(excerpt, isNull);
      expect(fs.requested, isEmpty);
    });

    test('a relative frame is refused even when that file exists under the root',
        () {
      // A repo vendoring the Dart SDK really does hold this path; joining a
      // relative frame onto the root would quote list.dart in every ticket.
      final fs = _FakeSourceFileSystem({
        '/repo/third_party/dart/sdk/lib/collection/list.dart': _numberedFile(300),
        '/repo/lib/store/screens.dart': _numberedFile(300),
      });

      final excerpt = SourceReader('/repo', fileSystem: fs).excerptFor(_trace);

      expect(excerpt!.path, 'lib/store/screens.dart');
      expect(
        fs.requested,
        isNot(contains('/repo/third_party/dart/sdk/lib/collection/list.dart')),
      );
    });

    test('a nonsensical line number skips that frame instead of the whole trace',
        () {
      final fs = _FakeSourceFileSystem({
        '/repo/lib/a.dart': _numberedFile(10),
        '/repo/lib/store/screens.dart': _numberedFile(300),
      });

      final excerpt = SourceReader('/repo', fileSystem: fs).excerptFor(
        '#0 x (/repo/lib/a.dart:99999999999999999999:1)\n$_trace',
      );

      expect(excerpt!.path, 'lib/store/screens.dart');
    });

    test('a window of very long lines is clamped by character count, not just line count',
        () {
      // _radius bounds the window in LINES; a minified/generated file can
      // still pack thousands of characters into a handful of them.
      final longLines = [for (var i = 1; i <= 30; i++) 'x' * 500];
      final fs = _FakeSourceFileSystem({'/repo/lib/generated.dart': longLines});

      final excerpt =
          SourceReader('/repo', fileSystem: fs).excerptFor('#0 x (/repo/lib/generated.dart:15:1)');

      expect(excerpt, isNotNull);
      expect(excerpt!.numberedLines.length, lessThan(3100));
      expect(excerpt.numberedLines, endsWith('...(truncated)'));
    });

    test('an unset, empty or unreadable source root degrades to null', () {
      final fs = _FakeSourceFileSystem({'/repo/lib/store/screens.dart': _numberedFile(300)});

      expect(SourceReader(null, fileSystem: fs).excerptFor(_trace), isNull);
      expect(SourceReader('  ', fileSystem: fs).excerptFor(_trace), isNull);
      expect(
        SourceReader('/nowhere', fileSystem: fs).excerptFor(_trace),
        isNull,
        reason: 'a root that holds none of the frames finds nothing',
      );
      expect(
        fs.requested,
        isNot(contains('/repo/lib/store/screens.dart')),
        reason: 'no configured root means the app file is never opened',
      );
    });

    test('a window at the file edges stays in bounds', () {
      final fs = _FakeSourceFileSystem({'/repo/lib/tiny.dart': _numberedFile(5)});
      final reader = SourceReader('/repo', fileSystem: fs);

      final atStart = reader.excerptFor('#0 x (/repo/lib/tiny.dart:1:1)');
      expect(atStart!.numberedLines.split('\n'), hasLength(5));
      expect(atStart.numberedLines, startsWith('1 | line 1'));

      final atEnd = reader.excerptFor('#0 x (/repo/lib/tiny.dart:5:1)');
      expect(atEnd!.numberedLines.split('\n'), hasLength(5));
      expect(atEnd.numberedLines, endsWith('5 | line 5'));

      expect(
        reader.excerptFor('#0 x (/repo/lib/tiny.dart:900:1)'),
        isNull,
        reason: 'a line past the end of the file is not a crash site we can show',
      );
    });
  });
}
