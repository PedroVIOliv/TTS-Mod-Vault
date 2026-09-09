enum ExportLocalLinksProgressEnum { idle, verifying, writing }

class ExportLocalLinksProgressState {
  final ExportLocalLinksProgressEnum status;
  final int currentCount;
  final int totalCount;
  final String saveName;

  const ExportLocalLinksProgressState({
    required this.status,
    required this.currentCount,
    required this.totalCount,
    required this.saveName,
  });

  const ExportLocalLinksProgressState.idle()
      : status = ExportLocalLinksProgressEnum.idle,
        currentCount = 0,
        totalCount = 0,
        saveName = '';

  ExportLocalLinksProgressState copyWith({
    ExportLocalLinksProgressEnum? status,
    int? currentCount,
    int? totalCount,
    String? saveName,
  }) {
    return ExportLocalLinksProgressState(
      status: status ?? this.status,
      currentCount: currentCount ?? this.currentCount,
      totalCount: totalCount ?? this.totalCount,
      saveName: saveName ?? this.saveName,
    );
  }
}
