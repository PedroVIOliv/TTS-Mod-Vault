import 'dart:isolate' show SendPort;

import 'package:tts_mod_vault/src/state/enums/asset_type_enum.dart'
    show AssetTypeEnum;

enum BackupStatusEnum {
  idle,
  awaitingBackupFolder,
  backingUp,
}

class BackupState {
  final BackupStatusEnum status;
  final int totalCount;
  final int currentCount;
  final String message;

  const BackupState({
    this.status = BackupStatusEnum.idle,
    this.totalCount = 0,
    this.currentCount = 0,
    this.message = "",
  });

  BackupState copyWith({
    BackupStatusEnum? status,
    int? totalCount,
    int? currentCount,
    String? message,
  }) {
    return BackupState(
      status: status ?? this.status,
      totalCount: totalCount ?? this.totalCount,
      currentCount: currentCount ?? this.currentCount,
      message: message ?? this.message,
    );
  }
}

// Message types for isolate communication
abstract class BackupMessage {}

class BackupProgressMessage extends BackupMessage {
  final int current;
  final int total;

  BackupProgressMessage(this.current, this.total);
}

class BackupCompleteMessage extends BackupMessage {
  final bool success;
  final String message;

  final int assetCount;
  BackupCompleteMessage(this.success, this.message, [this.assetCount = 0]);
}

// Data to send to isolate
class BackupIsolateData {
  final String sourceJsonPath;
  final String jsonEntryPath;
  final String? thumbnail;
  final Map<AssetTypeEnum, String> directories;
  final String targetBackupFilePath;
  final SendPort sendPort;
  BackupIsolateData(
      {required this.sourceJsonPath,
      required this.jsonEntryPath,
      required this.directories,
      required this.targetBackupFilePath,
      required this.sendPort,
      this.thumbnail});
}
