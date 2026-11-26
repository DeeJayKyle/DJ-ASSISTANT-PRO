import 'dart:io';

import 'package:dj_assistant/analysis/analysis.dart' show analyseFile;
import 'package:dj_assistant/analysis/beatgrid.dart';
import 'package:dj_assistant/core/analysis_store.dart';
import 'package:dj_assistant/core/catalogue.dart';
import 'package:dj_assistant/core/jobs.dart';
import 'package:dj_assistant/core/roots.dart';
import 'package:dj_assistant/core/scanner.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'scanner_test.dart' show copyLibrary, hashes;

/// Half or double time can't be heard; the genre settles it.
void main() {
  test('genre ranges match whole words', () {
    expect(genreTempoRange('Drum & Bass'), (160.0, 185.0));
    expect(genreTempoRange('Liquid Funk / DnB'), (160.0, 185.0));
    expect(genreTempoRange('Afro House'), (110.0, 135.0));
    expect(genreTempoRange('Hip-Hop'), (65.0, 115.0));
    expect(genreTempoRange('Lighthouse Pop'), isNull);
    expect(genreTempoRange(null), isNull);
    expect(foldBpmForGenre(87, 'Drum & Bass'), 174);
    expect(foldBpmForGenre(174, 'Drum & Bass'), isNull, reason: 'already in');
    expect(foldBpmForGenre(145, 'R&B'), 72.5);
    expect(foldBpmForGenre(64, 'Techno'), 128);
    expect(foldBpmForGenre(100, 'Pop'), isNull, reason: 'no reliable range');
  });

  test('analysis with a genre hint', () {
    const dnb = 'test/fixtures/analysis/dnb174.flac';
    final plain = analyseFile(dnb);
    expect(plain.bpm, 87.0, reason: 'without a genre: half time, as 1.x');
    expect(plain.bpmAlt, 174.0);
    final tagged = analyseFile(dnb, genre: 'Drum & Bass');
    expect(tagged.bpm, 174.0);
    expect(tagged.bpmAlt, 87.0, reason: 'the other reading stays offered');
    final slow = analyseFile(
      'test/fixtures/analysis/slow90_fsmin.flac',
      genre: 'Hip Hop',
    );
    expect(slow.bpm, 90.0);
  });

}
