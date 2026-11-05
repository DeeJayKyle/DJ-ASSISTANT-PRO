import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:http/http.dart' as http;

/// App updates (1.x: the Tauri updater). Same manifest (`latest.json` on the
/// GitHub release), same minisign signing key, checked only while the "App
/// updates" service is on. Sends nothing but the request for the manifest.
const updaterPublicKey =
    'dW50cnVzdGVkIGNvbW1lbnQ6IG1pbmlzaWduIHB1YmxpYyBrZXk6IDI3Qjc4RDg3ODk1Q0REMjMKUldRajNWeUpoNDIzSnlBNW5HZHRqa05jUlN5QWU3R2ZlUFY0MEFYYlg4OTA1bzl0Y2Z4MGFVOTAK';
const updateEndpoints = [
  'https://github.com/DeeJayKyle/DJ-ASSISTANT-PRO/releases/latest/download/latest.json',
  'https://github.com/DeeJayKyle/dj-assistant-releases/releases/latest/download/latest.json',
];
const updatePlatform = 'windows-x86_64';

class UpdateException implements Exception {
  UpdateException(this.message);
  final String message;
  @override
  String toString() => message;
}

class MinisignKey {
  MinisignKey(this.keyId, this.publicKey);
  final Uint8List keyId, publicKey;
}

/// The base64 line of a minisign file (the line after "untrusted comment:").
List<String> _lines(String text) => const LineSplitter()
    .convert(text)
    .map((l) => l.trim())
    .where((l) => l.isNotEmpty)
    .toList();

String _maybeBase64Text(String s) {
  final t = s.trim();
  if (t.startsWith('untrusted comment:')) return t;
  try {
    return utf8.decode(base64.decode(t));
  } on FormatException {
    return t;
  }
}

/// A minisign public key, given as the file text or base64 of it (Tauri's form).
MinisignKey parseMinisignKey(String text) {
  final l = _lines(_maybeBase64Text(text));
  final b = base64.decode(
    l.firstWhere((x) => !x.startsWith('untrusted comment:')),
  );
  if (b.length != 42 || b[0] != 0x45 || b[1] != 0x64) {
    throw UpdateException('not a minisign Ed25519 public key');
  }
  return MinisignKey(b.sublist(2, 10), b.sublist(10));
}

/// Verifies a minisign signature (the .sig text or base64 of it) over [data].
/// Accepts plain ("Ed") and BLAKE2b-prehashed ("ED") signatures, and checks
/// the trusted-comment signature as minisign does.
Future<bool> verifyMinisign(
  Uint8List data,
  String signature,
  MinisignKey key,
) async {
  final l = _lines(_maybeBase64Text(signature));
  if (l.length < 4 || !l[0].startsWith('untrusted comment:')) return false;
  final sig = base64.decode(l[1]);
  if (sig.length != 74) return false;
  final alg = String.fromCharCodes(sig.sublist(0, 2));
  if (alg != 'Ed' && alg != 'ED') return false;
  for (var i = 0; i < 8; i++) {
    if (sig[2 + i] != key.keyId[i]) return false;
  }
  const prefix = 'trusted comment: ';
  if (!l[2].startsWith(prefix)) return false;
  final trusted = utf8.encode(l[2].substring(prefix.length));
  final global = base64.decode(l[3]);
  final ed = Ed25519();
  final pub = SimplePublicKey(key.publicKey, type: KeyPairType.ed25519);
  final message = alg == 'ED' ? (await Blake2b().hash(data)).bytes : data;
  final ok = await ed.verify(
    message,
    signature: Signature(sig.sublist(10), publicKey: pub),
  );
  if (!ok) return false;
  return ed.verify([
    ...sig.sublist(10),
    ...trusted,
  ], signature: Signature(global, publicKey: pub));
}

/// Is [a] a newer version than [b]? ("2.0.1" > "2.0.0"; pre-releases are older.)
bool isNewer(String a, String b) {
  List<int> parts(String v) {
    final core = v
        .trim()
        .replaceFirst(RegExp('^v'), '')
        .split(RegExp('[-+]'))
        .first;
    return [for (final x in core.split('.')) int.tryParse(x) ?? 0];
  }

  final x = parts(a), y = parts(b);
  for (var i = 0; i < 3; i++) {
    final d = (i < x.length ? x[i] : 0) - (i < y.length ? y[i] : 0);
    if (d != 0) return d > 0;
  }
  final pa = a.contains('-'), pb = b.contains('-');
  return pb && !pa;
}

class UpdateInfo {
  UpdateInfo(this.version, this.notes, this.url, this.signature);
  final String version, notes, url, signature;
  Map<String, Object?> toJson() => {
    'version': version,
    'notes': notes,
    'url': url,
  };
}

/// Reads the release manifest; returns the update when it is newer.
Future<UpdateInfo?> checkForUpdate(
  http.Client client,
  String current, {
  List<String> endpoints = updateEndpoints,
}) async {
  Object? lastError;
  for (final e in endpoints) {
    try {
      final r = await client
          .get(Uri.parse(e))
          .timeout(const Duration(seconds: 20));
      if (r.statusCode != 200) {
        lastError = 'HTTP ${r.statusCode}';
        continue;
      }
      final m = jsonDecode(utf8.decode(r.bodyBytes)) as Map;
      final v = m['version'] as String;
      final p = (m['platforms'] as Map?)?[updatePlatform] as Map?;
      if (p == null) return null;
      if (!isNewer(v, current)) return null;
      return UpdateInfo(
        v,
        m['notes'] as String? ?? '',
        p['url'] as String,
        p['signature'] as String,
      );
    } on Exception catch (err) {
      lastError = err;
    }
  }
  throw UpdateException("couldn't check for updates ($lastError)");
}

/// Downloads the installer to [dest] and keeps it only if its signature is
/// valid for the app's key. Returns the installer path.
Future<String> downloadUpdate(
  http.Client client,
  UpdateInfo u,
  String dest, {
  String publicKey = updaterPublicKey,
}) async {
  final r = await client
      .get(Uri.parse(u.url))
      .timeout(const Duration(minutes: 10));
  if (r.statusCode != 200) {
    throw UpdateException('download failed (HTTP ${r.statusCode})');
  }
  if (!await verifyMinisign(
    r.bodyBytes,
    u.signature,
    parseMinisignKey(publicKey),
  )) {
    throw UpdateException(
      "the downloaded update isn't signed by DJ Assistant; it was not installed",
    );
  }
  File(dest).writeAsBytesSync(r.bodyBytes, flush: true);
  return dest;
}
