import 'catalogue.dart';

/// Auto-analyse: after new music is scanned, the Analyse run (see
/// app/analyse_job.dart) works on the new and incomplete tracks by itself:
/// metadata from names, Serato's BPM and key, every online analyser at once
/// with the majority deciding, and the result written into the files.
bool autoPrepEnabled(Catalogue cat) =>
    (cat.getSetting('auto_prep') ?? '1') == '1';
