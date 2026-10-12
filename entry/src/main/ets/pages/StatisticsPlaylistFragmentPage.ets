/**
 * S3 — StatisticsPlaylistFragment (screen_statistics_playlist), the watch-history screen.
 * Structure from fragment_playlist.xml + statistic_playlist_control.xml (which includes
 * playlist_control.xml) + StatisticsPlaylistFragment.java.
 *
 * The list is a LocalItemListAdapter whose rows are STATISTIC_STREAM_ITEMs, so the row root and
 * its click / long-click come from LocalItemHolder and the body from LocalStatisticStreamItemHolder
 * — the same dispatch every local list uses.
 *
 * 🟥 handleResult() ORDER, reproduced exactly: playlistControlBinding.getRoot() is made VISIBLE
 * and THEN `if (result.isEmpty()) { showEmptyState(); return; }`. The early return means
 * PlayButtonHelper.initPlaylistControlClickListener() and the sortButton listener are NEVER
 * attached on an empty history — so with no watch history the sort button and the three play
 * controls are VISIBLE BUT INERT. That is the source's behaviour, not a defect to fix here.
 *
 * The sort button is a TOGGLE whose label always names the mode it would switch TO, never the
 * current one, and the row's third line concatenates watch count + last-played date + service.
 *
 * Structure only — S5 styles it from the capture.
 */
import { router } from '@kit.ArkUI';
import { promptAction } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { intl } from '@kit.LocalizationKit';

import { LocalItemType } from '../model/enums/LocalItemLocalItemType';
import { PlaylistLocalItem } from '../model/db/view/PlaylistLocalItem';
import { PlaylistMetadataEntry } from '../model/db/view/PlaylistMetadataEntry';
import { StreamStatisticsEntry } from '../model/db/view/StreamStatisticsEntry';
import { StreamEntity } from '../model/db/entity/StreamEntity';
import { StreamInfoItem } from '../model/extractor/StreamInfoItem';
import { isAudioStream, isLiveStream } from '../model/app/StreamItem';
import { DownloadDialogHost } from './DownloadDialogPage';

import { LocalItemListAdapter, LocalItemDataSource } from '../components/LocalItemListAdapter';
import { LocalItemHolder } from '../components/LocalItemHolder';
import { LocalStatisticStreamItemHolder } from '../components/LocalStatisticStreamItemHolder';
import { getNameOfServiceById } from '../components/SelectedTabsAdapter';
import { LocalPlaylistItemHolder } from '../components/LocalPlaylistItemHolder';
import { LocalBookmarkPlaylistItemHolder } from '../components/LocalBookmarkPlaylistItemHolder';
import { RemotePlaylistItemHolder } from '../components/RemotePlaylistItemHolder';
import { RemoteBookmarkPlaylistItemHolder } from '../components/RemoteBookmarkPlaylistItemHolder';
import { LocalPlaylistStreamItemHolder } from '../components/LocalPlaylistStreamItemHolder';
import { PlaylistItemHolder } from '../components/PlaylistItemHolder';
import { HeaderFooterHolder } from '../components/HeaderFooterHolder';
import { FallbackViewHolder } from '../components/FallbackViewHolder';
import { buildStreamMenuActions, DialogAction, InfoItemDialog, StreamMenuHandlers,
  StreamMenuTarget } from '../components/InfoItemDialog';
import { enqueueNextStream } from '../common/util/StreamRowActions';
import { PlaylistDialog } from '../components/PlaylistDialog';
import { PlaylistAppendDialog } from '../components/PlaylistAppendDialog';
import { PlaylistCreationDialog } from '../components/PlaylistCreationDialog';

import { AppDatabase } from '../common/db/AppDatabase';
import { HistoryRecordManager } from '../common/db/HistoryRecordManager';
import { LocalPlaylistManager, playlistAppendToast } from '../common/db/PlaylistManager';
import { ServiceLocator } from '../common/di/ServiceLocator';
// recordManager.getStreamStatistics().subscribe(getHistoryObserver()) — the subscription is held
// so onDestroyView()'s disposal still happens when the page goes away mid-load.
import { Disposable, Observable } from '../common/rx/Rx';
import { AppPreferences } from '../common/prefs/Preferences';
import { enable_playback_state_lists_key, show_hold_to_append_key } from '../common/prefs/SettingsKeys';
import { ExtractorHelper } from '../common/extractor/ExtractorHelper';
import { StreamInfo } from '../model/extractor/StreamInfo';
import { BackgroundWorkMode } from '../common/background/BackgroundWork';
import { PlayerService } from '../common/player/PlayerService';
import { PlayerPrefs } from '../common/player/PlayerPrefs';

import { openPopupOnSurface, PopupPlayerSurface } from '../components/PopupPlayerSurface';
import { PlayQueueItem } from '../model/app/PlayQueueItem';
import { PlayQueue, SimplePlayQueue, currentPlayQueue, enqueueOnCurrentPlayQueue,
  setCurrentPlayQueue } from '../model/app/PlayQueue';
import { Localization } from '../common/i18n/Localization';
import { MediaSessionService } from '../common/player/MediaSessionService';
import { ConfirmDeleteDialog } from '../components/ConfirmDeleteDialog';
import { DIALOG_MASK_COLOR } from '../common/theme/ServiceTheme';
import { BLACK_THEME_KEY, themedBackground } from '../common/theme/ThemeBackground';

const TAG: string = 'StatisticsPlaylistFragmentPage';

/** How long one play-control tap swallows the taps behind it. */
const CONTROL_TAP_DEBOUNCE_MILLIS: number = 800;
/** Toast.LENGTH_SHORT: what the reference's first toast occupies before the tip queues behind it. */
const HOLD_TO_APPEND_TIP_DELAY: number = 2000;

/* S5 — style only, LightTheme (both captured states are light): the toolbar band is
 * ?attr/colorPrimary with ?attr/actionColor = @color/white content, the body is
 * ?attr/windowBackground = light_background_color. */
/** AppCompat android:textColorPrimary — no migrated resource carries it. */
const COLOR_ON_SURFACE: Resource = $r('app.color.on_surface');

/** StatisticsPlaylistFragment.StatisticSortMode. */
enum StatisticSortMode {
  LAST_PLAYED,
  MOST_PLAYED
}

/** NavigationHelper.openVideoDetailFragment(serviceId, url, title, queue). */
class PlayerParams {
  serviceId: number;
  url: string;
  name: string;
  playerType: string;
  /** NavigationHelper.enqueueOnPlayer() rather than playOn*Player() — the long-press half. */
  enqueue: boolean;

  constructor(serviceId: number, url: string, name: string, playerType: string,
    enqueue: boolean = false) {
    this.serviceId = serviceId;
    this.url = url;
    this.name = name;
    this.playerType = playerType;
    this.enqueue = enqueue;
  }
}

