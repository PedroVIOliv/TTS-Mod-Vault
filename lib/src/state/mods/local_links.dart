import 'dart:io' show Directory, File, FileSystemException;

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:path/path.dart' as p;
import 'package:tts_mod_vault/src/state/asset/models/asset_model.dart'
    show Asset;

import '../asset/asset_rewrite.dart';
import '../asset/asset_cache.dart';
import '../asset/asset_document.dart';
import '../asset/asset_identity.dart';
import '../backup/recovery_bundle.dart';

export '../asset/asset_rewrite.dart'
    show localFileUrl, LocalLinksRewriteResult, rewriteUrlsToLocalFiles;

String localLinksOutputPath(String jsonFilePath) {
  final directory = p.dirname(jsonFilePath);
  final name = p.basenameWithoutExtension(jsonFilePath);
  final extension = p.extension(jsonFilePath);

  return p.join(directory, '$name Local$extension');
}

class ExportLocalLinksParams {
  final String sourceJsonFilePath;
  final String outputJsonFilePath;
  final String? sourceImageFilePath;
  final Map<String, String> urlToFilePath;

  const ExportLocalLinksParams({
    required this.sourceJsonFilePath,
    required this.outputJsonFilePath,
    required this.urlToFilePath,
    this.sourceImageFilePath,
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

  if (result.notFoundUrls.isNotEmpty) {
    throw FormatException(
        'Unmatched asset URLs: ${result.notFoundUrls.join(', ')}');
  }
  final seen = <String>{};
  for (final reference in collectAssetReferences(result.jsonString)) {
    final path = localPathFromUrl(reference.url);
    if (path == null) {
      throw FormatException('Unresolved asset: ${reference.url}');
    }
    if (seen.add('${reference.type.name}:$path')) {
      await validateAssetFile(path, reference.type);
    }
  }
  // Validate even supplied mappings not represented by recognized asset fields.
  for (final path in params.urlToFilePath.values.toSet()) {
    final handle = await File(path).open();
    try {
      if (await handle.length() == 0) {
        throw FileSystemException('Empty asset', path);
      }
      await handle.read(1);
    } finally {
      await handle.close();
    }
  }
  final staging = await Directory(p.dirname(params.outputJsonFilePath))
      .createTemp('.local-');
  try {
    final temporary = File(p.join(staging.path, 'save.json'));
    await temporary.writeAsString(result.jsonString, flush: true);
    await commitFile(temporary.path, params.outputJsonFilePath,
        overwrite: false);
  } finally {
    await staging.delete(recursive: true);
  }

  await _copyThumbnail(params);

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

// TTS shows the sibling <name>.png as the save's thumbnail. A failed copy
// leaves the export usable, so it never aborts.
Future<void> _copyThumbnail(ExportLocalLinksParams params) async {
  final source = params.sourceImageFilePath;
  if (source == null || source.isEmpty) return;

  try {
    final imageFile = File(source);
    if (!imageFile.existsSync()) return;

    await imageFile.copy(p.setExtension(params.outputJsonFilePath, '.png'));
  } catch (e) {
    debugPrint('exportLocalLinksIsolate - thumbnail copy failed: $e');
  }
}
