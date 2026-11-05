// Verifies a downloaded installer against a latest.json manifest with the
// app's update key: dart run tool/verify_update.dart latest.json setup.exe
import 'dart:convert';
import 'dart:io';

import 'package:dj_assistant/core/updater.dart';

Future<void> main(List<String> args) async {
  final m = jsonDecode(File(args[0]).readAsStringSync()) as Map;
  final sig =
      ((m['platforms'] as Map)[updatePlatform] as Map)['signature'] as String;
  final ok = await verifyMinisign(
    File(args[1]).readAsBytesSync(),
    sig,
    parseMinisignKey(updaterPublicKey),
  );
  stdout.writeln(ok ? 'signature OK' : 'signature INVALID');
  exitCode = ok ? 0 : 1;
}
