import 'package:unorm_dart/unorm_dart.dart' as unorm;

/// Accent- and case-insensitive form used for search and matching, identical to
/// 1.x `text::fold`: Unicode NFD, combining marks removed, lower-cased.
/// `fold("Beyoncé") == "beyonce"`.
String fold(String s) {
  final d = unorm.nfd(s);
  final out = StringBuffer();
  for (final r in d.runes) {
    if (_isCombiningMark(r)) continue;
    out.write(String.fromCharCode(r).toLowerCase());
  }
  return out.toString();
}

bool _isCombiningMark(int r) =>
    (r >= 0x0300 && r <= 0x036F) ||
    (r >= 0x1AB0 && r <= 0x1AFF) ||
    (r >= 0x1DC0 && r <= 0x1DFF) ||
    (r >= 0x20D0 && r <= 0x20FF) ||
    (r >= 0xFE20 && r <= 0xFE2F);