/**
 * The source's itemListAdapter IS a LocalItemListAdapter and a StreamStatisticsEntry IS one of
 * its LocalItems. The ported LocalItemDataSource is typed to PlaylistLocalItem (the bookmark
 * screen was ported first), which a StreamStatisticsEntry does not satisfy, so this shim carries
 * the entry through the adapter with the four fields that interface needs.
 *
 * ponytail: a shim rather than a widened shared datasource, which is a file this screen does not
 * own. Upgrade path: retype LocalItemDataSource to LocalItem and delete this class.
 */
/** ChannelFragmentPage's route arguments - the same three fields every list passes. */
class ItemParams {
  serviceId: number;
  url: string;
  name: string;

  constructor(serviceId: number, url: string, name: string) {
    this.serviceId = serviceId;
    this.url = url;
    this.name = name;
  }
}

class StatisticListItem implements PlaylistLocalItem {
  readonly entry: StreamStatisticsEntry;
  readonly orderingName: string | null;
  readonly displayIndex: number | null = null;
  readonly uid: number;
  readonly thumbnailUrl: string | null;

  constructor(entry: StreamStatisticsEntry) {
    this.entry = entry;
    this.orderingName = entry.streamEntity.title;
    this.uid = entry.streamId;
    this.thumbnailUrl = entry.streamEntity.thumbnailUrl;
  }

  get localItemType(): LocalItemType {
    return LocalItemType.STATISTIC_STREAM_ITEM;
  }
}

/**
 * The reference's toolbar overflows are flat white rectangles with square corners, anchored at
 * the icon - measured on three of its screens (Play queue, Subscriptions, History), all at
 * x 528..1020 of 1080. ArkUI's default menu is a rounded pale-gradient bubble with a tail.
 */
const SQUARE_MENU_CORNERS: MenuOptions = { borderRadius: 0 };

@Entry
@Component
export struct StatisticsPlaylistFragmentPage {
  /** ThemeHelper's black theme: the window background follows it. */
  @StorageProp(BLACK_THEME_KEY) blackTheme: boolean = false;

  /** itemListAdapter's backing list <- recordManager.getStreamStatistics(). */
  @State historyList: LocalItemDataSource = new LocalItemDataSource();
  /** processResult()'s comparator: latestAccessDate or watchCount, reversed. */
  @State sortMode: StatisticSortMode = StatisticSortMode.LAST_PLAYED;
  /** sortButtonText always names the OTHER mode — the one the tap would switch TO. */
  @State sortButtonLabel: Resource = $r('app.string.title_most_played');
  /** setTitle(): title_last_played / title_most_played, then title_activity_history on resume. */
  @State screenTitle: Resource = $r('app.string.title_activity_history');
  /**
   * Set by the host when this screen sits in MainActivity's fragment_holder. MainActivity owns
   * the one toolbar there and setTitle() writes into it, so drawing a second bar of our own put
   * two page names on screen at once.
   */
  @StorageProp('mainShellOwnsToolbar') useAsFrontPage: boolean = false;
  /**
   * The shell's copy of action_history_clear. While this fragment is hosted, its own toolbar is
   * not drawn, so the item is rendered in the shell's bar and arrives here as a bumped counter -
   * the same channel mainSearchRequest already uses for MainFragment's search item.
   */
  @StorageProp('mainHistoryClearRequest') @Watch('onClearHistoryRequested')
  private clearHistoryRequest: number = 0;
  /** The host toolbar's title, the same AppStorage key MainFragmentPage writes per tab. */
  @StorageLink('mainActionBarTitle') hostActionBarTitle: string = '';
  /** processResult() ordering, kept as state so the header and the rows agree. */
  @State sortOrder: string = 'latestAccessDate';

  @State isLoading: boolean = true;
  @State errorInfo: string | null = null;
  /** How many rows the adapter holds — showEmptyState() is driven by this, not by the pixels. */
  @State loadedCount: number = 0;
  /** LocalItemListAdapter.useItemHandle — false outside BookmarkFragment. */
  @State useItemHandle: boolean = false;

  /** showInfoItemDialog(item) / the clear-history confirmation. */
  @State menuTitle: string = '';
  @State menuActions: DialogAction[] = [];
  /** PlaylistDialog: with playlists it appends, without any it goes to creation. */
  @State hasPlaylists: boolean = false;
  @State appendTargets: PlaylistMetadataEntry[] = [];

  /**
   * handleResult()'s early return: on an empty history the sort listener and
   * PlayButtonHelper.initPlaylistControlClickListener() are never attached, so the header's four
   * buttons are visible but do nothing.
   */
  @State headerListenersAttached: boolean = false;
  /** The last accepted play-control tap, so a rapid burst starts one session, not five. */
  private lastControlTapMs: number = 0;

  private historyWorker: Disposable | null = null;
  private recordManager: HistoryRecordManager | null = null;
  private playlistManager: LocalPlaylistManager | null = null;
  /** The row the long-press menu is acting on. */
  private heldItem: StreamStatisticsEntry | null = null;

  private infoItemDialog: CustomDialogController = new CustomDialogController({
    maskColor: DIALOG_MASK_COLOR,
    builder: InfoItemDialog({ title: this.menuTitle, actions: this.menuActions })
  });

  /** StreamDialogDefaultEntry.APPEND_PLAYLIST -> PlaylistDialog.createCorrespondingDialog(). */
  private playlistDialog: CustomDialogController = new CustomDialogController({
    maskColor: DIALOG_MASK_COLOR,
    builder: PlaylistDialog({
      hasPlaylists: this.hasPlaylists,
      onAppend: (): void => {
        this.appendDialog.open();
      },
      onCreate: (): void => {
        this.creationDialog.open();
      }
    })
  });

  private appendDialog: CustomDialogController = new CustomDialogController({
    maskColor: DIALOG_MASK_COLOR,
    // customStyle: the builder draws its own square, sized card. Without it the system
    // dialog container draws a rounded surface under the content and the corners the
    // builder sets are never visible.
    customStyle: true,
    builder: PlaylistAppendDialog({
      playlists: this.appendTargets,
      onSelected: (playlist: PlaylistMetadataEntry): void => {
        this.appendToPlaylist(playlist);
      }
    })
  });

  private creationDialog: CustomDialogController = new CustomDialogController({
    maskColor: DIALOG_MASK_COLOR,
    // customStyle: the builder draws its own square, sized card. Without it the system
    // dialog container draws a rounded surface under the content and the corners the
    // builder sets are never visible.
    customStyle: true,
    builder: PlaylistCreationDialog({
      name: '',
      onCreate: (name: string): void => {
        this.createPlaylistWithHeldItem(name);
      }
    })
  });

  /* //////////////////////////////////////////////////////////////////////////
  // Lifecycle
  ////////////////////////////////////////////////////////////////////////// */

  aboutToAppear(): void {
    this.positionsInLists = AppPreferences.instance()
      .getBooleanSync(enable_playback_state_lists_key, true);
    this.startLoading();
  }

