import 'dart:io' show File;
import 'dart:isolate' show Isolate;

import 'package:archive/archive.dart' show ZipDecoder;
import 'package:hooks_riverpod/hooks_riverpod.dart' show Notifier;
import 'package:tts_mod_vault/src/state/delete_assets/delete_assets_state.dart'
    show DeleteAssetsState, DeleteAssetsStatusEnum, SharedAssetInfo, ScanResult;
import 'package:tts_mod_vault/src/state/mods/mod_model.dart'
    show Mod, ModTypeEnum;
import 'package:tts_mod_vault/src/state/provider.dart'
    show existingAssetListsProvider, modsProvider, storageProvider, logProvider;
import 'package:tts_mod_vault/src/state/bulk_actions/bulk_actions_state.dart'
    show PostBackupDeletionEnum;
import 'package:tts_mod_vault/src/state/enums/asset_type_enum.dart'
    show AssetTypeEnum;

import '../backup/recovery_bundle.dart';
import '../asset/asset_cache.dart';
import '../asset/asset_identity.dart';

class DeleteAssetsNotifier extends Notifier<DeleteAssetsState> {
  DeleteAssetsNotifier();

  @override
  DeleteAssetsState build() {
    return const DeleteAssetsState();
  }

  Future<void> scanModAssets(Mod selectedMod) async {
    state = state.copyWith(
      status: DeleteAssetsStatusEnum.scanning,
      statusMessage: 'Scanning for assets that can be safely deleted...',
    );

    try {
      // Get all existing assets from the selected mod
      final existingModAssets =
          selectedMod.getAllAssets().where((a) => a.fileExists);

      if (existingModAssets.isEmpty) {
        state = state.copyWith(
          status: DeleteAssetsStatusEnum.completed,
          statusMessage: 'No asset files found for ${selectedMod.saveName}',
        );
        return;
      }

      // Get all mods and their URLs
      final allMods = ref.read(modsProvider.notifier).getAllMods();
      final jsonFileNames = allMods.map((mod) => mod.jsonFileName).toList();
      final allModUrls =
          ref.read(storageProvider).getModUrlsBulk(jsonFileNames);

      // Create a map of mod type for each mod
      final modTypeMap = {
        for (final mod in allMods) mod.jsonFileName: mod.modType
      };

      // Run the scanning in an isolate to avoid blocking the UI
      final result = await Isolate.run(() => scanForDeletableAssetsStatic(
            selectedMod.jsonFileName,
            existingModAssets.map((a) => a.url).toList(),
            allModUrls,
            modTypeMap,
          ));

      if (result.filesToDelete.isEmpty && result.sharedFilesToDelete.isEmpty) {
        state = state.copyWith(
          status: DeleteAssetsStatusEnum.completed,
          statusMessage: 'No asset files found for ${selectedMod.saveName}',
        );
        return;
      }

      if (result.filesToDelete.isEmpty) {
        state = state.copyWith(
          status: DeleteAssetsStatusEnum.awaitingConfirmation,
          filesToDelete: result.filesToDelete,
          sharedFilesToDelete: result.sharedFilesToDelete,
          totalFiles: 0,
          sharedAssetInfo: result.sharedAssetInfo,
          statusMessage:
              'All ${result.sharedFilesToDelete.length} asset(s) are shared with other mods',
        );
        return;
      }

      state = state.copyWith(
        status: DeleteAssetsStatusEnum.awaitingConfirmation,
        filesToDelete: result.filesToDelete,
        sharedFilesToDelete: result.sharedFilesToDelete,
        totalFiles: result.filesToDelete.length,
        sharedAssetInfo: result.sharedAssetInfo,
        statusMessage:
            'Found ${result.filesToDelete.length} asset(s) that can be safely deleted',
      );
    } catch (e) {
      state = state.copyWith(
        status: DeleteAssetsStatusEnum.error,
        errorMessage: 'Error scanning assets: $e',
      );
    }
  }

