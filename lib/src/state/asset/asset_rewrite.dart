import 'dart:io' show Platform;

import 'asset_document.dart';
import 'asset_identity.dart';

/// Builds the `file://` URL TTS stores for a cached asset.
///
/// The path is NOT percent-encoded: Unity hands it to the OS verbatim, so an
/// encoded space makes it look for a directory literally named "My%20Games".
/// Separators still have to be forward slashes, or the backslashes would need
/// escaping inside the JSON.
String localFileUrl(String filePath, {bool? windows}) {
  final isWindows = windows ?? Platform.isWindows;
  final slashed = filePath.replaceAll(r'\', '/');

  if (slashed.startsWith('//')) return 'file:$slashed';
  return isWindows ? 'file:///$slashed' : 'file://$slashed';
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
  final replaced = <String>{};
  final byIdentity = <String, MapEntry<String, String>>{};
  for (final entry in urlToFilePath.entries) {
    byIdentity.putIfAbsent(assetCacheKey(entry.key), () => entry);
  }
  final output = rewriteAssetDocument(jsonString, (url) {
    final direct = urlToFilePath[url];
    final entry =
        direct == null ? byIdentity[assetCacheKey(url)] : MapEntry(url, direct);
    if (entry == null) return null;
    // Avoid matching arbitrary ordinary text through lossy cache names.
    if (url != entry.key && steamContentToken(url) == null) return null;
    replaced.add(entry.key);
    return localFileUrl(entry.value, windows: windows);
  });
  return LocalLinksRewriteResult(
    jsonString: output,
    replacedUrls: replaced.toList(),
    notFoundUrls: urlToFilePath.keys
        .where((url) =>
            !replaced.contains(url) &&
            !replaced
                .any((other) => assetCacheKey(other) == assetCacheKey(url)))
        .toList(),
  );
}
