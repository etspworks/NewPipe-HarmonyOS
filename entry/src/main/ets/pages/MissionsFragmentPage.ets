/**
 * S3 - MissionsFragment (screen_missions), hosted by DownloadActivityPage.
 *
 * missions.xml is only two views: R.id.list_empty_view and R.id.mission_recycler, both declared
 * unconditionally. MissionAdapter.checkEmptyMessageVisibility() toggles mEmptyMessage ONLY -
 * nothing in MissionAdapter or MissionsFragment ever hides mList. So the recycler renders
 * ALWAYS and the empty view renders ON TOP of it when the iterator is empty; the real app's
 * empty DownloadActivity capture shows both at once.
 *
 * Everything visible in the recycler comes from MissionAdapter's three item types:
 *   SPECIAL_PENDING / SPECIAL_FINISHED -> missions_header.xml (a section title),
 *   DownloadMission                    -> mission_item(_linear).xml,
 *   FinishedMission                    -> the same row, with a date and 100 percent.
 * mLinear picks GridLayoutManager(2) or LinearLayoutManager; the host owns the switch_mode menu
 * item that flips it, so it arrives here as a @Prop.
 *
 * Live updates are here only to the extent the HOST's S4 needs them: the list rebuilds off the
 * same DownloadManager.observeMissions() stream the host reads, so the two never disagree.
 *
 * NOT here (screen_missions' own S4 batch): the 13-item R.menu.mission popup, the row tap that
 * opens a finished file, per-row progress and the ProgressDrawable/marquee background on
 * R.id.item_bkg, and the clear-history undo snackbar. The two popup entries that NAVIGATE (retry -> the storage picker,
 * source -> RouterActivity) are wired now so this screen's nav edges stay wired.
 */
import { formatBytes } from '../common/text/ByteFormat';
import { promptAction, router } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { fileIo, hash } from '@kit.CoreFileKit';
import { ServiceLocator } from '../common/di/ServiceLocator';
import { DownloadManager, MissionEvent, MissionEventKind } from '../common/download/DownloadManager';
import { Deleter, PendingDeletion } from '../common/download/Deleter';
import { BackgroundWork, BackgroundWorkMode } from '../common/background/BackgroundWork';
import { Notifications } from '../common/notify/Notifications';
import { ShareUtils } from '../common/share/ShareUtils';
import { AppPreferences } from '../common/prefs/Preferences';
import { CompositeDisposable } from '../common/rx/Rx';
import { Mission } from '../model/app/Mission';
import {
  DownloadMission,
  ERROR_CONNECT_HOST,
  ERROR_FILE_CREATION,
  ERROR_HTTP_NO_CONTENT,
  ERROR_INSUFFICIENT_STORAGE,
  ERROR_NOTHING,
  ERROR_PATH_CREATION,
  ERROR_PERMISSION_DENIED,
  ERROR_POSTPROCESSING,
  ERROR_POSTPROCESSING_HOLD,
  ERROR_POSTPROCESSING_STOPPED,
  ERROR_PROGRESS_LOST,
  ERROR_RESOURCE_GONE,
  ERROR_SSL_EXCEPTION,
  ERROR_TIMEOUT,
  ERROR_UNKNOWN_HOST
} from '../model/app/DownloadMission';
import { Localization } from '../common/i18n/Localization';
import { NewPipe } from '../common/extractor/core/NewPipe';
import { FinishedMission } from '../model/app/FinishedMission';
import { ErrorInfo } from '../model/app/ErrorInfo';
import { UserAction } from '../model/enums/UserAction';
import { FileAccess, StoredFile, TAG_AUDIO, TAG_VIDEO } from '../common/file/FileAccess';
import {
  isMissionHeader,
  MissionAdapter,
  MissionDataSource,
  MissionItem,
  MissionRowKind
} from '../components/MissionAdapter';
import { BLACK_THEME_KEY, themedBackground } from '../common/theme/ThemeBackground';

const TAG: string = 'MissionsFragment';

/** MissionAdapter.HASH_NOTIFICATION_ID - the ongoing row the checksum job posts. */
const HASH_NOTIFICATION_ID: number = 4100;

/**
 * MissionAdapter's mHandler repaints a running row on a tick, not once per transferred block.
 * PROGRESS here arrives once per TRANSFER_CHUNK_SIZE (1 MB), so it is rate-limited to the same
 * effect rather than rebuilding the whole list on every chunk.
 */
const PROGRESS_PAINT_INTERVAL_MS: number = 500;

/**
 * How long a row suppresses progress repaints after it is touched, waiting for its popup.
 *
 * missionRowKey() puts `done` in the row's key, so a PROGRESS repaint gives a RUNNING row a new
 * key and LazyForEach destroys the child it is showing - taking the popup anchored to that
 * child's item_more with it. `rowMenuOpen` is armed by the menu's own onAppear, which on device
 * lands AFTER the show animation, so a tick inside that window killed the menu before it ever
 * appeared: on MJE0224B05009259 a running row's overflow never opened at all, while the same
 * row's menu opened normally the moment it was paused. The touch is the earliest signal the app
 * gets, so the window is armed there and onAppear/onDisappear carry it from then on. A grace
 * rather than a flag because a touch that never becomes a menu (a scroll) must heal itself.
 * Long press needs ~500 ms before the menu is even requested, hence 1.5 s rather than 1 s.
 */
const ROW_MENU_ARM_GRACE_MS: number = 1500;

/** How much of the file the digest reads at a time. */
const HASH_CHUNK_SIZE: number = 1024 * 1024;

/**
 * NavigationHelper.getIntentByLink(ctx, mission.source) - what R.id.source hands the router.
 *
 * The field is named for what RouterActivityPage.readArguments() reads: params['uri']. It used
 * to be 'url', so the router received no link at all and fell through to its empty-link path.
 */
class MissionSourceParams {
  uri: string;

  constructor(uri: string) {
    this.uri = uri;
  }
}

/** What VideoDetailFragmentPage reads when the info screen is opened directly. */
class MissionInfoParams {
  serviceId: number;
  url: string;
  name: string;

  constructor(serviceId: number, url: string, name: string) {
    this.serviceId = serviceId;
    this.url = url;
    this.name = name;
  }
}
/** MissionsFragment: mPrefs.getBoolean("linear", false). The source's own literal key. */
const LINEAR_PREF_KEY: string = 'linear';

/**
 * The source's popup is an Android PopupMenu: a square-cornered card. ArkUI rounds a menu's
 * corners by default, which is what TC-LIBRARY-165 reports as 'the opened mini window does not
 * have 90-degree corners'.
 *
 * The radius belongs to the menu WINDOW, not to the Menu component - `.borderRadius(0)` on the
 * Menu itself changes nothing, because the container that draws the corners is outside it. It has
 * to come through the bind options, and MenuOptions extends ContextMenuOptions so both bind sites
 * take the same shape.
 *
 * onAppear / onDisappear: a row's popup is anchored to the row, so repainting the row while the
 * popup is open takes the popup down with it. The source's PopupMenu is a separate window and
 * survives updateProgress(), so progress repaints are held back while one is showing - see
 * `rowMenuOpen` below.
 */
const SQUARE_MENU_CORNERS: MenuOptions = { borderRadius: 0 };

/** How many times missionName() will unwrap percent-encoding before giving up. */
const DECODE_PASSES: number = 4;

