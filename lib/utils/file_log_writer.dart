import 'dart:io';

/// Appends log lines to a rotating file under [dir] (#97).
///
/// When writing a line would push the active file (`<baseName>.log`) past
/// [maxBytes], it rotates: `<baseName>.log` -> `.1.log` -> `.2.log` …, keeping
/// at most [maxFiles] files total (oldest dropped). Platform-agnostic: the
/// caller resolves [dir] (e.g. `getApplicationSupportDirectory()`) and only
/// constructs this where a filesystem exists, never on web. Writes are appended
/// and flushed so logs survive a crash.
class FileLogWriter {
  FileLogWriter({
    required this.dir,
    this.baseName = 'offband',
    this.maxBytes = 2 * 1024 * 1024,
    this.maxFiles = 3,
  }) : assert(maxFiles >= 1);

  final Directory dir;
  final String baseName;
  final int maxBytes;
  final int maxFiles;

  File get activeFile => File('${dir.path}/$baseName.log');
  File _rotated(int n) => File('${dir.path}/$baseName.$n.log');

  /// Append [line] (a trailing newline is added), rotating first if it would
  /// push the active file past [maxBytes].
  Future<void> writeLine(String line) async {
    if (!await dir.exists()) await dir.create(recursive: true);
    final active = activeFile;
    final size = await active.exists() ? await active.length() : 0;
    if (size > 0 && size + line.length + 1 > maxBytes) {
      await _rotate();
    }
    await activeFile.writeAsString(
      '$line\n',
      mode: FileMode.append,
      flush: true,
    );
  }

  /// Append a batch of [lines] in one write (single open + flush), rotating
  /// once first if the batch would push the active file past [maxBytes]. Used by
  /// the service's periodic flush so frequent log calls don't each hit the disk.
  Future<void> writeLines(List<String> lines) async {
    if (lines.isEmpty) return;
    if (!await dir.exists()) await dir.create(recursive: true);
    final data = '${lines.join('\n')}\n';
    final active = activeFile;
    final size = await active.exists() ? await active.length() : 0;
    if (size > 0 && size + data.length > maxBytes) {
      await _rotate();
    }
    await activeFile.writeAsString(data, mode: FileMode.append, flush: true);
  }

  /// `<base>.(N-1).log` -> `<base>.N.log` … and active -> `.1.log`; anything
  /// beyond [maxFiles] total is dropped. With [maxFiles] == 1 the active file is
  /// simply restarted (no rotated copies).
  Future<void> _rotate() async {
    if (maxFiles <= 1) {
      if (await activeFile.exists()) await activeFile.delete();
      return;
    }
    final oldest = _rotated(maxFiles - 1);
    if (await oldest.exists()) await oldest.delete();
    for (var n = maxFiles - 2; n >= 1; n--) {
      final f = _rotated(n);
      if (await f.exists()) await f.rename(_rotated(n + 1).path);
    }
    if (await activeFile.exists()) {
      await activeFile.rename(_rotated(1).path);
    }
  }
}
