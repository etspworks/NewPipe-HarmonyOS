/**
 * S3 - PlayQueueActivity (screen_play_queue_activity), activity_player_queue_control.xml +
 * play_queue_item.xml + menu_play_queue.xml + menu_play_queue_bg.xml + menu_play_queue_item.xml.
 *
 * activity_player_queue_control.xml is a bottom-anchored RelativeLayout, so the real tree is a
 * Column of five bands with ONE overlay:
 *   appbar             the Toolbar (title app_name) and its menu
 *   play_queue         the RecyclerView, filling everything between appbar and metadata
 *   metadata           song_name over artist_name; the whole block is clickable
 *   progress_bar       current_time, seek_bar, end_time, live_sync
 *   playback_controls  repeat, previous, rewind, play/pause, forward, next, shuffle
 *   seek_display       centerInParent ABOVE metadata, GONE unless a drag is in progress
 * launchMode=singleTask, not exported. It binds PlayerService directly with
 * BIND_PLAYER_HOLDER_ACTION (a source comment says this deliberately bypasses PlayerHolder) and
 * FINISHES on onServiceStopped() - S4 wires that teardown, and every subscription is disposed in
 * aboutToDisappear.
 *
 * Routed edges, all read off PlayQueueActivity.onOptionsItemSelected (verbatim, via codegraph):
 *   action_settings      -> NavigationHelper.openSettings   -> SettingsActivity      (wired)
 *   action_switch_main   -> setRecovery(); playOnMainPlayer  -> VideoDetailFragment   (wired)
 *   menu_item_details    -> NavigationHelper.openVideoDetail -> VideoDetailFragment   (wired)
 *   menu_item_channel_details -> fetchUploaderUrlIfSparse -> ChannelFragment          (wired)
 * Two `present` edges are overlays and are NOT pushed:
 *   action_playback_speed -> PlaybackParameterDialog, presentation modal whose hostScreen is THIS
 *     screen. It is a CustomDialogController opened by action_playback_speed, matching
 *     PlayQueueActivity.openPlaybackParameterDialog().
 *   menu_item_download    -> DownloadDialog, presentation modal hosted by screen_video_detail -
 *     mounted on ITS host, so that control stays unwired here (an expected Stage-0 warn).
 *
 * MENUS ARE POPUPS, so they are CONDITIONAL subtrees here, never permanently visible rows:
 *  - menu_play_queue + menu_play_queue_bg are ONE toolbar menu. showAsAction=ifRoom puts
 *    action_append_playlist, action_playback_speed, action_audio_track and action_mute in the bar
 *    itself; showAsAction=never puts action_settings, action_system_audio, action_switch_main,
 *    action_switch_background and action_switch_popup in the overflow.
 *  - menu_play_queue_item is the LONG-PRESS popup on a queue row (QueueItemMenuUtil.openPopupMenu),
 *    so it renders only while a row is held.
 *
 * PLAN GAP (reported, not silently absorbed): controlInventory omits the toolbar menu items
 * themselves, two of which the plan's OWN navOut edges depend on. They are rendered with their
 * real source slugs because the source defines them; the inventory needs those entries added.
 *
 * conditionalVariants, built here as real ArkUI `if` rather than one flattened layout:
 *  - action_switch_popup only when !player.popupPlayerSelected()
 *  - action_switch_background only when !player.audioPlayerSelected()
 *  - action_audio_track hidden when availableStreams is null, has <2 entries, or the selected
 *    audio stream is empty (android:visible="false" is its start state)
 *  - live_sync shown and end_time hidden for LIVE_STREAM / AUDIO_LIVE_STREAM; the reverse
 *    otherwise. live_sync is a LABEL, not a jump-to-live-edge button - see the seek bar below.
 *  - control_play_pause is INVISIBLE and control_progress_bar shown when the player state is not
 *    PAUSED, PLAYING or COMPLETED; its own glyph is ic_play_arrow / ic_pause / ic_replay per state
 *  - action_mute flips title and icon to unmute / ic_volume_up while player.isMuted()
 *  - seek_display shows only while the seek bar is being dragged
 *
 * Other source facts S4 must honour and S3 must not pre-empt:
 *  - The audio-track submenu is BUILT AT RUNTIME under group id 71 (MENU_ID_AUDIO_TRACK) from
 *    Player.getCurrentMetadata().getMaybeAudioTrack().getAudioStreams() - never a literal list.
 *  - The queue row has THREE gestures: tap -> selectQueueItem, long-press -> the row popup menu,
 *    and the drag -> playQueue.move(); a horizontal swipe removes the item. The drag and the
 *    swipe live in PlayQueueItemTouchCallback, which wraps PlayQueueItemHolder here.
 *  - !playQueue.isComplete() plus a scroll to the bottom -> playQueue.fetch(); otherwise the
 *    scroll listener is cleared. That is PlayQueueAdapter's onReachEnd.
 *  - metadata tap -> scrollToSelected(): the queue smooth-scrolls to the playing index.
 *  - action_switch_popup needs SYSTEM_ALERT_WINDOW, which a self-signed build cannot grant -
 *    phase2-logic-contract §2.1 substitutes @ohos.PiPWindow with the in-app minimized player.
 *  - Share (menu_item_share) is NOT @kit.ShareKit: that Kit does not exist in this SDK. The send
 *    path is startAbility with the implicit ohos.want.action.sendData Want, with the mandatory
 *    @ohos.pasteboard copy + toast fallback (phase2-logic-contract §10.1).
 *  - control_fast_rewind / control_fast_forward use exo_controls_rewind / exo_controls_fastforward,
 *    ExoPlayer LIBRARY drawables with no res/drawable file to carry over and no icon-map entry.
 *    They render below on the nearest bundled glyph; S5 must substitute the real one.
 *
 * S5/S6 own every colour, size and glyph; S4 sets structure, state and the conditionals only.
 */
import { promptAction, router } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { PlayQueueItem } from '../model/app/PlayQueueItem';
import { PlayQueue, PlayQueueEvent, SimplePlayQueue, currentPlayQueue, setCurrentPlayQueue }
  from '../model/app/PlayQueue';
import { StreamInfo } from '../model/extractor/StreamInfo';
import { StreamType } from '../model/enums/StreamType';
import { PlayerService, PlayerStatus, PlayerPosition, PlayableSource, StreamSetAdapter }
  from '../common/player/PlayerService';
import { MediaSessionService } from '../common/player/MediaSessionService';
import { common } from '@kit.AbilityKit';
import { ExtractorHelper } from '../common/extractor/ExtractorHelper';
import { ServiceLocator } from '../common/di/ServiceLocator';
import { ShareUtils } from '../common/share/ShareUtils';
import { CompositeDisposable, Disposable, Observable } from '../common/rx/Rx';
import { Localization } from '../common/i18n/Localization';
import { PlaylistCreationDialog } from '../components/PlaylistCreationDialog';
import { PlaylistAppendDialog } from '../components/PlaylistAppendDialog';
import { PlaylistMetadataEntry } from '../model/db/view/PlaylistMetadataEntry';
import { LocalPlaylistManager, playlistAppendToast } from '../common/db/PlaylistManager';
import { AppDatabase } from '../common/db/AppDatabase';
import { StreamEntity } from '../model/db/entity/StreamEntity';
import { PlayQueueAdapter, PlayQueueDataSource } from '../components/PlayQueueAdapter';
import { PlayQueueItemHolder } from '../components/PlayQueueItemHolder';
import { PlayQueueItemTouchCallback } from '../components/PlayQueueItemTouchCallback';
import { PlayQueueRowMenu } from '../components/PlayQueueRowMenu';
import { PlaybackParameterDialogHost, PlaybackParameters, formatSpeed }
  from './PlaybackParameterDialogPage';
import { DIALOG_MASK_COLOR } from '../common/theme/ServiceTheme';
import { DownloadDialogHost } from './DownloadDialogPage';
import { PlayerPrefs } from '../common/player/PlayerPrefs';
import { openChannelOfQueueItem, openSystemSoundSettings } from '../common/util/QueueItemMenuUtil';
import { AudioTrackGroup, audioTrackName, groupAudioTracks } from '../components/AudioTrackAdapter';
import { AudioStream } from '../model/extractor/AudioStream';
import { preferredHeightOf } from '../common/settings/PreferredHeight';
import { default_resolution_key, default_resolution_value } from '../common/prefs/SettingsKeys';
import { AppPreferences } from '../common/prefs/Preferences';
import { BLACK_THEME_KEY, themedBackground } from '../common/theme/ThemeBackground';