/** mission_item.xml: the grid cell's name box is two lines, wrapped, not a marquee. */
const GRID_NAME_LINES: number = 2;

@Entry
@Component
export struct MissionsFragmentPage {
  /** ThemeHelper's black theme: the window background follows it. */
  @StorageProp(BLACK_THEME_KEY) blackTheme: boolean = false;

  /**
   * MissionsFragment.mLinear. The host DownloadActivityPage owns it because it owns the
   * switch_mode menu item; @Prop (not @Consume) because this struct is also a registered route,
   * so it must still render when it is deep-linked with no provider above it.
   */
  @Prop @Watch('onHostLinearChanged') missionsLinear: boolean = false;
  /**
   * MissionsFragment.mLinear: mPrefs.getBoolean("linear", false) picks LinearLayoutManager over
   * GridLayoutManager(2). The host's switch_mode menu item writes that same preference, which is
   * why the prop is watched rather than read straight into the layout.
   */
  @State mLinear: boolean = false;
  /** The iterator's rows: the pending section, then the finished one. */
  @State missionList: MissionItem[] = [];
  /** checkEmptyMessageVisibility(): mEmptyMessage is shown exactly when the iterator is empty. */
  @State emptyState: boolean = true;
  /** The download manager is read once the binder is up; until then the list is not known. */
  @State isLoading: boolean = true;
  /** showError(mission): the errCode message, shown in the panel until it is dismissed. */
  @State errorInfo: string | null = null;
  /** showError(mission)'s Error report button: shown for a non-HTTP failure with an exception. */
  @State errorReportable: boolean = false;
  /** The mission the error panel is about, which the Error report button reports. */
  private errorMission: DownloadMission | null = null;
  /** Deleter's snackbar: the pending delete's message, '' while none is pending. */
  @State pendingDeleteMessage: string = '';
  private source: MissionDataSource = new MissionDataSource();
  /** MissionAdapter's CompositeDisposable, disposed in onDestroy() (Rule 8). */
  private disposables: CompositeDisposable = new CompositeDisposable();
  /** The tick PROGRESS is rate-limited against. */
  private lastProgressPaint: number = 0;
  /** True while a row popup is showing; a progress repaint would close it. */
  private rowMenuOpen: boolean = false;
  /** Date.now() of the last touch on a row - see ROW_MENU_ARM_GRACE_MS. */
  private rowMenuArmedAt: number = 0;
  /** mission.metadata -> [sampled at, done at that moment, bytes per second] - see missionSpeed(). */
  private speedSamples: Map<string, number[]> = new Map();

  /** SQUARE_MENU_CORNERS plus the open/closed bookkeeping both bind sites share. */
  private menuOptions(): MenuOptions {
    return {
      borderRadius: SQUARE_MENU_CORNERS.borderRadius,
      onAppear: (): void => {
        this.rowMenuOpen = true;
      },
      onDisappear: (): void => {
        this.rowMenuOpen = false;
      }
    };
  }

  /**
   * Both row builders route their touches here: a touch on a row may be about to become a popup,
   * and a running row that repaints in between loses the child the popup is anchored to.
   */
  private armRowMenu(event: TouchEvent): void {
    if (event.type === TouchType.Down) {
      this.rowMenuArmedAt = Date.now();
    }
  }

  aboutToAppear(): void {
    this.mLinear = MissionsFragmentPage.readLinearPreference() || this.missionsLinear;
    // onServiceConnected(): mBinder.clearDownloadNotifications().
    this.manager().clearDownloadNotifications();
    this.loadMissions();

    // mBinder.addMissionEventListener(mAdapter) -> handleMessage -> applyChanges(): the list is
    // rebuilt from the manager whenever a mission changes state. The host subscribes to the same
    // stream, so the menu and the list never disagree.
    //
    // PROGRESS used to be dropped here, on the grounds that per-row progress was 'screen_missions'
    // own pass' - but this port has no such pass, so the only thing that ever repainted a row was
    // a membership event. A running row therefore sat frozen at whatever percentage it held when
    // the last RUNNING/PAUSED/FINISHED arrived, which is TC-LIBRARY-169/170 ('progress begins
    // advancing' never observed). It is rate-limited rather than dropped.
    this.disposables.add(ServiceLocator.get().downloadManager.observeMissions().subscribeCallbacks(
      (event: MissionEvent): void => {
        if (event.kind === MissionEventKind.PROGRESS) {
          if (this.rowMenuOpen || Date.now() - this.rowMenuArmedAt < ROW_MENU_ARM_GRACE_MS) {
            return;
          }
          const now: number = Date.now();
          if (now - this.lastProgressPaint < PROGRESS_PAINT_INTERVAL_MS) {
            return;
          }
          this.lastProgressPaint = now;
        }
        this.loadMissions();
      },
      (err: Error): void => {
        hilog.error(0x0000, TAG, 'mission events: %{public}s', err.message);
      }
    ));
    this.disposables.add(Deleter.get().observe().subscribeCallbacks((): void => {
      this.loadMissions();
    }));
  }

  /** mPrefs.getBoolean("linear", false). */
  private static readLinearPreference(): boolean {
    try {
      return AppPreferences.instance().getBooleanSync(LINEAR_PREF_KEY, false);
    } catch (err) {
      return false;
    }
  }

  /** The host's switch_mode menu item writes the preference and flips the prop. */
  private onHostLinearChanged(): void {
    this.mLinear = this.missionsLinear;
  }

  /**
   * onResume() / onPause(): mBinder.enableNotifications(false / true). These two run only when
   * this page is the route itself; hosted in DownloadActivityPage, the host's own pair does it.
   */
  onPageShow(): void {
    this.manager().enableNotifications(false);
  }

  onPageHide(): void {
    this.manager().enableNotifications(true);
  }

  /** MissionsFragment.onDestroy(): removeMissionEventListener + mAdapter.onDestroy(). */
  aboutToDisappear(): void {
    // ... and mBinder.enableNotifications(true).
    this.manager().enableNotifications(true);
    this.disposables.dispose();
    // Deleter.dispose(): whatever is still pending is deleted when the screen goes.
    Deleter.get().commit();
  }

  /** MissionAdapter's iterator: the pending section, then the finished section. */
  private loadMissions(): void {
    const manager: DownloadManager = ServiceLocator.get().downloadManager;
    const deleter: Deleter = Deleter.get();
    const pending: DownloadMission[] = manager.getPendingMissions()
      .filter((mission: DownloadMission): boolean => !deleter.isHidden(mission));
    const finished: FinishedMission[] = manager.getFinishedMissions()
      .filter((mission: FinishedMission): boolean => !deleter.isHidden(mission));
    const deletion: PendingDeletion | null = deleter.current();
    this.pendingDeleteMessage = deletion === null ? '' : deletion.message;
    const items: MissionItem[] = [];

    if (pending.length > 0) {
      items.push(new MissionItem(MissionRowKind.PendingHeader, null));
      for (const mission of pending) {
        items.push(new MissionItem(MissionRowKind.Pending, mission));
      }
    }
    if (finished.length > 0) {
      items.push(new MissionItem(MissionRowKind.FinishedHeader, null));
      for (const mission of finished) {
        items.push(new MissionItem(MissionRowKind.Finished, mission));
      }
    }

    this.source.setItems(items);
    this.missionList = items;
    this.emptyState = pending.length + finished.length === 0;
    this.isLoading = false;
  }

