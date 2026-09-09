import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart' show useMemoized;
import 'package:hooks_riverpod/hooks_riverpod.dart'
    show HookConsumerWidget, WidgetRef;
import 'package:tts_mod_vault/src/state/mods/export_local_links_state.dart'
    show ExportLocalLinksProgressEnum;
import 'package:tts_mod_vault/src/state/provider.dart'
    show exportLocalLinksProgressProvider;

class ExportLocalLinksProgressBar extends HookConsumerWidget {
  const ExportLocalLinksProgressBar({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final export = ref.watch(exportLocalLinksProgressProvider);

    // Writing the copy is one indivisible step, so the bar fills rather than
    // inventing a fraction for it.
    final progress = useMemoized(() {
      if (export.status == ExportLocalLinksProgressEnum.writing) return 1.0;
      return export.totalCount > 0
          ? export.currentCount / export.totalCount
          : 0.0;
    }, [export]);

    final progressText = useMemoized(() {
      return export.status == ExportLocalLinksProgressEnum.verifying &&
              export.totalCount > 0
          ? "(${export.currentCount}/${export.totalCount})"
          : "";
    }, [export]);

    final message = useMemoized(() {
      switch (export.status) {
        case ExportLocalLinksProgressEnum.verifying:
          return "Verifying assets for ${export.saveName}";

        case ExportLocalLinksProgressEnum.writing:
          return "Writing local links copy of ${export.saveName}";

        case ExportLocalLinksProgressEnum.idle:
          return "";
      }
    }, [export]);

    if (export.status == ExportLocalLinksProgressEnum.idle) {
      return const SizedBox.shrink();
    }

    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.end,
        spacing: 4,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            spacing: 4,
            children: [
              Text(
                progressText,
                style: const TextStyle(fontSize: 20),
              ),
              Expanded(
                child: Text(
                  message,
                  maxLines: 4,
                  style: const TextStyle(fontSize: 20),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.only(right: 8, bottom: 8),
            child: Container(
              width: double.infinity,
              decoration: BoxDecoration(
                color: Colors.grey.shade300,
                borderRadius: BorderRadius.circular(32),
              ),
              child: Stack(
                children: [
                  FractionallySizedBox(
                    widthFactor: progress.clamp(0.0, 1.0),
                    child: Container(
                      height: 20,
                      decoration: BoxDecoration(
                        color: Colors.green,
                        borderRadius: BorderRadius.circular(32),
                      ),
                    ),
                  )
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
