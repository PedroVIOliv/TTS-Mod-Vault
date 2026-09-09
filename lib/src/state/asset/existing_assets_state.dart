class ExistingAssetsListsState {
  // Maps: cache name -> every file path claiming it
  final Map<String, List<String>> assetBundles;
  final Map<String, List<String>> audio;
  final Map<String, List<String>> images;
  final Map<String, List<String>> models;
  final Map<String, List<String>> pdf;

  ExistingAssetsListsState({
    required this.assetBundles,
    required this.audio,
    required this.images,
    required this.models,
    required this.pdf,
  });

  ExistingAssetsListsState.empty()
      : assetBundles = {},
        audio = {},
        images = {},
        models = {},
        pdf = {};

  ExistingAssetsListsState copyWith({
    Map<String, List<String>>? assetBundles,
    Map<String, List<String>>? audio,
    Map<String, List<String>>? images,
    Map<String, List<String>>? models,
    Map<String, List<String>>? pdf,
  }) {
    return ExistingAssetsListsState(
      assetBundles: assetBundles ?? this.assetBundles,
      audio: audio ?? this.audio,
      images: images ?? this.images,
      models: models ?? this.models,
      pdf: pdf ?? this.pdf,
    );
  }
}