  static ScanResult scanForDeletableAssetsStatic(
    String selectedModJsonFileName,
    List<String> selectedModAssetUrls,
    Map<String, Map<String, String>?> allModUrls,
    Map<String, ModTypeEnum> modTypeMap,
  ) {
    // Build a map of filename -> Set of mod names that use it
    final Map<String, Set<String>> assetUsageMap = {};

    for (final modEntry in allModUrls.entries) {
      final modJsonFileName = modEntry.key;
      final urls = modEntry.value;
      if (urls == null) continue;

      for (final url in urls.keys) {
        final filename = assetCacheKey(url);
        assetUsageMap.putIfAbsent(filename, () => {}).add(modJsonFileName);
      }
    }

    // Find assets that are only used by the selected mod and count shared assets
    final List<String> filesToDelete = [];
    final List<String> sharedFilesToDelete = [];
    int sharedWithMods = 0;
    int sharedWithSaves = 0;
    int sharedWithSavedObjects = 0;
    final Map<String, List<String>> sharedAssetDetails = {};

    for (final url in selectedModAssetUrls) {
      final filename = assetCacheKey(url);
      final modsUsingAsset = assetUsageMap[filename] ?? {};

      // Only delete if this asset is used by exactly one mod (the selected mod)
      if (modsUsingAsset.length == 1 &&
          modsUsingAsset.contains(selectedModJsonFileName)) {
        filesToDelete.add(url);
      } else if (modsUsingAsset.length > 1) {
        // Track shared file for optional deletion
        sharedFilesToDelete.add(url);

        // Track which mods are using this asset (excluding the selected mod)
        final sharingMods = <String>[];

        for (final modJsonFileName in modsUsingAsset) {
          if (modJsonFileName == selectedModJsonFileName) continue;

          sharingMods.add(modJsonFileName);

          final modType = modTypeMap[modJsonFileName];
          if (modType == ModTypeEnum.mod) {
            sharedWithMods++;
          } else if (modType == ModTypeEnum.save) {
            sharedWithSaves++;
          } else if (modType == ModTypeEnum.savedObject) {
            sharedWithSavedObjects++;
          }
        }

        if (sharingMods.isNotEmpty) {
          sharedAssetDetails[url] = sharingMods;
        }
      }
    }

    return ScanResult(
      filesToDelete: filesToDelete,
      sharedFilesToDelete: sharedFilesToDelete,
      sharedAssetInfo: SharedAssetInfo(
        sharedWithMods: sharedWithMods,
        sharedWithSaves: sharedWithSaves,
        sharedWithSavedObjects: sharedWithSavedObjects,
        sharedAssetDetails: sharedAssetDetails,
      ),
    );
  }

  Future<List<String>> executeDelete({bool includeShared = false}) async {
    if (state.status != DeleteAssetsStatusEnum.awaitingConfirmation) {
      return [];
    }

    state = state.copyWith(
      status: DeleteAssetsStatusEnum.deleting,
      currentFile: 0,
      statusMessage: 'Deleting assets...',
    );

    try {
      final filesToDelete = includeShared
          ? [...state.filesToDelete, ...state.sharedFilesToDelete]
          : state.filesToDelete;
      final existingAssets = ref.read(existingAssetListsProvider);

      await deleteFilesStatic(filesToDelete, existingAssets);

      // Refresh existing assets lists after deletion
      for (final type in AssetTypeEnum.values) {
        await ref
            .read(existingAssetListsProvider.notifier)
            .setExistingAssetsListByType(type);
      }

      state = state.copyWith(
        status: DeleteAssetsStatusEnum.completed,
        currentFile: filesToDelete.length,
        statusMessage: 'Successfully deleted ${filesToDelete.length} asset(s)',
      );

      return filesToDelete;
    } catch (e) {
      state = state.copyWith(
        status: DeleteAssetsStatusEnum.error,
        errorMessage: 'Error deleting assets: $e',
      );
      return [];
    }
  }

  static Future<void> deleteFilesStatic(
      List<String> fileNames, existingAssets) async {
    for (final fileName in fileNames) {
      try {
        // Keep the original URL so query-named exact cache candidates can be
        // resolved as well as the shared Steam content identity.
        String? filePath;
        for (final cache in [
          existingAssets.assetBundles,
          existingAssets.audio,
          existingAssets.images,
          existingAssets.models,
          existingAssets.pdf
        ]) {
          filePath =
              resolveAssetPath(fileName, Map<String, String>.from(cache));
          if (filePath != null) break;
        }

        if (filePath != null && filePath.isNotEmpty) {
          final file = File(filePath);
          if (await file.exists()) {
            await file.delete();
          }
        }
      } catch (e) {
        // Continue with other files even if one fails
        continue;
      }
    }
  }

  void resetState() {
    state = const DeleteAssetsState();
  }

  /// Returns a map of mod type to list of display names that share this asset.
  /// The currentModJsonFileName is excluded from the result.
  Future<Map<ModTypeEnum, List<String>>> getModsSharingAsset(
      String assetUrl, String currentModJsonFileName) async {
    final allMods = ref.read(modsProvider.notifier).getAllMods();
    final allModUrls = ref.read(storageProvider).getAllModUrls();

    final modNameMap = {
      for (final mod in allMods)
        mod.jsonFileName: mod.saveName.isEmpty ? mod.jsonFileName : mod.saveName
    };
    final modTypeMap = {
      for (final mod in allMods) mod.jsonFileName: mod.modType
    };

    return await Isolate.run(() => getModsSharingAssetStatic(
          assetUrl: assetUrl,
          currentModJsonFileName: currentModJsonFileName,
          allModUrls: allModUrls,
          modNameMap: modNameMap,
          modTypeMap: modTypeMap,
        ));
  }