  /** DependentPreferenceHelper.getPositionsInListsEnabled(): the rows' progress bars. */
  @State positionsInLists: boolean = true;

  /** onDestroyView(): databaseSubscription.dispose() — a load in flight must not outlive us. */
  aboutToDisappear(): void {
    this.disposeWorker();
  }

  private disposeWorker(): void {
    const worker: Disposable | null = this.historyWorker;
    if (worker !== null) {
      worker.dispose();
      this.historyWorker = null;
    }
  }

  /** onResume(): setTitle(R.string.title_activity_history). */
  onPageShow(): void {
    this.setScreenTitle($r('app.string.title_activity_history'), 'title_activity_history');
  }

  /**
   * setTitle(): the local bar when this screen is pushed on its own, the host's when it is the
   * drawer fragment. Either way exactly one bar carries the name.
   */
  private setScreenTitle(title: Resource, key: string): void {
    this.screenTitle = title;
    if (this.useAsFrontPage) {
      this.hostActionBarTitle = Localization.getString(key);
    }
  }

  private async ensureServices(): Promise<HistoryRecordManager | null> {
    const existing: HistoryRecordManager | null = this.recordManager;
    if (existing !== null) {
      return existing;
    }
    try {
      const context: common.Context = getContext(this) as common.Context;
      const db: AppDatabase = await AppDatabase.getInstance(context);
      const manager: HistoryRecordManager = new HistoryRecordManager(db);
      this.recordManager = manager;
      this.playlistManager = new LocalPlaylistManager(db);
      return manager;
    } catch (err) {
      const failure: BusinessError = err as BusinessError;
      this.showSnackBarError(failure.message);
      return null;
    }
  }

  /* //////////////////////////////////////////////////////////////////////////
  // Statistics loader
  ////////////////////////////////////////////////////////////////////////// */

  /** startLoading(forceLoad): recordManager.getStreamStatistics().subscribe(historyObserver). */
  private async startLoading(): Promise<void> {
    const manager: HistoryRecordManager | null = await this.ensureServices();
    if (manager === null) {
      return;
    }
    // A re-sort or a delete restarts the load: the previous subscription is dropped first.
    this.disposeWorker();
    this.isLoading = true;
    this.errorInfo = null;
    this.historyWorker = Observable
      .fromPromise(manager.getStreamStatistics())
      .subscribeCallbacks((stats: StreamStatisticsEntry[]): void => {
        this.handleResult(stats);
      }, (error: Error): void => {
        hilog.error(0x0000, TAG, 'History Statistics: %{public}s', error.message);
        this.isLoading = false;
        this.errorInfo = error.message;
      });
  }

  /**
   * handleResult(result), in the source's own order: the play controls become visible FIRST, and
   * an empty result then returns early — before either listener is attached.
   */
  private handleResult(result: StreamStatisticsEntry[]): void {
    this.headerListenersAttached = false;
    this.historyList.setItems([]);
    this.loadedCount = 0;

    if (result.length === 0) {
      this.isLoading = false;
      return;
    }

    const rows: StatisticListItem[] = [];
    this.processResult(result).forEach((entry: StreamStatisticsEntry) => {
      rows.push(new StatisticListItem(entry));
    });
    this.historyList.setItems(rows);
    this.loadedCount = rows.length;
    // PlayButtonHelper.initPlaylistControlClickListener + sortButton.setOnClickListener.
    this.headerListenersAttached = true;
    this.isLoading = false;
  }

  /** processResult(): sorted by latestAccessDate or watchCount, reversed. */
  private processResult(results: StreamStatisticsEntry[]): StreamStatisticsEntry[] {
    const sorted: StreamStatisticsEntry[] = results.slice();
    if (this.sortMode === StatisticSortMode.MOST_PLAYED) {
      sorted.sort((a: StreamStatisticsEntry, b: StreamStatisticsEntry) =>
        b.watchCount - a.watchCount);
    } else {
      sorted.sort((a: StreamStatisticsEntry, b: StreamStatisticsEntry) =>
        b.latestAccessDate - a.latestAccessDate);
    }
    return sorted;
  }

  /** toggleSortMode(): flip the mode, retitle, swap icon and label, then startLoading(true). */
  private toggleSortMode(): void {
    if (!this.headerListenersAttached) {
      // handleResult() returned early on an empty history: no listener was ever attached.
      hilog.info(0x0000, TAG, 'sort button is inert while the history is empty');
      return;
    }
    if (this.sortMode === StatisticSortMode.LAST_PLAYED) {
      this.sortMode = StatisticSortMode.MOST_PLAYED;
      this.sortOrder = 'watchCount';
      this.setScreenTitle($r('app.string.title_most_played'), 'title_most_played');
      this.sortButtonLabel = $r('app.string.title_last_played');
    } else {
      this.sortMode = StatisticSortMode.LAST_PLAYED;
      this.sortOrder = 'latestAccessDate';
      this.setScreenTitle($r('app.string.title_last_played'), 'title_last_played');
      this.sortButtonLabel = $r('app.string.title_most_played');
    }
    this.startLoading();
  }

  /* //////////////////////////////////////////////////////////////////////////
  // Play controls (playlist_control.xml, shared with LocalPlaylistFragment)
  ////////////////////////////////////////////////////////////////////////// */

  /** getPlayQueue(index): every StreamStatisticsEntry as a StreamInfoItem. */
  private playQueue(): StreamInfoItem[] {
    const streams: StreamInfoItem[] = [];
    this.historyList.getItemsList().forEach((item: PlaylistLocalItem) => {
      if (item instanceof StatisticListItem) {
        streams.push((item as StatisticListItem).entry.toStreamInfoItem());
      }
    });
    return streams;
  }

  /**
   * A burst of taps on one play control must start ONE session and open ONE popup. Android's
   * activity launch collapses a double tap by itself (singleTask + the player service already
   * running); here every tap is an independent prepare() and, for popup, an independent
   * router.pushUrl - which stacks a second copy of the detail page on top of the first.
   */
  private acceptControlTap(): boolean {
    const now: number = Date.now();
    if (now - this.lastControlTapMs < CONTROL_TAP_DEBOUNCE_MILLIS) {
      hilog.info(0x0000, TAG, 'play control tapped again within the debounce window; ignored');
      return false;
    }
    this.lastControlTapMs = now;
    return true;
  }

  /** playOn*Player(activity, getPlayQueue()): hand over the WHOLE list, positioned at `index`. */
  private publishPlayQueue(streams: StreamInfoItem[], index: number): void {
    const items: PlayQueueItem[] = StatisticsPlaylistFragmentPage.toQueueItems(streams);
    setCurrentPlayQueue(new SimplePlayQueue(index, items));
  }

