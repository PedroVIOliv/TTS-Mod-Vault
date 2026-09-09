import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:mime/mime.dart' show lookupMimeType;
import 'package:path/path.dart' as p;

import 'asset_identity.dart';
import '../enums/asset_type_enum.dart';

/// Raised when candidate files for one URL hold different bytes, so no
/// candidate can be chosen without guessing which one the save meant.
const conflictingCachedBytes = 'Conflicting cached bytes';

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

/// Values are every real path a name maps to, in a stable order. The scan
/// reads no file contents: a directory holds thousands of assets, only a
/// handful of which any one operation cares about, so whether two files
/// claiming a name agree byte for byte is settled per URL by
/// [resolveVerifiedAssetPath] instead.
Future<Map<String, List<String>>> scanAssetCache(
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
  for (final paths in groups.values) {
    paths.sort();
  }
  return groups;
}

/// Answers existence, which is all a listing needs. It opens nothing.
String? resolveAssetPath(String url, Map<String, List<String>> cache) {
  final local = localPathFromUrl(url);
  if (local != null && File(local).existsSync()) {
    return File(local).absolute.path;
  }
  final paths = cache[legacyAssetCacheKey(url)] ?? cache[assetCacheKey(url)];
  return paths == null || paths.isEmpty ? null : paths.first;
}

/// A strict operation also compares exact/query-name and hash candidates. The
/// cache filename itself is never used as evidence that their bytes agree.
Future<String> resolveVerifiedAssetPath(
    String url, Map<String, List<String>> cache, AssetTypeEnum type) async {
  final local = localPathFromUrl(url);
  final candidates = <String>{
    if (local != null) File(local).absolute.path,
    ...?cache[legacyAssetCacheKey(url)],
    ...?cache[assetCacheKey(url)],
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
      throw FileSystemException(conflictingCachedBytes, url);
    }
  }
  return valid.first;
}
