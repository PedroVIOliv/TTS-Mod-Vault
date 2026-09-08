import 'package:path/path.dart' as p;

final _hex = RegExp(r'^[0-9a-fA-F]{40}$');

bool isSteamAssetHost(String host) {
  final h = host.toLowerCase();
  return h == 'steamusercontent.com' ||
      h == 'images.steamusercontent.com' ||
      RegExp(r'^cloud-\d+\.steamusercontent\.com$').hasMatch(h) ||
      h == 'steamusercontent-a.akamaihd.net' ||
      h == 'steamuserimages-a.akamaihd.net';
}

/// An opaque Steam content token, not a claim about the digest of local bytes.
String? steamContentToken(String value) {
  final uri = Uri.tryParse(value);
  if (uri != null && (uri.scheme == 'https' || uri.scheme == 'http')) {
    if (!isSteamAssetHost(uri.host)) return null;
    final parts = uri.pathSegments.where((s) => s.isNotEmpty).toList();
    if (parts.length == 3 &&
        parts[0] == 'ugc' &&
        RegExp(r'^\d+$').hasMatch(parts[1]) &&
        _hex.hasMatch(parts[2])) {
      return parts[2].toUpperCase();
    }
    return null;
  }
  // Only recognized TTS Steam cache stems. Anchor after the numeric UGC ID,
  // taking the FINAL 40 characters (the ID also consists of hex characters).
  var stem = value.replaceAll('\\', '/').split('/').last;
  stem = p.basenameWithoutExtension(stem);
  final match = RegExp(
    r'^https?(?:steamusercontentaakamaihdnet|steamuserimagesaakamaihdnet|(?:cloud\d+|images)?steamusercontentcom)ugc\d+([a-f0-9]{40})$',
    caseSensitive: false,
  ).firstMatch(stem);
  return match?.group(1)?.toUpperCase();
}

String? localPathFromUrl(String url) {
  if (!url.startsWith('file://')) return null;
  var path = url.substring(7); // TTS uses literal spaces, not URI encoding.
  if (RegExp(r'^/[a-zA-Z]:/').hasMatch(path)) path = path.substring(1);
  if (!path.startsWith('/') && !RegExp(r'^[a-zA-Z]:/').hasMatch(path)) {
    path = '//$path';
  }
  return path;
}

/// Shared by lookup, download, cleanup and shared-file deletion.
String assetCacheKey(String urlOrStem) {
  final token = steamContentToken(urlOrStem);
  if (token != null) return 'steam:$token';
  if (urlOrStem.startsWith('steam:')) return urlOrStem;
  return legacyAssetCacheKey(urlOrStem);
}

String legacyAssetCacheKey(String urlOrStem) {
  final local = localPathFromUrl(urlOrStem);
  final value = local == null ? urlOrStem : p.basenameWithoutExtension(local);
  return value
      .replaceAll(RegExp(r'[^a-zA-Z0-9]'), '')
      .toLowerCase()
      .replaceFirst(RegExp(r'^httpcloud3steamusercontentcom'),
          'httpssteamusercontentaakamaihdnet');
}