  /**
   * enqueueOnPlayer(activity, getPlayQueue(), type): APPEND to what is already queued and leave
   * the playing item alone. With nothing playing at all there is nothing to append behind, which
   * is the one case where the source opens the player on the appended items.
   */
  private enqueueAll(streams: StreamInfoItem[], audioOnly: boolean): void {
    const live: PlayQueue | null = currentPlayQueue.getValue();
    promptAction.showToast({ message: $r('app.string.enqueued'), duration: 2000 });
    enqueueOnCurrentPlayQueue(StatisticsPlaylistFragmentPage.toQueueItems(streams));
    // A queue that was already there keeps its playing item: nothing is prepared, nothing restarts.
    if (live === null && !PlayerService.getInstance().hasPlayer()) {
      this.startPlayer(streams[0], audioOnly);
    }
  }

  private static toQueueItems(streams: StreamInfoItem[]): PlayQueueItem[] {
    const items: PlayQueueItem[] = [];
    for (const stream of streams) {
      items.push(PlayQueueItem.fromStreamInfoItem(stream));
    }
    return items;
  }

  /**
   * PlayButtonHelper.initPlaylistControlClickListener: playOnMainPlayer is the ONLY one of the
   * three controls that navigates. playOnBackgroundPlayer / playOnPopupPlayer
   * (NavigationHelper.java:144-171) toast and hand the queue to PlayerService in place, so the
   * history stays on screen. The controls are INERT until handleResult() attached their listeners.
   */
  /** StreamDialogDefaultEntry.DOWNLOAD opens DownloadDialog on the stream that was held. */
  @State downloadServiceId: number = -1;
  @State downloadUrl: string = '';
  @State @Watch('onDownloadDialogVisibility') showDownloadDialog: boolean = false;
  /**
   * screen_download_dialog is an AlertDialog: a CustomDialogController fades its own scrim in
   * over the whole window, where a transparent bindSheet carrying a hand-drawn scrim slid in
   * and stopped at the status bar. The flag drives the controller; an outside tap clears it.
   */
  private downloadDialog: CustomDialogController = new CustomDialogController({
    customStyle: true,
    maskColor: DIALOG_MASK_COLOR,
    cancel: (): void => {
      this.showDownloadDialog = false;
    },
    builder: DownloadDialogHost({
      isShown: this.showDownloadDialog,
      serviceId: this.downloadServiceId,
      url: this.downloadUrl
    })
  });

  private onDownloadDialogVisibility(): void {
    if (this.showDownloadDialog) {
      this.downloadDialog.open();
    } else {
      this.downloadDialog.close();
    }
  }

  /** PopupPlayerSurface is mounted only while a popup is being opened or is open. */
  @State popupSurfaceMounted: boolean = false;
  /** The item the popup was raised for; read once the surface is bound. */
  private popupItem: StreamInfoItem | null = null;
  private popupSurfaceController: XComponentController = new XComponentController();

  private openPlayer(startIndex: number, playerType: string, enqueue: boolean = false): void {
    if (!this.headerListenersAttached) {
      hilog.info(0x0000, TAG, 'play controls are inert while the history is empty');
      return;
    }
    if (!this.acceptControlTap()) {
      return;
    }
    const streams: StreamInfoItem[] = this.playQueue();
    if (streams.length === 0) {
      return;
    }
    const index: number = startIndex < streams.length ? startIndex : 0;
    const item: StreamInfoItem = streams[index];
    if (enqueue) {
      // enqueueOnPlayer(activity, getPlayQueue(), type) APPENDS and navigates for no player type.
      // Every long-press landed on startPlayer()/pushUrl() instead, which REPLACED playback with
      // the first entry - the toast said "enqueued" and the app did the opposite.
      this.enqueueAll(streams, playerType === 'AUDIO');
      return;
    }
    // getPlayQueue(index): the whole history, not just the entry that starts. Handing over one
    // item is why nothing more than the playing stream was ever in the queue.
    this.publishPlayQueue(streams, index);
    if (playerType === 'MAIN') {
      router.pushUrl({
        url: 'pages/VideoDetailFragmentPage',
        params: new PlayerParams(item.getServiceId(), item.getUrl(), item.getName(), playerType,
          enqueue)
      });
    } else if (playerType === 'AUDIO') {
      promptAction.showToast({
        message: $r('app.string.background_player_playing_toast'),
        duration: 2000
      });
      this.startPlayer(item, true);
    } else {
      // A second tap while the first popup is still opening must do nothing: the row menu's own
      // onPopup has guarded this since T-0064, the header control did not, and a rapid burst on
      // the header left popupSurfaceMounted true with popupItem stranded and no window open -
      // after which the control was dead until the app restarted (TC-LIBRARY-457).
      if (this.popupSurfaceMounted) {
        return;
      }
      promptAction.showToast({ message: $r('app.string.popup_playing_toast'), duration: 2000 });
      // playOnPopupPlayer() opens the float window OVER the screen the user is on - Most Played
      // stays visible behind it, and the toast stays on Most Played where it was raised. This
      // page used to push VideoDetailFragmentPage instead, because PiPWindow renders from an
      // XComponent surface (PiPConfiguration.componentController) and that page owned the only
      // one; the user landed on the standard player and the tooltip went with them. That is the
      // same defect TC-LIBRARY-252 reported for a bookmarked playlist, fixed there by giving the
      // list screen its own surface - this screen never got one. PopupPlayerSurface is that
      // surface. The mini player remains the documented fallback when PiP is unavailable.
      this.popupItem = item;
      this.popupSurfaceMounted = true;
    }
    if (!enqueue && (playerType === 'MAIN' || playerType === 'AUDIO')) {
      // promptAction.showToast REPLACES the visible toast instead of queueing behind it the way
      // Android's Toast does, so raising the tip straight away wiped the action's own toast.
      // Measured on the reference (Background on History > Most Played): "Playing in background"
      // is up from ~0.7s to ~1.4s after the tap and "Hold to enqueue" follows at ~2.1s - one
      // Toast.LENGTH_SHORT apart. Delaying the tip by that much reproduces the pair. MAIN toasts
      // nothing of its own, so its tip still fires at once. POPUP leaves this page for
      // VideoDetailFragmentPage, where the tip would land on a screen the reference never shows
      // it on, so it stays out until that path is measured.
      this.showHoldToAppendToastIfNeeded(playerType === 'AUDIO' ? HOLD_TO_APPEND_TIP_DELAY : 0);
    }
  }

  /**
   * The surface is bound: prepare the stream on it and hand it to PiP. enterPip() reports which
   * of the two it managed - the real float window, or the in-app mini player - and the popup
   * entry point must visibly do one of them, never nothing.
   */
  private async onPopupSurfaceReady(): Promise<void> {
    const item: StreamInfoItem | null = this.popupItem;
    if (item === null) {
      return;
    }
    this.popupItem = null;
    await openPopupOnSurface(getContext(this) as common.UIAbilityContext, item.getServiceId(),
      item.getUrl(), this.popupSurfaceController, (): void => {
        this.popupSurfaceMounted = false;
      });
  }

