import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Fails when this process still holds a file open inside [dir]. Windows
/// refuses to delete such files (and an open handle can lock a DJ's file), so
/// the check runs on Linux, where /proc shows every open handle.
void expectNoOpenFiles(Directory dir) {
  if (!Platform.isLinux) return;
  final root = dir.resolveSymbolicLinksSync();
  final open = <String>[];
  for (final fd in Directory('/proc/self/fd').listSync(followLinks: false)) {
    try {
      final target = Link(fd.path).targetSync();
      if (target.startsWith(root)) open.add(target);
    } on FileSystemException {
      // closed while listing
    }
  }
  expect(open, isEmpty, reason: 'files still open in ${dir.path}');
}
