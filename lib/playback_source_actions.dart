part of 'app.dart';

enum PlaybackSourceChangeKind { quality, source, external }

class PlaybackSourceChange {
  const PlaybackSourceChange(this.kind, this.cancelToken, this.statusText);
  final PlaybackSourceChangeKind kind;
  final SearchCancelToken cancelToken;
  final String statusText;
}

final playbackSourceChangeProvider =
    StateProvider<PlaybackSourceChange?>((ref) => null);

final _sourceRecoverySnapshotProvider =
    StateProvider<_SourcePlaybackSnapshot?>((ref) {
  ref.watch(activePlaySpecProvider);
  return null;
});

/// Preferences live only as long as the current configuration, keyed by site.
final playbackQualityPreferencesProvider =
    StateProvider<Map<String, String>>((ref) {
  ref.watch(vodConfigProvider);
  return const {};
});

final switchPlaybackQualityProvider = Provider<Future<void> Function(int)>(
    (ref) => (index) => _switchPlaybackQuality(ref, index));

final switchLiveLineProvider = Provider<Future<void> Function(int)>(
    (ref) => (index) => _switchLiveLine(ref, index));

typedef PlaybackSourceChooser = Future<CrossSiteCandidate?> Function(
    List<CrossSiteCandidate> candidates);

final switchPlaybackSourceProvider = Provider<
    Future<void> Function(PlaybackSourceChooser,
        {CrossSiteCandidate? preselect})>((ref) => (choose, {preselect}) =>
    _switchPlaybackSource(ref, choose, preselect: preselect));

/// 直接切到某个已知候选（选集抽屉「其他来源」点击时用）：不重新搜索。
final switchToSourceCandidateProvider =
    Provider<Future<void> Function(CrossSiteCandidate)>((ref) => (candidate) =>
        _switchPlaybackSource(ref, (_) async => null, preselect: candidate));

/// 选集抽屉「其他来源」的自动搜索控制器。
///
/// 抽屉每次打开调用 [SourceCandidatesController.ensure]：同一集已经搜过就复用结果，
/// 换集或手动刷新才重新搜。结果按延迟升序，供抽屉直接展示。
class SourceCandidatesController extends StateNotifier<SourceCandidatesState> {
  SourceCandidatesController(this._ref) : super(const SourceCandidatesState());

  final Ref _ref;
  SearchCancelToken? _token;
  String? _inFlightKey;

  @override
  void dispose() {
    _token?.cancel();
    super.dispose();
  }

  /// 抽屉打开时调用：同一集搜过就不再打扰站点。
  Future<void> ensure(String episodeKey) async {
    if (_inFlightKey == episodeKey) return;
    if (state.searched && state.episodeKey == episodeKey) return;
    await refresh(episodeKey);
  }

  Future<void> refresh(String episodeKey) async {
    _token?.cancel();
    final token = SearchCancelToken();
    _token = token;
    _inFlightKey = episodeKey;
    state = SourceCandidatesState(searching: true, episodeKey: episodeKey);

    final session = _sourceSearchContext(_ref);
    if (session == null || session.site == null || session.episodes.isEmpty) {
      _inFlightKey = null;
      state = SourceCandidatesState(
        searched: true,
        episodeKey: episodeKey,
        message: '当前会话不支持跨站换源',
      );
      return;
    }

    var message = '';
    try {
      final result = await CrossSiteSearchService(
              searchEngine: _ref.read(searchEngineProvider),
              siteApi: _ref.read(siteApiProvider),
              // 抽屉要「尽量列全」：默认只探 3 个候选，这里放到 8 个。
              maxCandidates: 8)
          .search(
        target: CrossSiteTarget(
          item: session.item,
          episodeName: session.episodes[session.index].name,
          episodeCount: session.episodes.length,
          siteKey: session.site!.key,
        ),
        sites: _ref.read(configRepositoryProvider).currentVodConfig.sites,
        cancelToken: token,
      );
      if (!identical(_token, token) || token.isCancelled) return;
      final sorted = sortCandidatesByLatency(result.candidates);
      message = sorted.isNotEmpty
          ? ''
          : switch (result.status) {
              CrossSiteSearchStatus.timedOut => '搜索超时，请稍后重试',
              CrossSiteSearchStatus.failed => '站点查找失败',
              CrossSiteSearchStatus.cancelled => '',
              CrossSiteSearchStatus.completed => '没有找到可信的同片同集',
            };
      state = SourceCandidatesState(
        searched: true,
        candidates: sorted,
        episodeKey: episodeKey,
        message: message.isEmpty ? null : message,
      );
      if (sorted.isNotEmpty) {
        // 照 KimBoxPC 的做法：列表先出来，后台逐条体检可播性，回来后重排。
        unawaited(_probeCandidates(token, episodeKey, sorted));
      }
    } catch (_) {
      if (!identical(_token, token) || token.isCancelled) return;
      state = SourceCandidatesState(
        searched: true,
        episodeKey: episodeKey,
        message: '站点查找失败',
      );
    } finally {
      if (identical(_token, token)) _inFlightKey = null;
    }
  }

