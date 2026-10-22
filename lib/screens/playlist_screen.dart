import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart' show CupertinoIcons;
import 'package:audio_service/audio_service.dart' show MediaItem;
import 'package:mornye/screens/track_history_snapshot.dart';
import 'package:mornye/widgets/album_detail_header.dart';
import 'package:mornye/widgets/expressive_button_group.dart';
import 'package:mornye/screens/selection_mode_mixin.dart';
import 'package:mornye/widgets/collection_scaffold.dart';
import 'package:mornye/widgets/selection_bottom_bar.dart';
import 'package:mornye/widgets/selection_action_button.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/services/platform_bridge.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/providers/download_queue_provider.dart';
import 'package:mornye/providers/extension_provider.dart';
import 'package:mornye/providers/library_collections_provider.dart';
import 'package:mornye/providers/music_player_provider.dart';
import 'package:mornye/utils/image_cache_utils.dart';
import 'package:mornye/utils/cover_art_utils.dart';
import 'package:mornye/utils/adaptive_layout.dart';
import 'package:mornye/utils/provider_resource_ids.dart';
import 'package:mornye/widgets/playlist_picker_sheet.dart';
import 'package:mornye/widgets/animation_utils.dart';
import 'package:mornye/widgets/cached_cover_image.dart';
import 'package:mornye/widgets/motion_header_banner.dart';
import 'package:mornye/widgets/track_list_tile.dart';
import 'package:mornye/widgets/library_fast_scroller.dart';
import 'package:mornye/widgets/track_detail_actions.dart';
import 'package:mornye/screens/collapsing_header_scroll_mixin.dart';
import 'package:mornye/widgets/error_card.dart';
import 'package:mornye/widgets/downloadable_cover.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/widgets/mornye_artist_header.dart';

class PlaylistScreen extends ConsumerStatefulWidget {
  final String playlistName;
  final String? coverUrl;
  final String? headerVideoUrl;
  final List<Track> tracks;
  final String? playlistId;
  final String? metadataProviderId;
  final String? recommendedService;

  const PlaylistScreen({
    super.key,
    required this.playlistName,
    this.coverUrl,
    this.headerVideoUrl,
    required this.tracks,
    this.playlistId,
    this.metadataProviderId,
    this.recommendedService,
  });

  @override
  ConsumerState<PlaylistScreen> createState() => _PlaylistScreenState();
}

