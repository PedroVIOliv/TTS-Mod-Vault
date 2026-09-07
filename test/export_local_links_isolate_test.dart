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
    expect(writtenUrl, contains('My%20Cache'));
    expect(File.fromUri(Uri.parse(writtenUrl)).path, cachePath);
  });
}