  /** playOnBackgroundPlayer / playOnPopupPlayer / enqueueOnPlayer: PlayerService, in place. */
  private async startPlayer(item: StreamInfoItem, audioOnly: boolean): Promise<void> {
    try {
      const info: StreamInfo = await ServiceLocator.get().backgroundWork.runWithBackgroundTask(
        BackgroundWorkMode.DATA_TRANSFER,
        (): Promise<StreamInfo> =>
          ExtractorHelper.getStreamInfo(item.getServiceId(), item.getUrl(), false));
      await PlayerService.getInstance().prepare(info, audioOnly,
      audioOnly ? 0 : PlayerPrefs.defaultPlaybackHeight());
      // Same as PlaylistFragmentPage: these paths own no player screen, so nothing else creates
      // the AVSession or the continuous task that keeps background audio alive.
      await MediaSessionService.getInstance()
        .startDetached(getContext(this) as common.UIAbilityContext, info);
    } catch (err) {
      const failure: BusinessError = err as BusinessError;
      this.showSnackBarError(failure.message);
    }
  }

  /**
   * showHoldToAppendToastIfNeeded(): the tip fires after a plain tap, only while the
   * show_hold_to_append preference is on — which is its default.
   */
  private showHoldToAppendToastIfNeeded(delayMillis: number): void {
    if (!AppPreferences.instance().getBooleanSync(show_hold_to_append_key, true)) {
      return;
    }
    if (delayMillis <= 0) {
      promptAction.showToast({ message: $r('app.string.hold_to_append'), duration: 2000 });
      return;
    }
    setTimeout((): void => {
      promptAction.showToast({ message: $r('app.string.hold_to_append'), duration: 2000 });
    }, delayMillis);
  }

  /* //////////////////////////////////////////////////////////////////////////
  // Row gestures and the menus
  ////////////////////////////////////////////////////////////////////////// */

  /** OnClickGesture.selected -> NavigationHelper.openVideoDetailFragment(...). */
  private onItemSelected(item: PlaylistLocalItem): void {
    if (!(item instanceof StatisticListItem)) {
      return;
    }
    const stream: StreamEntity = (item as StatisticListItem).entry.streamEntity;
    router.pushUrl({
      url: 'pages/VideoDetailFragmentPage',
      params: new PlayerParams(stream.serviceId, stream.url, stream.title, 'MAIN')
    });
  }

  /** OnClickGesture.held -> showInfoItemDialog(entry): the defaults plus DELETE. */
  private onItemHeld(item: PlaylistLocalItem): void {
    if (!(item instanceof StatisticListItem)) {
      return;
    }
    const entry: StreamStatisticsEntry = (item as StatisticListItem).entry;
    const stream: StreamInfoItem = entry.toStreamInfoItem();
    this.heldItem = entry;
    this.menuTitle = entry.streamEntity.title;

    // InfoItemDialog.Builder owns the entry list and its order. This screen used to write out
    // four entries of its own; the reference shows ten here - the standard set with DELETE
    // inserted straight after the start-here block, measured on "Me at the zoo".
    const target: StreamMenuTarget = new StreamMenuTarget();
    target.serviceId = entry.streamEntity.serviceId;
    target.url = entry.streamEntity.url;
    target.title = entry.streamEntity.title;
    target.uploader = entry.streamEntity.uploader;
    const uploaderUrl: string | null = entry.streamEntity.uploaderUrl;
    target.uploaderUrl = uploaderUrl === null ? '' : uploaderUrl;
    target.audioOnly = isAudioStream(entry.streamEntity.streamType);
    target.live = isLiveStream(entry.streamEntity.streamType);

    const handlers: StreamMenuHandlers = new StreamMenuHandlers();
    handlers.onEnqueue = (): void => {
      promptAction.showToast({ message: $r('app.string.enqueued'), duration: 2000 });
      enqueueOnCurrentPlayQueue([PlayQueueItem.fromStreamInfoItem(stream)]);
    };
    handlers.onEnqueueNext = (): void => {
      // NavigationHelper.enqueueNextOnPlayer(): straight after the playing stream.
      enqueueNextStream(stream);
    };
    handlers.onBackground = (): void => {
      promptAction.showToast({
        message: $r('app.string.background_player_playing_toast'),
        duration: 2000
      });
      this.startPlayer(stream, true);
    };
    handlers.onPopup = (): void => {
      // This screen owns a popup surface, so the row's popup entry opens the window in place the
      // same way its header control does - see T-0064 and the shared launcher from T-0115.
      if (this.popupSurfaceMounted) {
        return;
      }
      promptAction.showToast({ message: $r('app.string.popup_playing_toast'), duration: 2000 });
      this.popupItem = stream;
      this.popupSurfaceMounted = true;
    };
    handlers.onDownload = (): void => {
      this.downloadServiceId = entry.streamEntity.serviceId;
      this.downloadUrl = entry.streamEntity.url;
      this.showDownloadDialog = true;
    };
    handlers.onAddToPlaylist = (): void => {
      this.openPlaylistDialog();
    };
    handlers.onMarkAsWatched = (): void => {
      this.markAsWatched(stream);
    };
    handlers.onShowChannelDetails = (): void => {
      router.pushUrl({
        url: 'pages/ChannelFragmentPage',
        params: new ItemParams(entry.streamEntity.serviceId, target.uploaderUrl,
          entry.streamEntity.uploader)
      });
    };
    // setAction(StreamDialogDefaultEntry.DELETE, (f, i) -> deleteEntry(indexOf(item))). The
    // reference puts it fourth, right after the start-here entries.
    handlers.afterStartHere = [new DialogAction($r('app.string.delete'), 'DELETE', (): void => {
      this.deleteEntry(entry);
    })];

    this.menuActions = buildStreamMenuActions(target, handlers);
    this.infoItemDialog.open();
  }

  /** StreamDialogDefaultEntry.MARK_AS_WATCHED -> recordManager.markAsWatched(item). */
  private async markAsWatched(stream: StreamInfoItem): Promise<void> {
    const manager: HistoryRecordManager | null = await this.ensureServices();
    if (manager === null) {
      return;
    }
    try {
      await manager.markAsWatched(stream);
      this.startLoading();
    } catch (err) {
      const failure: BusinessError = err as BusinessError;
      this.showSnackBarError(failure.message);
    }
  }

  /** deleteEntry(index): recordManager.deleteStreamHistoryAndState(entry.getStreamId()). */
  private async deleteEntry(entry: StreamStatisticsEntry): Promise<void> {
    const manager: HistoryRecordManager | null = await this.ensureServices();
    if (manager === null) {
      return;
    }
    try {
      await manager.deleteStreamHistoryAndState(entry.streamId);
      promptAction.showToast({ message: $r('app.string.one_item_deleted'), duration: 2000 });
      this.startLoading();
    } catch (err) {
      const failure: BusinessError = err as BusinessError;
      this.showSnackBarError(failure.message);
    }
  }

