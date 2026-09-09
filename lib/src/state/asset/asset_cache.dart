import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:mime/mime.dart' show lookupMimeType;
import 'package:path/path.dart' as p;

import 'asset_identity.dart';
import '../enums/asset_type_enum.dart';

/// Header validation rejects common corrupt downloads; TTS itself remains the
/// authority on complete media/Unity compatibility. Digests protect archives.
Future<void> validateAssetFile(String path, AssetTypeEnum type) async {
  final file = File(path);
  final handle = await file.open();
  try {
    if (await handle.length() == 0) {
      throw FileSystemException('Empty asset', path);
    }
    final bytes = await handle.read(1024);
    final text = latin1.decode(bytes).trimLeft().toLowerCase();
    if (text.startsWith('<!doctype html') ||
        text.startsWith('<html') ||
        text.startsWith('<?xml') && !text.contains('<svg')) {
      throw FileSystemException('Asset is an error document', path);
    }
    if (type == AssetTypeEnum.assetBundle &&
        !['unityfs', 'unityraw', 'unityweb'].any(text.startsWith)) {
      throw FileSystemException('Not a Unity AssetBundle', path);
    }
    final mime = lookupMimeType('', headerBytes: bytes) ?? '';
    if (type == AssetTypeEnum.image &&
        !mime.startsWith('image/') &&
        !text.startsWith('<svg') &&
        !(text.startsWith('<?xml') && text.contains('<svg'))) {
      throw FileSystemException('Unrecognized image header', path);
    }
    if (type == AssetTypeEnum.audio &&
        !mime.startsWith('audio/') &&
        !mime.startsWith('video/') &&
        !text.startsWith('id3') &&
        !text.startsWith('oggs')) {
      throw FileSystemException('Unrecognized audio header', path);
    }
    if (type == AssetTypeEnum.model &&
        (bytes.contains(0) ||
            !RegExp(r'(^|\n)\s*(#|v[nt]? |f |o |g |s |mtllib |usemtl )')
                .hasMatch(text))) {
      throw FileSystemException('Unrecognized OBJ header', path);
    }
    if (type == AssetTypeEnum.pdf && !text.startsWith('%pdf-')) {
      throw FileSystemException('Not a PDF', path);
    }
  } finally {
    await handle.close();
  }
}

Future<String> assetDigest(String path) async =>
    (await sha256.bind(File(path).openRead()).first).toString();

/// Values are real paths. An empty value marks conflicting byte contents,
/// rather than silently choosing whichever directory entry was read last.
///
/// Contents are read only for names that collide, since a name owned by a
/// single file needs no tie-break. Callers that must know an asset is intact
/// validate it themselves; a scan of the whole cache directory cannot afford
/// to open every file.
Future<Map<String, String>> scanAssetCache(
    String directory, AssetTypeEnum type) async {
  final groups = <String, List<String>>{};
  if (directory.isEmpty || !await Directory(directory).exists()) return {};
  await for (final entry in Directory(directory).list(followLinks: false)) {
    if (entry is! File || p.basename(entry.path).endsWith('_temp')) continue;
    final stem = p.basenameWithoutExtension(entry.path);
    for (final key in {assetCacheKey(stem), legacyAssetCacheKey(stem)}) {
      groups.putIfAbsent(key, () => []).add(entry.absolute.path);
    }
  }
  // A file that shares any name with another is validated once and, if
  // damaged, withdrawn from every name it claims. Dropping it only from the
  // contested name would leave it reachable under its uncontested one and let
  // it hide the readable candidate.
  final contested = <String>{
    for (final paths in groups.values.where((g) => g.length > 1)) ...paths
  };
  final damaged = <String>{};
  for (final path in contested) {
    try {
      await validateAssetFile(path, type);
    } on FileSystemException {
      damaged.add(path);
    }
  }
  final result = <String, String>{};
  for (final entry in groups.entries) {
    final paths = entry.value.where((path) => !damaged.contains(path)).toList()
      ..sort();
    if (paths.isEmpty) continue;
    if (paths.length == 1) {
      result[entry.key] = paths.single;
      continue;
    }
    final digests = <String>{};
    for (final path in paths) {
      digests.add(await assetDigest(path));
    }
    result[entry.key] = digests.length == 1 ? paths.first : '';
  }
  return result;
}

String? resolveAssetPath(String url, Map<String, String> cache) {
  final key = assetCacheKey(url);
  // Ambiguity must not be bypassed by an exact path.
  if (cache[key] == '' || cache[legacyAssetCacheKey(url)] == '') return null;
  final local = localPathFromUrl(url);
  if (local != null && File(local).existsSync()) {
    return File(local).absolute.path;
  }
  final path = cache[legacyAssetCacheKey(url)] ?? cache[key];
  return path == null || path.isEmpty ? null : path;
}

/// A strict operation also compares exact/query-name and hash candidates. The
/// cache filename itself is never used as evidence that their bytes agree.
Future<String> resolveVerifiedAssetPath(
    String url, Map<String, String> cache, AssetTypeEnum type) async {
  final key = assetCacheKey(url);
  final legacy = legacyAssetCacheKey(url);
  if (cache[key] == '' || cache[legacy] == '') {
    throw FileSystemException('Conflicting cached bytes', url);
  }
  final local = localPathFromUrl(url);
  final candidates = <String>{
    if (local != null) File(local).absolute.path,
    if (cache[legacy] != null) cache[legacy]!,
    if (cache[key] != null) cache[key]!,
  };
  final valid = <String>[];
  for (final path in candidates) {
    try {
      await validateAssetFile(path, type);
      valid.add(path);
    } on FileSystemException {
      /* A verified alternative can replace bad cache data. */
    }
  }
  if (valid.isEmpty) throw FileSystemException('Missing or invalid asset', url);
  if (valid.length > 1) {
    final digests = <String>{};
    for (final path in valid) {
      digests.add(await assetDigest(path));
    }
    if (digests.length != 1) {
      throw FileSystemException('Conflicting cached bytes', url);
    }
  }
  return valid.first;
}