  /// 后台逐条体检「这条来源到底能不能播」：解析一次 + 判断返回的是不是媒体。
  ///
  /// 照 KimBoxPC 的做法（`/api/sites/ping` + `probeMedia`）：列表先出来，体验结果陆续回填，
  /// 可用 / 不可用会重排。并发 3，单条 8 秒上限，全部失败也不会拖住界面。
  Future<void> _probeCandidates(SearchCancelToken token, String episodeKey,
      List<CrossSiteCandidate> candidates) async {
    var cursor = 0;
    Future<void> worker() async {
      while (true) {
        if (!identical(_token, token) || token.isCancelled) return;
        final index = cursor++;
        if (index >= candidates.length) return;
        final candidate = candidates[index];
        final probe = await _probe(candidate);
        if (!identical(_token, token) || token.isCancelled) return;
        if (state.episodeKey != episodeKey) return;
        final probes = Map<String, SourceProbe>.of(state.probes);
        probes[sourceCandidateKey(candidate)] = probe;
        state = state.copyWith(
          probes: probes,
          candidates: sortCandidatesByProbe(state.candidates, probes),
        );
      }
    }

    await Future.wait([for (var i = 0; i < 3; i++) worker()]);
  }

  Future<SourceProbe> _probe(CrossSiteCandidate candidate) async {
    final attempt = resolveLineAttempts(candidate).first;
    final watch = Stopwatch()..start();
    try {
      final config = _ref.read(configRepositoryProvider).currentVodConfig;
      final spec = await _ref
          .read(siteApiProvider)
          .resolvePlayback(
            candidate.site,
            id: attempt.episode.url,
            flag: attempt.lineName,
            preferredQualityName: _ref
                .read(playbackQualityPreferencesProvider)[candidate.site.key],
            parseEngine: _ref.read(parseEngineProvider),
            parses: config.parses,
          )
          .timeout(const Duration(seconds: 8));
      watch.stop();
      if (!await _looksLikeMediaUrl(spec.url, spec.headers ?? const {})) {
        return SourceProbe(
            ok: false, ms: watch.elapsedMilliseconds, reason: '网页直链');
      }
      return SourceProbe(ok: true, ms: watch.elapsedMilliseconds);
    } on TimeoutException {
      watch.stop();
      return SourceProbe(
          ok: false, ms: watch.elapsedMilliseconds, reason: '解析超时');
    } catch (error) {
      watch.stop();
      return SourceProbe(
          ok: false, ms: watch.elapsedMilliseconds, reason: _shortFailure(error));
    }
  }
}

final sourceCandidatesProvider =
    StateNotifierProvider<SourceCandidatesController, SourceCandidatesState>(
        (ref) => SourceCandidatesController(ref));

bool _sourceChangeBlocked(Ref ref) =>
    ref.read(playbackSourceChangeProvider) != null ||
    ref.read(playerRefreshBusyProvider) ||
    ref.read(playerAutoSwitchBusyProvider) ||
    (ref.read(activePlaybackSessionProvider)?.switching ?? false);

class _SourceChangeOwner {
  _SourceChangeOwner(this.ref, this.kind)
      : epoch = ++_playbackSessionEpoch,
        config = ref.read(configRepositoryProvider).currentVodConfig,
        siteKey = ref.read(configRepositoryProvider).selectedSite?.key,
        cancelToken = SearchCancelToken() {
    ref.read(playbackSourceChangeProvider.notifier).state =
        PlaybackSourceChange(kind, cancelToken, '正在查找…');
    final autoLine = ref.read(autoLineSwitchProvider);
    if (kind == PlaybackSourceChangeKind.external) {
      // invariant: external launch preserves the existing early-error window and timer.
      autoLine.rebindEpoch(epoch);
    } else {
      autoLine.disarm();
    }
    _configSubscription = ref.listen(vodConfigProvider, (_, next) {
      if (!identical(config, next)) cancelToken.cancel();
    });
    _siteSubscription = ref.listen(currentSiteProvider, (_, next) {
      if (next?.key != siteKey) cancelToken.cancel();
    });
    _timer = Timer.periodic(const Duration(milliseconds: 100), (_) {
      if (!isCurrent) cancelToken.cancel();
    });
    ref.onDispose(() {
      if (_disposed) return;
      _disposed = true;
      _closeSubscriptions();
      cancelToken.cancel();
    });
  }