  /**
   * Utility.getFileType(kind, name): 'v' video, 'a' audio, anything else a plain file.
   *
   * The source's kind is a CHAR ('v'/'a'/'s'); the port's DownloadDialogPage hands
   * DownloadMission.create() the StoredFileHelper TAG instead ('video'/'audio' from
   * FileAccess.TAG_VIDEO/TAG_AUDIO), so every mission stored by this build carries 'video' and
   * this test never matched - the reference draws a movie clapperboard for the downloaded .mp4
   * and the port drew the generic download arrow. Both spellings are accepted here because rows
   * already persisted carry the tag and a fix at the write site would not repair them.
   */
  private rowIcon(item: MissionItem): Resource {
    const mission: Mission | null = item.mission;
    const kind: string = mission !== null ? mission.kind : '';
    if (kind === 'v' || kind === TAG_VIDEO) {
      return $r('app.media.ic_movie');
    }
    if (kind === 'a' || kind === TAG_AUDIO) {
      return $r('app.media.ic_music_note');
    }
    return $r('app.media.ic_file_download');
  }

  /** mission.storage.getName(). */
  private missionName(item: MissionItem): string {
    const mission: Mission | null = item.mission;
    if (mission === null) {
      return '';
    }
    const file: StoredFile | null = mission.storage;
    if (file === null) {
      return '';
    }
    // The name comes back PERCENT-ENCODED when the storage is a content URI - a Turkish title
    // rendered as "%20%C4%B0%C5%9Fler_..." instead of " İşler_...". That is the case's
    // "errors occurring in the display of characters in video names", and it hits list and grid
    // alike because both read this. A name that is not encoded decodes to itself; a malformed
    // one would throw, so the raw name is the fallback rather than an empty row.
    // A single decode is not enough. The picker hands back a document URI whose last path
    // segment is encoded, and the name that went INTO it already carried its own escapes, so the
    // segment arrives doubly encoded: the device showed "10%2520Hours%2520of%2520Rain..." where
    // the reference reads "10 Hours of Rain...". One pass turns %2520 into %20 and stops, still
    // unreadable - and six characters per space instead of one is also why the name runs out of
    // the cell long before the reference's does, which is this case's "not fully viewable".
    // So decode until it stops changing, with a small bound so a name that legitimately contains
    // a percent sequence cannot spin.
    let name: string = file.getName();
    for (let pass: number = 0; pass < DECODE_PASSES; pass++) {
      let decoded: string;
      try {
        decoded = decodeURIComponent(name);
      } catch (err) {
        // A malformed escape anywhere leaves the WHOLE string raw, so keep what the last good
        // pass produced rather than dropping back to the encoded original.
        break;
      }
      if (decoded === name) {
        break;
      }
      name = decoded;
    }
    return name;
  }

  /** Utility.formatBytes(). */


  private static pad2(value: number): string {
    return value < 10 ? `0${value}` : `${value}`;
  }

  /** The remaining time the reference prints beside the transferred bytes: mm:ss, h:mm:ss past the hour. */
  private static formatEta(seconds: number): string {
    const total: number = Math.max(0, Math.round(seconds));
    const seconds2: string = MissionsFragmentPage.pad2(total % 60);
    const minutes: number = Math.floor(total / 60);
    if (minutes < 60) {
      return MissionsFragmentPage.pad2(minutes) + ':' + seconds2;
    }
    return `${Math.floor(minutes / 60)}:${MissionsFragmentPage.pad2(minutes % 60)}:${seconds2}`;
  }

  /**
   * MissionAdapter.updateProgress()'s h.lastTimeStamp / h.lastDone pair, in bytes per second.
   *
   * The source keeps the pair on the ViewHolder and re-reads it once per handler tick. There are
   * no view holders here - rows are rebuilt from the item list - so the pair lives on the page,
   * keyed by the mission's own metadata path. A sample is only taken once per paint interval, so
   * the several calls one frame makes for the same row all read back the same figure instead of
   * dividing by a zero delta.
   */
  private missionSpeed(mission: DownloadMission): number {
    const now: number = Date.now();
    const previous: number[] | undefined = this.speedSamples.get(mission.metadata);
    if (previous === undefined) {
      this.speedSamples.set(mission.metadata, [now, mission.done, 0]);
      return 0;
    }
    const elapsed: number = now - previous[0];
    if (elapsed < PROGRESS_PAINT_INTERVAL_MS) {
      return previous[2];
    }
    const transferred: number = mission.done - previous[1];
    const speed: number = transferred > 0 ? transferred * 1000 / elapsed : 0;
    this.speedSamples.set(mission.metadata, [now, mission.done, speed]);
    return speed;
  }

  /**
   * ViewHolderItem.size. Device-checked against the reference: item_size is NOT just the length.
   * A running mission appends "  <transferred>/<eta>  <speed>" to it and a stopped one appends
   * "  (paused)" - the two labels the case reports as missing, the second of which is the whole
   * of its 'the row's state label updates to Paused'. item_status keeps the percentage in every
   * state and item_date stays empty until the mission finishes, both of which already matched.
   */
  private missionSize(item: MissionItem): string {
    const mission: Mission | null = item.mission;
    if (mission === null) {
      return '';
    }
    if (!(mission instanceof DownloadMission)) {
      return formatBytes(mission.length);
    }
    const download: DownloadMission = mission as DownloadMission;
    const total: number = download.getLength();
    const size: string = formatBytes(total);
    // An errored row reads its message out of item_status; nothing is appended to the size.
    if (download.errCode !== ERROR_NOTHING || download.isFinished()) {
      return size;
    }
    if (download.running && download.isPsRunning()) {
      return `${size}  (${Localization.getString('post_processing')})`;
    }
    if (!download.running) {
      // The reference has TWO stopped labels, not one: a mission waiting its turn in the download
      // queue reads "(queued)" and only a mission the user stopped reads "(paused)". Enqueue had
      // no visible effect on the port because every stopped row said "(paused)" either way.
      return `${size}  (${Localization.getString(download.enqueued ? 'queued' : 'paused')})`;
    }
    const speed: number = this.missionSpeed(download);
    if (speed <= 0 || download.unknownLength || total < 1) {
      // The source returns early until it holds two samples, leaving the plain length.
      return size;
    }
    const eta: string = MissionsFragmentPage.formatEta((total - download.done) / speed);
    return `${size}  ${formatBytes(download.done)}/${eta}`
      + `  ${formatBytes(Math.round(speed))}/s`;
  }

  /** ViewHolderItem.status: UNDEFINED_PROGRESS until the length is known, else done/length. */
  private missionStatus(item: MissionItem): string {
    const mission: Mission | null = item.mission;
    if (mission === null) {
      return '';
    }
    if (mission instanceof FinishedMission) {
      return '100%';
    }
    if (mission instanceof DownloadMission) {
      // updateProgress(): `boolean hasError = mission.errCode != ERROR_NOTHING` is tested BEFORE
      // the progress branches, and an errored mission's status field reads R.string.msg_error.
      // The port went straight to the progress branches, so a mission that had failed still
      // showed UNDEFINED_PROGRESS and looked like one that had simply not started yet.
      if (mission.errCode !== ERROR_NOTHING) {
        return Localization.getString('msg_error');
      }
      const total: number = mission.getLength();
      if (mission.unknownLength || total < 1) {
        return '--.-%';
      }
      // String.format("%.2f%%", ...) - TWO decimals. Measured side by side on the same video:
      // the reference reads 56.10% / 59.23% / 46.61% where the port read 15.1% / 3.0%.
      return `${(mission.done * 100 / total).toFixed(2)}%`;
    }
    return '';
  }