  /**
   * action_history_clear -> HistorySettingsFragment.openDeleteWatchHistoryDialog(): a confirm
   * dialog over the whole watch history.
   */
  private confirmDialog: CustomDialogController = new CustomDialogController({
    maskColor: DIALOG_MASK_COLOR,
    customStyle: true,
    builder: ConfirmDeleteDialog({
      title: $r('app.string.delete_view_history_alert'),
      onConfirm: (): void => {
        this.deleteWholeWatchHistory();
      }
    })
  });

  /** The shell's action_history_clear: open the same confirm dialog the own-toolbar item does. */
  private onClearHistoryRequested(): void {
    if (this.clearHistoryRequest > 0) {
      this.openDeleteWatchHistoryDialog();
    }
  }

  private openDeleteWatchHistoryDialog(): void {
    // openDeleteWatchHistoryDialog(): setTitle(R.string.delete_view_history_alert) on an
    // AlertDialog - CANCEL and DELETE side by side at the bottom right. This used to go through
    // the long-press context dialog, which stacks its actions vertically instead.
    this.confirmDialog.open();
  }

  /**
   * HistoryRecordManager.openDeleteWatchHistoryDialog() - the SAME routine Settings > History runs:
   * the playback states, then the history rows, then the orphaned stream records, each step
   * confirming with its toast. This path used to drop the history rows alone.
   */
  private async deleteWholeWatchHistory(): Promise<void> {
    const manager: HistoryRecordManager | null = await this.ensureServices();
    if (manager === null) {
      return;
    }
    try {
      await manager.deleteCompleteStreamStateHistory();
      promptAction.showToast({ message: $r('app.string.watch_history_states_deleted'),
        duration: 2000 });
      await manager.deleteWholeStreamHistory();
      promptAction.showToast({ message: $r('app.string.watch_history_deleted'),
        duration: 2000 });
      await manager.removeOrphanedRecords();
      this.startLoading();
    } catch (err) {
      const failure: BusinessError = err as BusinessError;
      this.showSnackBarError(failure.message);
    }
  }

  /** PlaylistDialog.createCorrespondingDialog(): append when there are playlists, else create. */
  private async openPlaylistDialog(): Promise<void> {
    if (await this.ensureServices() === null) {
      return;
    }
    const manager: LocalPlaylistManager | null = this.playlistManager;
    if (manager === null) {
      return;
    }
    const held: StreamStatisticsEntry | null = this.heldItem;
    try {
      // getPlaylistDuplicates(streamUrl) rather than getPlaylists(): the rows then carry
      // timesStreamIsContained, which is what lets PlaylistAppendDialog grey out a
      // playlist that already holds this stream and refuse a second append.
      const playlists: PlaylistMetadataEntry[] = held === null
        ? await manager.getPlaylists()
        : await manager.getPlaylistDuplicates(held.streamEntity.url);
      this.appendTargets = playlists;
      this.hasPlaylists = playlists.length > 0;
      // PlaylistDialog.createCorrespondingDialog() is a FACTORY in the source, not a
      // dialog of its own: with playlists it shows the append dialog, without any it
      // goes straight to creation. The port made it a visible intermediate dialog
      // carrying one unstyled Text, which rendered as a chromeless pill and meant the
      // append dialog behind it never opened at all.
      if (this.hasPlaylists) {
        this.appendDialog.open();
      } else {
        this.creationDialog.open();
      }
    } catch (err) {
      const failure: BusinessError = err as BusinessError;
      this.showSnackBarError(failure.message);
    }
  }

  private async appendToPlaylist(playlist: PlaylistMetadataEntry): Promise<void> {
    const manager: LocalPlaylistManager | null = this.playlistManager;
    const entry: StreamStatisticsEntry | null = this.heldItem;
    if (manager === null || entry === null) {
      return;
    }
    try {
      await manager.appendToPlaylist(playlist.uid, [entry.streamEntity]);
      // PlaylistAppendDialog.onPlaylistSelected() ends in a Toast on the reference - the string
      // `playlist_add_stream_success` ("Playlisted") was already in this port's resources and had
      // no caller anywhere, so an append finished silently. Every entry point that appends says
      // so, not just the one the case happens to name.
      promptAction.showToast({ message: playlistAppendToast(playlist),
        duration: 2000 });
    } catch (err) {
      const failure: BusinessError = err as BusinessError;
      this.showSnackBarError(failure.message);
    }
  }

  private async createPlaylistWithHeldItem(name: string): Promise<void> {
    const manager: LocalPlaylistManager | null = this.playlistManager;
    const entry: StreamStatisticsEntry | null = this.heldItem;
    if (manager === null || entry === null || name.length === 0) {
      return;
    }
    try {
      await manager.createPlaylist(name, [entry.streamEntity]);
      // PlaylistCreationDialog: Toast @string/playlist_creation_success.
      promptAction.showToast({ message: $r('app.string.playlist_creation_success'),
        duration: 2000 });
    } catch (err) {
      const failure: BusinessError = err as BusinessError;
      this.showSnackBarError(failure.message);
    }
  }

  private showSnackBarError(message: string): void {
    hilog.error(0x0000, TAG, '%{public}s', message);
    promptAction.showToast({ message: message, duration: 3000 });
  }

  /* //////////////////////////////////////////////////////////////////////////
  // Builders
  ////////////////////////////////////////////////////////////////////////// */