  final Ref ref;
  final PlaybackSourceChangeKind kind;
  final int epoch;
  final VodConfig config;
  final String? siteKey;
  final SearchCancelToken cancelToken;
  late final Timer _timer;
  late final ProviderSubscription<VodConfig> _configSubscription;
  late final ProviderSubscription<Site?> _siteSubscription;

  bool _disposed = false;

  // invariant: context cancellation still permits rollback until new playback owns the engine.
  bool get ownsPlayback =>
      !_disposed &&
      epoch == _playbackSessionEpoch &&
      identical(
          ref.read(playbackSourceChangeProvider)?.cancelToken, cancelToken);
  bool get isCurrent =>
      ownsPlayback &&
      !cancelToken.isCancelled &&
      identical(config, ref.read(configRepositoryProvider).currentVodConfig) &&
      siteKey == ref.read(configRepositoryProvider).selectedSite?.key;

  void status(String text) {
    final current = ref.read(playbackSourceChangeProvider);
    if (identical(current?.cancelToken, cancelToken)) {
      ref.read(playbackSourceChangeProvider.notifier).state =
          PlaybackSourceChange(current!.kind, cancelToken, text);
    }
  }

  Future<T> wait<T>(Future<T> future) {
    final cancelled = Completer<T>();
    cancelToken.onCancel(() {
      if (!cancelled.isCompleted) {
        cancelled.completeError(const PlaybackSourceCancelled());
      }
    });
    return Future.any([future, cancelled.future]);
  }

  void _closeSubscriptions() {
    _timer.cancel();
    _configSubscription.close();
    _siteSubscription.close();
  }

  void dispose({bool rearm = true}) {
    if (_disposed) return;
    final owned = ownsPlayback;
    _closeSubscriptions();
    if (identical(
        ref.read(playbackSourceChangeProvider)?.cancelToken, cancelToken)) {
      ref.read(playbackSourceChangeProvider.notifier).state = null;
    }
    _disposed = true;
    if (owned && rearm && ref.read(_sourceRecoverySnapshotProvider) == null) {
      if (kind == PlaybackSourceChangeKind.external) {
        ref.read(autoLineSwitchProvider).resumePendingAttempt();
      } else {
        _armSourceSession(ref);
      }
    }
  }
}

void _armSourceSession(Ref ref) {
  final session = ref.read(activePlaybackSessionProvider);
  if (session == null ||
      session.episodes.isEmpty ||
      ref.read(activePlaySpecProvider)?.isLive != false) {
    return;
  }
  ref.read(autoLineSwitchProvider).arm(
        sources: session.sources,
        currentSourceIndex: session.sourceIndex,
        currentSourceName: session.sourceName,
        episodeName: session.episodes[session.index].name,
        currentEpisodeUrl: session.episodes[session.index].url,
        tried: session.triedLines,
        epoch: _playbackSessionEpoch,
        startPosition: ref.read(playerEngineProvider).position,
      );
}

/// Snapshotted immediately before replacing the source, after a search ends.
class _SourcePlaybackSnapshot {
  factory _SourcePlaybackSnapshot(Ref ref) =>
      ref.read(_sourceRecoverySnapshotProvider) ??
      _SourcePlaybackSnapshot._(ref);

  _SourcePlaybackSnapshot._(Ref ref)
      : spec = ref.read(activePlaySpecProvider),
        liveCatalog = _LiveCatalogPlaybackSnapshot(
            ref.read(activePlaySpecProvider), ref.read(liveRuntimeProvider)),
        recordId = ref.read(playbackHistoryTrackerProvider).activeRecordId,
        position = ref.read(playerEngineProvider).position,
        rate = ref.read(playerEngineProvider).rate,
        volume = ref.read(playerEngineProvider).volume,
        paused = _sourceIsPaused(ref.read(playerEngineProvider));