  /** ViewHolderItem.date: only a finished mission carries one. */
  private missionDate(item: MissionItem): string {
    const mission: Mission | null = item.mission;
    if (mission === null || !(mission instanceof FinishedMission)) {
      return '';
    }
    // Utility.formatDate(): a SHORT localized date, not the full JS date string. toString()
    // produced "Wed Sep 23 2026 00:54:00 GMT+0300 (...)", which the row clipped to "Wed ...".
    return new Date(mission.timestamp)
      .toLocaleDateString('default', { year: 'numeric', month: 'short', day: 'numeric' });
  }

  /**
   * MissionsFragment.recoverMission(): `StoredFileHelper.getNewPicker(ctx, storage.getName(),
   * storage.getType(), null)` started for result, and onActivityResult reassigns
   * `mission.storage` from what came back and resumes the mission.
   *
   * The port pushed CustomFilePickerFragmentPage with NO arguments, so it opened on
   * `access.filesDir()` - the app's PRIVATE sandbox - and offered the user `pending_downloads`,
   * the mission-metadata folder, as a place to save a download. Worse, nothing consumed the
   * page's result, so even a successful pick was discarded and the mission stayed invalid.
   *
   * The system picker is what the source uses and what DownloadDialogPage already uses on the
   * enqueue side: it returns a document URI, which is the exact form StoredFile carries, so there
   * is no path/URI confusion to get wrong. The custom picker stays as the fallback for a device
   * with no system picker, which is the same shape DownloadDialogPage has.
   */
  private async recoverMission(mission: DownloadMission): Promise<void> {
    const previous: StoredFile | null = mission.storage;
    if (previous === null) {
      return;
    }
    const files: FileAccess = ServiceLocator.get().fileAccess;
    let picked: StoredFile | null = null;
    try {
      picked = await files.pickFileToSave(previous.getName(), previous.getType(),
        previous.getTag());
    } catch (err) {
      // No system picker on this device: the ported NoNonsense picker, as on the enqueue side.
      hilog.warn(0x0000, TAG, 'save picker unavailable: %{public}s',
        (err as BusinessError).message);
      this.openStoragePicker();
      return;
    }
    if (picked === null) {
      // RESULT_CANCELED: the mission keeps its invalid handle and stays where it is.
      return;
    }
    mission.storage = picked;
    // MissionAdapter.recoverMission(): the mission is cleared of its failure before it is
    // resumed, or hasError stays true and the row keeps reading 'Error' over a live handle.
    //
    //     mission.errObject = null;
    //     mission.resetState(true, false, DownloadMission.ERROR_NOTHING);
    //     mDownloadManager.resumeMission(mission);
    //
    // resetState's second argument is persistChanges, which the port's two-argument signature
    // leaves to the caller - and the caller has to do it here, because the new handle is only in
    // memory until the mission's JSON is rewritten. Without that, the next app start reads the
    // empty storageUri back and the mission is unrecoverable all over again.
    mission.resetState(true, ERROR_NOTHING);
    this.manager().resumeMission(mission);
    this.loadMissions();
  }

  /** The no-system-picker fallback only. See recoverMission() for why it is not the first choice. */
  private openStoragePicker(): void {
    router.pushUrl({ url: 'pages/CustomFilePickerFragmentPage' }).catch((err: Error) => {
      hilog.error(0x0000, TAG, 'pushUrl CustomFilePicker: %{public}s', err.message);
    });
  }

  /**
   * R.menu.mission R.id.source -> the page the download came from.
   *
   * Measured on the reference with the chooser's own default in force (an external link opened
   * through it still raises the dialog, so "always ask" is set there too): Show info goes STRAIGHT
   * to the stream's detail page. The port pushed RouterActivityPage, so the user met the chooser -
   * NewPipe / Show info / Video player / ... / Just once / Always - before the screen the entry
   * names. The chooser stays for a link arriving from OUTSIDE the app; a row in this list already
   * knows which stream it is.
   *
   * The chooser is still the fallback for a source no service claims - an old mission whose source
   * is the media CDN url rather than the stream page, which is what RouterActivity's
   * unsupported-link dialog exists for.
   */
  private openMissionSource(mission: Mission): void {
    let serviceId: number = -1;
    try {
      serviceId = NewPipe.getServiceByUrl(mission.source).getServiceId();
    } catch (err) {
      hilog.info(0x0000, TAG, 'no service claims %{public}s: routing it', mission.source);
      router.pushUrl({
        url: 'pages/RouterActivityPage',
        params: new MissionSourceParams(mission.source)
      }).catch((pushErr: Error) => {
        hilog.error(0x0000, TAG, 'pushUrl RouterActivity: %{public}s', pushErr.message);
      });
      return;
    }
    router.pushUrl({
      url: 'pages/VideoDetailFragmentPage',
      params: new MissionInfoParams(serviceId, mission.source, '')
    }).catch((err: Error) => {
      hilog.error(0x0000, TAG, 'pushUrl VideoDetail: %{public}s', err.message);
    });
  }

  private manager(): DownloadManager {
    return ServiceLocator.get().downloadManager;
  }

  /** R.id.retry: recover the mission, and pick a new location when its storage went invalid. */
  private retryMission(mission: DownloadMission): void {
    if (mission.isPsRunning()) {
      // mission.psContinue(true): run the held muxing step again.
      this.manager().psContinue(mission, true).catch((err: Error): void => {
        hilog.error(0x0000, TAG, 'psContinue: %{public}s', err.message);
      });
      return;
    }
    this.manager().tryRecover(mission);
    if (mission.hasInvalidStorage()) {
      this.recoverMission(mission).catch((err: Error): void => {
        hilog.error(0x0000, TAG, 'recoverMission: %{public}s', err.message);
      });
      return;
    }
    this.manager().resumeMission(mission);
    this.loadMissions();
  }

  /** R.id.cancel: psContinue(false) gives the held post-processing step up. */
  private cancelMission(mission: DownloadMission): void {
    this.manager().psContinue(mission, false).catch((err: Error): void => {
      hilog.error(0x0000, TAG, 'psContinue: %{public}s', err.message);
    });
  }

  /** R.id.start -> resumeMission, R.id.pause -> pauseMission. */
  private startMission(mission: DownloadMission): void {
    this.manager().resumeMission(mission);
    this.loadMissions();
  }

  private pauseMission(mission: DownloadMission): void {
    this.manager().pauseMission(mission);
    this.loadMissions();
  }

  /** mission.xml#queue: the checkbox flips mission.setEnqueued(flag). */
  private toggleEnqueued(mission: DownloadMission): void {
    // setEnqueued() writes the mission record, so the choice survives a restart.
    this.manager().setEnqueued(mission, !mission.enqueued);
    this.loadMissions();
  }

  /**
   * R.id.delete deletes the file too; R.id.delete_entry drops only the list entry. Both go
   * through mDeleter.append(): hidden at once, committed after the Undo snackbar's five seconds.
   */
  private deleteMission(mission: Mission, alsoDeleteFile: boolean): void {
    const file: StoredFile | null = mission.storage;
    const message: string = alsoDeleteFile && file !== null
      ? `${Localization.getString('file_deleted')}:\n${file.getName()}`
      : Localization.getString('entry_deleted');
    Deleter.get().append([mission], alsoDeleteFile, message);
  }

