import 'dart:convert' show jsonDecode;
import 'dart:io' show Directory, File;

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:tts_mod_vault/src/state/mods/local_links.dart'
    show ExportLocalLinksParams, exportLocalLinksIsolate;

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('local_links_test');
  });

  tearDown(() async {
    await tempDir.delete(recursive: true);
  });

  test('writes a parseable copy and leaves the source untouched', () async {
    const url = 'https://steamusercontent-a.akamaihd.net/ugc/123/ABC/';
    final sourcePath = p.join(tempDir.path, 'TS_Save_12.json');
    final outputPath = p.join(tempDir.path, 'TS_Save_12 Local.json');
    final sourceJson = '{"SaveName":"T","ObjectStates":[{"ImageURL":"$url"}]}';
    await File(sourcePath).writeAsString(sourceJson);

    final cachePath = p.join(tempDir.path, 'My Cache', 'a.png');

    final result = await exportLocalLinksIsolate(
      ExportLocalLinksParams(
        sourceJsonFilePath: sourcePath,
        outputJsonFilePath: outputPath,
        urlToFilePath: {url: cachePath},
      ),
    );

    expect(result.replacedUrls, [url]);
    expect(await File(sourcePath).readAsString(), sourceJson);

    final written = jsonDecode(await File(outputPath).readAsString());
    final writtenUrl = written['ObjectStates'][0]['ImageURL'] as String;

    expect(writtenUrl, startsWith('file://'));
    expect(writtenUrl, contains('My Cache'));
    expect(writtenUrl, isNot(contains('%')));
    expect(writtenUrl, isNot(contains(r'\')));
    expect(writtenUrl, endsWith(cachePath.replaceAll(r'\', '/')));
  });

  test('copies the sibling thumbnail next to the exported JSON', () async {
    final sourcePath = p.join(tempDir.path, 'TS_Save_12.json');
    final outputPath = p.join(tempDir.path, 'TS_Save_12 Local.json');
    final imagePath = p.join(tempDir.path, 'TS_Save_12.png');
    await File(sourcePath).writeAsString('{"SaveName":"T"}');
    await File(imagePath).writeAsBytes([1, 2, 3]);

    await exportLocalLinksIsolate(
      ExportLocalLinksParams(
        sourceJsonFilePath: sourcePath,
        outputJsonFilePath: outputPath,
        sourceImageFilePath: imagePath,
        urlToFilePath: const {},
      ),
    );

    final copied = File(p.join(tempDir.path, 'TS_Save_12 Local.png'));

    expect(copied.existsSync(), isTrue);
    expect(await copied.readAsBytes(), [1, 2, 3]);
  });

  test('exports fine when the mod has no thumbnail', () async {
    final sourcePath = p.join(tempDir.path, 'TS_Save_12.json');
    final outputPath = p.join(tempDir.path, 'TS_Save_12 Local.json');
    await File(sourcePath).writeAsString('{"SaveName":"T"}');

    await exportLocalLinksIsolate(
      ExportLocalLinksParams(
        sourceJsonFilePath: sourcePath,
        outputJsonFilePath: outputPath,
        sourceImageFilePath: null,
        urlToFilePath: const {},
      ),
    );

    expect(File(outputPath).existsSync(), isTrue);
    expect(File(p.join(tempDir.path, 'TS_Save_12 Local.png')).existsSync(),
        isFalse);
  });
}