  final MediaPlaySpec? spec;
  final _LiveCatalogPlaybackSnapshot liveCatalog;
  final String? recordId;
  final Duration position;
  final double rate;
  final double volume;
  final bool paused;

  Future<void> open(MpvPlayerEngine engine, MediaPlaySpec target,
      {required bool Function() ownsPlayback}) async {
    if (!ownsPlayback()) throw const PlaybackSourceCancelled();
    if (engine.runtimeType == MpvPlayerEngine) {
      await engine.switchSource(target);
    } else {
      // Tests and alternate adapters retain the base PlayerEngine contract.
      await engine.play(target);
    }
    bool ownsTarget() =>
        ownsPlayback() && identical(engine.currentSpec, target);
    if (!ownsTarget()) return;
    await engine.setRate(rate);
    if (!ownsTarget()) return;
    await engine.setVolume(volume);
    if (!ownsTarget()) return;
    if (paused) await engine.pause();
  }

  Future<void> restore(Ref ref, _SourceChangeOwner owner) async {
    if (!owner.ownsPlayback) return;
    owner.status('正在恢复原播放…');
    final engine = ref.read(playerEngineProvider);
    final original = spec;
    if (original == null) {
      await engine.stop();
      return;
    }
    final rollback = original.copyWith(
        startPosition: original.isLive ? Duration.zero : position);
    try {
      await PlaybackSourceLoader(
              engine: engine,
              open: (s) =>
                  open(engine, s, ownsPlayback: () => owner.ownsPlayback))
          .load(rollback, isCurrent: () => owner.ownsPlayback);
      if (!owner.ownsPlayback) return;
      final committed = liveCatalog.rebase(rollback, ref.read(liveRuntimeProvider));
      ref.read(liveRuntimeProvider.notifier).state = committed.runtime;
      ref.read(activePlaySpecProvider.notifier).state = committed.spec;
      resumeTracking(ref);
    } catch (_) {
      if (owner.ownsPlayback) {
        // invariant: failed media cannot write progress; refresh retains the saved record and position.
        ref.read(_sourceRecoverySnapshotProvider.notifier).state = this;
        ref.read(lineSwitchNoticeProvider.notifier).state =
            '原播放也未能恢复，请刷新或重新选择来源';
      }
    }
  }

  void resumeTracking(Ref ref) =>
      ref.read(playbackHistoryTrackerProvider).track(recordId,
          flushPrevious: false,
          baseline: position,
          floor: position > Duration.zero ? position : null);
}

bool _sourceIsPaused(MpvPlayerEngine engine) =>
    engine.runtimeType == MpvPlayerEngine
        ? engine.isPlaybackPaused
        : engine.status == PlaybackStatus.paused;

Future<void> _switchLiveLine(Ref ref, int index) async {
  final previous = ref.read(activePlaySpecProvider);
  final runtime = ref.read(liveRuntimeProvider);
  final session = ref.read(activePlaybackSessionProvider);
  if (_sourceChangeBlocked(ref) || previous == null ||
      index < 0 || index >= previous.qualities.length ||
      index == previous.qualityIndex) {
    return;
  }
  final scriptedRoom = previous.isLive &&
      previous.liveDanmakuSources.isNotEmpty && session != null;
  if (!scriptedRoom && _livePlayingIndex(previous, runtime) < 0) return;
  final owner = _SourceChangeOwner(ref, PlaybackSourceChangeKind.quality);
  final selected = previous.qualities[index];
  _SourcePlaybackSnapshot? snapshot;
  var opened = false;
  try {
    owner.status('正在切换到${selected.name}…');
    var target = scriptedRoom
        ? await owner.wait(ref.read(siteApiProvider).resolveQuality(previous,
            index: index,
            flag: session.sourceName,
            parseEngine: ref.read(parseEngineProvider),
            parses: owner.config.parses).timeout(const Duration(seconds: 20)))
        : previous.copyWith(
            url: selected.url,
            headers: selected.headers,
            qualityIndex: index,
          );
    if (!owner.isCurrent) return;
    snapshot = _SourcePlaybackSnapshot(ref);
    target = target.copyWith(
        startPosition: target.isLive ? Duration.zero : snapshot.position);
    final engine = ref.read(playerEngineProvider);
    opened = true;
    await PlaybackSourceLoader(
      engine: engine,
      open: (spec) => snapshot!.open(engine, spec,
          ownsPlayback: () => owner.ownsPlayback),
    ).load(target, isCurrent: () => owner.isCurrent);
    if (!owner.isCurrent) throw const PlaybackSourceCancelled();
    final committed = snapshot.liveCatalog.rebase(target, ref.read(liveRuntimeProvider));
    ref.read(liveRuntimeProvider.notifier).state = committed.runtime;
    ref.read(activePlaySpecProvider.notifier).state = committed.spec;
    ref.read(lineSwitchNoticeProvider.notifier).state = '已切换到${selected.name}';
  } catch (error) {
    if (owner.ownsPlayback) {
      ref.read(lineSwitchNoticeProvider.notifier).state =
          error is PlaybackSourceCancelled ? '已取消切换' : '直播线路切换失败';
      if (opened && snapshot != null) await snapshot.restore(ref, owner);
    }
  } finally {
    owner.dispose(rearm: false);
  }
}