  /** R.id.error_message_view -> showError(mission): the errCode, mapped to a message. */
  private showMissionError(mission: DownloadMission): void {
    // MissionAdapter.showError() is only ever reached for a mission that HAS an error; the
    // source treats any other code as a programming mistake. Here the entry could be opened on
    // a plainly paused row, so the guard is a return rather than a message.
    if (mission.errCode === ERROR_NOTHING) {
      return;
    }
    this.errorInfo = MissionsFragmentPage.errorMessageFor(mission.errCode);
    // "add report button for non-HTTP errors (range 100-599)", and only with an exception to send.
    this.errorMission = mission;
    this.errorReportable = mission.errObject !== null
      && (mission.errCode < 100 || mission.errCode >= 600);
  }

  /**
   * The dialog's error_report_title button -> showError(mission, DOWNLOAD_FAILED, msg):
   * ErrorUtil.createNotification with the exception, the mission's source plus its recovery
   * info as the request, and the service that source belongs to.
   */
  private reportMissionError(mission: DownloadMission): void {
    const err: Error | null = mission.errObject;
    if (err === null) {
      return;
    }
    let serviceId: number | null = null;
    try {
      serviceId = NewPipe.getServiceByUrl(mission.source).getServiceId();
    } catch (ignored) {
      // the source's `service = null`
    }
    const request: string = `${mission.source} [ ${JSON.stringify(mission.recoveryInfo)} ]`;
    ServiceLocator.get().errorReporter.createNotification(ErrorInfo.fromMessage(
      ErrorInfo.throwableToStringList(err), UserAction.DOWNLOAD_FAILED, request, serviceId,
      'general_error'));
  }

  /**
   * MissionAdapter.showError()'s switch over errCode. The port returned the resource NAME for
   * the two codes it knew and the raw number for everything else, so the panel showed
   * "error_insufficient_storage" or a bare "-1" instead of a sentence.
   */
  private static errorMessageFor(errCode: number): string {
    switch (errCode) {
      case ERROR_PATH_CREATION:
        return Localization.getString('error_path_creation');
      case ERROR_FILE_CREATION:
        return Localization.getString('error_file_creation');
      case ERROR_PERMISSION_DENIED:
        return Localization.getString('permission_denied');
      case ERROR_SSL_EXCEPTION:
        return Localization.getString('error_ssl_exception');
      case ERROR_UNKNOWN_HOST:
        return Localization.getString('error_unknown_host');
      case ERROR_CONNECT_HOST:
        return Localization.getString('error_connect_host');
      case ERROR_POSTPROCESSING:
      case ERROR_POSTPROCESSING_STOPPED:
        return Localization.getString('error_postprocessing_failed');
      case ERROR_POSTPROCESSING_HOLD:
        return Localization.getString('error_postprocessing_stopped');
      case ERROR_INSUFFICIENT_STORAGE:
        return Localization.getString('error_insufficient_storage');
      case ERROR_PROGRESS_LOST:
        return Localization.getString('error_progress_lost');
      case ERROR_TIMEOUT:
        return Localization.getString('error_timeout');
      case ERROR_RESOURCE_GONE:
        return Localization.getString('error_download_resource_gone');
      case ERROR_HTTP_NO_CONTENT:
        return Localization.getString('error_http_no_content');
      default:
        break;
    }
    // The source's default branch: a response code is reported as such, and anything else is
    // reported as an unknown error rather than printed raw.
    if (errCode >= 100 && errCode < 600) {
      return Localization.getStringArgs('error_occurred_detail', ['HTTP ' + errCode]);
    }
    return Localization.getString('error_snackbar_message');
  }

  /** R.id.menu_item_share: ACTION_SEND of the downloaded file. */
  private shareMission(mission: Mission): void {
    const file: StoredFile | null = mission.storage;
    if (file === null || file.isInvalid()) {
      return;
    }
    if (!this.checkValidFile(file)) {
      return;
    }
    const share: ShareUtils = ServiceLocator.get().share;
    share.shareFile(file.getUri(), file.getName(), file.getType());
  }

  /** checkInvalidFile(): a file that is gone says so instead of handing out a dead uri. */
  private checkValidFile(file: StoredFile): boolean {
    if (!file.isVerifiable() || file.existsAsFile()) {
      return true;
    }
    promptAction.showToast({ message: $r('app.string.missing_file'), duration: 2000 });
    return false;
  }

  /** itemView.setOnClickListener: a FINISHED row opens its file; a running one does nothing. */
  private openMission(item: MissionItem): void {
    const mission: Mission | null = item.mission;
    if (mission === null || !(mission instanceof FinishedMission)) {
      return;
    }
    const file: StoredFile | null = mission.storage;
    if (file === null || file.isInvalid() || !this.checkValidFile(file)) {
      return;
    }
    ServiceLocator.get().share.openFile(file.getUri(), file.getName(), file.getType());
  }

  /**
   * The digest of the file behind a URI.
   *
   * hash.hash() takes an application SANDBOX PATH. A mission's storage is the document URI
   * DocumentViewPicker handed back, so hash.hash() answered 'No such file or directory' for every
   * downloaded file and the checksum entry produced nothing at all (TC-LIBRARY-187/188). fileIo
   * opens that URI happily - existsAsFile() and the transfer loop both do - so the digest is
   * streamed off the descriptor instead. Streaming is also what lets a PARTIAL file be hashed:
   * it reads what is there and stops.
   */
  private static async digestOf(uri: string, algorithm: string): Promise<string> {
    const stream: hash.HashStream = hash.createHash(algorithm);
    let file: fileIo.File;
    try {
      file = fileIo.openSync(uri, fileIo.OpenMode.READ_ONLY);
    } catch (err) {
      // StoredFile.existsAsFile()'s case: the save picker's grant refuses READ_ONLY but opens in
      // the mode the transfer used. READ_WRITE without CREATE/TRUNC leaves the file untouched.
      file = fileIo.openSync(uri, fileIo.OpenMode.READ_WRITE);
    }
    try {
      const buffer: ArrayBuffer = new ArrayBuffer(HASH_CHUNK_SIZE);
      let read: number = fileIo.readSync(file.fd, buffer);
      while (read > 0) {
        stream.update(read === HASH_CHUNK_SIZE ? buffer : buffer.slice(0, read));
        read = fileIo.readSync(file.fd, buffer);
      }
    } finally {
      fileIo.closeSync(file);
    }
    // HashStream.digest() is UPPERCASE hex; the source copies okio's ByteString.hex(), lowercase.
    return stream.digest().toLowerCase();
  }

