import 'dart:io' show Directory, File;
import 'dart:isolate' show ReceivePort, Isolate;

import 'package:file_picker/file_picker.dart' show FilePicker;
import 'package:flutter/material.dart' show debugPrint;
import 'package:hooks_riverpod/hooks_riverpod.dart' show Ref, StateNotifier;
import 'package:path/path.dart' as p
    show basename, dirname, join, relative, isWithin;
import 'package:tts_mod_vault/src/state/backup/backup_state.dart'
    show
        BackupCompleteMessage,
        BackupIsolateData,
        BackupProgressMessage,
        BackupState,
        BackupStatusEnum;
import 'package:tts_mod_vault/src/state/backup/models/existing_backup_model.dart'
    show ExistingBackup;
import 'package:tts_mod_vault/src/state/bulk_actions/bulk_actions_state.dart'
    show BulkActionsStatusEnum;
import 'package:tts_mod_vault/src/state/enums/asset_type_enum.dart'
    show AssetTypeEnum;
import 'package:tts_mod_vault/src/state/mods/mod_model.dart' show Mod;
import 'package:tts_mod_vault/src/state/provider.dart'
    show
        bulkActionsProvider,
        directoriesProvider,
        existingBackupsProvider,
        settingsProvider,
        logProvider;
import 'package:tts_mod_vault/src/utils.dart' show getBackupFilenameByMod;

import 'recovery_bundle.dart';

class BackupNotifier extends StateNotifier<BackupState> {
  final Ref ref;

  BackupNotifier(this.ref) : super(const BackupState());

  void resetMessage() {
    state = state.copyWith(message: "");
  }

  Future<bool> createBackup(Mod mod, [String? backupDirectory]) async {
    state = state.copyWith(
      status: backupDirectory != null && backupDirectory.isNotEmpty
          ? BackupStatusEnum.backingUp
          : BackupStatusEnum.awaitingBackupFolder,
      currentCount: 0,
      totalCount: 0,
      message: "",
    );

    final backupsDir = ref.read(directoriesProvider).backupsDir;

    final backupDirPath = backupDirectory != null && backupDirectory.isNotEmpty
        ? backupDirectory
        : await FilePicker.platform.getDirectoryPath(
            lockParentWindow: true,
            initialDirectory: backupsDir.isEmpty ? null : backupsDir,
          );

    if (backupDirPath == null) {
      state = state.copyWith(status: BackupStatusEnum.idle);
      return false;
    }

    state = state.copyWith(status: BackupStatusEnum.backingUp);
    var succeeded = false;

    try {
      final receivePort = ReceivePort();
      final forceBackupJsonFilename =
          ref.read(settingsProvider).forceBackupJsonFilename;
      final backupFileName =
          getBackupFilenameByMod(mod, forceBackupJsonFilename);
      final targetBackupFilePath = p.join(backupDirPath, backupFileName);

      final modsDir = Directory(ref.read(directoriesProvider).modsDir);
      final savesDir = Directory(ref.read(directoriesProvider).savesDir);

      final isolateData = BackupIsolateData(
        sourceJsonPath: mod.jsonFilePath,
        thumbnail: mod.imageFilePath,
        jsonEntryPath: (p.isWithin(savesDir.path, mod.jsonFilePath)
                ? 'Saves/${p.relative(mod.jsonFilePath, from: savesDir.path)}'
                : 'Mods/${p.relative(mod.jsonFilePath, from: modsDir.path)}')
            .replaceAll('\\', '/'),
        directories: {
          for (final type in AssetTypeEnum.values)
            type:
                ref.read(directoriesProvider.notifier).getDirectoryByType(type)
        },
        targetBackupFilePath: targetBackupFilePath,
        sendPort: receivePort.sendPort,
      );

      // Start the isolate
      await Isolate.spawn(_backupIsolate, isolateData);

      // Listen for messages from isolate
      await for (final message in receivePort) {
        if (message is BackupProgressMessage) {
          state = state.copyWith(
            currentCount: message.current,
            totalCount: message.total,
          );
        } else if (message is BackupCompleteMessage) {
          receivePort.close();

          succeeded = message.success;
          if (!succeeded) {
            ref
                .read(logProvider.notifier)
                .addError('Backup failed: ${mod.saveName}: ${message.message}');
          }
          if (message.success) {
            // Add new backup to state
            final backupFile = File(targetBackupFilePath);
            final backupFileSize =
                backupFile.existsSync() ? backupFile.lengthSync() : 0;
            final newBackup = ExistingBackup(
              filename: backupFileName,
              filepath: targetBackupFilePath,
              parentFolderName: p.basename(p.dirname(targetBackupFilePath)),
              lastModifiedTimestamp:
                  DateTime.now().millisecondsSinceEpoch ~/ 1000,
              totalAssetCount: message.assetCount,
              fileSize: backupFileSize,
            );
            ref.read(existingBackupsProvider.notifier).addBackup(newBackup);
          }

          if (ref.read(bulkActionsProvider).status ==
              BulkActionsStatusEnum.idle) {
            state = state.copyWith(message: message.message);
          }
          break;
        }
      }
    } catch (e) {
      debugPrint('createBackup - error: ${e.toString()}');
      ref
          .read(logProvider.notifier)
          .addError('Backup failed: ${mod.saveName}: $e');
      state = state.copyWith(message: e.toString());
    } finally {
      state = state.copyWith(status: BackupStatusEnum.idle);
    }
    return succeeded;
  }
}

void _backupIsolate(BackupIsolateData data) async {
  try {
    final count = await writeRecoveryBundle(
      sourceJsonPath: data.sourceJsonPath,
      jsonEntryPath: data.jsonEntryPath,
      target: data.targetBackupFilePath,
      directories: data.directories,
      thumbnail: data.thumbnail,
      onProgress: (current, total) =>
          data.sendPort.send(BackupProgressMessage(current, total)),
    );
    data.sendPort.send(BackupCompleteMessage(true,
        'Verified backup created at ${data.targetBackupFilePath}', count));
  } catch (e) {
    data.sendPort.send(BackupCompleteMessage(false, e.toString()));
  }
}