Future<void> _switchPlaybackQuality(Ref ref, int index) async {
  final previous = ref.read(activePlaySpecProvider);
  final session = ref.read(activePlaybackSessionProvider);
  if (_sourceChangeBlocked(ref) ||
      previous == null ||
      session == null ||
      previous.isLive ||
      index < 0 ||
      index >= previous.qualities.length ||
      index == previous.qualityIndex) {
    return;
  }
  final owner = _SourceChangeOwner(ref, PlaybackSourceChangeKind.quality);
  final name = previous.qualities[index].name;
  final api = ref.read(siteApiProvider);
  _SourcePlaybackSnapshot? snapshot;
  var opened = false;
  try {
    owner.status('正在切换到$name…');
    var target = await owner.wait(api
        .resolveQuality(previous,
            index: index,
            flag: session.sourceName,
            parseEngine: ref.read(parseEngineProvider),
            parses: owner.config.parses)
        .timeout(const Duration(seconds: 20)));
    if (!owner.isCurrent) return;
    snapshot = _SourcePlaybackSnapshot(ref);
    final tracker = ref.read(playbackHistoryTrackerProvider);
    await tracker.flush();
    if (!owner.isCurrent) return;
    tracker.track(null, flushPrevious: false);
    target = target.copyWith(startPosition: snapshot.position);
    final engine = ref.read(playerEngineProvider);
    final loader = PlaybackSourceLoader(
        engine: engine,
        open: (s) =>
            snapshot!.open(engine, s, ownsPlayback: () => owner.ownsPlayback));
    opened = true;
    try {
      await loader.load(target, isCurrent: () => owner.isCurrent);
    } catch (error) {
      if (!owner.isCurrent || !isExpiredPlaybackUrl(error)) rethrow;
      owner.status('地址已过期，正在刷新$name…');
      target = await owner.wait(api
          .resolvePlayback(session.site,
              id: session.episodes[session.index].url,
              flag: session.sourceName,
              preferredQualityName: name,
              parseEngine: ref.read(parseEngineProvider),
              parses: owner.config.parses)
          .timeout(const Duration(seconds: 20)));
      // A removed quality must not silently become a different selection.
      if (target.qualities.isEmpty ||
          target.qualities[target.qualityIndex].name != name) {
        throw const PlaybackSourceFailure('原清晰度已不可用');
      }
      if (!owner.isCurrent) throw const PlaybackSourceCancelled();
      target = target.copyWith(
          title: previous.title, startPosition: snapshot.position);
      await loader.load(target, isCurrent: () => owner.isCurrent);
    }
    if (!owner.isCurrent) throw const PlaybackSourceCancelled();
    ref.read(activePlaySpecProvider.notifier).state = target;
    snapshot.resumeTracking(ref);
    final siteKey = session.site?.key;
    if (siteKey != null) {
      ref.read(playbackQualityPreferencesProvider.notifier).state = {
        ...ref.read(playbackQualityPreferencesProvider),
        siteKey: name,
      };
    }
    final recordId = snapshot.recordId;
    if (recordId != null) {
      unawaited(ref.read(configRepositoryProvider).updateHistorySource(recordId,
          sourceName: session.sourceName,
          playUrl: target.url,
          episodeUrl: session.episodes[session.index].url));
    }
    ref.read(lineSwitchNoticeProvider.notifier).state = '已切换到$name';
  } catch (error) {
    if (owner.ownsPlayback) {
      ref.read(lineSwitchNoticeProvider.notifier).state =
          error is PlaybackSourceCancelled ? '已取消切换' : '清晰度切换失败';
      if (opened && snapshot != null) await snapshot.restore(ref, owner);
    }
  } finally {
    owner.dispose();
  }
}