  /**
   * R.id.md5 / R.id.sha1: the source posts a HASH_NOTIFICATION_ID progress notification, computes
   * the digest off the UI thread, copies it to the clipboard and cancels the notification. The
   * off-thread half is a continuous task here, so a long hash survives the app being backgrounded.
   */
  private async checksum(mission: Mission, algorithm: string): Promise<void> {
    const file: StoredFile | null = mission.storage;
    if (file === null || file.isInvalid()) {
      return;
    }
    if (file.isVerifiable() && !file.existsAsFile()) {
      // R.id.md5 / sha1 on a file that is gone: missing_file, and the entry goes too. Only for a
      // handle that can answer that (checkValidFile()'s rule): an unpersisted grant from an
      // earlier process fails existsAsFile() with the file intact, and this deleted its entry.
      promptAction.showToast({ message: $r('app.string.missing_file'), duration: 2000 });
      this.deleteMission(mission, true);
      return;
    }
    const path: string = file.getUri();
    const notifications: Notifications = ServiceLocator.get().notifications;
    const work: BackgroundWork = ServiceLocator.get().backgroundWork;
    // "Calculating hash" / "Please wait…", as the source's hash notification reads.
    await notifications.publishDownloadProgress(HASH_NOTIFICATION_ID,
      Localization.getString('msg_calculating_hash'), Localization.getString('msg_wait'), true);
    try {
      const digest: string = await work.runWithBackgroundTask(BackgroundWorkMode.DATA_TRANSFER,
        (): Promise<string> => MissionsFragmentPage.digestOf(path, algorithm));
      await ServiceLocator.get().share.copyToClipboard(digest);
    } catch (err) {
      const failure: BusinessError = err as BusinessError;
      hilog.error(0x0000, TAG, 'checksum: %{public}s', failure.message);
    } finally {
      await notifications.cancel(HASH_NOTIFICATION_ID);
    }
  }

  /**
   * showPopupMenu(): R.menu.mission with only the entries valid for THIS mission's state - the
   * source hides the rest rather than disabling them, and the branch order is its own.
   */
  private rowMenu(item: MissionItem): MenuElement[] {
    const entries: MenuElement[] = [];
    const mission: Mission | null = item.mission;
    if (mission === null) {
      return entries;
    }

    if (mission instanceof FinishedMission) {
      // The mission == null branch: a finished download offers Share, Delete and the checksums.
      const finished: FinishedMission = mission as FinishedMission;
      entries.push({
        value: $r('app.string.share'),
        action: (): void => {
          this.shareMission(finished);
        }
      });
      entries.push({
        // R.menu.mission's delete item is titled @string/delete_file: what it removes is the
        // file on disk, as against delete_entry, which drops only the row. The port used the
        // bare @string/delete for both kinds of mission, so the menu read "Delete" and gave no
        // clue which of the two it was.
        value: $r('app.string.delete_file'),
        action: (): void => {
          this.deleteMission(finished, true);
        }
      });
      entries.push({
        // delete_entry drops the ROW and leaves the file on disk. It was built for a
        // DownloadMission but not for a FinishedMission, so a completed download's menu offered
        // no way to forget it without also deleting the file - the reference build lists both.
        value: $r('app.string.delete_entry'),
        action: (): void => {
          this.deleteMission(finished, false);
        }
      });
      // md5 and sha1 are NOT loose entries: R.menu.mission nests them under one
      // <item android:title="@string/checksum"> submenu. A MenuElement[] cannot express that -
      // ArkUI's element list has no nesting - so they are built in rowMenuContent() below, which
      // is a real Menu() and can carry a MenuItem with its own builder.
    } else if (mission instanceof DownloadMission) {
      const download: DownloadMission = mission as DownloadMission;
      if (download.hasInvalidStorage()) {
        // Retry, Delete, Show error.
        entries.push({
          value: $r('app.string.retry'),
          action: (): void => {
            this.retryMission(download);
          }
        });
        entries.push({
          value: $r('app.string.delete_file'),
          action: (): void => {
            this.deleteMission(download, true);
          }
        });
        if (download.errCode !== ERROR_NOTHING) {
          entries.push({
            value: $r('app.string.show_error'),
            action: (): void => {
              this.showMissionError(download);
            }
          });
        }
      } else if (download.isPsRunning() && (download.errCode === ERROR_INSUFFICIENT_STORAGE
        || download.errCode === ERROR_POSTPROCESSING_HOLD)) {
        // Retry, Cancel, Show error.
        entries.push({
          value: $r('app.string.retry'),
          action: (): void => {
            this.retryMission(download);
          }
        });
        entries.push({
          value: $r('app.string.cancel'),
          action: (): void => {
            this.cancelMission(download);
          }
        });
        entries.push({
          value: $r('app.string.show_error'),
          action: (): void => {
            this.showMissionError(download);
          }
        });
      } else if (download.isPsRunning()) {
        // showPopupMenu(): a post-processing step that is not held offers nothing of its own -
        // it cannot be paused - only Show info below.
      } else if (download.running) {
        // Pause then Delete entry; the title of the first is Stop when the length is unknown.
        // Device-checked against the reference, whose running row offers Pause / Delete entry /
        // Show info: handlePopupItem() answers delete_entry for a DownloadMission in ANY state,
        // and MissionAdapter only hides the entries that make no sense while bytes are moving -
        // delete_file and start are hidden, delete_entry is not. The port offered Pause alone, so
        // a running row had no way to be dropped from the list without first being paused.
        entries.push({
          value: download.unknownLength ? $r('app.string.stop') : $r('app.string.pause'),
          action: (): void => {
            this.pauseMission(download);
          }
        });
        entries.push({
          value: $r('app.string.delete_entry'),
          action: (): void => {
            this.deleteMission(download, false);
          }
        });
      } else {
        // A stopped (paused) download. R.menu.mission is ONE resource, inflated in XML order,
        // out of which MissionAdapter only hides the entries this state cannot use - so every
        // state's popup is that single list filtered, with the order preserved:
        //
        //   Cancel, Start, Pause, Retry, Share, Enqueue, Delete file, Delete entry, Show error,
        //   Show info, Checksum
        //
        // Filtered for a paused row that is the reference's Start / Enqueue / Delete file /
        // Delete entry / Show info, device-checked - Start and Enqueue come FIRST, and Share is
        // not offered at all. e12288c read handlePopupItem() answering menu_item_share for
        // either kind of mission as proof the entry belonged here, but answering an id is not
        // showing it: there is no whole file to hand out until the mission finishes, so the
        // adapter hides Share for a DownloadMission. The port pushed it, and pushed the two
        // delete entries ahead of Start/Enqueue, so the paused row carried a sixth entry the
        // reference does not have, in an order the reference does not use.
        if (!download.isPsFailed() && download.urls.length > 0) {
          entries.push({
            value: $r('app.string.start'),
            action: (): void => {
              this.startMission(download);
            }
          });
          entries.push({
            // R.menu.mission's queue entry is CHECKABLE and carries the mission's current state;
            // the reference draws its box ticked while the mission is enqueued.
            value: $r('app.string.enqueue'),
            icon: download.enqueued ? $r('app.media.ic_done') : undefined,
            action: (): void => {
              this.toggleEnqueued(download);
            }
          });
        }
        entries.push({
          value: $r('app.string.delete_file'),
          action: (): void => {
            this.deleteMission(download, true);
          }
        });
        entries.push({
          value: $r('app.string.delete_entry'),
          action: (): void => {
            this.deleteMission(download, false);
          }
        });
        if (download.errCode !== ERROR_NOTHING) {
          entries.push({
            value: $r('app.string.show_error'),
            action: (): void => {
              this.showMissionError(download);
            }
          });
        }
      }
    }

    // R.menu.mission R.id.source, added once for every mission that remembers where it came
    // from - which is what MissionAdapter does: the item is inflated from the menu and its
    // visibility is decided once, not per branch.
    //
    // e12288c wired openMissionSource() into the finished and stopped branches without noticing
    // this push already covered them, so both menus carried TWO 'Show info' rows. The branch
    // copies are gone; this one stays because it is also the only one the invalid-storage branch
    // ever had.
    if (mission.source.length > 0) {
      entries.push({
        value: $r('app.string.show_info'),
        action: (): void => {
          this.openMissionSource(mission);
        }
      });
    }
    return entries;
  }