  static Map<ModTypeEnum, List<String>> getModsSharingAssetStatic({
    required String assetUrl,
    required String currentModJsonFileName,
    required Map<String, Map<String, String>?> allModUrls,
    required Map<String, String> modNameMap,
    required Map<String, ModTypeEnum> modTypeMap,
  }) {
    final filename = assetCacheKey(assetUrl);
    final sharingMods = <ModTypeEnum, List<String>>{};

    for (final modEntry in allModUrls.entries) {
      final modJsonFileName = modEntry.key;
      if (modJsonFileName == currentModJsonFileName) continue;

      final urls = modEntry.value;
      if (urls == null) continue;

      for (final url in urls.keys) {
        if (assetCacheKey(url) == filename) {
          final type = modTypeMap[modJsonFileName] ?? ModTypeEnum.mod;
          final name = modNameMap[modJsonFileName] ?? modJsonFileName;
          sharingMods.putIfAbsent(type, () => []).add(name);
          break;
        }
      }
    }

    return sharingMods;
  }

  /// Deletes a single asset file by its file path.
  /// Returns true if deleted successfully.
  Future<bool> deleteSingleAsset(String? filePath, AssetTypeEnum type) async {
    if (filePath == null || filePath.isEmpty) return false;

    try {
      final file = File(filePath);
      if (await file.exists()) {
        await file.delete();
        // Refresh the asset list for this type
        await ref
            .read(existingAssetListsProvider.notifier)
            .setExistingAssetsListByType(type);
        return true;
      }
    } catch (e) {
      return false;
    }
    return false;
  }

  /// Deletes assets for a single mod based on the deletion option.
  /// Returns the list of deleted filenames.
  /// Used by both bulk backup and single mod backup operations.
  Future<List<String>> deleteModAssetsAfterBackup(
    Mod mod,
    PostBackupDeletionEnum deletionOption,
  ) async {
    if (deletionOption == PostBackupDeletionEnum.none) {
      return [];
    }

    // Deletion after a skipped/old backup is safe only if that archive actually
    // contains the current bytes. Legacy/unverified backups cannot authorize it.
    try {
      final backup = mod.backup;
      if (backup == null) throw StateError('No verified backup');
      final archive =
          ZipDecoder().decodeBytes(await File(backup.filepath).readAsBytes());
      final inventory = verifyRecoveryArchive(archive);
      if (inventory == null) {
        throw StateError('Backup has no integrity inventory');
      }
      for (final asset in mod.getAllAssets().where((a) => a.filePath != null)) {
        final digest = await assetDigest(asset.filePath!);
        final backedUp = (inventory['assets'] as List).any((entry) =>
            entry['type'] == asset.type.name &&
            assetCacheKey(entry['url']) == assetCacheKey(asset.url) &&
            inventory['files'][entry['path']]['sha256'] == digest);
        if (!backedUp) {
          throw StateError(
              'Current asset is not verified in the backup: ${asset.url}');
        }
      }
    } catch (e) {
      ref.read(logProvider.notifier).addError('Assets retained: $e');
      return [];
    }

    // Get existing assets that can be deleted
    final existingModAssets = mod.getAllAssets().where((a) => a.fileExists);
    if (existingModAssets.isEmpty) {
      return [];
    }

    state = state.copyWith(status: DeleteAssetsStatusEnum.scanning);

    // Get all mods and their URLs for shared asset detection
    final allMods = ref.read(modsProvider.notifier).getAllMods();
    final jsonFileNames = allMods.map((m) => m.jsonFileName).toList();
    final allModUrls = ref.read(storageProvider).getModUrlsBulk(jsonFileNames);
    final modTypeMap = {for (final m in allMods) m.jsonFileName: m.modType};

    // Scan for deletable assets (reusing existing static method)
    final scanResult = await Isolate.run(
      () => scanForDeletableAssetsStatic(
        mod.jsonFileName,
        existingModAssets.map((a) => a.url).toList(),
        allModUrls,
        modTypeMap,
      ),
    );

    // Determine which files to delete based on deletion option
    final List<String> filesToDelete;
    if (deletionOption == PostBackupDeletionEnum.deleteAllAssets) {
      filesToDelete = [
        ...scanResult.filesToDelete,
        ...scanResult.sharedFilesToDelete
      ];
    } else {
      // deleteNonSharedAssets
      filesToDelete = scanResult.filesToDelete;
    }

    if (filesToDelete.isEmpty) {
      return [];
    }

    // Delete the files
    final existingAssets = ref.read(existingAssetListsProvider);
    await deleteFilesStatic(filesToDelete, existingAssets);

    // Refresh asset lists after deletion
    for (final type in AssetTypeEnum.values) {
      await ref
          .read(existingAssetListsProvider.notifier)
          .setExistingAssetsListByType(type);
    }

    state = state.copyWith(status: DeleteAssetsStatusEnum.idle);

    return filesToDelete;
  }
}