PlaybackSession? _sourceSearchContext(Ref ref) {
  final pending = ref.read(pendingPlayProvider);
  if (ref.read(playbackIntentProvider)?.isFailed == true && pending != null) {
    final selection = pending.selection;
    return PlaybackSession(
        item: pending.item,
        sourceName: selection.sourceName,
        episodes: selection.episodes,
        index: selection.index,
        site: pending.site ?? ref.read(configRepositoryProvider).selectedSite,
        sources: selection.sources,
        sourceIndex: selection.sourceIndex);
  }
  return ref.read(activePlaybackSessionProvider);
}

/// 失败提示用的短原因：只取首行、去掉 URL，避免把源站地址打到界面上。
String _shortFailure(Object error) {
  var text = '$error'.split('\n').first.trim();
  text = text.replaceAll(RegExp(r'https?://\S+'), '<地址>');
  if (text.length > 60) text = '${text.substring(0, 60)}…';
  return text.isEmpty ? '未知错误' : text;
}

/// 已知媒体后缀：直接放行，不做探测。
bool _hasMediaExtension(String url) {
  final path = Uri.tryParse(url)?.path.toLowerCase() ?? '';
  const suffixes = [
    '.m3u8', '.m3u', '.mp4', '.m4v', '.ts', '.flv',
    '.mkv', '.webm', '.mov', '.mp3', '.m4a', '.aac', '.mpd',
  ];
  return suffixes.any(path.endsWith);
}

/// 这个地址到底是媒体流还是网页？
///
/// 站点把「需要解析的网页」当直链返回时，mpv 会报 `Failed to recognize file format.`。
/// 在这里先用 HEAD 探一次 Content-Type：是网页就让这条线路失败、换同站下一条线路。
/// **探测失败（超时 / 405 / 没给 Content-Type）一律放行**——绝不因为探测把能播的源拦掉。
Future<bool> _looksLikeMediaUrl(String url, Map<String, String> headers) async {
  if (_hasMediaExtension(url)) return true;
  final uri = Uri.tryParse(url);
  if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https')) return true;
  final client = HttpClientFactory.createHttpClient(
    connectionTimeout: const Duration(seconds: 4),
    idleTimeout: HttpClientFactory.dioDefaultIdleTimeout,
    proxy: DanmakuApi.systemProxy,
  );
  try {
    final request =
        await client.headUrl(uri).timeout(const Duration(seconds: 4));
    headers.forEach(request.headers.set);
    final response = await request.close().timeout(const Duration(seconds: 4));
    final mime = response.headers.contentType?.mimeType.toLowerCase() ?? '';
    try {
      await response.drain<void>();
    } catch (_) {
      // 丢弃响应体失败不影响结论。
    }
    if (mime.isEmpty) return true;
    if (mime.startsWith('video/') || mime.startsWith('audio/')) return true;
    if (mime.contains('mpegurl')) return true;
    if (mime == 'application/octet-stream' || mime == 'binary/octet-stream') {
      return true;
    }
    return false;
  } catch (_) {
    return true;
  } finally {
    client.close(force: true);
  }
}

