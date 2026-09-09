import 'dart:convert';
import 'dart:io';
import 'package:archive/archive_io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:tts_mod_vault/src/state/asset/asset_cache.dart';
import 'package:tts_mod_vault/src/state/asset/asset_identity.dart';
import 'package:tts_mod_vault/src/state/backup/recovery_bundle.dart';
import 'package:tts_mod_vault/src/state/cleanup/cleanup.dart';
import 'package:tts_mod_vault/src/state/delete_assets/delete_assets.dart';
import 'package:tts_mod_vault/src/state/enums/asset_type_enum.dart';
import 'package:tts_mod_vault/src/state/mods/local_links.dart';
import 'package:tts_mod_vault/src/state/mods/mod_model.dart';
import 'package:tts_mod_vault/src/state/mods/mods_isolates.dart';

const hash = '6ABC7F9AA55377FAF59E8C5F05544D5FE1DFDCE8';
const remote =
    'https://steamusercontent-a.akamaihd.net/ugc/10462623203842388677/$hash/';
const old =
    'http://cloud-3.steamusercontent.com/ugc/9558543797575373508/$hash/';
const oldStem = 'httpcloud3steamusercontentcomugc9558543797575373508$hash';

void main() {
  late Directory dir;
  setUp(() async {
    dir = await Directory.systemTemp.createTemp('vault-recovery');
  });
  tearDown(() async {
    await dir.delete(recursive: true);
  });
  Future<String> bundle(String name,
      [String bytes = 'UnityFS\u0000payload']) async {
    final file = File(p.join(dir.path, '$name.unity3d'));
    await file.writeAsString(bytes);
    return file.path;
  }

  test('query cache names resolve but conflicting hash alternatives fail',
      () async {
    const signed = '$remote?download=1';
    final name = signed.replaceAll(RegExp(r'[^a-zA-Z0-9]'), '');
    final exact = await bundle(name);
    var cache = await scanAssetCache(dir.path, AssetTypeEnum.assetBundle);
    expect(
        await resolveVerifiedAssetPath(
            signed, cache, AssetTypeEnum.assetBundle),
        exact);
    expect(
        await processDirectoryInIsolate(DirectoryProcessData(
            directoryPath: dir.path,
            referencedFileNames: {
              assetCacheKey(signed),
              legacyAssetCacheKey(signed)
            },
            assetType: AssetTypeEnum.assetBundle)),
        isEmpty);
    await bundle(oldStem, 'UnityFS\u0000conflict');
    cache = await scanAssetCache(dir.path, AssetTypeEnum.assetBundle);
    await expectLater(
        resolveVerifiedAssetPath(signed, cache, AssetTypeEnum.assetBundle),
        throwsA(isA<FileSystemException>()));
  });

  test('Steam host variants share an identity; unrelated hosts never do', () {
    for (final host in [
      'steamusercontent-a.akamaihd.net',
      'steamuserimages-a.akamaihd.net',
      'cloud-2.steamusercontent.com',
      'cloud-3.steamusercontent.com',
      'images.steamusercontent.com',
      'steamusercontent.com'
    ]) {
      for (final scheme in ['http', 'https']) {
        expect(assetCacheKey('$scheme://$host/ugc/123/$hash/?x=1'),
            assetCacheKey(remote));
      }
    }
    expect(steamContentToken('https://example.com/ugc/123/$hash/'), isNull);
    expect(steamContentToken('prefix$hash.png'), isNull);
    expect(steamContentToken('${oldStem}bad.png'), isNull);
  });

  test(
      'real historical file resolves and identical duplicates are deterministic',
      () async {
    final original = await bundle(oldStem);
    final cache = await scanAssetCache(dir.path, AssetTypeEnum.assetBundle);
    expect(resolveAssetPath(remote, cache), original);
    await bundle(
        'httpssteamusercontentaakamaihdnetugc10462623203842388677$hash');
    final duplicated =
        await scanAssetCache(dir.path, AssetTypeEnum.assetBundle);
    expect(duplicated[assetCacheKey(remote)], isNotEmpty);
    final again = await scanAssetCache(dir.path, AssetTypeEnum.assetBundle);
    expect(duplicated, again);
  });

  test('different bytes with same token are refused, exact local path included',
      () async {
    final original = await bundle(oldStem);
    await bundle(
        'httpssteamusercontentaakamaihdnetugc10462623203842388677$hash',
        'UnityFS\u0000different');
    final cache = await scanAssetCache(dir.path, AssetTypeEnum.assetBundle);
    // The listing reports existence; agreement is settled per URL.
    expect(resolveAssetPath(remote, cache), isNotNull);
    for (final url in [remote, localFileUrl(original)]) {
      await expectLater(
          resolveVerifiedAssetPath(url, cache, AssetTypeEnum.assetBundle),
          throwsA(isA<FileSystemException>().having(
              (e) => e.message, 'message', conflictingCachedBytes)));
    }
  });

  test('an uncontested damaged file is indexed but never resolved as verified',
      () async {
    final broken = await bundle(
        'httpssteamusercontentaakamaihdnetugc10462623203842388677$hash',
        '<html>dead</html>');
    final cache = await scanAssetCache(dir.path, AssetTypeEnum.assetBundle);
    // The scan reads nothing, so a damaged file still counts as present.
    expect(resolveAssetPath(remote, cache), broken);
    await expectLater(
        resolveVerifiedAssetPath(remote, cache, AssetTypeEnum.assetBundle),
        throwsA(isA<FileSystemException>()));
  });

  test('invalid exact bundle cannot hide a valid historical candidate',
      () async {
    final original = await bundle(oldStem);
    await bundle(
        'httpssteamusercontentaakamaihdnetugc10462623203842388677$hash',
        '<html>dead</html>');
    final cache = await scanAssetCache(dir.path, AssetTypeEnum.assetBundle);
    expect(
        await resolveVerifiedAssetPath(
            remote, cache, AssetTypeEnum.assetBundle),
        original);
  });

  test('discovery decodes escaped slashes and preserves multiple type roles',
      () {
    final source = jsonEncode({
      'MeshURL': remote,
      'ImageURL': remote,
      'ContainedObjects': [
        {'PDFUrl': 'file:///cache/book.PDF'}
      ],
      'LuaScript':
          'local object = ${jsonEncode(jsonEncode({'AssetbundleURL': old}))}',
    }).replaceAll('/', r'\/');
    final urls = extractUrlsFromJsonString(source);
    expect(urls[remote]!.split('|'), containsAll(['MeshURL', 'ImageURL']));
    expect(urls[old], 'AssetbundleURL');
    expect(urls['file:///cache/book.PDF'], 'PDFUrl');
    final lists =
        buildAssetListsFromUrls(urls, {}, {}, {}, {}, {}, false, 'test', {});
    expect(lists.$2, 4);
  });

  test(
      'rewrite covers both hosts, nested state and Lua literals without prefix corruption',
      () {
    final path = '${dir.path}/quote" and space.unity3d';
    final source = jsonEncode({
      'AssetbundleURL': remote,
      'AssetbundleSecondaryURL': old,
      'LuaScriptState': jsonEncode({
        'urlReplacements': {old: remote}
      }),
      'LuaScript':
          'local asset = "$remote"\nlocal unrelated = "https://example.com/a.png.more"',
      'ImageURL': 'https://example.com/a.png.more',
    });
    final result = rewriteUrlsToLocalFiles(jsonString: source, urlToFilePath: {
      remote: path,
      'https://example.com/a.png': '/cache/a.png',
    });
    final data = jsonDecode(result.jsonString);
    expect(data['AssetbundleURL'], localFileUrl(path));
    expect(data['AssetbundleSecondaryURL'], localFileUrl(path));
    expect(data['ImageURL'], 'https://example.com/a.png.more');
    expect(jsonDecode(data['LuaScriptState'])['urlReplacements'][old],
        localFileUrl(path));
    expect(data['LuaScript'], contains('[['));
    expect(result.notFoundUrls, ['https://example.com/a.png']);
  });

  test('recovery reports progress once per unique asset, ending at the total',
      () async {
    final source = File('${dir.path}/save.json');
    await bundle(oldStem);
    await source.writeAsString(jsonEncode({
      'AssetbundleURL': remote,
      // The same asset under its other identity must not be counted twice.
      'AssetbundleSecondaryURL': old,
      'ContainedObjects': [
        {'AssetbundleURL': remote}
      ],
    }));
    final seen = <(int, int)>[];
    final assets = await resolveRecoveryAssets(
      await source.readAsString(),
      {AssetTypeEnum.assetBundle: dir.path},
      onProgress: (done, total) => seen.add((done, total)),
    );
    expect(seen, isNotEmpty);
    expect(seen.length, assets.length);
    expect(seen.map((e) => e.$1), List.generate(seen.length, (i) => i + 1));
    expect(seen.every((e) => e.$2 == seen.last.$1), true);
  });

  test('export rejects stale paths and unresolved references without an output',
      () async {
    final source = File('${dir.path}/save.json');
    await source.writeAsString(jsonEncode({'AssetbundleURL': remote}));
    final output = '${dir.path}/local.json';
    await expectLater(
        exportLocalLinksIsolate(ExportLocalLinksParams(
          sourceJsonFilePath: source.path,
          outputJsonFilePath: output,
          urlToFilePath: {remote: '${dir.path}/missing.unity3d'},
        )),
        throwsA(isA<FileSystemException>()));
    expect(File(output).existsSync(), false);
    await expectLater(
        exportLocalLinksIsolate(ExportLocalLinksParams(
          sourceJsonFilePath: source.path,
          outputJsonFilePath: output,
          urlToFilePath: {},
        )),
        throwsFormatException);
    expect(File(output).existsSync(), false);
  });

  test('backup includes local and hidden audio refs and verifies before commit',
      () async {
    final path = await bundle(oldStem);
    final audio = File('${dir.path}/music.mp3');
    await audio.writeAsString('ID3audio');
    final source = File('${dir.path}/save.json');
    await source.writeAsString(jsonEncode({
      'AssetbundleURL': remote,
      'CurrentAudioURL': localFileUrl(audio.path)
    }));
    final target = '${dir.path}/backup.ttsmod';
    await writeRecoveryBundle(
        sourceJsonPath: source.path,
        jsonEntryPath: 'Saves/save.json',
        target: target,
        directories: {AssetTypeEnum.assetBundle: dir.path});
    final archive = ZipDecoder().decodeBytes(await File(target).readAsBytes());
    final inventory = verifyRecoveryArchive(archive)!;
    expect((inventory['assets'] as List).length, 2);
    final originalBackup = await File(target).readAsBytes();
    await File(path).delete();
    await expectLater(
        writeRecoveryBundle(
            sourceJsonPath: source.path,
            jsonEntryPath: 'Saves/save.json',
            target: target,
            directories: {AssetTypeEnum.assetBundle: dir.path}),
        throwsA(isA<FileSystemException>()));
    expect(await File(target).readAsBytes(), originalBackup);
  });

  test('archive damage and unsafe paths fail verification', () async {
    await bundle(oldStem);
    final source = File('${dir.path}/save.json');
    await source.writeAsString(jsonEncode({'AssetbundleURL': remote}));
    final target = '${dir.path}/backup.ttsmod';
    await writeRecoveryBundle(
        sourceJsonPath: source.path,
        jsonEntryPath: 'Saves/save.json',
        target: target,
        directories: {AssetTypeEnum.assetBundle: dir.path});
    final archive = ZipDecoder().decodeBytes(await File(target).readAsBytes());
    final assetName = (verifyRecoveryArchive(archive)!['assets'] as List)
        .first['path'] as String;
    archive.addFile(ArchiveFile.string(assetName, 'damaged'));
    expect(() => verifyRecoveryArchive(archive), throwsFormatException);
    for (final path in [
      '../bad',
      '/bad',
      'Mods/../../bad',
      r'Mods\..\bad',
      'C:/bad'
    ]) {
      expect(() => safeArchivePath(path), throwsFormatException);
    }
  });

  test('restore rebases a full backup after original files disappear',
      () async {
    final original = await bundle(oldStem);
    final audio = File('${dir.path}/local.mp3');
    await audio.writeAsString('ID3audio');
    final source = File('${dir.path}/save.json');
    await source.writeAsString(jsonEncode({
      'AssetbundleURL': remote,
      'CurrentAudioURL': localFileUrl(audio.path),
      'LuaScriptState': jsonEncode({
        'urlReplacements': {'slot': remote}
      })
    }));
    final target = '${dir.path}/backup.ttsmod';
    await writeRecoveryBundle(
        sourceJsonPath: source.path,
        jsonEntryPath: 'Saves/save.json',
        target: target,
        directories: {AssetTypeEnum.assetBundle: dir.path});
    final archive = ZipDecoder().decodeBytes(await File(target).readAsBytes());
    final inventory = verifyRecoveryArchive(archive)!;
    await File(original).delete();
    await audio.delete();
    String destination(String entry) => '${dir.path}/different user/$entry';
    for (final asset in inventory['assets'] as List) {
      final entry = asset['path'] as String;
      final out = File(destination(entry));
      await out.create(recursive: true);
      await out.writeAsBytes(archive.findFile(entry)!.content as List<int>);
    }
    final restored = jsonDecode(await restoreRecoveryJson(
        await source.readAsString(), inventory, destination));
    for (final field in ['AssetbundleURL', 'CurrentAudioURL']) {
      expect(restored[field], contains('/different user/Mods/'));
      expect(File(localPathFromUrl(restored[field])!).existsSync(), true);
    }
    expect(jsonDecode(restored['LuaScriptState'])['urlReplacements']['slot'],
        restored['AssetbundleURL']);
    final firstPath = destination((inventory['assets'] as List).first['path']);
    await File(firstPath).writeAsString('UnityFS\u0000wrong');
    await expectLater(
        restoreRecoveryJson(
            await source.readAsString(), inventory, destination),
        throwsA(isA<FileSystemException>()));
  });

  test('cleanup and sharing protect a historical UGC candidate', () async {
    final path = await bundle(oldStem);
    expect(
        await processDirectoryInIsolate(DirectoryProcessData(
            directoryPath: dir.path,
            referencedFileNames: {assetCacheKey(remote)},
            assetType: AssetTypeEnum.assetBundle)),
        isEmpty);
    final scan = DeleteAssetsNotifier.scanForDeletableAssetsStatic('a', [
      remote
    ], {
      'a': {remote: 'AssetbundleURL'},
      'b': {old: 'AssetbundleURL'},
    }, {
      'a': ModTypeEnum.save,
      'b': ModTypeEnum.save
    });
    expect(scan.filesToDelete, isEmpty);
    expect(scan.sharedFilesToDelete, [remote]);
    expect(File(path).existsSync(), true);
  });
}
