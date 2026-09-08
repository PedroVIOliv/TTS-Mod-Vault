import 'dart:convert';

import '../enums/asset_type_enum.dart';

final assetFieldTypes = <String, AssetTypeEnum>{
  for (final type in AssetTypeEnum.values)
    for (final field in type.subtypes) field: type,
};

class AssetReference {
  final String url;
  final String field;
  AssetTypeEnum get type => assetFieldTypes[field]!;
  const AssetReference(this.url, this.field);
}

final _languageUrl = RegExp(r'(?:^|\{[^}]+\})((?:https?|file)://[^{}]+)');

List<String> assetUrls(String value) {
  if (value.startsWith('{')) {
    return _languageUrl.allMatches(value).map((m) => m.group(1)!).toList();
  }
  return RegExp(
              r'^(?:[a-zA-Z][a-zA-Z0-9+.-]*://|[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}(?:/|$))')
          .hasMatch(value)
      ? [value]
      : [];
}

/// Walk serialized objects, states and serialized JSON strings. Lua is never
/// executed. JSON object literals embedded in Lua strings are inspected too.
List<AssetReference> collectAssetReferences(String source) {
  final result = <AssetReference>[];
  void visit(dynamic value) {
    if (value is Map) {
      for (final entry in value.entries) {
        if (assetFieldTypes.containsKey(entry.key) && entry.value is String) {
          for (final url in assetUrls(entry.value as String)) {
            result.add(AssetReference(url, entry.key as String));
          }
        } else {
          visit(entry.value);
        }
      }
    } else if (value is List) {
      for (final child in value) {
        visit(child);
      }
    } else if (value is String) {
      try {
        final decoded = jsonDecode(value);
        if (decoded is Map || decoded is List) {
          visit(decoded);
          return;
        }
      } on FormatException {/* Not serialized JSON. */}
      for (final match in _luaStrings.allMatches(value)) {
        final literal = decodeLuaLiteral(match.group(0)!);
        if (literal != null && literal != value) {
          try {
            final decoded = jsonDecode(literal);
            if (decoded is Map || decoded is List) visit(decoded);
          } on FormatException {/* Ordinary Lua string. */}
        }
      }
    }
  }

  visit(jsonDecode(source));
  return result;
}

// Tokens include comments so a comment cannot be mistaken for a live string.
final _luaStrings = RegExp(
  r'''--\[(=*)\[[\s\S]*?\]\1\]|--[^\r\n]*|"(?:\\[\s\S]|[^"\\])*"|'(?:\\[\s\S]|[^'\\])*'|\[(=*)\[[\s\S]*?\]\2\]''',
);

String? decodeLuaLiteral(String token) {
  if (token.startsWith('--')) return null;
  if (token.startsWith('[')) {
    final open = RegExp(r'^\[(=*)\[').firstMatch(token)!;
    return token.substring(open.end, token.length - open.end);
  }
  // JSON's common escapes are a subset of Lua's string escapes. Fail closed on
  // uncommon escapes rather than changing the meaning of user scripts.
  var body = token.substring(1, token.length - 1);
  if (token.startsWith("'")) {
    body = body.replaceAll(r"\'", "'").replaceAll('"', r'\"');
  }
  try {
    return jsonDecode('"$body"') as String;
  } on FormatException {
    return null;
  }
}

String _luaLiteral(String value) {
  // Use a Lua long string, which preserves spaces, quotes and backslashes
  // exactly. A leading newline in a long string has special Lua semantics.
  if (value.startsWith('\n') || value.startsWith('\r')) {
    return jsonEncode(value);
  }
  var equals = '';
  while (value.contains(']$equals]')) {
    equals += '=';
  }
  return '[$equals[$value]$equals]';
}

/// Rewrites complete values, including Lua literals and nested JSON state.
/// Dictionary keys remain stable identifiers/aliases. No raw JSON replacement.
String rewriteAssetDocument(String source, String? Function(String) resolve) {
  late dynamic Function(dynamic) visit;
  String rewriteText(String value, {bool lua = false}) {
    final direct = resolve(value);
    if (direct != null) return direct;
    if (value.startsWith('{')) {
      final parts = _languageUrl.allMatches(value).toList();
      if (parts.isNotEmpty) {
        return value.replaceAllMapped(_languageUrl, (m) {
          final url = m.group(1)!;
          return m.group(0)!.replaceRange(m.group(0)!.length - url.length,
              m.group(0)!.length, resolve(url) ?? url);
        });
      }
    }
    try {
      final decoded = jsonDecode(value);
      if (decoded is Map || decoded is List) return jsonEncode(visit(decoded));
    } on FormatException {/* Ordinary text or script. */}
    if (!lua) return value;
    return value.replaceAllMapped(_luaStrings, (match) {
      final token = match.group(0)!;
      final decoded = decodeLuaLiteral(token);
      if (decoded == null) return token;
      final rewritten = rewriteText(decoded);
      return rewritten == decoded ? token : _luaLiteral(rewritten);
    });
  }

  visit = (dynamic value) {
    if (value is Map) {
      return {
        for (final entry in value.entries)
          entry.key: entry.value is String
              ? rewriteText(entry.value as String,
                  lua: entry.key == 'LuaScript')
              : visit(entry.value)
      };
    }
    if (value is List) return value.map(visit).toList();
    if (value is String) return rewriteText(value);
    return value;
  };
  return jsonEncode(visit(jsonDecode(source)));
}