Future<void> _switchPlaybackSource(
  Ref ref,
  PlaybackSourceChooser choose, {
  CrossSiteCandidate? preselect,
}) async {
  if (_sourceChangeBlocked(ref)) return;
  final session = _sourceSearchContext(ref);
  if (session == null ||
      session.site == null ||
      session.episodes.isEmpty ||
      ref.read(liveRuntimeProvider) != null &&
          _isLivePage(ref.read(activePlaySpecProvider),
              ref.read(liveRuntimeProvider))) {
    return;
  }
  final owner = _SourceChangeOwner(ref, PlaybackSourceChangeKind.source);
  _SourcePlaybackSnapshot? snapshot;
  var opened = false;
  try {
    // 选集抽屉点了某个已知来源时直接用它，省掉一次跨站搜索。
    CrossSiteCandidate? candidate = preselect;
    if (candidate == null) {
      owner.status('正在其他站点查找同片同集…');
      final result = await CrossSiteSearchService(
              searchEngine: ref.read(searchEngineProvider),
              siteApi: ref.read(siteApiProvider))
          .search(
              target: CrossSiteTarget(
                  item: session.item,
                  episodeName: session.episodes[session.index].name,
                  episodeCount: session.episodes.length,
                  siteKey: session.site!.key),
              sites: owner.config.sites,
              cancelToken: owner.cancelToken);
      if (!owner.isCurrent) return;
      final candidates = result.candidates;
      if (candidates.isEmpty) {
        ref.read(lineSwitchNoticeProvider.notifier).state =
            result.status == CrossSiteSearchStatus.timedOut
                ? '查找超时，当前播放已保留，请稍后重试'
                : result.status == CrossSiteSearchStatus.failed
                    ? '站点查找失败，当前播放已保留'
                    : '没有找到可信的同片同集，当前播放已保留';
        return;
      }
      if (candidates.length == 1 &&
          candidates.single.confidence == CrossSiteConfidence.high) {
        candidate = candidates.single;
      } else {
        owner.status('请选择播放来源');
        // Cancellation does not wait for an unanswered dialog.
        final cancelled = Completer<CrossSiteCandidate?>();
        owner.cancelToken.onCancel(() {
          if (!cancelled.isCompleted) cancelled.complete(null);
        });
        candidate = await Future.any([choose(candidates), cancelled.future]);
      }
    } else {
      owner.status('正在切换来源…');
    }
    if (!owner.isCurrent || candidate == null) return;
    owner.status('正在解析${candidate.site.name}…');
    // 一个站点常有多条线路（`PlayFrom`），候选只挑了其中最匹配的那条；那条解析失败时
    // 同站其它线路往往还能播。所以按「候选线路 → 同站其它线路」依次尝试，最多 3 条。
    final attempts = resolveLineAttempts(candidate);
    MediaPlaySpec? resolved;
    var resolvedSourceIndex = candidate.sourceIndex;
    var resolvedSourceName = candidate.source.name;
    var resolvedEpisode = candidate.episodeMatch.episode;
    var resolvedEpisodeIndex = candidate.episodeMatch.episodeIndex;
    Object? lastError;
    for (final attempt in attempts) {
      if (!owner.isCurrent) return;
      try {
        final spec = await owner.wait(ref.read(siteApiProvider).resolvePlayback(
          candidate.site,
          id: attempt.episode.url,
          flag: attempt.lineName,
          preferredQualityName: ref
              .read(playbackQualityPreferencesProvider)[candidate.site.key],
          parseEngine: ref.read(parseEngineProvider),
          parses: owner.config.parses,
        ).timeout(const Duration(seconds: 20)));
        // 解析成功但拿到的是网页（站点没给可播直链 / 需要额外解析）：
        // mpv 只会报 `Failed to recognize file format.`，这里提前判失败换下一条线路。
        if (!await _looksLikeMediaUrl(spec.url, spec.headers ?? const {})) {
          lastError = FormatException(
              '「${attempt.lineName}」返回的是网页而不是媒体地址（该站可能需要解析）');
          continue;
        }
        resolved = spec;
        resolvedSourceIndex = attempt.lineIndex;
        resolvedSourceName = attempt.lineName;
        resolvedEpisode = attempt.episode;
        resolvedEpisodeIndex = attempt.episodeIndex;
        break;
      } catch (error) {
        if (error is PlaybackSourceCancelled) rethrow;
        lastError = error;
      }
    }
    if (resolved == null) {
      throw StateError('该来源的 ${attempts.length} 条线路都没能播放'
          '${lastError == null ? '' : '：${_shortFailure(lastError)}'}');
    }
    var target = resolved;
    if (!owner.isCurrent) return;
    snapshot = _SourcePlaybackSnapshot(ref);
    // An unrelated old video can still sit behind an initial preparation error.
    // Only carry the actual target's playhead into the new site.
    final continuing =
        identical(session, ref.read(activePlaybackSessionProvider));
    final position = continuing ? snapshot.position : Duration.zero;
    target = target.copyWith(
        title:
            '${candidate.item.name} - ${resolvedEpisode.name} ($resolvedSourceName)',
        startPosition: position);
    final tracker = ref.read(playbackHistoryTrackerProvider);
    await tracker.flush();
    if (!owner.isCurrent) return;
    tracker.track(null, flushPrevious: false);
    owner.status('正在启动${candidate.site.name}…');
    final engine = ref.read(playerEngineProvider);
    opened = true;
    await PlaybackSourceLoader(
            engine: engine,
            open: (s) => snapshot!
                .open(engine, s, ownsPlayback: () => owner.ownsPlayback))
        .load(target, isCurrent: () => owner.isCurrent);
    if (!owner.isCurrent) throw const PlaybackSourceCancelled();
    final item = candidate.item;
    final recordId =
        '${candidate.site.key}::${HistoryRecord.buildId(item.id, resolvedEpisode.name)}';
    final record = HistoryRecord(
        id: recordId,
        vodId: item.id,
        vodName: item.name,
        vodPic: item.pic,
        episodeName: resolvedEpisode.name,
        sourceName: resolvedSourceName,
        playUrl: target.url,
        episodeUrl: resolvedEpisode.url,
        siteKey: candidate.site.key,
        siteName: candidate.site.name,
        timestamp: DateTime.now().millisecondsSinceEpoch,
        positionMs: position.inMilliseconds,
        durationMs: engine.duration.inMilliseconds);
    // addHistory updates memory synchronously. A disk error cannot undo a
    // successful media load or turn a candidate into a false playback failure.
    unawaited(ref
        .read(configRepositoryProvider)
        .addHistory(record)
        .catchError((Object _) {}));
    ref.read(activePlaySpecProvider.notifier).state = target;
    ref.read(activePlaybackSessionProvider.notifier).state = PlaybackSession(
        item: item,
        sourceName: resolvedSourceName,
        episodes: candidate.detail.sources[resolvedSourceIndex].episodes,
        index: resolvedEpisodeIndex,
        site: candidate.site,
        sources: candidate.detail.sources,
        sourceIndex: resolvedSourceIndex,
        triedLines: {lineSwitchKey(resolvedSourceIndex, resolvedSourceName)});
    ref.read(episodeBrowseSourceIndexProvider.notifier).state = null;
    tracker.track(recordId,
        flushPrevious: false,
        baseline: position,
        floor: position > Duration.zero ? position : null);
    _playPreparationEpoch++;
    ref.read(pendingPlayProvider.notifier).state = null;
    ref.read(playbackIntentProvider.notifier).state = null;
    ref.read(lineSwitchNoticeProvider.notifier).state =
        '已换到「${candidate.site.name}」 · ${resolvedEpisode.name}';
  } catch (error, stack) {
    if (owner.ownsPlayback) {
      // 失败原因进错误日志（关于页「错误日志」可看），提示里只放短原因。
      ErrorLog.instance.record('换源', error, stack);
      ref.read(lineSwitchNoticeProvider.notifier).state =
          error is PlaybackSourceCancelled
              ? '已取消换源'
              : '换源失败：${_shortFailure(error)}（当前会话已保留）';
      if (opened && snapshot != null) await snapshot.restore(ref, owner);
    }
  } finally {
    owner.dispose();
  }
}

