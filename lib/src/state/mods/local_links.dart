import 'dart:io' show File, Platform;

import 'package:path/path.dart' as p;
import 'package:tts_mod_vault/src/state/asset/models/asset_model.dart'
    show Asset;
import 'package:tts_mod_vault/src/utils.dart'
    show newSteamUserContentUrl, oldCloudUrl;

/// Builds the `file://` URL TTS stores for a cached asset.
///
/// The path is NOT percent-encoded: Unity hands it to the OS verbatim, so an
/// encoded space makes it look for a directory literally named "My%20Games".
/// Separators still have to be forward slashes, or the backslashes would need
/// escaping inside the JSON.
String localFileUrl(String filePath, {bool? windows}) {
  final isWindows = windows ?? Platform.isWindows;
  final slashed = filePath.replaceAll(r'\', '/');

  return isWindows ? 'file:///$slashed' : 'file://$slashed';
}

String localLinksOutputPath(String jsonFilePath) {
  final directory = p.dirname(jsonFilePath);
  final name = p.basenameWithoutExtension(jsonFilePath);
  final extension = p.extension(jsonFilePath);

  return p.join(directory, '$name Local$extension');
}

class LocalLinksRewriteResult {
  final String jsonString;
  final List<String> replacedUrls;
  final List<String> notFoundUrls;

  const LocalLinksRewriteResult({
    required this.jsonString,
    required this.replacedUrls,
    required this.notFoundUrls,
  });
}

LocalLinksRewriteResult rewriteUrlsToLocalFiles({
  required String jsonString,
  required Map<String, String> urlToFilePath,
  bool? windows,
}) {
  var output = jsonString;
  final replaced = <String>[];
  final notFound = <String>[];

  for (final entry in urlToFilePath.entries) {
    final target = _urlAsStoredIn(output, entry.key);

    if (target == null) {
      notFound.add(entry.key);
      continue;
    }

    output = output.replaceAll(
      target,
      localFileUrl(entry.value, windows: windows),
    );
    replaced.add(entry.key);
  }

  return LocalLinksRewriteResult(
    jsonString: output,
    replacedUrls: replaced,
    notFoundUrls: notFound,
  );
}

// Asset URLs are normalized to the akamaihd host, while the JSON on disk may
// still hold the cloud-3 form of the same asset.
String? _urlAsStoredIn(String jsonString, String url) {
  if (jsonString.contains(url)) return url;

  if (url.startsWith(newSteamUserContentUrl)) {
    final cloudUrl = url.replaceFirst(newSteamUserContentUrl, oldCloudUrl);
    if (jsonString.contains(cloudUrl)) return cloudUrl;
  }

  return null;
}

class ExportLocalLinksParams {
  final String sourceJsonFilePath;
  final String outputJsonFilePath;
  final Map<String, String> urlToFilePath;

  const ExportLocalLinksParams({
    required this.sourceJsonFilePath,
    required this.outputJsonFilePath,
    required this.urlToFilePath,
  });
}

Future<LocalLinksRewriteResult> exportLocalLinksIsolate(
  ExportLocalLinksParams params,
) async {
  final jsonString = await File(params.sourceJsonFilePath).readAsString();

  final result = rewriteUrlsToLocalFiles(
    jsonString: jsonString,
    urlToFilePath: params.urlToFilePath,
  );

  await File(params.outputJsonFilePath).writeAsString(result.jsonString);

  return result;
}

enum ExportLocalLinksStatus { success, missingAssets, outputExists, failed }

class ExportLocalLinksResult {
  final ExportLocalLinksStatus status;
  final List<Asset> missingAssets;
  final String? outputPath;
  final LocalLinksRewriteResult? rewrite;
  final String? errorMessage;

  const ExportLocalLinksResult._({
    required this.status,
    this.missingAssets = const [],
    this.outputPath,
    this.rewrite,
    this.errorMessage,
  });

  factory ExportLocalLinksResult.success(
    String outputPath,
    LocalLinksRewriteResult rewrite,
  ) =>
      ExportLocalLinksResult._(
        status: ExportLocalLinksStatus.success,
        outputPath: outputPath,
        rewrite: rewrite,
      );

  factory ExportLocalLinksResult.missingAssets(List<Asset> assets) =>
      ExportLocalLinksResult._(
        status: ExportLocalLinksStatus.missingAssets,
        missingAssets: assets,
      );

  factory ExportLocalLinksResult.outputExists(String outputPath) =>
      ExportLocalLinksResult._(
        status: ExportLocalLinksStatus.outputExists,
        outputPath: outputPath,
      );

  factory ExportLocalLinksResult.failed(String message) =>
      ExportLocalLinksResult._(
        status: ExportLocalLinksStatus.failed,
        errorMessage: message,
      );
}
