import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../asset/asset_cache.dart';
import '../asset/asset_document.dart';
import '../asset/asset_identity.dart';
import '../enums/asset_type_enum.dart';
import '../asset/asset_rewrite.dart' show rewriteUrlsToLocalFiles;

const recoveryInventoryPath = 'Vault/Recovery.json';

class RecoveryAsset {
  final AssetReference reference;
  final String path;
  const RecoveryAsset(this.reference, this.path);
}

/// Always reads JSON and disk afresh, including audio and already-local files.
Future<List<RecoveryAsset>> resolveRecoveryAssets(
  String source,
  Map<AssetTypeEnum, String> directories, {
  void Function(int done, int total)? onProgress,
}) async {
  final caches = <AssetTypeEnum, Map<String, List<String>>>{};
  final references = collectAssetReferences(source);
  for (final type in references.map((r) => r.type).toSet()) {
    caches[type] = await scanAssetCache(directories[type] ?? '', type);
  }
  final unique = <String, AssetReference>{};
  for (final reference in references) {
    unique.putIfAbsent('${reference.type.name}:${reference.url}', () => reference);
  }
  final assets = <RecoveryAsset>[];
  final errors = <String>[];
  var done = 0;
  for (final reference in unique.values) {
    final cache = caches[reference.type]!;
    try {
      final path =
          await resolveVerifiedAssetPath(reference.url, cache, reference.type);
      assets.add(RecoveryAsset(reference, path));
    } on FileSystemException catch (e) {
      errors.add(e.toString());
    }
    onProgress?.call(++done, unique.length);
  }
  if (errors.isNotEmpty) {
    throw FileSystemException(
        'Recovery requires every asset:\n${errors.join('\n')}');
  }
  final byUrl = <String, List<RecoveryAsset>>{};
  for (final asset in assets) {
    byUrl.putIfAbsent(asset.reference.url, () => []).add(asset);
  }
  for (final group in byUrl.values.where((g) => g.length > 1)) {
    final digests = <String>{};
    for (final asset in group) {
      digests.add(await assetDigest(asset.path));
    }
    if (digests.length != 1) {
      throw FileSystemException(
          'Conflicting bytes across asset types', group.first.reference.url);
    }
  }
  return assets;
}

/// Replaces only after a completely written and verified sibling file exists.
Future<void> commitFile(String temporary, String target,
    {bool overwrite = true}) async {
  if (!overwrite && await File(target).exists()) {
    throw FileSystemException('Output already exists', target);
  }
  // Windows cannot rename over an existing file. Preserve the previous output
  // until the replacement is committed and restore it if rename fails.
  final previous = '$temporary.previous';
  final hadPrevious = await File(target).exists();
  if (hadPrevious && !overwrite) {
    throw FileSystemException('Output already exists', target);
  }
  if (hadPrevious) await File(target).rename(previous);
  try {
    await File(temporary).rename(target);
  } catch (_) {
    if (hadPrevious) await File(previous).rename(target);
    rethrow;
  }
  if (hadPrevious) await File(previous).delete();
}

Future<int> writeRecoveryBundle({
  required String sourceJsonPath,
  required String jsonEntryPath,
  required String target,
  required Map<AssetTypeEnum, String> directories,
  String? thumbnail,
  void Function(int, int)? onProgress,
}) async {
  final source = await File(sourceJsonPath).readAsString();
  final assets = await resolveRecoveryAssets(source, directories);
  final staging = await Directory(p.dirname(target)).createTemp('.vault-');
  final temporary = p.join(staging.path, 'backup.ttsmod');
  final files = <String, Map<String, dynamic>>{};
  final references = <Map<String, dynamic>>[];
  final encoder = ZipFileEncoder();
  var open = false;
  try {
    encoder.create(temporary);
    open = true;
    Future<void> add(String path, String name) async {
      safeArchivePath(name);
      final digest = await assetDigest(path);
      final length = await File(path).length();
      if (files.containsKey(name)) {
        if (files[name]!['sha256'] != digest) {
          throw FileSystemException('Conflicting archive paths', name);
        }
        return;
      }
      files[name] = {'sha256': digest, 'bytes': length};
      await encoder.addFile(File(path), name);
    }

    // Snapshot the JSON used for discovery, not a concurrently edited source.
    final jsonSnapshot = File(p.join(staging.path, 'save.json'));
    await jsonSnapshot.writeAsString(source);
    await add(jsonSnapshot.path, jsonEntryPath);
    if (thumbnail != null && await File(thumbnail).exists()) {
      await add(thumbnail, p.posix.setExtension(jsonEntryPath, '.png'));
    }
    for (var i = 0; i < assets.length; i++) {
      final asset = assets[i];
      final type = asset.reference.type;
      final folder =
          type == AssetTypeEnum.assetBundle ? 'Assetbundles' : type.label;
      var entry = 'Mods/$folder/${p.basename(asset.path)}';
      // Files from arbitrary local directories can share a basename. Preserve
      // each payload under a digest name when necessary; restore uses inventory.
      if (files.containsKey(entry) &&
          files[entry]!['sha256'] != await assetDigest(asset.path)) {
        entry =
            'Mods/$folder/vault${await assetDigest(asset.path)}${p.extension(asset.path)}';
      }
      await add(asset.path, entry);
      references
          .add({'url': asset.reference.url, 'type': type.name, 'path': entry});
      onProgress?.call(i + 1, assets.length);
    }
    final inventory = File(p.join(staging.path, 'inventory.json'));
    await inventory.writeAsString(jsonEncode({
      'version': 1,
      'json': jsonEntryPath,
      'files': files,
      'assets': references,
    }));
    await encoder.addFile(inventory, recoveryInventoryPath);
    await encoder.close();
    open = false;
    final input = InputFileStream(temporary);
    try {
      final archive = ZipDecoder().decodeStream(input);
      verifyRecoveryArchive(archive);
    } finally {
      await input.close();
    }
    await commitFile(temporary, target);
    return references.map((a) => a['path']).toSet().length;
  } finally {
    if (open) await encoder.close();
    await staging.delete(recursive: true);
  }
}

