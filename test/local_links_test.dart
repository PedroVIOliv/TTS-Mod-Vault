import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:tts_mod_vault/src/state/mods/local_links.dart'
    show localFileUrl, localLinksOutputPath, rewriteUrlsToLocalFiles;

void main() {
  group('localFileUrl', () {
    test('leaves spaces literal in a macOS cache path', () {
      expect(
        localFileUrl(
          '/Users/me/Library/Tabletop Simulator/Mods/Images/httpsexample.png',
          windows: false,
        ),
        'file:///Users/me/Library/Tabletop Simulator/Mods/Images/httpsexample.png',
      );
    });

    // Unity's AssetBundle.LoadFromFile passes the path to Windows verbatim, so
    // a percent-encoded space makes it look for a directory named "My%20Games".
    test('converts Windows backslashes without percent-encoding spaces', () {
      expect(
        localFileUrl(
          r'C:\Users\me\Documents\My Games\Tabletop Simulator\Mods\Images\a.png',
          windows: true,
        ),
        'file:///C:/Users/me/Documents/My Games/Tabletop Simulator/Mods/Images/a.png',
      );
    });
  });

  group('rewriteUrlsToLocalFiles', () {
    test('replaces an asset URL with its local file URL', () {
      const url = 'https://steamusercontent-a.akamaihd.net/ugc/123/ABC/';
      final json = '{"ImageURL": "$url"}';

      final result = rewriteUrlsToLocalFiles(
        jsonString: json,
        urlToFilePath: {url: '/cache/Images/httpsugc123ABC.png'},
        windows: false,
      );

      expect(
        result.jsonString,
        '{"ImageURL": "file:///cache/Images/httpsugc123ABC.png"}',
      );
      expect(result.replacedUrls, [url]);
      expect(result.notFoundUrls, isEmpty);
    });

    test('reports URLs that appear in no form in the JSON', () {
      const url = 'https://steamusercontent-a.akamaihd.net/ugc/999/ZZZ/';

      final result = rewriteUrlsToLocalFiles(
        jsonString: '{"ImageURL": "https://example.com/other.png"}',
        urlToFilePath: {url: '/cache/Images/z.png'},
        windows: false,
      );

      expect(result.jsonString, '{"ImageURL": "https://example.com/other.png"}');
      expect(result.replacedUrls, isEmpty);
      expect(result.notFoundUrls, [url]);
    });

    test('matches the old cloud-3 URL still stored in the JSON', () {
      const normalizedUrl =
          'https://steamusercontent-a.akamaihd.net/ugc/123/ABC/';
      const json =
          '{"ImageURL": "http://cloud-3.steamusercontent.com/ugc/123/ABC/"}';

      final result = rewriteUrlsToLocalFiles(
        jsonString: json,
        urlToFilePath: {normalizedUrl: '/cache/Images/a.png'},
        windows: false,
      );

      expect(result.jsonString, '{"ImageURL": "file:///cache/Images/a.png"}');
      expect(result.replacedUrls, [normalizedUrl]);
      expect(result.notFoundUrls, isEmpty);
    });
  });

  group('localLinksOutputPath', () {
    test('suffixes the file name with Local, keeping the directory', () {
      // Built with p.join so the expectation holds under either separator.
      final output = localLinksOutputPath(p.join('Users', 'me', 'Saves',
          'TS_Save_12.json'));

      expect(p.dirname(output), p.join('Users', 'me', 'Saves'));
      expect(p.basename(output), 'TS_Save_12 Local.json');
    });
  });
}