  /** The same menu as a long-press context menu (setOnLongClickListener -> showPopupMenu()). */
  @Builder
  rowMenuContent(item: MissionItem) {
    Menu() {
      ForEach(this.rowMenu(item), (entry: MenuElement, index: number) => {
        // entry.icon carries the reference's CHECKED state for a checkable entry (R.menu.mission's
        // queue item). It goes on endIcon, where the reference draws its checkbox - to the right
        // of the label. rowMenuContent() used to drop the field entirely, so the tick never drew.
        MenuItem({ content: entry.value, endIcon: entry.icon })
          .onClick(() => {
            entry.action();
          })
      }, (entry: MenuElement, index: number) => `${index}`)
      // The submenu R.menu.mission declares: one Checksum entry holding MD5 and SHA-1. A finished
      // mission is the only state that offers it, which is the source's own gating.
      if (item.mission instanceof FinishedMission) {
        MenuItem({
          content: $r('app.string.checksum'),
          builder: (): void => {
            this.checksumSubmenu(item.mission as FinishedMission);
          }
        })
          .id('checksum')
      }
    }
    // TC-LIBRARY-466. Measured on the reference: tapping Checksum REPLACES the menu, and the
    // submenu is drawn at the SAME top-left corner - one popup, not two.
    //
    // ArkUI's default is SIDE_EXPAND, which puts the submenu beside the parent; in the grid layout
    // the parent already reaches the right edge, so there was no room and the submenu flipped to
    // the bottom-LEFT of the screen with the parent still open behind it - the case's "the windows
    // that open are not opening in the correct positions". STACK_EXPAND is no better here: it
    // keeps the parent on screen, dimmed, and stacks the child BELOW it, so there are still two
    // windows in two places. EMBEDDED_EXPAND keeps the one popup where it already is and opens the
    // entries inside it, which is the arrangement the reference shows.
    .subMenuExpandingMode(SubMenuExpandingMode.EMBEDDED_EXPAND)
  }

  /** R.id.md5 and R.id.sha1, the two entries inside that submenu. */
  @Builder
  checksumSubmenu(mission: FinishedMission) {
    Menu() {
      MenuItem({ content: $r('app.string.md5') })
        .id('md5')
        .onClick(() => {
          this.checksum(mission, 'md5');
        })
      MenuItem({ content: $r('app.string.sha1') })
        .id('sha1')
        .onClick(() => {
          this.checksum(mission, 'sha1');
        })
    }
  }

  /** missions_header.xml - SPECIAL_PENDING / SPECIAL_FINISHED. */
  @Builder
  headerRow(item: MissionItem) {
    Row() {
      Text(item.rowKind === MissionRowKind.PendingHeader
        ? $r('app.string.missions_header_pending')
        : $r('app.string.missions_header_finished'))
        .fontSize(16)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.on_surface'))
    }
    .width('100%')
    .height(30)
    .alignItems(VerticalAlign.Center)
    .margin({ left: 8, right: 8, top: 16 })
  }

