import 'package:hooks_riverpod/hooks_riverpod.dart' show StateNotifier;
import 'package:tts_mod_vault/src/state/mods/export_local_links_state.dart'
    show ExportLocalLinksProgressEnum, ExportLocalLinksProgressState;

class ExportLocalLinksProgressNotifier
    extends StateNotifier<ExportLocalLinksProgressState> {
  ExportLocalLinksProgressNotifier()
      : super(const ExportLocalLinksProgressState.idle());

  void startVerifying(String saveName) {
    state = ExportLocalLinksProgressState(
      status: ExportLocalLinksProgressEnum.verifying,
      currentCount: 0,
      totalCount: 0,
      saveName: saveName,
    );
  }

  void reportVerified(int done, int total) {
    state = state.copyWith(currentCount: done, totalCount: total);
  }

  void startWriting() {
    state = state.copyWith(status: ExportLocalLinksProgressEnum.writing);
  }

  void reset() {
    state = const ExportLocalLinksProgressState.idle();
  }
}
