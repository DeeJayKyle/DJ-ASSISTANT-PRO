import 'dart:io';

import 'package:unorm_dart/unorm_dart.dart' as unorm;

/// Whether the file system is treated as case-insensitive (1.x `CASE_INSENSITIVE`).
final bool caseInsensitive = Platform.isWindows || Platform.isMacOS;

/// Identity key for a path: NFC, Windows separators, no trailing separator and,
/// on case-insensitive systems, lower case. Same as 1.x `path_key_with`, so keys
/// stored by 1.x match.
String pathKey(String path, {bool? insensitive}) {
  final ci = insensitive ?? caseInsensitive;
  var s = unorm.nfc(path);
  if (Platform.isWindows || ci) s = s.replaceAll('/', r'\');
  while ((s.endsWith(r'\') || s.endsWith('/')) && s.length > 3) {
    s = s.substring(0, s.length - 1);
  }
  if (ci) s = s.toLowerCase();
  return s;
}

/// True if [child] is the same key as, or inside, [parent].
bool keyIsWithin(String child, String parent) {
  if (child == parent) return true;
  if (!child.startsWith(parent)) return false;
  final rest = child.substring(parent.length);
  return rest.startsWith(r'\') ||
      rest.startsWith('/') ||
      parent.endsWith(r'\') ||
      parent.endsWith('/');
}