  /** getListHeaderSupplier(): statistic_playlist_control.xml — the sort row + playlist_control. */
  @Builder
  listHeader() {
    HeaderFooterHolder() {
      Column() {
        Row() {
          Image(this.sortMode === StatisticSortMode.LAST_PLAYED
            ? $r('app.media.ic_filter_list')
            : $r('app.media.ic_history'))
            .id('sortButtonIcon')
            .width(48)
            .height(28)
            .objectFit(ImageFit.Contain)
            // 12dp either side, which puts sortButtonText at the capture's 72dp start.
            .margin({ left: 12, right: 12 })
          // textAppearanceLarge overridden to 15sp bold, gravity left|center in a 50dp row.
          Text(this.sortButtonLabel)
            .id('sortButtonText')
            .layoutWeight(1)
            .fontSize(15)
            .fontWeight(FontWeight.Bold)
            .fontColor(COLOR_ON_SURFACE)
            .textAlign(TextAlign.Start)
        }
        .id('sortButton')
        .width('100%')
        .height(50)
        .alignItems(VerticalAlign.Center)
        .onClick(() => {
          this.toggleSortMode();
        })

        // playlist_control.xml — visible from handleResult(), inert until it attaches listeners.
        Row() {
          Row() {
            // android:drawableStart with android:drawablePadding="4dp" — the label's own
            // compound glyph, at the vector's intrinsic 24dp, tinted like the text.
            Image($r('app.media.ic_headset'))
              .width(24)
              .height(24)
              .objectFit(ImageFit.Contain)
              .fillColor($r('app.color.accent'))
              .margin({ right: 4 })
            Text($r('app.string.controls_background_title'))
              .fontSize($r('app.float.channel_rss_title_size'))
              .fontColor($r('app.color.accent'))
          }
          .id('playlist_ctrl_play_bg_button')
          .layoutWeight(1)
          .height($r('app.float.playlist_ctrl_height'))
          .justifyContent(FlexAlign.Center)
          .alignItems(VerticalAlign.Center)
          .onClick(() => {
            this.openPlayer(0, 'AUDIO');
          })
          .gesture(LongPressGesture().onAction(() => {
            // enqueueOnPlayer(activity, getPlayQueue(), PlayerType.AUDIO)
            this.openPlayer(0, 'AUDIO', true);
          }))

          Divider()
            .vertical(true)
            .strokeWidth(1)
            .color($r('app.color.accent'))
            .height(30)
            .margin({
              top: $r('app.float.playlist_ctrl_separator_margin'),
              bottom: $r('app.float.playlist_ctrl_separator_margin')
            })

          Row() {
            // android:drawableStart with android:drawablePadding="4dp" — the label's own
            // compound glyph, at the vector's intrinsic 24dp, tinted like the text.
            Image($r('app.media.ic_playlist_play'))
              .width(24)
              .height(24)
              .objectFit(ImageFit.Contain)
              .fillColor($r('app.color.accent'))
              .margin({ right: 4 })
            Text($r('app.string.play_all'))
              .fontSize($r('app.float.channel_rss_title_size'))
              .fontColor($r('app.color.accent'))
          }
          .id('playlist_ctrl_play_all_button')
          .layoutWeight(1)
          .height($r('app.float.playlist_ctrl_height'))
          .justifyContent(FlexAlign.Center)
          .alignItems(VerticalAlign.Center)
          .onClick(() => {
            this.openPlayer(0, 'MAIN');
          })
          .gesture(LongPressGesture().onAction(() => {
            // enqueueOnPlayer(activity, getPlayQueue(), PlayerType.MAIN)
            this.openPlayer(0, 'MAIN', true);
          }))

          Divider()
            .vertical(true)
            .strokeWidth(1)
            .color($r('app.color.accent'))
            .height(30)
            .margin({
              top: $r('app.float.playlist_ctrl_separator_margin'),
              bottom: $r('app.float.playlist_ctrl_separator_margin')
            })

          Row() {
            // android:drawableStart with android:drawablePadding="4dp" — the label's own
            // compound glyph, at the vector's intrinsic 24dp, tinted like the text.
            Image($r('app.media.ic_picture_in_picture'))
              .width(24)
              .height(24)
              .objectFit(ImageFit.Contain)
              .fillColor($r('app.color.accent'))
              .margin({ right: 4 })
            Text($r('app.string.controls_popup_title'))
              .fontSize($r('app.float.channel_rss_title_size'))
              .fontColor($r('app.color.accent'))
          }
          .id('playlist_ctrl_play_popup_button')
          .layoutWeight(1)
          .height($r('app.float.playlist_ctrl_height'))
          .justifyContent(FlexAlign.Center)
          .alignItems(VerticalAlign.Center)
          .onClick(() => {
            this.openPlayer(0, 'POPUP');
          })
          .gesture(LongPressGesture().onAction(() => {
            // enqueueOnPlayer(activity, getPlayQueue(), PlayerType.POPUP)
            this.openPlayer(0, 'POPUP', true);
          }))
        }
        .id('playlist_control')
        .width('100%')
        .height($r('app.float.playlist_ctrl_height'))
        .alignItems(VerticalAlign.Center)
      }
      .width('100%')
      .backgroundColor(themedBackground(this.blackTheme))
    }
  }

  /** LocalItemHolder owns the row root (itemRoot) and its click / long-click. */
  @Builder
  itemRow(item: PlaylistLocalItem) {
    LocalItemHolder({
      item: item,
      onSelected: (selected: PlaylistLocalItem): void => {
        this.onItemSelected(selected);
      },
      onHeld: (held: PlaylistLocalItem): void => {
        this.onItemHeld(held);
      },
      // An arrow keeps `this` on this page; `this.itemBody` would re-bind it to the holder.
      body: (row: PlaylistLocalItem): void => {
        this.itemBody(row);
      }
    })
  }

  /** LocalItemListAdapter.getItemViewType() + onCreateViewHolder(), in its branch order. */
  @Builder
  itemBody(item: PlaylistLocalItem) {
    if (item.localItemType === LocalItemType.STATISTIC_STREAM_ITEM) {
      LocalStatisticStreamItemHolder({
        thumbnailUrl: item.thumbnailUrl,
        title: item.orderingName,
        uploader: this.rowUploader(item),
        duration: this.rowDuration(item),
        additionalDetails: this.rowDetailLine(item),
        durationSeconds: item instanceof StatisticListItem
          ? (item as StatisticListItem).entry.streamEntity.duration : 0,
        progressMillis: item instanceof StatisticListItem && this.positionsInLists
          ? (item as StatisticListItem).entry.progressMillis : 0
      })
    } else if (item.localItemType === LocalItemType.PLAYLIST_LOCAL_ITEM) {
      if (this.useItemHandle) {
        LocalBookmarkPlaylistItemHolder({
          item: item,
          body: (row: PlaylistLocalItem): void => {
            this.playlistBody(row);
          }
        })
      } else {
        LocalPlaylistItemHolder({
          item: item,
          body: (row: PlaylistLocalItem): void => {
            this.playlistBody(row);
          }
        })
      }
    } else if (item.localItemType === LocalItemType.PLAYLIST_REMOTE_ITEM) {
      if (this.useItemHandle) {
        RemoteBookmarkPlaylistItemHolder({
          item: item,
          body: (row: PlaylistLocalItem): void => {
            this.playlistBody(row);
          }
        })
      } else {
        RemotePlaylistItemHolder({
          item: item,
          body: (row: PlaylistLocalItem): void => {
            this.playlistBody(row);
          }
        })
      }
    } else if (item.localItemType === LocalItemType.PLAYLIST_STREAM_ITEM) {
      LocalPlaylistStreamItemHolder({
        thumbnailUrl: item.thumbnailUrl,
        title: item.orderingName,
        showItemHandle: this.useItemHandle
      })
    } else {
      FallbackViewHolder()
    }
  }

  /** PlaylistItemHolder: the views every playlist row shares. */
  @Builder
  playlistBody(item: PlaylistLocalItem) {
    PlaylistItemHolder({
      thumbnailUrl: item.thumbnailUrl,
      title: item.orderingName,
      showUploader: item.localItemType === LocalItemType.PLAYLIST_REMOTE_ITEM
    })
  }

  /** StreamEntity.uploader. */
  private rowUploader(item: PlaylistLocalItem): string | null {
    return item instanceof StatisticListItem
      ? (item as StatisticListItem).entry.streamEntity.uploader : null;
  }