/// 选集抽屉「其他来源」点选：直接切到该候选（不再跨站搜索）。
void _handleSourceCandidatePick(
    BuildContext context, WidgetRef ref, CrossSiteCandidate candidate) {
  unawaited(ref.read(switchToSourceCandidateProvider)(candidate));
}

Future<CrossSiteCandidate?> _choosePlaybackSource(BuildContext context,
    WidgetRef ref, List<CrossSiteCandidate> candidates) async {
  final token = ref.read(playbackSourceChangeProvider)?.cancelToken;
  final navigator = Navigator.of(context, rootNavigator: true);
  final route = DialogRoute<CrossSiteCandidate>(
      context: context,
      builder: (dialogContext) => AlertDialog(
            title: const Text('选择播放来源'),
            content: SizedBox(
                width: 440,
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  for (final candidate in candidates)
                    ListTile(
                      title: Text(
                          '${candidate.site.name} · ${candidate.item.name}'),
                      subtitle: Text(
                          '${candidate.source.name} · ${candidate.episodeName}'
                          '${candidate.item.year?.isNotEmpty == true ? ' · ${candidate.item.year}' : ''}'
                          '\n${candidate.confidence == CrossSiteConfidence.high ? '匹配度高' : '请确认同片同集'}'),
                      onTap: () => Navigator.of(dialogContext).pop(candidate),
                    ),
                ])),
            actions: [
              TextButton(
                  onPressed: () => Navigator.of(dialogContext).pop(),
                  child: const Text('取消'))
            ],
          ));
  token?.onCancel(() {
    if (route.isActive) navigator.removeRoute(route);
  });
  return navigator.push(route);
}