  /** mission_item.xml / mission_item_linear.xml - the same fields in a different arrangement. */
  @Builder
  missionRow(item: MissionItem) {
    Row() {
      // item_icon: a 72dp box with 15dp padding, tinted ?attr/actionColor = @color/white.
      Image(this.rowIcon(item))
        .width(72)
        .height(72)
        .padding(15)
        .objectFit(ImageFit.Contain)
        .fillColor($r('app.color.white'))

      Column() {
        // item_name: 16sp bold; item_size / item_date: 12sp; item_status: 12sp bold. All white,
        // all padded 6dp.
        // mission_item_linear.xml WRAPS the name over up to three lines rather than marqueeing
        // it - device-checked on the reference, where the full
        // "Organize İşler_ Karun Hazinesi _ Resmi Fragman _ Netflix.mp4" sits on three static
        // lines and two captures a few seconds apart are pixel-identical. The marquee belongs to
        // the GRID card (mission_item.xml), whose cell is too narrow to wrap into. The port had
        // marquee in both, so the list row showed one scrolling line.
        Text(this.missionName(item))
          .fontSize(16)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.white'))
          .padding(6)
          .width('100%')
          .maxLines(3)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        // size, status and date share ONE row in the linear layout - item_size starts at the
        // text column's left edge, item_status follows it and item_date ends at the row's end.
        // The port stacked them as three more lines of the Column, which is three rows the
        // reference does not have.
        Row() {
          Text(this.missionSize(item))
            .fontSize(12)
            .fontColor($r('app.color.white'))
            .padding(6)
            .maxLines(1)
          Text(this.missionStatus(item))
            .fontSize(12)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.white'))
            .padding(6)
            .maxLines(1)
          Blank()
          Text(this.missionDate(item))
            .fontSize(12)
            .fontColor($r('app.color.white'))
            .padding(6)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      // item_more: a 49dp centerInside button, 4dp off the card's end.
      Image($r('app.media.ic_more_vert'))
        .id('item_more')
        .width(49)
        .height(49)
        .padding(12)
        .objectFit(ImageFit.Contain)
        .fillColor($r('app.color.white'))
        .margin({ right: 4 })
        // The same builder the long press uses, not the flat element list - otherwise the
        // overflow button would be the one menu of the two without a Checksum entry.
        // SQUARE_MENU_CORNERS: the source's popup is an Android PopupMenu, a square-cornered
        // card, and ArkUI rounds a menu's corners by default - which is what TC-LIBRARY-165
        // reports. The radius belongs to the menu WINDOW, so it is set through the bind options;
        // .borderRadius(0) on the Menu component itself does nothing, because the container that
        // draws the corners is outside it.
        .bindMenu(this.rowMenuContent(item), this.menuOptions())
    }
    // R.id.item_bkg. Rule 12 exception: every row shares one id ending in `itemroot`, so the
    // replay resolves tap-card-N by index. Its ProgressDrawable background is S4/S5.
    .id('item_bkg_itemroot')
    .width('100%')
    .alignItems(VerticalAlign.Center)
    .onTouch((event: TouchEvent): void => {
      this.armRowMenu(event);
    })
    // itemView.setOnClickListener: a finished row opens its file, a downloading one does nothing.
    .onClick(() => {
      this.openMission(item);
    })
    // setOnLongClickListener: the same popup the overflow button shows.
    .bindContextMenu(this.rowMenuContent(item), ResponseType.LongPress,
      this.menuOptions())
    // item_bkg carries ?attr/colorPrimary - the SCREEN's colour, the same one the toolbar above
    // it uses, not the active service's. Device-checked on the reference: with PeerTube selected
    // the drawer is orange and this screen is still red, toolbar and tile alike. The port had the
    // tile pinned to @color/bluegray, so every row was slate - the "background colors displayed
    // on the page are incorrect" half of the case. android:layout_margin="2dp".
    .backgroundColor($r('app.color.primary'))
    .margin(2)
  }

  /**
   * mission_item.xml - the GRID cell, which is a stacked card rather than a row: the status
   * percentage top-left and the More button top-right, the media glyph centred under them, then
   * the name, then size and date sharing the last line.
   *
   * The port rendered missionRow() in both modes, so the grid cell got a 72vp leading icon and a
   * trailing 49vp button squeezed into a half-width cell and the name was left with barely three
   * characters - which is what the case reports as characters being wrong "in both list and grid
   * views". mission_item_linear.xml is the other arrangement and stays in missionRow().
   */
  @Builder
  missionCard(item: MissionItem) {
    Column() {
      Row() {
        Text(this.missionStatus(item))
          .fontSize(12)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.white'))
          .maxLines(1)
        Blank()
        Image($r('app.media.ic_more_vert'))
          .id('item_more')
          .width(32)
          .height(32)
          .padding(6)
          .objectFit(ImageFit.Contain)
          .fillColor($r('app.color.white'))
          .bindMenu(this.rowMenuContent(item), this.menuOptions())
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      // item_icon is constrained to BOTH parent edges in mission_item.xml, i.e. centred in the
      // cell - the reference's clapperboard sits on the card's midline. The Column is
      // HorizontalAlign.Start for the name and the size/date row, so the glyph needs its own
      // alignment or it hugs the left edge, which is where the port drew it.
      Image(this.rowIcon(item))
        .width(72)
        .height(72)
        .padding(15)
        .margin({ top: 8, bottom: 8 })
        .alignSelf(ItemAlign.Center)
        .objectFit(ImageFit.Contain)
        .fillColor($r('app.color.white'))

      Text(this.missionName(item))
        .fontSize(16)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.white'))
        .width('100%')
        .maxLines(GRID_NAME_LINES)
        // mission_item.xml gives the name a FIXED two-line box and lets it wrap.
        // Measured on the reference in grid view: the name node is 101 px tall on a
        // 1080 px screen for both a long pending name and a short finished one, i.e.
        // two lines reserved either way. A marquee is single-line by definition, so it
        // cannot be what the reference does here - it showed one line where the
        // reference shows two, which is this case's "names are not fully viewable".
        .textOverflow({ overflow: TextOverflow.Ellipsis })

      Row() {
        Text(this.missionSize(item))
          .fontSize(12)
          .fontColor($r('app.color.white'))
          .maxLines(1)
        Blank()
        Text(this.missionDate(item))
          .fontSize(12)
          .fontColor($r('app.color.white'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .width('100%')
      .margin({ top: 4 })
    }
    .id('item_bkg_itemroot')
    .width('100%')
    .padding(8)
    .alignItems(HorizontalAlign.Start)
    .onTouch((event: TouchEvent): void => {
      this.armRowMenu(event);
    })
    .onClick(() => {
      this.openMission(item);
    })
    .bindContextMenu(this.rowMenuContent(item), ResponseType.LongPress, this.menuOptions())
    .backgroundColor($r('app.color.primary'))
    .margin(2)
  }

  @Builder
  missionCell(item: MissionItem) {
    if (isMissionHeader(item)) {
      this.headerRow(item);
    } else if (this.mLinear) {
      this.missionRow(item);
    } else {
      this.missionCard(item);
    }
  }

  /** list_empty_view.xml, included by missions.xml. */
  @Builder
  emptyView() {
    Column() {
      // textAppearanceLarge (22sp) over the light theme's 87%-black primary text colour.
      Text('¯\\_(ツ)_/¯')
        .fontSize(22)
        .fontColor($r('app.color.on_surface'))
      // 6dp below it, centred, 16dp of horizontal padding, at the 54%-black secondary colour.
      Text($r('app.string.empty_list_subtitle'))
        .fontSize(14)
        .fontColor($r('app.color.on_surface_variant'))
        .textAlign(TextAlign.Center)
        .margin({ top: 6 })
        .padding({ left: 16, right: 16 })
    }
    .id('list_empty_view')
    .width('100%')
    // android:minHeight="128dp" with android:gravity="center".
    .height(128)
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
  }

  build() {
    Column() {
      // checkEmptyMessageVisibility(): mEmptyMessage alone is toggled. mission_recycler below
      // is never hidden, so it is NOT in this branch.
      if (this.emptyState) {
        this.emptyView();
      }

      // showError(mission): the errCode message, dismissed by the user.
      if (this.errorInfo !== null) {
        // showError() surfaces as a dismissible bar over the list, in the Snackbar idiom the
        // source uses: a dark strip, a 14sp white message and a flat accent action.
        Row() {
          Text(this.errorInfo)
            .id('error_message_view')
            .layoutWeight(1)
            .fontSize(14)
            .fontColor($r('app.color.white'))
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          if (this.errorReportable) {
            Button($r('app.string.error_report_title'))
              .id('error_report_button')
              .type(ButtonType.Normal)
              .fontSize(14)
              .fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.settings_accent'))
              .backgroundColor($r('app.color.transparent_background_color'))
              .padding({ left: 8, right: 8, top: 8, bottom: 8 })
              .margin({ left: 8 })
              .onClick(() => {
                const mission: DownloadMission | null = this.errorMission;
                this.errorInfo = null;
                if (mission !== null) {
                  this.reportMissionError(mission);
                }
              })
          }
          Button($r('app.string.ok'))
            .type(ButtonType.Normal)
            .fontSize(14)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.settings_accent'))
            .backgroundColor($r('app.color.transparent_background_color'))
            .padding({ left: 8, right: 8, top: 8, bottom: 8 })
            .margin({ left: 8 })
            .onClick(() => {
              this.errorInfo = null;
            })
        }
        .id('error_panel')
        .width('100%')
        .padding({ left: 16, right: 8, top: 8, bottom: 8 })
        .alignItems(VerticalAlign.Center)
        .backgroundColor('#323232')
      }

      // MissionAdapter owns the recycler and its Linear / Grid(2) layout manager; this screen
      // owns the rows, because the popup menu and the row tap are its behaviour.
      Column() {
        MissionAdapter({
          dataSource: this.source,
          linear: this.mLinear,
          // An arrow keeps `this` on this page; a bare `this.missionCell` would re-bind it.
          cell: (item: MissionItem): void => {
            this.missionCell(item);
          }
        })
      }
      .width('100%')
      .layoutWeight(1)

      // Deleter's Snackbar.LENGTH_INDEFINITE: the message and a yellow UNDO until the commit.
      if (this.pendingDeleteMessage.length > 0) {
        Row() {
          Text(this.pendingDeleteMessage)
            .id('snackbar_text')
            .layoutWeight(1)
            .fontSize(14)
            .fontColor($r('app.color.white'))
            .maxLines(3)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Button(Localization.getString('undo').toUpperCase())
            .id('snackbar_action')
            .type(ButtonType.Normal)
            .fontSize(14)
            .fontWeight(FontWeight.Medium)
            .fontColor(Color.Yellow)
            .backgroundColor($r('app.color.transparent_background_color'))
            .padding({ left: 8, right: 8, top: 8, bottom: 8 })
            .margin({ left: 8 })
            .onClick(() => {
              Deleter.get().undo();
            })
        }
        .id('snackbar')
        .width('100%')
        .padding({ left: 16, right: 8, top: 6, bottom: 6 })
        .alignItems(VerticalAlign.Center)
        .backgroundColor('#323232')
      }
    }
    .id('MissionsFragmentPage')
    .width('100%')
    .height('100%')
    .backgroundColor(themedBackground(this.blackTheme))
  }
}