void safeArchivePath(String name) {
  if (name.contains('\\') ||
      name.contains(':') ||
      p.posix.isAbsolute(name) ||
      name.split('/').any((part) => part == '..' || part.isEmpty)) {
    throw FormatException('Unsafe archive path: $name');
  }
}

/// Runs before restore writes anything. Legacy archives remain readable but
/// cannot claim inventory verification.
Map<String, dynamic>? verifyRecoveryArchive(Archive archive) {
  final names = <String>{};
  for (final file in archive) {
    if (!file.isFile) continue;
    safeArchivePath(file.name);
    if (!names.add(file.name)) {
      throw FormatException('Duplicate archive entry: ${file.name}');
    }
  }
  final manifest = archive.findFile(recoveryInventoryPath);
  if (manifest == null) return null;
  final inventory = jsonDecode(utf8.decode(manifest.content as List<int>))
      as Map<String, dynamic>;
  if (inventory['version'] != 1) {
    throw const FormatException('Unsupported recovery inventory');
  }
  final files = inventory['files'] as Map<String, dynamic>;
  if (files.length != names.length - 1) {
    throw const FormatException('Incomplete recovery inventory');
  }
  for (final entry in files.entries) {
    final file = archive.findFile(entry.key);
    if (file == null || !file.isFile) {
      throw FormatException('Missing backup file: ${entry.key}');
    }
    final bytes = file.content as List<int>;
    if (bytes.length != entry.value['bytes'] ||
        sha256.convert(bytes).toString() != entry.value['sha256']) {
      throw FormatException('Backup checksum mismatch: ${entry.key}');
    }
  }
  final jsonFile = archive.findFile(inventory['json'] as String);
  if (jsonFile == null) throw const FormatException('Missing recovery save');
  final expected =
      collectAssetReferences(utf8.decode(jsonFile.content as List<int>))
          .map((r) => '${r.type.name}:${r.url}')
          .toSet();
  final recorded = <String>{};
  for (final asset in inventory['assets'] as List) {
    if (!files.containsKey(asset['path'])) {
      throw const FormatException('Missing inventory asset');
    }
    final key = '${asset['type']}:${asset['url']}';
    if (!recorded.add(key)) {
      throw FormatException('Duplicate inventory reference: $key');
    }
  }
  if (expected.length != recorded.length || !expected.containsAll(recorded)) {
    throw const FormatException('Recovery inventory does not cover the save');
  }
  return inventory;
}

/// Rebase a verified archive's save only after every payload was restored.
Future<String> restoreRecoveryJson(
    String source,
    Map<String, dynamic> inventory,
    String Function(String) destinationFor) async {
  final paths = <String, String>{};
  final verified = <String>{};
  final files = inventory['files'] as Map<String, dynamic>;
  for (final asset in inventory['assets'] as List) {
    final entry = asset['path'] as String;
    final path = destinationFor(entry);
    final type = AssetTypeEnum.values.byName(asset['type'] as String);
    await validateAssetFile(path, type);
    if (verified.add(path)) {
      if (await File(path).length() != files[entry]['bytes'] ||
          await assetDigest(path) != files[entry]['sha256']) {
        throw FileSystemException('Restored asset checksum mismatch', path);
      }
    }
    final url = asset['url'] as String;
    final previous = paths[url];
    if (previous != null &&
        await assetDigest(previous) != await assetDigest(path)) {
      throw FileSystemException('Conflicting restored asset types', url);
    }
    paths[url] = path;
  }
  final result =
      rewriteUrlsToLocalFiles(jsonString: source, urlToFilePath: paths);
  if (result.notFoundUrls.isNotEmpty ||
      collectAssetReferences(result.jsonString)
          .any((r) => localPathFromUrl(r.url) == null)) {
    throw const FormatException('Backup has unresolved asset references');
  }
  return result.jsonString;
}
