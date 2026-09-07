import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart'
    show HookConsumerWidget, WidgetRef;
import 'package:path/path.dart' as p;
import 'package:tts_mod_vault/src/state/mods/local_links.dart'
    show ExportLocalLinksResult, ExportLocalLinksStatus;
import 'package:tts_mod_vault/src/state/mods/mod_model.dart' show Mod;
import 'package:tts_mod_vault/src/state/provider.dart' show modsProvider;
import 'package:tts_mod_vault/src/utils.dart'
    show copyToClipboard, openInFileExplorer;

/// Entry point for the "Export with local file links" action: runs the export
/// and shows either the cache-gate failure or the result.
///
/// Pass a [NavigatorState] captured before the await so it stays valid across
/// the async gap.
Future<void> runExportLocalLinksThenShowResults(
  NavigatorState navigator,
  WidgetRef ref,
  Mod mod,
) async {
  final result =
      await ref.read(modsProvider.notifier).exportModWithLocalLinks(mod);

  if (!navigator.mounted) return;

  showDialog(
    context: navigator.context,
    builder: (_) => ExportLocalLinksDialog(mod: mod, result: result),
  );
}

class ExportLocalLinksDialog extends HookConsumerWidget {
  final Mod mod;
  final ExportLocalLinksResult result;

  const ExportLocalLinksDialog({
    super.key,
    required this.mod,
    required this.result,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return BackdropFilter(
      filter: ImageFilter.blur(sigmaX: 2, sigmaY: 2),
      child: AlertDialog(
        title: Row(
          children: [
            Icon(
              result.status == ExportLocalLinksStatus.success
                  ? Icons.check_circle_outline
                  : Icons.warning_amber_rounded,
              color: result.status == ExportLocalLinksStatus.success
                  ? Colors.green
                  : Colors.orange,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'Export with local file links',
                style: const TextStyle(fontSize: 18),
              ),
            ),
          ],
        ),
        content: SizedBox(
          width: 1000,
          child: Column(
            spacing: 16,
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(mod.saveName, style: const TextStyle(fontSize: 16)),
              ..._body(),
            ],
          ),
        ),
        actions: [
          ElevatedButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Close'),
          ),
          if (result.status == ExportLocalLinksStatus.missingAssets)
            ElevatedButton.icon(
              onPressed: () => copyToClipboard(
                context,
                result.missingAssets.map((a) => a.url).join('\n'),
                showSnackBarAfterCopying: false,
              ),
              icon: const Icon(Icons.copy_all),
              label: const Text('Copy all missing URLs'),
            ),
          if (result.status == ExportLocalLinksStatus.success)
            ElevatedButton.icon(
              onPressed: () => openInFileExplorer(result.outputPath!),
              icon: const Icon(Icons.folder_open),
              label: const Text('Show file'),
            ),
        ],
      ),
    );
  }

  List<Widget> _body() {
    switch (result.status) {
      case ExportLocalLinksStatus.missingAssets:
        return [
          Text(
            'Not exported - ${result.missingAssets.length} '
            '${result.missingAssets.length == 1 ? "asset is" : "assets are"} '
            'not in your cache. Download them, then try again.',
            style: const TextStyle(color: Colors.red, fontSize: 16),
          ),
          Flexible(
            child: ListView.builder(
              shrinkWrap: true,
              itemCount: result.missingAssets.length,
              itemBuilder: (context, index) {
                final asset = result.missingAssets[index];
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Text(
                    '${index + 1}. [${asset.type.label}] ${asset.url}',
                    style: const TextStyle(fontSize: 16),
                  ),
                );
              },
            ),
          ),
        ];

      case ExportLocalLinksStatus.outputExists:
        return [
          Text(
            'Not exported - ${p.basename(result.outputPath!)} already exists. '
            'Rename or delete it first.',
            style: const TextStyle(color: Colors.red, fontSize: 16),
          ),
        ];

      case ExportLocalLinksStatus.failed:
        return [
          Text(
            'Export failed: ${result.errorMessage}',
            style: const TextStyle(color: Colors.red, fontSize: 16),
          ),
        ];

      case ExportLocalLinksStatus.success:
        final rewrite = result.rewrite!;
        return [
          Text(
            'Rewrote ${rewrite.replacedUrls.length} '
            '${rewrite.replacedUrls.length == 1 ? "URL" : "URLs"} to local '
            'files in:',
            style: const TextStyle(fontSize: 16),
          ),
          SelectableText(
            result.outputPath!,
            style: const TextStyle(fontSize: 16),
          ),
          if (rewrite.notFoundUrls.isNotEmpty)
            Text(
              '${rewrite.notFoundUrls.length} URLs were left unchanged because '
              'they were not found in the JSON text.',
              style: const TextStyle(color: Colors.orange, fontSize: 16),
            ),
          const Text(
            'Open it in Tabletop Simulator, then use Cloud Manager to upload '
            'the local files and re-save to share it.',
            style: TextStyle(fontSize: 16),
          ),
        ];
    }
  }
}
