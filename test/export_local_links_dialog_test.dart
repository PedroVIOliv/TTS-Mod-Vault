import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart' show ProviderScope;
import 'package:tts_mod_vault/src/mods/components/export_local_links_dialog.dart'
    show ExportLocalLinksDialog;
import 'package:tts_mod_vault/src/state/asset/models/asset_lists_model.dart'
    show AssetLists;
import 'package:tts_mod_vault/src/state/asset/models/asset_model.dart'
    show Asset;
import 'package:tts_mod_vault/src/state/backup/backup_status_enum.dart'
    show ExistingBackupStatusEnum;
import 'package:tts_mod_vault/src/state/enums/asset_type_enum.dart'
    show AssetTypeEnum;
import 'package:tts_mod_vault/src/state/mods/local_links.dart'
    show ExportLocalLinksResult, LocalLinksRewriteResult;
import 'package:tts_mod_vault/src/state/mods/mod_model.dart'
    show AudioAssetVisibility, Mod, ModTypeEnum;

Mod buildMod() => Mod(
      modType: ModTypeEnum.save,
      jsonFilePath: '/Saves/TS_Save_12.json',
      jsonFileName: 'TS_Save_12.json',
      parentFolderName: 'Saves',
      saveName: 'My Table',
      backupStatus: ExistingBackupStatusEnum.upToDate,
      createdAtTimestamp: 0,
      lastModifiedTimestamp: 0,
      backup: null,
      dateTimeStamp: null,
      imageFilePath: null,
      assetLists: AssetLists(),
      assetCount: 1,
      existingAssetCount: 0,
      audioVisibility: AudioAssetVisibility.useGlobalSetting,
      hasAudioAssets: false,
    );

Future<void> pumpDialog(WidgetTester tester, ExportLocalLinksResult result) {
  return tester.pumpWidget(
    ProviderScope(
      child: MaterialApp(
        home: ExportLocalLinksDialog(mod: buildMod(), result: result),
      ),
    ),
  );
}

void main() {
  testWidgets('missing assets are listed and nothing is reported as written',
      (tester) async {
    await pumpDialog(
      tester,
      ExportLocalLinksResult.missingAssets([
        Asset(
          url: 'https://example.com/missing.png',
          fileExists: false,
          type: AssetTypeEnum.image,
        ),
      ]),
    );

    expect(find.textContaining('Not exported'), findsOneWidget);
    expect(find.textContaining('1 asset is not in your cache'), findsOneWidget);
    expect(
      find.textContaining('https://example.com/missing.png'),
      findsOneWidget,
    );
    expect(find.text('Copy all missing URLs'), findsOneWidget);
    expect(find.text('Show file'), findsNothing);
  });

  testWidgets('success reports the count and the output path', (tester) async {
    await pumpDialog(
      tester,
      ExportLocalLinksResult.success(
        '/Saves/TS_Save_12 Local.json',
        const LocalLinksRewriteResult(
          jsonString: '{}',
          replacedUrls: ['https://example.com/a.png'],
          notFoundUrls: [],
        ),
      ),
    );

    expect(find.textContaining('Rewrote 1 URL'), findsOneWidget);
    expect(find.text('/Saves/TS_Save_12 Local.json'), findsOneWidget);
    expect(find.text('Show file'), findsOneWidget);
  });
}