class _PlaylistScreenState extends ConsumerState<PlaylistScreen>
    with
        SelectionModeMixin<PlaylistScreen>,
        CollapsingHeaderScrollMixin<PlaylistScreen> {
  final _historySnapshot = TrackHistorySnapshot();
  List<Track>? _fetchedTracks;
  bool _isLoading = false;
  String? _error;
  String? _resolvedPlaylistName;
  String? _resolvedCoverUrl;
  String? _resolvedHeaderVideoUrl;
  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';
  bool _showSearch = false;
  List<int>? _cachedVisibleTrackIndices;
  int? _jumpTargetIndex;
  GlobalKey? _jumpTargetKey;

  List<Track> get _tracks => _fetchedTracks ?? widget.tracks;
  String get _playlistName => _resolvedPlaylistName ?? widget.playlistName;
  String? get _coverUrl => _resolvedCoverUrl ?? widget.coverUrl;
  String? get _headerVideoUrl =>
      _resolvedHeaderVideoUrl ?? widget.headerVideoUrl;

  List<int> get _visibleTrackIndices {
    final cached = _cachedVisibleTrackIndices;
    if (cached != null) return cached;
    final query = _searchQuery.trim().toLowerCase();
    return _cachedVisibleTrackIndices = [
      for (var index = 0; index < _tracks.length; index++)
        if (query.isEmpty || _trackMatchesQuery(_tracks[index], query)) index,
    ];
  }

  bool _trackMatchesQuery(Track track, String query) {
    final searchable = <String?>[
      track.name,
      track.albumName,
      track.artistName,
      track.albumArtist,
      track.composer,
      track.genre,
      track.label,
    ];
    return searchable.any(
      (value) => value != null && value.toLowerCase().contains(query),
    );
  }

  int _findCurrentTrackIndex(MediaItem item) {
    final exactId = _tracks.indexWhere((track) => track.id == item.id);
    if (exactId >= 0) return exactId;

    final title = item.title.trim().toLowerCase();
    if (title.isEmpty) return -1;
    final artist = (item.artist ?? '').trim().toLowerCase();
    return _tracks.indexWhere((track) {
      if (track.name.trim().toLowerCase() != title) return false;
      if (artist.isEmpty) return true;
      final trackArtist = track.artistName.trim().toLowerCase();
      return trackArtist == artist || trackArtist.contains(artist);
    });
  }

  void _toggleSearch() {
    final opening = !_showSearch;
    setState(() {
      _showSearch = opening;
      if (!opening) {
        _searchController.clear();
        _searchQuery = '';
        _cachedVisibleTrackIndices = null;
      }
      _jumpTargetIndex = null;
      _jumpTargetKey = null;
    });
    if (opening) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !scrollController.hasClients) return;
        scrollController.animateTo(
          0,
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOutCubic,
        );
      });
    }
  }

  void _onSearchChanged(String value) {
    setState(() {
      _searchQuery = value;
      _cachedVisibleTrackIndices = null;
      _jumpTargetIndex = null;
      _jumpTargetKey = null;
    });
  }

  Future<void> _jumpToCurrentTrack() async {
    final item = ref.read(currentMediaItemProvider).value;
    if (item == null) return;
    final index = _findCurrentTrackIndex(item);
    if (index < 0) return;

    _searchController.clear();
    setState(() {
      _showSearch = false;
      _searchQuery = '';
      _cachedVisibleTrackIndices = null;
      _jumpTargetIndex = index;
      _jumpTargetKey = GlobalKey(debugLabel: 'current-playlist-track');
    });

    await WidgetsBinding.instance.endOfFrame;
    if (!mounted || !scrollController.hasClients) return;

    final position = scrollController.position;
    final headerExtent = calculateExpandedHeight(context);
    final estimatedTrackExtent =
        ((position.maxScrollExtent - headerExtent) / _tracks.length)
            .clamp(58.0, 100.0)
            .toDouble();
    final maxExtent = position.maxScrollExtent;
    final estimatedOffset = (headerExtent + index * estimatedTrackExtent)
        .clamp(0.0, maxExtent)
        .toDouble();
    final proportionalOffset = (maxExtent * index / _tracks.length)
        .clamp(0.0, maxExtent)
        .toDouble();

    BuildContext? targetContext;
    for (final offset in [estimatedOffset, proportionalOffset]) {
      await scrollController.animateTo(
        offset,
        duration: const Duration(milliseconds: 320),
        curve: Curves.easeOutCubic,
      );
      await WidgetsBinding.instance.endOfFrame;
      targetContext = _jumpTargetKey?.currentContext;
      if (targetContext != null) break;
    }

    if (targetContext != null) {
      await Scrollable.ensureVisible(
        targetContext,
        alignment: 0.2,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
      );
    }
  }

  /// Playlists can legitimately contain the same track twice, so selection is
  /// keyed by position as well as id (matching the album screen).
  String _trackSelectionId(Track track, int index) => '${track.id}#$index';

  List<Track> get _selectedTracks => [
    for (var index = 0; index < _tracks.length; index++)
      if (selectedIds.contains(_trackSelectionId(_tracks[index], index)))
        _tracks[index],
  ];

  Widget _buildSelectionBottomBar(
    BuildContext context,
    ColorScheme colorScheme,
    double bottomPadding,
  ) {
    final selectedCount = selectedIds.length;
    final allSelected = _tracks.isNotEmpty && selectedCount == _tracks.length;

    return SelectionBottomBar(
      selectedCount: selectedCount,
      allSelected: allSelected,
      onClose: exitSelectionMode,
      onToggleSelectAll: () {
        if (allSelected) {
          exitSelectionMode();
        } else {
          selectAll([
            for (var index = 0; index < _tracks.length; index++)
              _trackSelectionId(_tracks[index], index),
          ]);
        }
      },
      bottomPadding: bottomPadding,
      children: [
        SizedBox(
          width: double.infinity,
          child: SelectionActionButton(
            icon: Icons.download_rounded,
            label: '${context.l10n.dialogDownload} ($selectedCount)',
            onPressed: selectedCount == 0 ? null : _downloadSelected,
            colorScheme: colorScheme,
          ),
        ),
      ],
    );
  }

  Future<void> _downloadSelected() async {
    final selected = _selectedTracks;
    if (selected.isEmpty) return;
    await queueTracksSkippingDownloaded(
      context,
      ref,
      selected,
      artistNameForPicker: _playlistName,
      recommendedService: widget.recommendedService,
      forceQualityPicker: true,
      onQueued: exitSelectionMode,
    );
  }

  String? _metadataProviderId(String playlistId) {
    final providerId = resolvePreferredMetadataProviderId(
      widget.metadataProviderId,
      playlistId,
    );
    if (providerId == null) return null;
    final effective = resolveEffectiveMetadataProvider(
      providerId,
      ref.read(extensionProvider),
    );
    return effective.isEmpty ? null : effective;
  }

  String _metadataResourceId(String providerId, String playlistId) {
    return stripPrefixedResourceId(playlistId);
  }

  String? _recommendedDownloadService() {
    final explicit = widget.recommendedService;
    if (explicit != null && explicit.isNotEmpty) {
      return explicit;
    }

    final playlistId = widget.playlistId;
    if (playlistId != null) {
      final providerId = _metadataProviderId(playlistId);
      if (providerId != null && providerId.isNotEmpty) {
        return resolveEffectiveDownloadService(
          providerId,
          ref.read(extensionProvider),
        );
      }
    }

    final source = _tracks.firstOrNull?.source;
    if (source != null && source.isNotEmpty) {
      return source;
    }

    final trackId = _tracks.firstOrNull?.id ?? '';
    final trackProviderId = legacyProviderIdFromResourceId(trackId);
    if (trackProviderId != null) {
      return resolveEffectiveDownloadService(
        trackProviderId,
        ref.read(extensionProvider),
      );
    }
    return null;
  }

  @override
  void initState() {
    super.initState();
    _fetchTracksIfNeeded();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _fetchTracksIfNeeded() async {
    if (widget.tracks.isNotEmpty || widget.playlistId == null) return;

    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      String playlistId = widget.playlistId!;
      late final Map<String, dynamic> result;
      final providerId = _metadataProviderId(playlistId);
      if (providerId != null) {
        result = await PlatformBridge.getProviderMetadata(
          providerId,
          'playlist',
          _metadataResourceId(providerId, playlistId),
        );
      } else {
        result = await PlatformBridge.getProviderMetadata(
          'deezer',
          'playlist',
          playlistId,
        );
      }
      if (!mounted) return;

      final playlistInfo = result['playlist_info'] as Map<String, dynamic>?;
      final owner = playlistInfo?['owner'] as Map<String, dynamic>?;
      final resolvedPlaylistName =
          (playlistInfo?['name'] ?? owner?['name'])?.toString() ??
          _playlistName;

      final trackList = result['track_list'] as List<dynamic>? ?? [];
      final tracks = trackList
          .map(
            (t) => Track.fromBackendMap(
              t as Map<String, dynamic>,
              playlistName: resolvedPlaylistName,
            ),
          )
          .toList();

      final headerVideo = playlistInfo?['header_video']?.toString();

      setState(() {
        _fetchedTracks = tracks;
        _cachedVisibleTrackIndices = null;
        _resolvedPlaylistName = resolvedPlaylistName;
        _resolvedCoverUrl = (playlistInfo?['images'] ?? owner?['images'])
            ?.toString();
        _resolvedHeaderVideoUrl =
            (headerVideo != null && headerVideo.isNotEmpty)
            ? headerVideo
            : _resolvedHeaderVideoUrl;
        _isLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = context.friendlyError(e);
        _isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (context.isMornye) {
      return MornyeArtistSurface(
        imageSource: _coverUrl,
        neutralActions: true,
        child: Builder(builder: _buildPage),
      );
    }
    return _buildPage(context);
  }

  Widget _buildPage(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final bottomPadding = isSelectionMode
        ? MediaQuery.paddingOf(context).bottom
        : 0.0;

    pruneSelection({
      for (var index = 0; index < _tracks.length; index++)
        _trackSelectionId(_tracks[index], index),
    });

    return LibraryFastScroller(
      minScreens: 1.0,
      topPadding: MediaQuery.paddingOf(context).top + kToolbarHeight,
      labelAt: (fraction) {
        final indices = _visibleTrackIndices;
        if (indices.isEmpty) return null;
        final position = (fraction * indices.length)
            .floor()
            .clamp(0, indices.length - 1);
        final track = _tracks[indices[position]];
        return track.name.isNotEmpty ? track.name : track.artistName;
      },
      child: CollectionScaffold(
        scrollController: scrollController,
        isSelectionMode: isSelectionMode,
        onExitSelectionMode: exitSelectionMode,
        selectionBar: _buildSelectionBottomBar(
          context,
          colorScheme,
          bottomPadding,
        ),
        appBar: _buildAppBar(context, colorScheme),
        slivers: [
          if (_showSearch) _buildSearchField(context),
          _buildTrackList(context, colorScheme),
          _buildPlaylistFooter(context, colorScheme),
        ],
      ),
    );
  }

  Widget _buildSearchField(BuildContext context) {
    return SliverToBoxAdapter(
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          16 + wideListInset(context),
          12,
          16 + wideListInset(context),
          8,
        ),
        child: TextField(
          controller: _searchController,
          autofocus: true,
          onChanged: _onSearchChanged,
          textInputAction: TextInputAction.search,
          decoration: InputDecoration(
            hintText:
                '${context.l10n.searchSongs}, ${context.l10n.searchAlbums}, ${context.l10n.searchArtists}',
            prefixIcon: const Icon(Icons.search),
            suffixIcon: _searchQuery.isEmpty
                ? null
                : IconButton(
                    tooltip: context.l10n.dialogClear,
                    icon: const Icon(Icons.close),
                    onPressed: () {
                      _searchController.clear();
                      _onSearchChanged('');
                    },
                  ),
            filled: true,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(16),
              borderSide: BorderSide.none,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildAppBar(BuildContext context, ColorScheme colorScheme) {
    final expandedHeight = calculateExpandedHeight(context);
    final cacheWidth = coverCacheWidthForViewport(context);
    final motionUrl = _headerVideoUrl;
    final hasMotion =
        motionUrl != null &&
        motionUrl.trim().isNotEmpty &&
        Uri.tryParse(motionUrl)?.hasAuthority == true;
    Widget playlistPlaceholder({double? size}) {
      return Container(
        color: colorScheme.surfaceContainerHighest,
        child: Icon(
          Icons.playlist_play,
          size: size ?? 80,
          color: colorScheme.onSurfaceVariant,
        ),
      );
    }

    final Widget coverImage = _coverUrl != null
        ? CachedCoverImage(
            imageUrl: highResCoverUrl(_coverUrl) ?? _coverUrl!,
            fit: BoxFit.cover,
            memCacheWidth: cacheWidth,
            placeholder: (_, _) => Container(color: colorScheme.surface),
            errorWidget: (_, _, _) => Container(color: colorScheme.surface),
          )
        : playlistPlaceholder();

    return AlbumDetailHeader(
      title: _playlistName,
      appBarActions: [
        IconButton(
          tooltip: 'Search this playlist',
          icon: Icon(_showSearch ? Icons.search_off : Icons.search),
          onPressed: _toggleSearch,
        ),
        Consumer(
          builder: (context, ref, _) {
            final item = ref.watch(currentMediaItemProvider).value;
            final canLocate =
                item != null && _findCurrentTrackIndex(item) >= 0;
            return IconButton(
              tooltip: 'Jump to currently playing track',
              icon: const Icon(Icons.my_location),
              onPressed: canLocate ? _jumpToCurrentTrack : null,
            );
          },
        ),
      ],
      immersive: context.isMornye,
      squareArtwork: !hasMotion,
      expandedHeight: expandedHeight,
      showTitleInAppBar: showTitleInAppBar,
      background: hasMotion
          ? MotionHeaderBanner(videoUrl: motionUrl, fallback: coverImage)
          : coverImage,
      paletteSource: _coverUrl,
      blurAndScrimBackground: !hasMotion && _coverUrl != null,
      coverBuilder: hasMotion
          ? null
          : (context, coverSize) => _coverUrl != null
                ? DownloadableCover(
                    coverUrl: highResCoverUrl(_coverUrl) ?? _coverUrl,
                    baseName: _playlistName,
                    child: CachedCoverImage(
                      imageUrl: highResCoverUrl(_coverUrl) ?? _coverUrl!,
                      fit: BoxFit.cover,
                      memCacheWidth: cacheWidth,
                      placeholder: (_, _) => playlistPlaceholder(),
                      errorWidget: (_, _, _) => playlistPlaceholder(size: 48),
                    ),
                  )
                : playlistPlaceholder(size: 48),
      meta: HeaderMetaRow(
        items: [
          HeaderMetaItem(
            context.l10n.tracksCount(_tracks.length),
            icon: Icons.playlist_play,
          ),
        ],
      ),
      actions: context.isMornye
          ? Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                _buildLoveAllButton(),
                const SizedBox(width: 16),
                Flexible(
                  child: SizedBox(
                    width: 172,
                    child: _buildDownloadAllCenterButton(context),
                  ),
                ),
                const SizedBox(width: 16),
                _buildAddToPlaylistButton(context),
              ],
            )
          : ExpressiveButtonGroup(
              flexible: const {1},
              children: [
                _buildLoveAllButton(),
                _buildDownloadAllCenterButton(context),
                _buildAddToPlaylistButton(context),
              ],
            ),
    );
  }

  Widget _buildPlaylistFooter(BuildContext context, ColorScheme colorScheme) =>
      buildTrackListFooter(
        context,
        colorScheme,
        _tracks,
        excludeEpochReleaseDate: true,
      );

  Widget _buildTrackList(BuildContext context, ColorScheme colorScheme) {
    if (_isLoading) {
      // The skeleton rows carry the list's own inset.
      return const SliverToBoxAdapter(child: TrackListSkeleton(itemCount: 8));
    }

    if (_error != null) {
      return SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: ErrorCard(
            error: _error!,
            colorScheme: colorScheme,
            onRetry: _fetchTracksIfNeeded,
          ),
        ),
      );
    }

    if (_tracks.isEmpty) {
      return SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Center(
            child: Text(
              context.l10n.errorNoTracksFound,
              style: TextStyle(color: colorScheme.onSurfaceVariant),
            ),
          ),
        ),
      );
    }

    final visibleIndices = _visibleTrackIndices;
    if (visibleIndices.isEmpty) {
      return SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Center(child: Text(context.l10n.errorNoTracksFound)),
        ),
      );
    }
    final visibleTracks = [
      for (final originalIndex in visibleIndices) _tracks[originalIndex],
    ];
    _historySnapshot.update(visibleTracks);
    final historyLookups = _historySnapshot.lookups;
    final existingHistoryKeys = ref.watch(
      downloadHistoryVisibleBatchExistsProvider(_historySnapshot.request),
    );
    return SliverPadding(
      padding: EdgeInsets.symmetric(horizontal: wideListInset(context)),
      sliver: SliverList(
        delegate: SliverChildBuilderDelegate((context, index) {
          final originalIndex = visibleIndices[index];
          final track = _tracks[originalIndex];
          final selectionId = _trackSelectionId(track, originalIndex);
          final isInHistory = existingHistoryKeys.contains(
            historyLookups[index].lookupKey,
          );
          return KeyedSubtree(
            key: originalIndex == _jumpTargetIndex && _jumpTargetKey != null
                ? _jumpTargetKey
                : ValueKey(selectionId),
            child: StaggeredListItem(
              index: index,
              child: TrackListTile(
                track: track,
                isInHistory: isInHistory,
                isSelectionMode: isSelectionMode,
                isSelected: selectedIds.contains(selectionId),
                onToggleSelection: () => toggleSelection(selectionId),
                onEnterSelectionMode: () => enterSelectionMode(selectionId),
                onDownload: ({bool forceQualityPicker = false}) =>
                    _downloadTrack(
                      context,
                      track,
                      playlistPosition: originalIndex + 1,
                      forceQualityPicker: forceQualityPicker,
                    ),
                leading: track.coverUrl != null
                    ? DownloadableCover(
                        coverUrl: track.coverUrl,
                        baseName: '${track.artistName} - ${track.name}',
                        enabled: !isSelectionMode,
                        child: CachedCoverImage(
                          imageUrl: track.coverUrl!,
                          width: 48,
                          height: 48,
                          borderRadius: BorderRadius.circular(8),
                        ),
                      )
                    : Container(
                        width: 48,
                        height: 48,
                        decoration: BoxDecoration(
                          color: Theme.of(
                            context,
                          ).colorScheme.surfaceContainerHighest,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Icon(
                          Icons.music_note,
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
              ),
            ),
          );
        }, childCount: visibleIndices.length),
      ),
    );
  }

  void _downloadTrack(
    BuildContext context,
    Track track, {
    int? playlistPosition,
    bool forceQualityPicker = false,
  }) {
    downloadSingleTrack(
      context,
      ref,
      track,
      recommendedService: _recommendedDownloadService(),
      playlistName: _playlistName,
      playlistPosition: playlistPosition,
      forceQualityPicker: forceQualityPicker,
    );
  }

  Widget _buildLoveAllButton() {
    return Consumer(
      builder: (context, ref, _) {
        ref.watch(libraryCollectionsProvider.select((state) => state.loved));
        final collectionsState = ref.read(libraryCollectionsProvider);
        final allLoved =
            _tracks.isNotEmpty &&
            _tracks.every((t) => collectionsState.isLoved(t));
        return HeaderCircleButton(
          icon: allLoved ? Icons.favorite : Icons.favorite_border,
          tonal: true,
          iconColor: allLoved ? Theme.of(context).colorScheme.error : null,
          tooltip: allLoved
              ? context.l10n.trackOptionRemoveFromLoved
              : context.l10n.tooltipLoveAll,
          onPressed: _tracks.isEmpty ? null : () => _loveAll(_tracks),
        );
      },
    );
  }

  Widget _buildDownloadAllCenterButton(BuildContext context) {
    return HeaderFilledButton(
      icon: context.isMornye
          ? CupertinoIcons.arrow_down_circle_fill
          : Icons.download_rounded,
      tonal: true,
      label: context.isMornye
          ? context.l10n.dialogDownload
          : context.l10n.downloadAllCount(_tracks.length),
      onPressed: _tracks.isEmpty ? null : () => _confirmDownloadAll(context),
    );
  }

  Widget _buildAddToPlaylistButton(BuildContext context) {
    return HeaderCircleButton(
      icon: Icons.playlist_add,
      tonal: true,
      tooltip: context.l10n.tooltipAddToPlaylist,
      onPressed: _tracks.isEmpty
          ? null
          : () => showAddTracksToPlaylistSheet(
              context,
              ref,
              _tracks,
              playlistNamePrefill: widget.playlistName,
              preserveOccurrences: true,
            ),
    );
  }

  void _confirmDownloadAll(BuildContext context) {
    confirmDownloadAllDialog(
      context,
      _tracks.length,
      () => _downloadAll(context),
    );
  }

  Future<void> _loveAll(List<Track> tracks) =>
      loveAllTracks(context, ref, tracks);

  void _downloadAll(BuildContext context) {
    _downloadTracks(context, _tracks);
  }

  Future<void> _downloadTracks(BuildContext context, List<Track> tracks) async {
    await queueTracksSkippingDownloaded(
      context,
      ref,
      tracks,
      artistNameForPicker: _playlistName,
      recommendedService: _recommendedDownloadService(),
      playlistName: _playlistName,
      resolveDefaultService: false,
    );
  }
}