  /** Localization.getDurationString(streamEntity.duration), GONE when not positive. */
  private rowDuration(item: PlaylistLocalItem): string | null {
    if (!(item instanceof StatisticListItem)) {
      return null;
    }
    const duration: number = (item as StatisticListItem).entry.streamEntity.duration;
    // getDurationString(duration), and the badge is GONE rather than empty when it is not
    // positive — the port printed the raw second count, so a 38-minute talk read "2289".
    return duration > 0 ? Localization.getDurationString(duration) : null;
  }

  /**
   * StatisticsPlaylistFragment's "last played" field.
   *
   * This used to add the time of day, reasoning from the source's
   * DateTimeFormatter.ofLocalizedDateTime(FormatStyle.SHORT). What the REFERENCE actually renders
   * carries no time at all - measured on both of its sort modes, Most Played and Last Played:
   * "11 views • 9/24/26 • YouTube", "550 views • 9/23/26 • YouTube". The port printed
   * "25 views • 9/25/26, 02:44 • YouTube", which is what TC-LIBRARY-369 reports as the wrong
   * date format. The device is the bar, not the reading of the source.
   */
  private static formatAccessDate(epochMillis: number): string {
    // Two-digit year, as the reference has it: a four-digit year ran the line past the 195vp text
    // column of the folded Mate X7 and pushed the service name off the end.
    const options: intl.DateTimeOptions = {
      year: '2-digit', month: 'numeric', day: 'numeric'
    };
    return new intl.DateTimeFormat(Localization.getAppLocale(), options)
      .format(new Date(epochMillis));
  }

  /**
   * getDetailLine(): Localization.concatenateStrings(shortViewCount(watchCount),
   * dateTimeFormatter.format(latestAccessDate), ServiceHelper.getNameOfServiceById(serviceId)).
   */
  private rowDetailLine(item: PlaylistLocalItem): string | null {
    if (!(item instanceof StatisticListItem)) {
      return null;
    }
    const entry: StreamStatisticsEntry = (item as StatisticListItem).entry;
    return Localization.concatenateStrings([
      Localization.shortViewCount(entry.watchCount),
      StatisticsPlaylistFragmentPage.formatAccessDate(entry.latestAccessDate),
      getNameOfServiceById(entry.streamEntity.serviceId)
    ]);
  }

  /** menu_history.xml's single overflow row: action_history_clear. */
  @Builder
  historyOverflowMenu() {
    Column() {
      Text($r('app.string.clear_views_history_title'))
        .id('action_history_clear')
        .width('100%')
        .fontSize(16)
        .fontColor($r('app.color.on_surface'))
        .padding({ left: 16, right: 16, top: 12, bottom: 12 })
        .onClick(() => {
          this.openDeleteWatchHistoryDialog();
        })
    }
    .width(220)
  }

  build() {
    Column() {
      // toolbar_layout: the Up arrow, the title, and the menu_history overflow item. Skipped
      // entirely when the host owns the bar - see useAsFrontPage.
      if (!this.useAsFrontPage) {
      Row() {
        // 24dp glyph centred in the ?attr/actionBarSize target, ToolbarTheme's ?attr/actionColor.
        Image($r('app.media.ic_arrow_back'))
          .id('navigate_back')
          .accessibilityText($r('app.string.navigate_back'))
          .width(56)
          .height(56)
          .padding(16)
          .objectFit(ImageFit.Contain)
          .fillColor($r('app.color.on_primary'))
          .onClick(() => {
            router.back();
          })

        // Widget.AppCompat.Toolbar.Title: 20sp medium, inset 16dp past the navigation button.
        Text(this.screenTitle)
          .id('statistics_title')
          .layoutWeight(1)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .fontSize(20)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.on_primary'))
          .margin({ left: 16 })

        // menu_history.xml declares action_history_clear with app:showAsAction="never", so the
        // toolbar shows the ActionBar OVERFLOW button and the item lives inside its popup. The
        // port had put the item's title straight on the bar and drawn no overflow at all
        // (base.ui.json has no action_history_clear node and does carry "More options" at
        // [960,84][1080,228]). The slug is the overflow's content-desc, as it has no resource-id.
        Image($r('app.media.ic_more_vert'))
          .id('more_options')
          .width(48)
          .height(48)
          .padding(12)
          .margin({ right: 8 })
          .objectFit(ImageFit.Contain)
          .fillColor($r('app.color.on_primary'))
          .bindMenu(this.historyOverflowMenu, SQUARE_MENU_CORNERS)
      }
      .width('100%')
      // Toolbar: ?attr/actionBarSize tall on ?attr/colorPrimary.
      .height(56)
      .alignItems(VerticalAlign.Center)
      .backgroundColor($r('app.color.primary'))
      }

      this.listHeader()

      Stack() {
        LocalItemListAdapter({
          dataSource: this.historyList,
          row: (item: PlaylistLocalItem): void => {
            this.itemRow(item);
          }
        })

        if (this.isLoading) {
          LoadingProgress()
            .id('loading_progress_bar')
            .width(48)
            .height(48)
            .color($r('app.color.accent'))
        }

        if (this.errorInfo !== null) {
          Column() {
            Text(this.errorInfo)
              .id('error_message_view')
              .fontSize(16)
              .fontWeight(FontWeight.Bold)
              .fontColor(COLOR_ON_SURFACE)
              .textAlign(TextAlign.Center)
            Button(Localization.buttonLabel('retry'))
              .id('error_retry_button')
              .fontSize(16)
              .fontColor($r('app.color.on_primary'))
              .backgroundColor($r('app.color.primary'))
              .margin({ top: 4 })
              .onClick(() => {
                this.startLoading();
              })
          }
          .id('error_panel')
          .padding(16)
          .alignItems(HorizontalAlign.Center)
        }

        // showEmptyState() — rendered INSTEAD of the rows, never beside them.
        if (!this.isLoading && this.errorInfo === null && this.loadedCount === 0) {
          Column() {
            Text('(╯°-°)╯')
              .fontFamily('monospace')
              .fontSize(35)
              .fontColor(COLOR_ON_SURFACE)
              .margin({ bottom: 10 })
            Text($r('app.string.no_videos'))
              .fontSize(24)
              .fontColor(COLOR_ON_SURFACE)
          }
          .id('empty_state_view')
          .alignItems(HorizontalAlign.Center)
        }
      }
      .width('100%')
      .layoutWeight(1)

      // The popup's surface, mounted only while one is being opened or is open. 1x1 and
      // transparent: PiP composites the video into its own window, the in-page node only has to
      // exist and be bound to the player.
      if (this.popupSurfaceMounted) {
        PopupPlayerSurface({
          controller: this.popupSurfaceController,
          onSurfaceReady: (): void => {
            this.onPopupSurfaceReady();
          }
        })
      }
    }
    .id('StatisticsPlaylistFragmentPage')
    .width('100%')
    .height('100%')
    .backgroundColor(themedBackground(this.blackTheme))
  }

  /** DownloadDialog over this list, mounted the way the feed mounts it. */
}
