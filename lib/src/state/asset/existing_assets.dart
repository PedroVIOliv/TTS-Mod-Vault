import 'dart:isolate' show Isolate;

import 'package:flutter/material.dart' show debugPrint;
import 'package:hooks_riverpod/hooks_riverpod.dart' show Ref, StateNotifier;
import 'package:tts_mod_vault/src/state/asset/existing_assets_state.dart'
    show ExistingAssetsListsState;
import 'package:tts_mod_vault/src/state/enums/asset_type_enum.dart'
    show AssetTypeEnum;
import 'package:tts_mod_vault/src/state/provider.dart' show directoriesProvider;

import 'asset_cache.dart';
import 'asset_identity.dart';

class ExistingAssetsNotifier extends StateNotifier<ExistingAssetsListsState> {
  final Ref ref;

  ExistingAssetsNotifier(this.ref) : super(ExistingAssetsListsState.empty());

  Future<void> loadExistingAssetsLists() async {
    debugPrint('loadExistingAssetsLists - started at ${DateTime.now()}');

    final directoryPaths = {
      for (final type in AssetTypeEnum.values)
        type: ref.read(directoriesProvider.notifier).getDirectoryByType(type)
    };

    final futures = AssetTypeEnum.values.map((type) async {
      final directoryPath = directoryPaths[type] ?? '';

      final assetMap = await Isolate.run(
        () => scanAssetCache(directoryPath, type),
      );

      return (type, assetMap);
    });

    final results = await Future.wait(futures);

    final Map<AssetTypeEnum, Map<String, List<String>>> resultMap = {
      for (final (type, assetMap) in results) type: assetMap
    };

    state = ExistingAssetsListsState(
      assetBundles: resultMap[AssetTypeEnum.assetBundle] ?? {},
      audio: resultMap[AssetTypeEnum.audio] ?? {},
      images: resultMap[AssetTypeEnum.image] ?? {},
      models: resultMap[AssetTypeEnum.model] ?? {},
      pdf: resultMap[AssetTypeEnum.pdf] ?? {},
    );

    debugPrint('loadExistingAssetsLists - finished at ${DateTime.now()}');
  }

  Future<void> setExistingAssetsListByType(AssetTypeEnum type) async {
    final directoryPath =
        ref.read(directoriesProvider.notifier).getDirectoryByType(type);

    final assetMap = await Isolate.run(
      () => scanAssetCache(directoryPath, type),
    );

    _updateStateByType(type, assetMap);
  }

  /// Freshly downloaded files were validated before being committed, so the
  /// cache absorbs them without re-listing the directory.
  void addExistingAssets(
      AssetTypeEnum type, Iterable<(String, String)> downloads) {
    final updated = Map<String, List<String>>.from(_getAssetMapByType(type));
    for (final (url, filepath) in downloads) {
      for (final key in {assetCacheKey(url), legacyAssetCacheKey(url)}) {
        updated[key] = [filepath];
      }
    }
    _updateStateByType(type, updated);
  }

  Map<String, List<String>> cacheByType(AssetTypeEnum type) =>
      _getAssetMapByType(type);

  Map<String, List<String>> _getAssetMapByType(AssetTypeEnum type) {
    return switch (type) {
      AssetTypeEnum.assetBundle => state.assetBundles,
      AssetTypeEnum.audio => state.audio,
      AssetTypeEnum.image => state.images,
      AssetTypeEnum.model => state.models,
      AssetTypeEnum.pdf => state.pdf,
    };
  }

  void _updateStateByType(
      AssetTypeEnum type, Map<String, List<String>> assetMap) {
    state = switch (type) {
      AssetTypeEnum.assetBundle => state.copyWith(assetBundles: assetMap),
      AssetTypeEnum.audio => state.copyWith(audio: assetMap),
      AssetTypeEnum.image => state.copyWith(images: assetMap),
      AssetTypeEnum.model => state.copyWith(models: assetMap),
      AssetTypeEnum.pdf => state.copyWith(pdf: assetMap),
    };
  }

  bool doesAssetFileExist(String assetFileName, AssetTypeEnum type) =>
      resolveAssetPath(assetFileName, _getAssetMapByType(type)) != null;

  String? getAssetFilePath(String assetFilename, AssetTypeEnum type) =>
      resolveAssetPath(assetFilename, _getAssetMapByType(type));
}