/** Player.PLAY_PREV_ACTIVATION_LIMIT_MILLIS - Previous restarts the stream past this mark. */
const PLAY_PREV_ACTIVATION_LIMIT_MILLIS: number = 5000;

const TAG: string = 'PlayQueueActivityPage';

/**
 * activity_player_queue_control.xml declares current_time and end_time as "-:--:--" and
 * onProgressUpdate replaces them. Seeding them empty meant the two labels were simply absent
 * until the first position tick, and absent for good on a stream whose duration never arrives.
 */
const NO_TIME: string = '-:--:--';

/** onMetadataUpdate(info): song_name over artist_name. */
class QueueMetadata {
  title: string;
  uploader: string;

  constructor(title: string, uploader: string) {
    this.title = title;
    this.uploader = uploader;
  }
}

@Entry
@Component
export struct PlayQueueActivityPage {
  /** ThemeHelper's black theme: the window background follows it. */
  @StorageProp(BLACK_THEME_KEY) blackTheme: boolean = false;

  /** onMetadataUpdate(): songName and artistName, straight off the playing StreamInfo. */
  @State metadata: QueueMetadata = new QueueMetadata('', '');
  @State currentTime: string = NO_TIME;
  @State endTime: string = NO_TIME;
  /** onProgressUpdate(): seekBar setMax/setProgress, in milliseconds. */
  @State progress: number = 0;
  @State durationMs: number = 0;
  @State isLoading: boolean = false;
  @State errorInfo: string | null = null;
  /** seek_display is VISIBLE only while the bar is being dragged. */
  @State seeking: boolean = false;
  /**
   * onStartTrackingTouch/onStopTrackingTouch: only a real drag or tap seeks. ArkUI fires
   * onChange for the programmatic value change of every position tick too, and seeking there
   * re-seeks the player ~10x/second (801 Unsupport Capability on a live stream).
   */
  private seekBarTouched: boolean = false;
  @State seekDisplay: string = '';
  /** screen_playback_parameter_dialog, opened by action_playback_speed. */
  @State @Watch('onPlaybackParametersVisibility') showPlaybackParameters: boolean = false;
  /**
   * openPlaybackParameterDialog(): PlaybackParameterDialog.newInstance(player.getPlaybackSpeed(),
   * player.getPlaybackPitch(), player.getPlaybackSkipSilence(), this). AVPlayer carries no pitch
   * or skip-silence control, so those two are held HERE - the dialog's own values round-trip
   * through the activity exactly as the source's do.
   */
  @State playbackParameters: PlaybackParameters = new PlaybackParameters(1.0, 1.0, false);

  /**
   * player.getPlayQueue().getStreams() - the bound rows. The data source beside it is what
   * LazyForEach reads (Rule 7): an IDataSource cannot be the @State value itself.
   */
  @Watch('onQueueListChanged') @State queueList: PlayQueueItem[] = [];
  private queueSource: PlayQueueDataSource = new PlayQueueDataSource();
  /** PlayQueue.getIndex() - the playing row, which the source highlights. */
  @State queueIndex: number = 0;

  /**
   * info.getStreamType(): live_sync vs end_time. Named after the accessor the plan binds to,
   * because that is the identifier the variant is recorded against.
   */
  @State getStreamType: StreamType = StreamType.VIDEO_STREAM;
  /**
   * onStateChanged(): anything outside PAUSED/PLAYING/COMPLETED swaps in control_progress_bar.
   * The seed is the LAYOUT's own pre-callback appearance, not a guess: until the service binds and
   * onStateChanged fires, activity_player_queue_control.xml shows control_play_pause with
   * android:src="@drawable/ic_pause" and control_progress_bar android:visibility="invisible" -
   * which is what S0010 captures. Seeding IDLE rendered the spinner on an unbound screen instead.
   */
  @State playerStatus: PlayerStatus = PlayerStatus.PLAYING;
  /** player.isMuted() - action_mute flips its own title and icon. */
  @State isMuted: boolean = false;
  /** player.popupPlayerSelected() / audioPlayerSelected() gate two overflow entries. */
  @State popupPlayerSelected: boolean = false;
  @State audioPlayerSelected: boolean = false;
  /**
   * getMaybeAudioTrack().getAudioStreams(): action_audio_track is hidden below two entries.
   * Built at runtime from the player's metadata - never a literal list.
   */
  @State audioTrackSubmenu: string[] = [];
  /** The MENU_ID_AUDIO_TRACK submenu is a popup, so it renders only while it is open. */
  @State audioTrackMenuOpen: boolean = false;
  /** cycleNextRepeatMode(): off -> one -> all. */
  @State repeatMode: number = 0;
  /** !player.isLiveEdge(): live_sync is clickable only then. */
  @State behindLiveEdge: boolean = false;
  @State shuffled: boolean = false;

  /** The toolbar overflow (showAsAction=never) - a popup, so a conditional subtree. */
  @State overflowOpen: boolean = false;
  /** QueueItemMenuUtil.openPopupMenu(...) on a row long-press. */
  @State rowMenuOpen: boolean = false;
  /** Which row the popup belongs to; -1 while it is closed. */
  @State heldIndex: number = -1;

  /** Every subscription this screen opens; onServiceStopped() disposes the lot. */
  private disposables: CompositeDisposable = new CompositeDisposable();

  /**
   * menu_item_download -> DownloadDialog for the HELD row. The dialog is a component like any
   * other here, so this screen hosts its own copy instead of leaving the entry dead.
   */
  @State @Watch('onDownloadDialogVisibility') showDownloadDialog: boolean = false;
  @State private downloadServiceId: number = 0;
  @State private downloadUrl: string = '';
  private downloadDialog: CustomDialogController = new CustomDialogController({
    maskColor: DIALOG_MASK_COLOR,
    customStyle: true,
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

  /**
   * The rows the playlist dialogs write: the whole queue from the toolbar, ONE row from a queue
   * row's own menu (QueueItemMenuUtil: PlaylistDialog over List.of(new StreamEntity(item))).
   */
  private appendTargets: StreamEntity[] | null = null;

  /** The current stream's audio tracks, grouped as the submenu lists them. */
  private audioTrackGroups: AudioTrackGroup[] = [];
  /** player.getPlayQueue() - the live queue this screen controls. */
  private playQueue: PlayQueue | null = null;
  /** The live queue's own event bus, re-subscribed whenever the queue is replaced. */
  private queueEvents: Disposable | null = null;

  /**
   * PlaylistAppendDialog.fromPlayQueueItems(playQueue.getStreams()). The source wraps this in
   * PlaylistDialog.createCorrespondingDialog(), which asks LocalPlaylistManager.hasPlaylists()
   * and shows the APPEND picker when any local playlist exists and the CREATION dialog only
   * when there are none. This screen used to open the creation dialog unconditionally, on the
   * premise that no local playlist existed - device review found one (QADup) on both devices and
   * the reference opening the picker, so the branch is taken here now, exactly as the feed does.
   */
  private playlistManager: LocalPlaylistManager | null = null;
  /** The picker's rows; @State because PlaylistAppendDialog @Links them (see its comment). */
  @State appendPlaylists: PlaylistMetadataEntry[] = [];
  private appendDialog: CustomDialogController = new CustomDialogController({
    maskColor: DIALOG_MASK_COLOR,
    customStyle: true,
    builder: PlaylistAppendDialog({
      playlists: this.appendPlaylists,
      onSelected: (playlist: PlaylistMetadataEntry): void => {
        this.appendQueueToPlaylist(playlist);
      },
      onNewPlaylist: (): void => {
        this.creationDialog.open();
      }
    })
  });
  private creationDialog: CustomDialogController = new CustomDialogController({
    maskColor: DIALOG_MASK_COLOR,
    customStyle: true,
    builder: PlaylistCreationDialog({
      name: '',
      onCreate: (name: string): void => {
        this.createPlaylistFromQueue(name);
      }
    })
  });

  /**
   * PlaylistDialog.createCorrespondingDialog(): a factory, not a dialog. With at least one local
   * playlist the reference shows the picker ("New Playlist" plus each playlist); with none it
   * goes straight to creation.
   */
  private async openPlaylistDialog(targets: StreamEntity[] | null = null): Promise<void> {
    this.appendTargets = targets;
    const manager: LocalPlaylistManager | null = await this.openPlaylistManager();
    if (manager === null) {
      return;
    }
    let has: boolean = false;
    try {
      has = await manager.hasPlaylists();
    } catch (err) {
      const failure: BusinessError = err as BusinessError;
      hilog.warn(0x0000, TAG, 'hasPlaylists: %{public}s', failure.message);
    }
    if (!has) {
      this.creationDialog.open();
      return;
    }
    try {
      // getPlaylistDuplicates(streams[0].url), as PlaylistAppendDialog queries it.
      const rows: StreamEntity[] = this.playlistRows();
      this.appendPlaylists = rows.length === 0
        ? await manager.getPlaylists() : await manager.getPlaylistDuplicates(rows[0].url);
      this.appendDialog.open();
    } catch (err) {
      const failure: BusinessError = err as BusinessError;
      promptAction.showToast({ message: failure.message, duration: 2000 });
    }
  }

  /** PlaylistAppendDialog.onPlaylistSelected(): the WHOLE queue is appended, as fromPlayQueueItems. */
  private async appendQueueToPlaylist(playlist: PlaylistMetadataEntry): Promise<void> {
    const manager: LocalPlaylistManager | null = await this.openPlaylistManager();
    const rows: StreamEntity[] = this.playlistRows();
    if (manager === null || rows.length === 0) {
      return;
    }
    try {
      await manager.appendToPlaylist(playlist.uid, rows);
      promptAction.showToast({ message: playlistAppendToast(playlist),
        duration: 2000 });
    } catch (err) {
      const failure: BusinessError = err as BusinessError;
      promptAction.showToast({ message: failure.message, duration: 2000 });
    }
  }

  /** The queue's streams as playlist rows: PlayQueueItem carries everything StreamEntity needs. */
  private queueRows(): StreamEntity[] {
    return this.queueList.map((item: PlayQueueItem): StreamEntity => PlayQueueActivityPage.rowOf(item));
  }

  private static rowOf(item: PlayQueueItem): StreamEntity {
    const row: StreamEntity = new StreamEntity(item.serviceId, item.url, item.title,
      item.streamType, item.duration, item.uploader);
    row.uploaderUrl = item.uploaderUrl;
    return row;
  }

  /** What the open playlist dialog writes: the held row's, or the whole queue's. */
  private playlistRows(): StreamEntity[] {
    const targets: StreamEntity[] | null = this.appendTargets;
    return targets !== null ? targets : this.queueRows();
  }

  private async createPlaylistFromQueue(name: string): Promise<void> {
    const manager: LocalPlaylistManager | null = await this.openPlaylistManager();
    const rows: StreamEntity[] = this.playlistRows();
    if (manager === null || name.length === 0 || rows.length === 0) {
      return;
    }
    try {
      await manager.createPlaylist(name, rows);
      // PlaylistCreationDialog: Toast @string/playlist_creation_success.
      promptAction.showToast({ message: $r('app.string.playlist_creation_success'),
        duration: 2000 });
    } catch (err) {
      const failure: BusinessError = err as BusinessError;
      promptAction.showToast({ message: failure.message, duration: 2000 });
    }
  }

  /** The playlist store this screen's append action writes through; opened lazily. */
  private async openPlaylistManager(): Promise<LocalPlaylistManager | null> {
    const existing: LocalPlaylistManager | null = this.playlistManager;
    if (existing !== null) {
      return existing;
    }
    try {
      const db: AppDatabase = await AppDatabase.getInstance(getContext(this) as common.Context);
      const manager: LocalPlaylistManager = new LocalPlaylistManager(db);
      this.playlistManager = manager;
      return manager;
    } catch (err) {
      const failure: BusinessError = err as BusinessError;
      promptAction.showToast({ message: failure.message, duration: 2000 });
      return null;
    }
  }

  aboutToAppear(): void {
    this.openPlaylistManager();
    this.onQueueListChanged();
    this.seedQueueFromPlayer();
    this.observeQueue();
    this.observePlayer();
  }

  /** onDestroy(): unbind() and dispose every subscription. */
  aboutToDisappear(): void {
    const events: Disposable | null = this.queueEvents;
    if (events !== null) {
      events.dispose();
      this.queueEvents = null;
    }
    this.disposables.dispose();
  }

  /**
   * onServiceConnected() binds the player's EXISTING queue. A stream started down a path that
   * publishes no queue of its own (a bare deep link, the mini player) still has to be controllable
   * here, so it is promoted to a one-item queue ONCE - rather than re-synthesised into the list on
   * every metadata tick, which is what pinned this screen to a single row no matter what was
   * enqueued.
   */
  private seedQueueFromPlayer(): void {
    if (currentPlayQueue.getValue() !== null) {
      return;
    }
    const info: StreamInfo | null = PlayerService.getInstance().currentInfo.getValue();
    if (info === null) {
      return;
    }
    setCurrentPlayQueue(new SimplePlayQueue(0, [PlayQueueItem.fromStreamInfo(info)]));
  }

  /** The handle reports the queue being REPLACED; the queue's own bus reports it changing. */
  private observeQueue(): void {
    this.disposables.add(currentPlayQueue.subscribeCallbacks((queue: PlayQueue | null): void => {
      this.bindQueue(queue);
    }, (error: Error): void => {
      hilog.warn(0x0000, TAG, 'play queue: %{public}s', error.message);
    }));
  }

  private bindQueue(queue: PlayQueue | null): void {
    const previous: Disposable | null = this.queueEvents;
    if (previous !== null) {
      previous.dispose();
    }
    this.queueEvents = null;
    this.playQueue = queue;
    if (queue === null) {
      this.queueIndex = 0;
      this.queueList = [];
      return;
    }
    const bus: Observable<PlayQueueEvent> | null = queue.getBroadcastReceiver();
    if (bus !== null) {
      // Every mutation - append, remove, move, shuffle, select - arrives here, which is what
      // keeps the rendered list and the model the same list.
      this.queueEvents = bus.subscribeCallbacks((event: PlayQueueEvent): void => {
        this.readQueue();
      }, (error: Error): void => {
        hilog.warn(0x0000, TAG, 'play queue event: %{public}s', error.message);
      });
    }
    this.readQueue();
  }

  /** The index is written BEFORE the list: the @Watch on queueList reads it back. */
  private readQueue(): void {
    const queue: PlayQueue | null = this.playQueue;
    if (queue === null) {
      return;
    }
    this.queueIndex = queue.getIndex();
    this.queueList = queue.getStreams();
    this.shuffled = queue.isShuffled();
  }

  /**
   * The bound queue and the LazyForEach data source are kept in step here, so a move or a
   * removal only ever has to touch one of them.
   */
  private onQueueListChanged(): void {
    this.queueSource.setItems(this.queueList);
    const playing: PlayQueueItem | undefined = this.queueList[this.queueIndex];
    if (playing !== undefined) {
      this.metadata = new QueueMetadata(playing.getTitle(), playing.getUploader());
    }
  }

  /**
   * PlayerService's state / position subjects replace onProgressUpdate / onStateChanged /
   * onMetadataUpdate, exactly as the video page observes them.
   */
  private observePlayer(): void {
    const player: PlayerService = PlayerService.getInstance();
    // onServiceConnected(): `if (player == null || player.getPlayQueue() == null ||
    // player.exoPlayerIsNull()) { unbind(); }` — with no player the source observes NOTHING, so
    // control_play_pause stays as activity_player_queue_control.xml declares it (visible,
    // ic_pause) and control_progress_bar stays invisible, which is what S0010 captures.
    // Subscribing regardless replaces that with the state subject's idle seed and renders the
    // spinner in its place.
    if (!player.hasPlayer()) {
      return;
    }
    this.disposables.add(player.position.subscribeCallbacks((at: PlayerPosition): void => {
      this.progress = at.positionMs;
      this.durationMs = at.durationMs;
      // The subject's own seed is (0, 0): formatting it overwrote the layout's "-:--:--" with a
      // "00:00 / 00:00" that was never a measurement. Only a known duration is a measurement.
      if (at.durationMs <= 0) {
        return;
      }
      this.currentTime = Localization.getDurationString(Math.floor(at.positionMs / 1000));
      this.endTime = Localization.getDurationString(Math.floor(at.durationMs / 1000));
    }, (error: Error): void => {
      hilog.warn(0x0000, TAG, 'player position: %{public}s', error.message);
    }));
    this.disposables.add(player.behindLiveEdge.subscribeCallbacks((behind: boolean): void => {
      this.behindLiveEdge = behind;
    }, (error: Error): void => {
      hilog.warn(0x0000, TAG, 'live edge: %{public}s', error.message);
    }));
    this.disposables.add(player.state.subscribeCallbacks((status: PlayerStatus): void => {
      this.playerStatus = status;
    }, (error: Error): void => {
      hilog.warn(0x0000, TAG, 'player state: %{public}s', error.message);
    }));
    // The rows come from the QUEUE now (observeQueue), not from whatever single stream the
    // service happens to be on - synthesising the list here is exactly what capped this screen
    // at one row. currentInfo is still worth following for the stream TYPE, which decides
    // live_sync versus end_time.
    this.disposables.add(player.currentInfo.subscribeCallbacks((info: StreamInfo | null): void => {
      if (info !== null) {
        this.getStreamType = info.getStreamType();
      }
      this.buildAudioTrackMenu(info);
    }, (error: Error): void => {
      hilog.warn(0x0000, TAG, 'player metadata: %{public}s', error.message);
    }));
    // onPrepareOptionsMenu(): each "switch to X" entry is hidden while X IS the current player.
    const source: PlayableSource | null = player.getSource();
    this.audioPlayerSelected = source !== null && source.audioOnly;
    this.popupPlayerSelected = player.isPipActive();
    // isMuted has to open on the LEVEL, not on false: the toolbar icon otherwise offers to mute
    // a player that is already silent.
    this.isMuted = player.currentVolume() === 0;
    this.disposables.add(player.lastError.subscribeCallbacks((message: string): void => {
      if (message.length > 0) {
        this.errorInfo = message;
      }
    }, (error: Error): void => {
      hilog.warn(0x0000, TAG, 'player error: %{public}s', error.message);
    }));
  }

  /**
   * OnSelectedListener.selected -> player.selectQueueItem(item): the queue index moves and the
   * player is re-prepared with that stream, which is also what refreshes the media session.
   */
  private async selectQueueItem(index: number): Promise<void> {
    const item: PlayQueueItem | undefined = this.queueList[index];
    if (item === undefined) {
      return;
    }
    // setIndex() is what moves the queue's OWN cursor, and its SelectEvent is what re-reads the
    // list here. Writing queueIndex directly left the model on the old item, so the next / previous
    // buttons and the row highlight walked off a stale position.
    const queue: PlayQueue | null = this.playQueue;
    if (queue !== null) {
      queue.setIndex(index);
    } else {
      this.queueIndex = index;
    }
    this.metadata = new QueueMetadata(item.getTitle(), item.getUploader());
    this.isLoading = true;
    try {
      const info: StreamInfo =
        await ExtractorHelper.getStreamInfo(item.getServiceId(), item.getUrl(), false);
      this.getStreamType = info.getStreamType();
      // The player keeps its kind across the queue (a background queue stays audio-only) and a
      // video row opens at the Default resolution, as the detail page's own start does.
      const current: PlayableSource | null = PlayerService.getInstance().getSource();
      const audioOnly: boolean = current !== null && current.audioOnly;
      await PlayerService.getInstance().prepare(info, audioOnly,
        audioOnly ? 0 : PlayerPrefs.defaultPlaybackHeight());
      // MediaSessionPlayerUi.updateMetadata(): the session follows the queue selection. Reached
      // with no session at all, setMetadata() was a silent no-op and the queue played without any
      // system controls or continuous task; startDetached() creates one first when it has to.
      await MediaSessionService.getInstance()
        .startDetached(getContext(this) as common.UIAbilityContext, info);
    } catch (err) {
      this.errorInfo = (err as BusinessError).message;
    } finally {
      this.isLoading = false;
    }
  }

  /**
   * player.playNext(): playQueue.offsetIndex(+1), which wraps a COMPLETE queue back to its first
   * item and stops on the last item of one that is still loading.
   */
  private playNext(): void {
    const length: number = this.queueList.length;
    if (length === 0) {
      return;
    }
    const raw: number = this.queueIndex + 1;
    const queue: PlayQueue | null = this.playQueue;
    const target: number = raw < length ? raw
      : (queue !== null && queue.isComplete() ? raw % length : length - 1);
    if (target !== this.queueIndex) {
      this.selectQueueItem(target);
    }
  }

  /**
   * player.playPrevious(): past PLAY_PREV_ACTIVATION_LIMIT_MILLIS - or on the queue's first item -
   * the CURRENT stream restarts; inside it the queue steps back.
   */
  private playPrevious(): void {
    if (this.progress > PLAY_PREV_ACTIVATION_LIMIT_MILLIS || this.queueIndex <= 0) {
      PlayerService.getInstance().seekTo(0);
      return;
    }
    this.selectQueueItem(this.queueIndex - 1);
  }

  /** onStateChanged(): STATE_PAUSED, STATE_PLAYING and STATE_COMPLETED are the "has button" set. */
  private hasPlayPauseButton(): boolean {
    return this.playerStatus === PlayerStatus.PAUSED || this.playerStatus === PlayerStatus.PLAYING
      || this.playerStatus === PlayerStatus.COMPLETED;
  }

  /** The play/pause glyph per state: ic_play_arrow / ic_pause / ic_replay. */
  private playPauseIcon(): Resource {
    if (this.playerStatus === PlayerStatus.COMPLETED) {
      return $r('app.media.ic_replay');
    }
    return this.playerStatus === PlayerStatus.PLAYING
      ? $r('app.media.ic_pause') : $r('app.media.ic_play_arrow');
  }

  /** buildAudioTrackMenu(): hidden below two tracks. */
  private hasAudioTrackMenu(): boolean {
    return this.audioTrackSubmenu.length >= 2;
  }

  /**
   * buildAudioTrackMenu(): one entry per audio TRACK of the playing stream - the same grouping and
   * labels the player's own audio-track popup shows.
   */
  private buildAudioTrackMenu(info: StreamInfo | null): void {
    const streams: AudioStream[] = info === null ? [] : info.getAudioStreams();
    this.audioTrackGroups = groupAudioTracks(streams);
    this.audioTrackSubmenu = this.audioTrackGroups.map((group: AudioTrackGroup): string => {
      const label: string = audioTrackName(group.first());
      return label.length > 0 ? label : Localization.getString('unknown_audio_track');
    });
  }

  /**
   * onOptionsItemSelected(MENU_ID_AUDIO_TRACK): player.setAudioTrack(trackId). The player is
   * re-sourced on that track, keeping its position and its kind (video or background).
   */
  private async selectAudioTrack(index: number): Promise<void> {
    const group: AudioTrackGroup | undefined = this.audioTrackGroups[index];
    const info: StreamInfo | null = PlayerService.getInstance().currentInfo.getValue();
    const first: AudioStream | null = group === undefined ? null : group.first();
    if (info === null || first === null) {
      return;
    }
    const trackId: string | null = first.getAudioTrackId();
    const id: string = trackId === null ? '' : trackId;
    const at: number = id.lastIndexOf('.');
    PlayerService.getInstance().rememberPickedAudioLanguage(at > 0 ? id.substring(0, at) : id);
    const current: PlayableSource | null = PlayerService.getInstance().getSource();
    const audioOnly: boolean = current !== null && current.audioOnly;
    try {
      await PlayerService.getInstance().prepare(info, audioOnly,
        audioOnly ? 0 : PlayerPrefs.defaultPlaybackHeight(), id);
    } catch (err) {
      this.errorInfo = (err as BusinessError).message;
    }
  }

  /** scrollToSelected() - the metadata block smooth-scrolls the queue to the playing index. */
  private scrollToSelected(): void {
    // scrollToPosition(getPlayQueue().getIndex()): the List belongs to PlayQueueAdapter, which
    // exposes no Scroller, so the selection is re-asserted and the highlight follows it.
    const playing: PlayQueueItem | undefined = this.queueList[this.queueIndex];
    if (playing !== undefined) {
      this.metadata = new QueueMetadata(playing.getTitle(), playing.getUploader());
    }
    hilog.info(0x0000, TAG, 'scroll to queue index %{public}d', this.queueIndex);
  }

  /** menu_item_share: the implicit sendData Want, with the pasteboard fallback. */
  private shareHeldItem(): void {
    const item: PlayQueueItem | undefined = this.queueList[this.heldIndex];
    if (item === undefined) {
      return;
    }
    const share: ShareUtils = ServiceLocator.get().share;
    share.shareText(item.getTitle(), item.getUrl()).catch((err: BusinessError): void => {
      hilog.error(0x0000, TAG, 'share failed: %{public}s', err.message);
    });
  }

  /** The held row, for the popup menu's navigations. */
  private heldItem(): PlayQueueItem | null {
    const item: PlayQueueItem | undefined = this.queueList[this.heldIndex];
    return item === undefined ? null : item;
  }

  private openRowMenu(index: number): void {
    this.heldIndex = index;
    this.rowMenuOpen = true;
  }

  private closeRowMenu(): void {
    this.rowMenuOpen = false;
    this.heldIndex = -1;
  }

  private anyMenuOpen(): boolean {
    return this.overflowOpen || this.rowMenuOpen || this.audioTrackMenuOpen;
  }

  /** PopupMenu.dismiss(): a tap outside or Back closes the popup, never the screen. */
  private closeMenus(): void {
    this.overflowOpen = false;
    this.audioTrackMenuOpen = false;
    this.closeRowMenu();
  }

  onBackPress(): boolean {
    if (this.anyMenuOpen()) {
      this.closeMenus();
      return true;
    }
    return false;
  }

  /* //////////////////////////////////////////////////////////////////////////
  // Builders
  ////////////////////////////////////////////////////////////////////////// */

  private playbackParameterDialog: CustomDialogController = new CustomDialogController({
    customStyle: true,
    // The AlertDialog's backgroundDimAmount 0.6; the system default mask is much lighter.
    maskColor: DIALOG_MASK_COLOR,
    // An outside tap or back gesture closes the controller without touching the @Link.
    cancel: (): void => {
      this.showPlaybackParameters = false;
    },
    builder: PlaybackParameterDialogHost({
      isShown: this.showPlaybackParameters,
      initialValues: this.playbackParameters,
      // PlayQueueActivity implements PlaybackParameterDialog.Callback:
      //   onPlaybackParameterChanged -> player.setPlaybackParameters(tempo, pitch, skipSilence)
      onPlaybackParameterChanged:
        (tempo: number, pitchPercent: number, skipSilence: boolean): void => {
          this.onPlaybackParameterChanged(tempo, pitchPercent, skipSilence);
        }
    })
  });

  private onPlaybackParametersVisibility(): void {
    if (this.showPlaybackParameters) {
      this.playbackParameterDialog.open();
    } else {
      this.playbackParameterDialog.close();
    }
  }

  /**
   * PlayQueueActivity.onPlaybackParameterChanged(playbackTempo, playbackPitch,
   * playbackSkipSilence) -> player.setPlaybackParameters(...).
   *
   * AVPlayer applies the TEMPO through setPlaybackRate(number) - continuous, 0.125 ~ 4, and
   * PlayerService.setSpeed returns the rate that will really play (T-0133b). It has NOTHING for
   * pitch or skip-silence, so those two are recorded and logged rather than silently discarded;
   * the dialog shows them as unavailable. The reasons are on PlaybackParameterDialogPage.
   */
  private onPlaybackParameterChanged(playbackTempo: number, playbackPitch: number,
    playbackSkipSilence: boolean): void {
    // Player.setPlaybackParameters(): applied AND saved for the next session.
    const applied: number = PlayerService.getInstance()
      .setPlaybackParameters(playbackTempo, playbackPitch, playbackSkipSilence);
    this.playbackParameters =
      new PlaybackParameters(playbackTempo, playbackPitch, playbackSkipSilence);
    hilog.info(0x0000, TAG,
      'playback parameters: tempo=%{public}f (applied %{public}f) pitch=%{public}f '
        + 'skipSilence=%{public}d (pitch and skip-silence are not settable on AVPlayer)',
      playbackTempo, applied, playbackPitch, playbackSkipSilence ? 1 : 0);
  }

  /** play_queue_item, wrapped in the ItemTouchHelper callback that owns drag and swipe. */
  @Builder
  queueRow(item: PlayQueueItem, index: number) {
    PlayQueueItemTouchCallback({
      index: index,
      onMove: (fromIndex: number, toIndex: number): void => {
        // TouchCallback.onMove -> player.getPlayQueue().move(sourceIndex, targetIndex). Moving the
        // rendered copy alone left the queue itself in its old order, so a reorder survived only
        // until the next refresh; the queue's MoveEvent re-reads the list for us.
        this.moveQueueItem(fromIndex, toIndex);
      },
      onSwiped: (removedIndex: number): void => {
        // onSwiped -> player.getPlayQueue().remove(index)
        this.removeQueueItem(removedIndex);
      }
    }) {
      PlayQueueItemHolder({
        item: item,
        // PlayQueueActivity's list is the one mount on a LIGHT ground.
        onDarkPanel: false,
        selected: index === this.queueIndex,
        onSelected: (): void => {
          // OnSelectedListener.selected -> player.selectQueueItem(item)
          this.selectQueueItem(index);
        },
        onHeld: (): void => {
          this.openRowMenu(index);
        }
      })
    }
  }

  /** TouchCallback.onMove -> playQueue.move(); the queue's own event refreshes the list. */
  private moveQueueItem(fromIndex: number, toIndex: number): void {
    const queue: PlayQueue | null = this.playQueue;
    if (queue === null) {
      this.queueSource.move(fromIndex, toIndex);
      return;
    }
    queue.move(fromIndex, toIndex);
  }

  /** control_shuffle -> playQueue.shuffle() / unshuffle(). */
  private toggleShuffle(): void {
    const queue: PlayQueue | null = this.playQueue;
    if (queue === null) {
      this.shuffled = !this.shuffled;
      return;
    }
    if (queue.isShuffled()) {
      queue.unshuffle();
    } else {
      queue.shuffle();
    }
    // shuffle() of a queue of two or fewer emits nothing, so read the flag back rather than
    // waiting for a ReorderEvent that never comes.
    this.shuffled = queue.isShuffled();
  }

  /** onSwiped / menu_item_remove -> playQueue.remove(). */
  private removeQueueItem(index: number): void {
    const queue: PlayQueue | null = this.playQueue;
    if (queue === null) {
      this.queueSource.removeAt(index);
      return;
    }
    queue.remove(index);
  }

  /**
   * menu_play_queue_item: the row's long-press popup, now the PlayQueueRowMenu component so the
   * player's own queue panel can raise the SAME menu. Every entry's action stays here, because
   * only this screen knows which row is held.
   */
  @Builder
  rowPopupMenu() {
    PlayQueueRowMenu({
      onRemove: (): void => {
        // playQueue.remove(playQueue.indexOf(item))
        if (this.heldIndex >= 0) {
          this.removeQueueItem(this.heldIndex);
        }
        this.closeRowMenu();
      },
      onDetails: (): void => {
        const item: PlayQueueItem | null = this.heldItem();
        this.closeRowMenu();
        router.pushUrl({
          url: 'pages/VideoDetailFragmentPage',
          params: {
            serviceId: item === null ? 0 : item.getServiceId(),
            url: item === null ? '' : item.getUrl(),
            name: item === null ? '' : item.getTitle()
          }
        }).catch((err: BusinessError): void => {
          hilog.error(0x0000, TAG, 'detail push failed: %{public}s', err.message);
        });
      },
      onAppendPlaylist: (): void => {
        // QueueItemMenuUtil: PlaylistDialog.createCorrespondingDialog(context,
        // List.of(new StreamEntity(item)), ...) - the HELD row, not the whole queue.
        const item: PlayQueueItem | null = this.heldItem();
        this.closeRowMenu();
        if (item !== null) {
          this.openPlaylistDialog([PlayQueueActivityPage.rowOf(item)]);
        }
      },
      onChannelDetails: (): void => {
        // fetchUploaderUrlIfSparse(): a sparse row has its stream fetched for the url first.
        const item: PlayQueueItem | null = this.heldItem();
        this.closeRowMenu();
        if (item !== null) {
          openChannelOfQueueItem(item);
        }
      },
      onShare: (): void => {
        // ShareUtils.shareText(...) - the implicit sendData Want, with the clipboard fallback.
        this.shareHeldItem();
        this.closeRowMenu();
      },
      onDownload: (): void => {
        // menu_item_download: the stream is fetched by the dialog itself, on the HELD row.
        const item: PlayQueueItem | null = this.heldItem();
        this.closeRowMenu();
        if (item !== null && item.getUrl().length > 0) {
          this.downloadServiceId = item.getServiceId();
          this.downloadUrl = item.getUrl();
          this.showDownloadDialog = true;
        }
      }
    })
  }

  /**
   * buildAudioTrackMenu(): the MENU_ID_AUDIO_TRACK submenu, built at runtime from
   * Player.getCurrentMetadata().getMaybeAudioTrack().getAudioStreams() - never a literal list.
   */
  @Builder
  audioTrackMenu() {
    Column() {
      ForEach(this.audioTrackSubmenu, (track: string, index: number) => {
        Text(track)
          .id('audio_track_item')
          .width('100%')
          .height(48)
          .padding({ left: 16, right: 16 })
          .fontSize(16)
          .fontColor($r('app.color.on_surface'))
          .textAlign(TextAlign.Start)
          .width('100%')
          .onClick(() => {
            // menu.add(MENU_ID_AUDIO_TRACK, i, ...): selecting an entry switches the track.
            this.audioTrackMenuOpen = false;
            this.selectAudioTrack(index);
          })
      }, (track: string, index: number) => `${index}-${track}`)
    }
    .id('audio_track_menu')
    .backgroundColor($r('app.color.surface'))
    .borderRadius(2)
    .padding({ top: 8, bottom: 8 })
    .constraintSize({ minWidth: 180 })
    .shadow({ radius: 8, color: '#33000000', offsetX: 0, offsetY: 2 })
  }

  /** The showAsAction=never half of menu_play_queue + menu_play_queue_bg. */
  @Builder
  overflowMenu() {
    Column() {
      // The reference keeps the volume toggle HERE, as the overflow's first entry - measured on
      // 0.29.1: Mute / Settings / Audio Settings / Switch to Main / Switch to Popup / Switch to
      // Background. The port had it on the toolbar instead, where the reference's bar carries no
      // volume control at all. Moved rather than dropped: the function is the reference's, only
      // its place was wrong.
      Text(this.isMuted ? $r('app.string.unmute') : $r('app.string.mute'))
        .id('action_mute')
        .width('100%')
        .height(48)
        .padding({ left: 16, right: 16 })
        .fontSize(16)
        .fontColor($r('app.color.on_surface'))
        .textAlign(TextAlign.Start)
        .onClick(() => {
          this.overflowOpen = false;
          // player.toggleMute(). AVPlayer has no mute of its own, so mute IS setVolume(0).
          this.isMuted = !this.isMuted;
          PlayerService.getInstance().setVolume(this.isMuted ? 0 : 1);
        })

      Text($r('app.string.settings'))
        .id('action_settings')
        .width('100%')
        .height(48)
        .padding({ left: 16, right: 16 })
        .fontSize(16)
        .fontColor($r('app.color.on_surface'))
        .textAlign(TextAlign.Start)
        .onClick(() => {
          this.overflowOpen = false;
          router.pushUrl({ url: 'pages/SettingsActivityPage' });
        })

      Text($r('app.string.play_queue_audio_settings'))
        .id('action_system_audio')
        .width('100%')
        .height(48)
        .padding({ left: 16, right: 16 })
        .fontSize(16)
        .fontColor($r('app.color.on_surface'))
        .textAlign(TextAlign.Start)
        .onClick(() => {
          // Settings.ACTION_SOUND_SETTINGS: the Settings app's Sounds & vibration page.
          this.overflowOpen = false;
          openSystemSoundSettings(getContext(this) as common.UIAbilityContext);
        })

      Text($r('app.string.switch_to_main'))
        .id('action_switch_main')
        .width('100%')
        .height(48)
        .padding({ left: 16, right: 16 })
        .fontSize(16)
        .fontColor($r('app.color.on_surface'))
        .textAlign(TextAlign.Start)
        .onClick(() => {
          this.overflowOpen = false;
          this.switchToMainPlayer();
        })

      // onPrepareOptionsMenu: visible only when the popup player is NOT the current one.
      if (!this.popupPlayerSelected) {
        Text($r('app.string.switch_to_popup'))
          .id('action_switch_popup')
          .width('100%')
          .height(48)
          .padding({ left: 16, right: 16 })
          .fontSize(16)
          .fontColor($r('app.color.on_surface'))
          .textAlign(TextAlign.Start)
          .onClick(() => {
            // SYSTEM_ALERT_WINDOW is ungrantable on a self-signed build: §2.1 substitutes
            // @ohos.PiPWindow with the in-app minimized player.
            this.overflowOpen = false;
            this.switchToPopupPlayer();
          })
      }

      // Likewise for the background (audio-only) player.
      if (!this.audioPlayerSelected) {
        Text($r('app.string.switch_to_background'))
          .id('action_switch_background')
          .width('100%')
          .height(48)
          .padding({ left: 16, right: 16 })
          .fontSize(16)
          .fontColor($r('app.color.on_surface'))
          .textAlign(TextAlign.Start)
          .onClick(() => {
            this.overflowOpen = false;
            this.switchToBackgroundPlayer();
          })
      }
    }
    .id('play_queue_overflow_menu')
    .backgroundColor($r('app.color.surface'))
    .borderRadius(2)
    .padding({ top: 8, bottom: 8 })
    // An ANCHORED popup under the overflow icon, not a full-width list. Each row is width('100%'),
    // so without a bound the Column stretched to the whole 1216px screen and the menu read as a
    // sheet - the "wrong size and position" this case reports. The reference's popup runs
    // x 528..1020 of 1080 with its top just under the toolbar: right-aligned, 46% of the width.
    .width('45%')
    .position({ x: '50%', y: 26 })
    .constraintSize({ minWidth: 180 })
    .shadow({ radius: 8, color: '#33000000', offsetX: 0, offsetY: 2 })
  }

  /**
   * setRecovery(): PlayQueueActivity records where the current item is before handing playback to
   * another player, so the one that takes over resumes instead of restarting.
   */
  private setRecoveryOnCurrentItem(): void {
    const queue: PlayQueue | null = this.playQueue;
    if (queue === null) {
      return;
    }
    const at: PlayerPosition | null = PlayerService.getInstance().position.getValue();
    queue.setRecovery(queue.getIndex(), at === null ? 0 : at.positionMs);
  }

  /** The item the other player has to be opened on - the queue's current one. */
  private currentQueueItem(): PlayQueueItem | null {
    const item: PlayQueueItem | undefined = this.queueList[this.queueIndex];
    return item === undefined ? null : item;
  }

  /**
   * action_switch_main -> setRecovery(); NavigationHelper.playOnMainPlayer(): the MAIN player is
   * the video detail screen, not the app's home - pushing MainActivityPage left the tester on the
   * feed with the player nowhere in sight, which is the whole of TC-PLAYER-234.
   */
  private switchToMainPlayer(): void {
    this.setRecoveryOnCurrentItem();
    const item: PlayQueueItem | null = this.currentQueueItem();
    if (item === null) {
      this.goBackToHost();
      return;
    }
    router.pushUrl({
      url: 'pages/VideoDetailFragmentPage',
      params: {
        'serviceId': item.getServiceId(),
        'url': item.getUrl(),
        'name': item.getTitle()
      }
    }).catch((err: BusinessError): void => {
      hilog.error(0x0000, TAG, 'switch to main failed: %{public}s', err.message);
    });
  }

  /**
   * action_switch_popup -> NavigationHelper.playOnPopupPlayer(). The popup window needs
   * SYSTEM_ALERT_WINDOW, so §2.1 substitutes PiP - and PiP needs an XComponent surface, which only
   * the video detail screen owns. It reads `popup` off the route (VideoDetailFragmentPage's
   * readArguments()) and runs the ONE openPopupPlayer(), mini-player fallback included.
   */
  private switchToPopupPlayer(): void {
    this.setRecoveryOnCurrentItem();
    const item: PlayQueueItem | null = this.currentQueueItem();
    if (item === null) {
      return;
    }
    promptAction.showToast({ message: $r('app.string.popup_playing_toast'), duration: 2000 });
    router.pushUrl({
      url: 'pages/VideoDetailFragmentPage',
      params: {
        'serviceId': item.getServiceId(),
        'url': item.getUrl(),
        'name': item.getTitle(),
        'popup': 'true'
      }
    }).catch((err: BusinessError): void => {
      hilog.error(0x0000, TAG, 'switch to popup failed: %{public}s', err.message);
    });
  }

  /**
   * action_switch_background -> NavigationHelper.playOnBackgroundPlayer(). Re-preparing the same
   * stream audio-only is refused by the device (PlayerService.prepare() documents the single-use
   * manifest), and the source's own point is not a new pipeline: background is the AVSession plus
   * the continuous task that keep the audio alive off-screen. That session is what is started
   * here, which is exactly what the playlist and history background buttons do.
   */
  private switchToBackgroundPlayer(): void {
    const info: StreamInfo | null = PlayerService.getInstance().currentInfo.getValue();
    if (info === null) {
      return;
    }
    promptAction.showToast({
      message: $r('app.string.background_player_playing_toast'),
      duration: 2000
    });
    this.audioPlayerSelected = true;
    MediaSessionService.getInstance()
      .startDetached(getContext(this) as common.UIAbilityContext, info)
      .catch((err: BusinessError): void => {
        this.audioPlayerSelected = false;
        this.errorInfo = err.message;
        hilog.error(0x0000, TAG, 'switch to background failed: %{public}s', err.message);
      });
  }

  /** finish(): pop, or land on the hosting screen when this page IS the stack (deep link). */
  private goBackToHost(): void {
    let depth: number = 0;
    try {
      depth = Number(router.getLength());
    } catch (err) {
      depth = 0;
    }
    if (depth > 1) {
      router.back();
      return;
    }
    router.replaceUrl({ url: 'pages/VideoDetailFragmentPage' })
      .catch((err: BusinessError) => {
        hilog.error(0x0000, 'NewPipe',
          'PlayQueueActivityPage: home could not reach the host page: %{public}s', err.message);
      });
  }

  build() {
    Stack({ alignContent: Alignment.Center }) {
      Column() {
        // appbar: the Toolbar, its title, the ifRoom actions and the overflow trigger.
        Row() {
          // base.ui.json: 'Navigate up' is [0,72][168,240] = a 56vp box on a 56vp toolbar.
          Image($r('app.media.ic_arrow_back'))
            .id('home')
            .accessibilityText($r('app.string.navigate_back'))
            .width(56)
            .height(56)
            .padding(16)
            .fillColor($r('app.color.on_primary'))
            .objectFit(ImageFit.Contain)
            .onClick(() => {
              // PlayQueueActivity.java:131-133 android.R.id.home -> finish(): pop back to the
              // hosting screen. A deep-linked launch replaceUrl's this page in as the ONLY page
              // in the stack, where a bare back() ends the ABILITY (device evidence S0010: the
              // process died and the system browser resurfaced), so fall back to the host page.
              this.goBackToHost();
            })

          // getSupportActionBar().setTitle(R.string.title_activity_play_queue) - the toolbar's
          // app:title="@string/app_name" is replaced in onCreate(). Title x=216px = the 72vp inset.
          Text($r('app.string.title_activity_play_queue'))
            .id('toolbar_title')
            .layoutWeight(1)
            .maxLines(1)
            .fontSize(20)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.on_primary'))
            .margin({ left: 16 })
            .textOverflow({ overflow: TextOverflow.Ellipsis })

          // Each ifRoom action is a 48vp box ([672,84][816,228] and its siblings).
          Image($r('app.media.ic_playlist_add'))
            .id('action_append_playlist')
            .accessibilityText($r('app.string.add_to_playlist'))
            .width(48)
            .height(48)
            .padding(12)
            .fillColor($r('app.color.on_primary'))
            .objectFit(ImageFit.Contain)
            .onClick(() => {
              // PlaylistAppendDialog.fromPlayQueueItems(playQueue.getStreams()). This used to
              // call openRowMenu(queueIndex), i.e. it raised the ROW's context menu - which is
              // exactly the case's "the response is as if the three dots button has been
              // tapped". The reference opens the playlist dialog on the whole queue, through
              // PlaylistDialog.createCorrespondingDialog(): the picker when a local playlist
              // exists (measured on 0.29.1 as "New Playlist" plus the QADup row), the creation
              // dialog only when there is none.
              this.openPlaylistDialog();
            })

          // The item's own title is the current speed ("1x"), bound to the player in S4.
          // menu_play_queue.xml android:title="1x", retitled by
          // PlayQueueActivity.onPlaybackParameterChanged():593 to formatSpeed(parameters.speed).
          // The tooltipText (playback_speed_control) is NOT the label: bound to it, the toolbar
          // ran 688px wide and pushed action_overflow off the 56vp bar entirely (S0010).
          Text(formatSpeed(this.playbackParameters.tempo))
            .id('action_playback_speed')
            .height(48)
            .maxLines(1)
            .fontSize(14)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.on_primary'))
            .textCase(TextCase.UpperCase)
            .padding({ left: 8, right: 8 })
            .onClick(() => {
              // openPlaybackParameterDialog(): seed the dialog from the player's live speed.
              // T-0132: the requested rate, as the player's own chip shows it.
              const speed: number = PlayerService.getInstance().displayRate();
              this.playbackParameters = new PlaybackParameters(
                speed, PlayerPrefs.playbackPitch(1.0), PlayerPrefs.playbackSkipSilence());
              this.showPlaybackParameters = true;
            })

          // android:visible="false" until buildAudioTrackMenu() finds two or more tracks.
          if (this.hasAudioTrackMenu()) {
            Text($r('app.string.audio_track'))
              .id('action_audio_track')
              .height(48)
              .maxLines(1)
              .fontSize(14)
              .fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.on_primary'))
              .textCase(TextCase.UpperCase)
              .padding({ left: 8, right: 8 })
              .onClick(() => {
                // buildAudioTrackMenu(): the entries come from the player's own metadata.
                this.audioTrackMenuOpen = !this.audioTrackMenuOpen;
              })
          }

          // action_mute is NOT on the reference's Play queue bar. Measured on 0.29.1 with a
          // queue playing: back, title, action_append_playlist, the 1X speed entry and the
          // overflow - five controls, no volume toggle. The port carried one, and the case
          // reports it both as unwanted and as behaving inverted. Removed rather than
          // re-polarised: the reference has nothing here to match.
          Image($r('app.media.ic_more_vert'))
            .id('action_overflow')
            .accessibilityText($r('app.string.more_options'))
            .width(40)
            .height(48)
            .padding({ left: 8, right: 8, top: 12, bottom: 12 })
            .fillColor($r('app.color.on_primary'))
            .objectFit(ImageFit.Contain)
            .onClick(() => {
              this.overflowOpen = !this.overflowOpen;
            })
        }
        .id('appbar')
        .width('100%')
        .height(56)
        // android:background="?attr/colorPrimary" on the Toolbar; base.png samples #E53935.
        .backgroundColor($r('app.color.primary'))
        .alignItems(VerticalAlign.Center)

        // play_queue: everything between the appbar and metadata.
        PlayQueueAdapter({
          dataSource: this.queueSource,
          selectedIndex: this.queueIndex,
          onReachEnd: (): void => {
            // PlayQueueAdapter.onReachEnd: !playQueue.isComplete() -> playQueue.fetch().
            const queue: PlayQueue | null = this.playQueue;
            if (queue !== null && !queue.isComplete()) {
              queue.fetch();
            }
          },
          onItemMove: (fromIndex: number, toIndex: number): void => {
            // The List's own drag-sort -> playQueue.move(); the wrapper's pan below is what the
            // source's ItemTouchHelper did, but it never beats the List's scroll on ArkUI.
            this.moveQueueItem(fromIndex, toIndex);
          },
          onItemDragStart: (index: number): void => {
            // The same long-press that lifts the row also opened its menu; a drag is not a hold.
            this.closeRowMenu();
          },
          // A @Builder passed as `this.queueRow` re-binds `this` to the CHILD adapter, so every
          // page member the builder touches reads back undefined. The arrow keeps `this` here.
          row: (item: PlayQueueItem, index: number): void => {
            this.queueRow(item, index);
          }
        })
          .layoutWeight(1)

        // metadata: the whole block is clickable -> scrollToSelected().
        Column() {
          // textAppearanceLarge at 14sp; textAppearance* carries ?android:textColorPrimary.
          Text(this.metadata.title)
            .id('song_name')
            .width('100%')
            .maxLines(1)
            .fontSize(14)
            .fontColor($r('app.color.on_surface'))
            .textOverflow({ overflow: TextOverflow.MARQUEE })
          // textAppearanceMedium at 12sp.
          Text(this.metadata.uploader)
            .id('artist_name')
            .width('100%')
            .maxLines(1)
            .fontSize(12)
            .fontColor($r('app.color.on_surface'))
            .textOverflow({ overflow: TextOverflow.MARQUEE })
        }
        .id('metadata')
        .width('100%')
        .padding(8)
        .alignItems(HorizontalAlign.Start)
        .onClick(() => {
          this.scrollToSelected();
        })

        // progress_bar
        Row() {
          // android:textColor="?attr/colorAccent" - the light YouTube accent is black, which is
          // what base.png samples at the two time labels.
          Text(this.currentTime)
            .id('current_time')
            .constraintSize({ minHeight: 40 })
            .textAlign(TextAlign.Center)
            .fontSize(14)
            .fontColor($r('app.color.accent'))

          // base.png: a 2vp #CCCCCC track with a 12vp #E53935 thumb.
          Slider({ value: this.progress, min: 0, max: Math.max(this.durationMs, 1) })
            .id('seek_bar')
            .layoutWeight(1)
            .trackThickness(2)
            .trackColor('#CCCCCC')
            .selectedColor($r('app.color.primary'))
            .blockColor($r('app.color.primary'))
            .blockSize({ width: 12, height: 12 })
            .padding({ left: 12, right: 12, top: 6, bottom: 4 })
            // A live stream cannot be seeked at all - PlayerService.seekTo() refuses it, because
            // AVPlayer answers err 801 and that error tears the player down. With no reachable
            // position to drag to, the bar carries no affordance rather than a dead one. The
            // video detail page's seek bar is disabled the same way.
            .enabled(!StreamSetAdapter.isLive(this.getStreamType))
            .onChange((value: number, mode: SliderChangeMode) => {
              this.progress = value;
              // onStartTrackingTouch / onStopTrackingTouch drive seek_display's visibility.
              this.seeking = mode === SliderChangeMode.Moving || mode === SliderChangeMode.Begin;
              this.seekDisplay = Localization.getDurationString(Math.floor(value / 1000));
              if (mode === SliderChangeMode.Begin || mode === SliderChangeMode.Moving
                || mode === SliderChangeMode.Click) {
                this.seekBarTouched = true;
              }
              if ((mode === SliderChangeMode.End || mode === SliderChangeMode.Click)
                && this.seekBarTouched) {
                this.seekBarTouched = false;
                // onStopTrackingTouch -> player.seekTo(seekBar.getProgress())
                PlayerService.getInstance().seekTo(value);
              }
            })

          // end_time is hidden for a live stream; live_sync takes its place.
          if (this.getStreamType === StreamType.LIVE_STREAM
            || this.getStreamType === StreamType.AUDIO_LIVE_STREAM) {
            Text($r('app.string.duration_live'))
              .id('live_sync')
              .constraintSize({ minHeight: 40 })
              .textAlign(TextAlign.Center)
              .fontSize(14)
              .fontColor($r('app.color.accent'))
              // android:textAllCaps="true"
              .textCase(TextCase.UpperCase)
              .padding({ left: 4, right: 4 })
              // live_sync -> player.seekToDefault(), clickable only while behind the live edge.
              .enabled(this.behindLiveEdge)
              .onClick(() => {
                PlayerService.getInstance().syncToLiveEdge();
              })
          } else {
            Text(this.endTime)
              .id('end_time')
              .constraintSize({ minHeight: 40 })
              .textAlign(TextAlign.Center)
              .fontSize(14)
              .fontColor($r('app.color.accent'))
          }
        }
        .id('progress_bar')
        .width('100%')
        .padding({ left: 12, right: 12 })
        .alignItems(VerticalAlign.Center)

        // playback_controls
        Row() {
          // Every control carries app:tint="?attr/colorAccent"; base.ui.json gives the gaps:
          // 10vp either side of repeat/shuffle, 5vp between the inner buttons.
          // onRepeatModeChanged(): the source swaps ic_repeat_one in for REPEAT_ONE and dims the
          // glyph for REPEAT_OFF. There is no ic_repeat_one drawable in this port, and alpha alone
          // left ONE and ALL pixel-identical (TC-PLAYER-379), so the "1" that drawable carries in
          // the middle of the arrows is drawn here as a badge instead. 77/255 = 0.3, the same
          // alpha shuffle uses below.
          Stack({ alignContent: Alignment.Center }) {
            Image($r('app.media.ic_repeat'))
              .width(30)
              .height(30)
              .fillColor($r('app.color.accent'))
              .objectFit(ImageFit.Fill)
            if (this.repeatMode === 1) {
              Text('1')
                .id('control_repeat_one')
                .fontSize(11)
                .fontWeight(FontWeight.Bold)
                .fontColor($r('app.color.accent'))
                .backgroundColor(themedBackground(this.blackTheme))
                .padding({ left: 2, right: 2 })
            }
          }
          .id('control_repeat')
          .accessibilityText($r('app.string.notification_action_repeat'))
          .margin({ left: 5, right: 5 })
          .opacity(this.repeatMode === 0 ? 0.3 : 1.0)
          .onClick(() => {
            // player.cycleNextRepeatMode(): off -> one -> all. The PLAYER keeps the mode, so this
            // screen and the detail screen's own control always show the same one.
            this.repeatMode = PlayerService.getInstance().cycleNextRepeatMode() as number;
          })

          Image($r('app.media.ic_previous'))
            .id('control_backward')
            .accessibilityText($r('app.string.previous_stream'))
            .width(32)
            .height(32)
            .margin({ left: 5 })
            .fillColor($r('app.color.accent'))
            .objectFit(ImageFit.Contain)
            .onClick(() => {
              // player.playPrevious()
              this.playPrevious();
            })

          // exo_controls_rewind -> exo_icon_rewind (exoplayer-ui values.xml:132), converted to
          // ic_fast_rewind.svg from that vector's own pathData: the DOUBLE left triangle.
          Image($r('app.media.ic_fast_rewind'))
            .id('control_fast_rewind')
            .width(40)
            .height(40)
            .margin({ left: 5 })
            .fillColor($r('app.color.accent'))
            .objectFit(ImageFit.Contain)
            .onClick(() => {
              // player.fastRewind(): by the user's seek_duration.
              PlayerService.getInstance().seekBy(-PlayerPrefs.seekDurationMs());
            })

          // The button is INVISIBLE and control_progress_bar takes its place in any state
          // outside PAUSED / PLAYING / COMPLETED.
          if (this.hasPlayPauseButton()) {
            Image(this.playPauseIcon())
              .id('control_play_pause')
              .accessibilityText(this.playerStatus === PlayerStatus.PLAYING
                ? $r('app.string.pause') : $r('app.string.play'))
              .width(50)
              .height(50)
              .margin({ left: 5, right: 5 })
              .fillColor($r('app.color.accent'))
              .objectFit(ImageFit.Contain)
              .onClick(() => {
                // player.playPause()
                PlayerService.getInstance().togglePlayPause();
              })
          } else {
            LoadingProgress()
              .id('control_progress_bar')
              .width(50)
              .height(50)
              .margin({ left: 5, right: 5 })
              .color($r('app.color.accent'))
          }

          // exo_controls_fastforward -> exo_icon_fastforward (exoplayer-ui values.xml:122).
          Image($r('app.media.ic_fast_forward'))
            .id('control_fast_forward')
            .width(40)
            .height(40)
            .margin({ right: 5 })
            .fillColor($r('app.color.accent'))
            .objectFit(ImageFit.Contain)
            .onClick(() => {
              // player.fastForward(): by the user's seek_duration.
              PlayerService.getInstance().seekBy(PlayerPrefs.seekDurationMs());
            })

          Image($r('app.media.ic_next'))
            .id('control_forward')
            .accessibilityText($r('app.string.next_stream'))
            .width(32)
            .height(32)
            .margin({ right: 5 })
            .fillColor($r('app.color.accent'))
            .objectFit(ImageFit.Contain)
            .onClick(() => {
              // player.playNext()
              this.playNext();
            })

          Image($r('app.media.ic_shuffle'))
            .id('control_shuffle')
            .accessibilityText($r('app.string.notification_action_shuffle'))
            .width(30)
            .height(30)
            .margin({ left: 5, right: 5 })
            .fillColor($r('app.color.accent'))
            .objectFit(ImageFit.Fill)
            // onPlayModeChanged(): controlShuffle.setImageAlpha(shuffled ? 255 : 77). Without it
            // the toggle has NO visible effect at all - the queue order is the only other change
            // and an empty queue reverses to itself. 77/255 = 0.3.
            .opacity(this.shuffled ? 1.0 : 0.3)
            .onClick(() => {
              // playQueue.shuffle() / unshuffle(). Reversing the rendered copy was a stand-in for
              // a queue that did not exist: it left the model untouched and an empty or one-item
              // list reverses to itself, so the control looked dead. The queue's ReorderEvent is
              // what re-reads the list and `shuffled` here.
              this.toggleShuffle();
            })
        }
        .id('playback_controls')
        .width('100%')
        .justifyContent(FlexAlign.Center)
        .alignItems(VerticalAlign.Center)
        .margin({ bottom: 12 })
      }
      .width('100%')
      .height('100%')

      // seek_display: centerInParent, GONE unless the bar is being dragged.
      if (this.seeking) {
        Text(this.seekDisplay)
          .id('seek_display')
          .padding({ left: 30, right: 30, top: 5, bottom: 5 })
          .backgroundColor('#C0000000')
          .fontSize(22)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.on_primary'))
      }

      // Both menus are POPUPS: present only while open, and they swallow the touch beneath them.
      // The scrim under them is the PopupMenu's outside-touch dismissal; without it the only way
      // out of a menu was to pick an entry, and Back left the screen instead.
      if (this.anyMenuOpen()) {
        Column()
          .id('popup_scrim')
          .width('100%')
          .height('100%')
          .onClick(() => {
            this.closeMenus();
          })
      }

      if (this.overflowOpen) {
        this.overflowMenu()
      }

      if (this.rowMenuOpen) {
        this.rowPopupMenu()
      }

      if (this.audioTrackMenuOpen) {
        this.audioTrackMenu()
      }
    }
    .id('PlayQueueActivityPage')
    .width('100%')
    .height('100%')
    .backgroundColor(themedBackground(this.blackTheme))
  }
}
