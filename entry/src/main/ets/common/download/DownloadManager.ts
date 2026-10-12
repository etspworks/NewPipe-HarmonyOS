/*
 * svc_download_manager (endpoints `download_size_probe`, `download_range_get`) - port of
 * app/src/main/java/us/shandian/giga/service/DownloadManager.java and of the transfer half of
 * DownloadMission.java (DownloadInitializer / DownloadRunnable / DownloadRunnableFallback).
 *
 * Three things change shape, each for a stated reason:
 *
 * 1. PERSISTENCE (architecture.persistence). The source writes each pending mission with Java
 *    object serialization (`Utility.writeToFile(metadata, this)`), which has no ArkTS analogue
 *    and is not portable. Pending missions are therefore JSON files under
 *    `<filesDir>/pending_downloads`, one per mission, named by its timestamp - exactly the naming
 *    and directory the source used. The FINISHED list was a SQLite table (FinishedMissionStore),
 *    a class the plan gives no module; rather than invent one it is absorbed here as a second
 *    JSON file, `finished_missions.json`, with the same load/add/delete/clear operations.
 *
 * 2. CONCURRENCY (phase2-logic-contract.md section 1). `mHandler.obtainMessage(what, this)` and
 *    the MESSAGE_* constants were a Handler bus back to DownloadManagerService. Mission progress
 *    is a repeating event, so it is an `Observable<MissionEvent>` from common/rx/Rx.ts; the
 *    UI subscribes and disposes in `aboutToDisappear()`. There are no threads: `threadCount`
 *    ranged GETs are in flight at once instead (DownloadRunnable x threads), and `done` only
 *    advances over the unbroken run of finished ranges, so a resume never skips a hole. A
 *    resource of unknown length goes one request at a time, the source's DownloadRunnableFallback.
 *
 * 3. NETWORK. `handleConnectivityState(NetworkState, ...)` was fed by a BroadcastReceiver;
 *    `@ohos.net.connection` answers the same question directly, and `canDownloadInCurrentNetwork()`
 *    keeps the source's exact rule: refuse when there is no network, and refuse a metered network
 *    when the user has not enabled cross-network downloads.
 *
 * Rule 8: every `httpRequest` is destroyed and every file descriptor closed in `finally`.
 */

import { hilog } from '@kit.PerformanceAnalysisKit';
import { http } from '@kit.NetworkKit';
import { connection } from '@kit.NetworkKit';
import { fileIo } from '@kit.CoreFileKit';
import { Observable, Subject } from '../rx/Rx';
import { DownloadMission, DownloadMissionJson, ERROR_CONNECT_HOST, ERROR_FILE_CREATION,
  ERROR_HTTP_FORBIDDEN, ERROR_INSUFFICIENT_STORAGE, ERROR_NOTHING, ERROR_POSTPROCESSING,
  ERROR_POSTPROCESSING_HOLD, ERROR_POSTPROCESSING_STOPPED, ERROR_PROGRESS_LOST,
  ERROR_RESOURCE_GONE, ERROR_SSL_EXCEPTION, ERROR_TIMEOUT, ERROR_UNKNOWN_EXCEPTION,
  ERROR_UNKNOWN_HOST, MissionRecoveryInfo } from '../../model/app/DownloadMission';
import { StreamInfo } from '../../model/extractor/StreamInfo';
import { Stream } from '../../model/extractor/Stream';
import { DeliveryMethod } from '../../model/enums/DeliveryMethod';
import { ExtractorHelper } from '../extractor/ExtractorHelper';
import { NewPipe } from '../extractor/core/NewPipe';
import { BackgroundWork, BackgroundWorkMode } from '../background/BackgroundWork';
import { PostprocessingJob, RESULT_HOLD, RESULT_OK } from './postprocessing/Postprocessing';
import { FinishedMission } from '../../model/app/FinishedMission';
import { Mission, MissionJson } from '../../model/app/Mission';
import { MissionState } from '../../model/enums/MissionState';
import { FileAccess, StoredDirectory, StoredFile, TAG_AUDIO, TAG_VIDEO } from '../file/FileAccess';
import { AppPreferences } from '../prefs/Preferences';
import { USER_AGENT } from '../net/Downloader';
import { Notifications } from '../notify/Notifications';
import { Localization } from '../i18n/Localization';
import {
  downloads_cross_network,
  downloads_maximum_retry,
  downloads_queue_limit
} from '../prefs/SettingsKeys';

/** DownloadManager.DOWNLOADS_METADATA_FOLDER, verbatim. */
const DOWNLOADS_METADATA_FOLDER: string = 'pending_downloads';
/** Absorbed FinishedMissionStore, see the header. */
const FINISHED_MISSIONS_FILE: string = 'finished_missions.json';
/** DownloadMission.BUFFER_SIZE: how much is asked for per range request. */
const TRANSFER_CHUNK_SIZE: number = 1024 * 1024;

/**
 * DownloadManagerService's notification ids: FOREGROUND_NOTIFICATION_ID, the ongoing "NewPipe
 * Downloading" row that is up while anything transfers, and DOWNLOADS_NOTIFICATION_ID, the
 * finished row that stays. Each failed download gets its own id after that one.
 */
const DOWNLOAD_PROGRESS_NOTIFICATION_ID: number = 1000;
const DOWNLOAD_DONE_NOTIFICATION_ID: number = 1001;

export { TAG_AUDIO, TAG_VIDEO };

/**
 * DownloadMission.doPostprocessing()'s worker, injected by EntryAbility: the taskpool half lives
 * in an .ets module (PostprocessingTask.ets), which a .ts module may not import.
 */
export type Postprocessor = (job: PostprocessingJob, onProgress: (done: number) => void) =>
  Promise<string>;

/** Port of NetworkState. */
export enum NetworkState {
  Unavailable,
  Operating,
  MeteredOperating
}

/** What a mission emits while it runs; the port of the MESSAGE_* Handler codes. */
export enum MissionEventKind {
  PROGRESS,
  RUNNING,
  PAUSED,
  FINISHED,
  ERROR,
  DELETED
}

const TAG: string = 'DownloadManager';

/** What one ranged GET did: the bytes written, and whether the server sent the whole resource. */
class RangeResult {
  readonly written: number;
  /** A 200 to a ranged request: the server ignored the range and the body starts at byte 0. */
  readonly whole: boolean;

  constructor(written: number, whole: boolean) {
    this.written = written;
    this.whole = whole;
  }
}

export class MissionEvent {
  kind: MissionEventKind;
  /**
   * `Mission`, not `DownloadMission`: a FINISHED mission is removed too, and while this was the
   * narrower type those removals could not be announced at all - see forgetFinishedDownloads()
   * and deleteMission()'s FinishedMission branch. Subscribers read `kind` and reload from the
   * manager; none of them reads this field.
   */
  mission: Mission;

  constructor(kind: MissionEventKind, mission: Mission) {
    this.kind = kind;
    this.mission = mission;
  }
}

export class DownloadManager {
  private files: FileAccess | null = null;
  private prefs: AppPreferences | null = null;

  private readonly missionsPending: DownloadMission[] = [];
  private missionsFinished: FinishedMission[] = [];

  private pendingMissionsDir: string = '';
  private lastNetworkStatus: NetworkState = NetworkState.Unavailable;
  private selfMissionsControl: boolean = false;

  /** The three preferences the source caches on the manager. */
  prefMaxRetry: number = 3;
  prefMeteredDownloads: boolean = false;
  prefQueueLimit: boolean = false;
  /**
   * The shade. Injected by ServiceLocator rather than read from it: the locator constructs this
   * class, so reaching back into it from here would close an import cycle.
   */
  private notifications: Notifications | null = null;
  /** updateForegroundState()'s mForeground: whether the ongoing row is up. */
  private progressShown: boolean = false;
  /** Publish and cancel of the ongoing row, serialised so a late publish cannot outlive a cancel. */
  private progressSync: Promise<void> = Promise.resolve();
  /** mDownloadNotificationEnable: false while the Downloads screen is in front. */
  private downloadNotificationEnable: boolean = true;
  /** downloadDoneList / downloadDoneCount: the files the finished row lists. */
  private downloadDoneNames: string[] = [];
  /** mFailedDownloads: a mission already reported as failed is not reported again. */
  private readonly failedDownloads: Set<Mission> = new Set<Mission>();
  /** downloadFailedNotificationID: one row per failure, after the finished row's id. */
  private downloadFailedNotificationId: number = DOWNLOAD_DONE_NOTIFICATION_ID + 1;

  mainStorageAudio: StoredDirectory | null = null;
  mainStorageVideo: StoredDirectory | null = null;

  /** See Postprocessor. Null until EntryAbility sets it; a mission then fails its muxing step. */
  postprocessor: Postprocessor | null = null;
  /**
   * DownloadManagerService.startForeground(): the dataTransfer continuous task, held while any
   * mission transfers, whichever screen started it. It used to be the Downloads page's to hold,
   * so a download started from the detail page stopped as soon as the app went to the background.
   */
  private backgroundWork: BackgroundWork | null = null;
  private backgroundHeld: boolean = false;
  private backgroundSync: Promise<void> = Promise.resolve();

  private readonly events: Subject<MissionEvent> = new Subject<MissionEvent>();

  /**
   * The mission event stream. One-shot operations are awaited; progress repeats, so it is an
   * Observable (contract section 1). Subscribers own a CompositeDisposable and dispose it in
   * `aboutToDisappear()`.
   */
  observeMissions(): Observable<MissionEvent> {
    return this.events;
  }

  /**
   * Port of the DownloadManager constructor: read the preferences, load the finished list,
   * then load the pending missions from disk.
   */
  async init(files: FileAccess, prefs: AppPreferences, storageVideo: StoredDirectory | null,
    storageAudio: StoredDirectory | null, notifications: Notifications | null = null,
    backgroundWork: BackgroundWork | null = null): Promise<void> {
    this.files = files;
    this.prefs = prefs;
    this.notifications = notifications;
    if (notifications !== null) {
      // the finished row's deleteIntent: swiping it away starts the count again
      notifications.onDownloadsFinishedRemoved((): void => {
        this.downloadDoneNames = [];
      }).catch((err: Error): void => {
        hilog.warn(0x0000, TAG, 'finished-row removal: %{public}s', err.message);
      });
    }
    this.backgroundWork = backgroundWork;
    this.mainStorageVideo = storageVideo;
    this.mainStorageAudio = storageAudio;

    this.readPreferences();
    this.pendingMissionsDir = files.ensureAppDir(DOWNLOADS_METADATA_FOLDER);
    // T-0183b: re-arm every persisted URI BEFORE anything decides a file is gone. Without this
    // the first open in a new process fails on the grant and a live download looks deleted.
    await this.activatePersistedUris();
    this.missionsFinished = this.loadFinishedMissions();
    this.loadPendingMissions();
    this.lastNetworkStatus = DownloadManager.currentNetworkState();
    // DownloadManagerService.onCreate() ends with the queue running: the service exists to carry
    // the enqueued missions, and NewPipe resumes them the moment it is up. Nothing here did, so a
    // mission that outlived the process - or one queued behind another - stayed "(queued)" until
    // somebody pressed its row, which is not a state the Downloads screen even offers a way out
    // of. A mission the user PAUSED is not enqueued, so this leaves it alone.
    this.pumpQueue();
  }

  private requireFiles(): FileAccess {
    const files: FileAccess | null = this.files;
    if (files === null) {
      throw new Error('DownloadManager used before ServiceLocator.init()');
    }
    return files;
  }

  private requirePrefs(): AppPreferences {
    const prefs: AppPreferences | null = this.prefs;
    if (prefs === null) {
      throw new Error('DownloadManager used before ServiceLocator.init()');
    }
    return prefs;
  }

  /** Port of the three preference fields DownloadManagerService kept in sync. */
  readPreferences(): void {
    const prefs: AppPreferences = this.requirePrefs();
    const retry: string = prefs.getStringSync(downloads_maximum_retry, '3');
    const parsed: number = parseInt(retry, 10);
    // DownloadManagerService.handlePreferenceChange: an unparseable value falls back to 0, not 3.
    this.prefMaxRetry = isNaN(parsed) ? 0 : parsed;
    // downloads_cross_network is "pause downloads on metered networks" - stored as-is, NOT negated.
    // canDownloadInCurrentNetwork() already reads it as `!(prefMeteredDownloads && metered)`, the
    // same way DownloadManager.java:499 does, so negating here inverted the toggle's whole meaning.
    this.prefMeteredDownloads = prefs.getBooleanSync(downloads_cross_network, false);
    // defaultValue="true" in download_settings.xml, and prefs.getBoolean(key, true) in the source.
    this.prefQueueLimit = prefs.getBooleanSync(downloads_queue_limit, true);
  }

  /* //////////////////////////////////////////////////////////////////////////
  // Persistence
  ////////////////////////////////////////////////////////////////////////// */

  private metadataPath(timestamp: number): string {
    return `${this.pendingMissionsDir}/${timestamp}`;
  }

  private finishedMissionsPath(): string {
    return `${this.pendingMissionsDir}/${FINISHED_MISSIONS_FILE}`;
  }

  /**
   * Port of loadFinishedMissions(): reads the finished list and FORGETS any entry whose file is
   * gone, which is what stops the downloads screen showing rows that lead nowhere.
   *
   * "Gone" is only ever concluded for a handle that can be verified in THIS process. The
   * source can prune on existsAsFile() because takePersistableUriPermission keeps the handle
   * alive across restarts; here the picker's grant dies with the process, so on every restart
   * existsAsFile() was false for every finished download and the whole list was pruned and
   * written back empty. An unverifiable entry is kept - the row can render it as "not
   * accessible" off StoredFile.isVerifiable()/existsAsFile() - and only the user's delete drops
   * it.
   *
   * T-0183b: that upgrade is taken. activatePersistedUris() runs before this, re-arming every URI
   * whose grant was persisted, so those entries ARE verifiable now and a genuinely deleted file is
   * pruned again. The keep-the-unverifiable rule is untouched; only the set of verifiable handles
   * grew.
   */
  /**
   * The URIs of finished missions whose grant was persisted, re-activated for THIS process.
   *
   * Reads the same finished_missions.json loadFinishedMissions() is about to read. Doing it here
   * rather than inside that method keeps it synchronous, which the rest of the manager relies on.
   */
  private async activatePersistedUris(): Promise<void> {
    const json: string | null = this.requireFiles().readText(this.finishedMissionsPath());
    if (json === null) {
      return;
    }
    let records: MissionJson[] = [];
    try {
      records = JSON.parse(json) as MissionJson[];
    } catch (err) {
      return;
    }
    const uris: string[] = [];
    for (const record of records) {
      if (record.storagePersisted === true && record.storageUri.length > 0) {
        uris.push(record.storageUri);
      }
    }
    await this.requireFiles().activateUris(uris);
  }

  private loadFinishedMissions(): FinishedMission[] {
    const json: string | null = this.requireFiles().readText(this.finishedMissionsPath());
    if (json === null) {
      return [];
    }
    let records: MissionJson[] = [];
    try {
      records = JSON.parse(json) as MissionJson[];
    } catch (err) {
      return [];
    }

    const kept: FinishedMission[] = [];
    for (const record of records) {
      const mission: FinishedMission = FinishedMission.fromJson(record);
      const storage: StoredFile | null = mission.storage;
      if (storage === null) {
        continue; // never had a file: nothing a row could lead to
      }
      if (storage.isVerifiable() && !storage.existsAsFile()) {
        hilog.info(0x0000, TAG, 'downloaded file removed: %{public}s', storage.getName());
        continue;
      }
      kept.push(mission);
    }
    if (kept.length !== records.length) {
      this.saveFinishedMissions(kept);
    }
    return kept;
  }

  private saveFinishedMissions(missions: FinishedMission[]): void {
    const records: MissionJson[] = [];
    for (const mission of missions) {
      records.push(mission.toJson());
    }
    this.requireFiles().writeText(this.finishedMissionsPath(), JSON.stringify(records));
  }

  /**
   * Port of loadPendingMissions(ctx): every JSON file in the metadata directory is a mission.
   * The source's recovery branches are preserved: a mission that finished while the app was gone
   * moves to the finished list, and a mission whose file vanished is recovered or, failing that,
   * reset with ERROR_PROGRESS_LOST so the user sees it and can retry.
   */
  private loadPendingMissions(): void {
    const files: FileAccess = this.requireFiles();
    const names: string[] = files.listNames(this.pendingMissionsDir);

    for (const name of names) {
      if (name === FINISHED_MISSIONS_FILE || name === '.tmp') {
        continue;
      }
      const path: string = `${this.pendingMissionsDir}/${name}`;
      const json: string | null = files.readText(path);
      if (json === null) {
        files.deleteQuietly(path);
        continue;
      }

      let mission: DownloadMission;
      try {
        mission = DownloadMission.fromJson(JSON.parse(json) as DownloadMissionJson);
      } catch (err) {
        files.deleteQuietly(path);
        continue;
      }
      mission.metadata = path;
      mission.maxRetry = this.prefMaxRetry;
      mission.running = false;

      // do not delete missions that are truly finished - move them to the finished list
      if (mission.isFinished()) {
        this.setFinished(mission);
        files.deleteQuietly(path);
        continue;
      }

      // a mission with no storage at all is unrecoverable
      if (mission.storage === null) {
        files.deleteQuietly(path);
        continue;
      }

      if (mission.isPsRunning()) {
        // The process died mid-muxing: the copy over the download may have been half done.
        mission.psState = 0;
        mission.errCode = ERROR_POSTPROCESSING_STOPPED;
        this.missionsPending.push(mission);
        continue;
      }

      if (!mission.storage.existsAsFile()) {
        this.tryRecover(mission);
        // keep the mission even if recovery fails, so the user can see and retry it
        if (mission.isInitialized() && mission.errCode === ERROR_NOTHING) {
          mission.resetState(true, ERROR_PROGRESS_LOST);
        }
      }

      this.missionsPending.push(mission);
    }

    if (this.missionsPending.length > 1) {
      this.missionsPending.sort((a: DownloadMission, b: DownloadMission): number =>
        a.getTimestamp() - b.getTimestamp());
    }
  }

  /** Port of writeThisToFile(): the mission's JSON record, written to its metadata file. */
  private writeMission(mission: DownloadMission): void {
    if (mission.metadata.length === 0) {
      return;
    }
    this.requireFiles().writeText(mission.metadata, JSON.stringify(mission.toJson()));
  }

  /** Port of deleteThisFromFile(). */
  private deleteMissionFile(mission: DownloadMission): void {
    if (mission.metadata.length === 0) {
      return;
    }
    this.requireFiles().deleteQuietly(mission.metadata);
  }

  /* //////////////////////////////////////////////////////////////////////////
  // Queries
  ////////////////////////////////////////////////////////////////////////// */

  getPendingMissions(): DownloadMission[] {
    return this.missionsPending.slice();
  }

  getFinishedMissions(): FinishedMission[] {
    return this.missionsFinished.slice();
  }

  /** Port of getRunningMissionsCount(). */
  getRunningMissionsCount(): number {
    let count: number = 0;
    for (const mission of this.missionsPending) {
      if (mission.running && !mission.isPsFailed() && !mission.isFinished()) {
        count++;
      }
    }
    return count;
  }

  /** Port of getPendingMission(storage). */
  private getPendingMission(storage: StoredFile): DownloadMission | null {
    for (const mission of this.missionsPending) {
      const file: StoredFile | null = mission.storage;
      if (file !== null && file.equalsFile(storage)) {
        return mission;
      }
    }
    return null;
  }

  /** Port of getFinishedMissionIndex(storage). */
  private getFinishedMissionIndex(storage: StoredFile): number {
    for (let i: number = 0; i < this.missionsFinished.length; i++) {
      const file: StoredFile | null = this.missionsFinished[i].storage;
      if (file !== null && file.equalsFile(storage)) {
        return i;
      }
    }
    return -1;
  }

  /** Port of getAnyMission(storage). */
  private getAnyMission(storage: StoredFile): Mission | null {
    const pending: DownloadMission | null = this.getPendingMission(storage);
    if (pending !== null) {
      return pending;
    }
    const index: number = this.getFinishedMissionIndex(storage);
    return index >= 0 ? this.missionsFinished[index] : null;
  }

  /** Port of checkForExistingMission(storage). */
  checkForExistingMission(storage: StoredFile): MissionState {
    const pending: DownloadMission | null = this.getPendingMission(storage);
    if (pending === null) {
      if (this.getFinishedMissionIndex(storage) >= 0) {
        return MissionState.Finished;
      }
      return MissionState.None;
    }
    if (pending.isFinished()) {
      return MissionState.Finished; // race-condition; should never happen
    }
    return pending.running ? MissionState.PendingRunning : MissionState.Pending;
  }

  /** Port of canRecoverMission(mission). */
  canRecoverMission(mission: DownloadMission | null): boolean {
    if (mission === null) {
      return false;
    }
    return mission.errCode === ERROR_PROGRESS_LOST
      || mission.storage === null
      || !mission.storage.existsAsFile();
  }

  /** Port of getMainStorage(tag). */
  getMainStorage(tag: string): StoredDirectory | null {
    if (tag === TAG_AUDIO) {
      return this.mainStorageAudio;
    }
    if (tag === TAG_VIDEO) {
      return this.mainStorageVideo;
    }
    return null;
  }

  /* //////////////////////////////////////////////////////////////////////////
  // Lifecycle of a mission
  ////////////////////////////////////////////////////////////////////////// */

  /**
   * Port of startMission(mission): register, persist, then run if the queue allows.
   *
   * The three hilog lines in this class are load-bearing, not decoration: this whole class used
   * to log nothing at all, so "the mission never started" and "the mission failed and the error
   * was swallowed" looked identical from a device bundle - which is what made TC-LIBRARY-017
   * take three device sessions to narrow.
   */
  async startMission(mission: DownloadMission): Promise<void> {
    hilog.info(0x0000, TAG, 'startMission: %{public}d url(s), queueLimit=%{public}s',
      mission.urls.length, `${this.prefQueueLimit}`);
    mission.timestamp = Date.now();
    mission.maxRetry = this.prefMaxRetry;

    // create the metadata file, bumping the timestamp until the name is free (as the source does)
    while (fileIo.accessSync(this.metadataPath(mission.timestamp))) {
      mission.timestamp = mission.timestamp + 1;
    }
    mission.metadata = this.metadataPath(mission.timestamp);
    this.writeMission(mission);

    this.missionsPending.push(mission);
    this.selfMissionsControl = true;

    // the source starts immediately unless the queue limit says otherwise
    if (!this.prefQueueLimit || this.getRunningMissionsCount() === 0) {
      await this.resumeMission(mission);
    }
  }

  /** Port of resumeMission(mission). */
  async resumeMission(mission: DownloadMission): Promise<void> {
    if (!mission.running) {
      await this.runMission(mission);
    }
  }

  /** Port of pauseMission(mission). */
  pauseMission(mission: DownloadMission): void {
    if (mission.running) {
      mission.setEnqueued(false);
      mission.running = false;
      this.writeMission(mission);
      this.emit(MissionEventKind.PAUSED, mission);
      // The slot is free again, and something else may be waiting for it.
      this.pumpQueue();
    }
  }

  /** DownloadMission.setEnqueued(queue): the flag, written to the mission's record. */
  setEnqueued(mission: DownloadMission, queue: boolean): void {
    mission.setEnqueued(queue);
    this.writeMission(mission);
  }

  /**
   * DownloadMission.psContinue(recover): a post-processing step held for want of space is run
   * again (Retry) or given up, which leaves the mission failed (Cancel).
   */
  async psContinue(mission: DownloadMission, recover: boolean): Promise<void> {
    if (!mission.isPsRunning() || mission.running) {
      return;
    }
    if (recover) {
      await this.doPostprocessing(mission);
      return;
    }
    mission.psState = 0;
    this.notifyError(mission, ERROR_POSTPROCESSING, null);
  }

  /** Port of deleteMission(mission, alsoDeleteFile). */
  deleteMission(mission: Mission, alsoDeleteFile: boolean): void {
    if (mission instanceof DownloadMission) {
      const index: number = this.missionsPending.indexOf(mission);
      if (index >= 0) {
        this.missionsPending.splice(index, 1);
      }
      mission.running = false;
      this.deleteMissionFile(mission);
      this.emit(MissionEventKind.DELETED, mission);
    } else if (mission instanceof FinishedMission) {
      const index: number = this.missionsFinished.indexOf(mission);
      if (index >= 0) {
        this.missionsFinished.splice(index, 1);
        this.saveFinishedMissions(this.missionsFinished);
        // The pending branch above announces its removal; this one did not, so a finished row
        // deleted from its own menu stayed on screen until the list was rebuilt for some other
        // reason. MissionsFragmentPage reloads on any non-PROGRESS event.
        this.emit(MissionEventKind.DELETED, mission);
      }
    }

    if (alsoDeleteFile) {
      mission.delete();
    }
  }

  /** Port of forgetMission(storage): drop the record AND the file, whichever list it is in. */
  forgetMission(storage: StoredFile): void {
    const mission: Mission | null = this.getAnyMission(storage);
    if (mission === null) {
      return;
    }
    this.deleteMission(mission, false);
    mission.storage = null;
    mission.delete();
  }

  /** Port of setFinished(mission): move it from pending to the head of the finished list. */
  setFinished(mission: DownloadMission): void {
    const index: number = this.missionsPending.indexOf(mission);
    if (index >= 0) {
      this.missionsPending.splice(index, 1);
    }
    this.missionsFinished.splice(0, 0, FinishedMission.fromDownloadMission(mission));
    this.saveFinishedMissions(this.missionsFinished);
  }

  /**
   * Port of forgetFinishedDownloads(): forget the records, keep the files.
   *
   * The source's caller follows this with notifyItemRangeRemoved() on the adapter. Here the list
   * rebuilds itself from the mission event stream, so the removals have to be announced or the
   * rows stay on screen over an empty store - which is what 'Clear download history' did: the
   * header's overflow disappeared (it reads the manager) while the Finished section kept its
   * rows.
   */
  forgetFinishedDownloads(): void {
    const forgotten: FinishedMission[] = this.missionsFinished;
    this.missionsFinished = [];
    this.saveFinishedMissions(this.missionsFinished);
    for (const mission of forgotten) {
      this.emit(MissionEventKind.DELETED, mission);
    }
  }

  /**
   * Port of tryRecover(mission): recreate the file, and if that is impossible invalidate the
   * handle and create a fresh file in the current save directory, so the user is not asked to
   * pick a path again unless the directory itself is gone.
   */
  tryRecover(mission: DownloadMission): void {
    const storage: StoredFile | null = mission.storage;
    if (storage === null) {
      return;
    }
    const mainStorage: StoredDirectory | null = this.getMainStorage(storage.getTag());

    if (!storage.isInvalid() && storage.create()) {
      return;
    }
    storage.invalidate();
    if (mainStorage === null) {
      return;
    }
    const newStorage: StoredFile | null =
      mainStorage.createFile(storage.getName(), storage.getType());
    if (newStorage !== null) {
      mission.storage = newStorage;
    }
  }

  /** Port of pauseAllMissions(force). */
  pauseAllMissions(): void {
    for (const mission of this.missionsPending) {
      if (!mission.running || mission.isPsRunning() || mission.isFinished()) {
        continue;
      }
      this.pauseMission(mission);
    }
  }

  /** Port of startAllMissions(). */
  async startAllMissions(): Promise<void> {
    this.selfMissionsControl = true;
    for (const mission of this.missionsPending.slice()) {
      if (mission.running || mission.isCorrupt()) {
        continue;
      }
      await this.resumeMission(mission);
    }
  }

  /** Port of updateMaximumAttempts(). */
  updateMaximumAttempts(): void {
    this.readPreferences();
    for (const mission of this.missionsPending) {
      mission.maxRetry = this.prefMaxRetry;
    }
  }

  /**
   * Port of runMissions(): runs one or more queued missions if the network allows.
   * Returns true when at least one mission is running afterwards.
   */
  async runMissions(): Promise<boolean> {
    if (this.missionsPending.length === 0) {
      return false;
    }
    if (!this.canDownloadInCurrentNetwork()) {
      return false;
    }

    if (this.prefQueueLimit) {
      for (const mission of this.missionsPending) {
        if (!mission.isFinished() && mission.running) {
          return true;
        }
      }
    }

    let flag: boolean = false;
    for (const mission of this.missionsPending.slice()) {
      if (mission.running || !mission.enqueued || mission.isFinished()) {
        continue;
      }
      await this.resumeMission(mission);
      if (mission.errCode !== ERROR_NOTHING) {
        continue;
      }
      if (this.prefQueueLimit) {
        return true;
      }
      flag = true;
    }
    return flag;
  }

  /* //////////////////////////////////////////////////////////////////////////
  // Network
  ////////////////////////////////////////////////////////////////////////// */

  /** Reads the current network state; the port of what the BroadcastReceiver reported. */
  static currentNetworkState(): NetworkState {
    try {
      const handle: connection.NetHandle = connection.getDefaultNetSync();
      if (handle.netId === 0) {
        return NetworkState.Unavailable;
      }
      const capabilities: connection.NetCapabilities =
        connection.getNetCapabilitiesSync(handle);
      const caps: connection.NetCap[] =
        capabilities.networkCap === undefined ? [] : capabilities.networkCap;
      const notMetered: boolean = caps.includes(connection.NetCap.NET_CAPABILITY_NOT_METERED);
      return notMetered ? NetworkState.Operating : NetworkState.MeteredOperating;
    } catch (err) {
      return NetworkState.Unavailable;
    }
  }

  /** Port of canDownloadInCurrentNetwork(), rule for rule. */
  canDownloadInCurrentNetwork(): boolean {
    if (this.lastNetworkStatus === NetworkState.Unavailable) {
      return false;
    }
    return !(this.prefMeteredDownloads
      && this.lastNetworkStatus === NetworkState.MeteredOperating);
  }

  /**
   * Port of handleConnectivityState(currentStatus, updateOnly): pause on a metered network the
   * user did not allow, resume when it becomes allowed again - but never touch anything before
   * the user has interacted with the downloads screen (`selfMissionsControl`).
   */
  async handleConnectivityState(currentStatus: NetworkState, updateOnly: boolean): Promise<void> {
    if (currentStatus === this.lastNetworkStatus) {
      return;
    }
    this.lastNetworkStatus = currentStatus;
    if (currentStatus === NetworkState.Unavailable) {
      return;
    }
    if (!this.selfMissionsControl || updateOnly) {
      return; // don't touch anything without the user interaction
    }

    const isMetered: boolean =
      this.prefMeteredDownloads && currentStatus === NetworkState.MeteredOperating;

    for (const mission of this.missionsPending.slice()) {
      if (mission.isCorrupt() || mission.isPsRunning()) {
        continue;
      }
      if (mission.running && isMetered) {
        this.pauseMission(mission);
      } else if (!mission.running && !isMetered && mission.enqueued) {
        await this.resumeMission(mission);
        if (this.prefQueueLimit) {
          break;
        }
      }
    }
  }

  /* //////////////////////////////////////////////////////////////////////////
  // The transfer
  ////////////////////////////////////////////////////////////////////////// */

  private emit(kind: MissionEventKind, mission: Mission): void {
    this.events.onNext(new MissionEvent(kind, mission));
    if (kind !== MissionEventKind.PROGRESS) {
      this.syncBackgroundWork();
      this.syncProgressNotification();
      if (kind !== MissionEventKind.ERROR) {
        // handleMessage(): `if (msg.what != MESSAGE_ERROR) mFailedDownloads.remove(mission)`
        this.failedDownloads.delete(mission);
      }
    }
  }

  /**
   * updateForegroundState(): the foreground notification - "NewPipe Downloading", "Tap for
   * details" - is up exactly while a mission transfers. It used to carry the file name and a
   * percentage, repainted per chunk, and was only cancelled when a mission FINISHED, so a failed
   * or paused download left an ongoing row behind.
   */
  private syncProgressNotification(): void {
    const notifications: Notifications | null = this.notifications;
    const wanted: boolean = this.getRunningMissionsCount() > 0;
    if (notifications === null || wanted === this.progressShown) {
      return;
    }
    this.progressShown = wanted;
    this.progressSync = this.progressSync.then((): Promise<void> => wanted
      ? notifications.publishDownloadProgress(DOWNLOAD_PROGRESS_NOTIFICATION_ID,
        Localization.getString('msg_running'), Localization.getString('msg_running_detail'), true)
      : notifications.cancel(DOWNLOAD_PROGRESS_NOTIFICATION_ID)
    ).catch((err: Error): void => {
      hilog.warn(0x0000, TAG, 'progress notification: %{public}s', err.message);
    });
  }

  /** DownloadManagerBinder.enableNotifications(): the Downloads screen turns them off while shown. */
  enableNotifications(enable: boolean): void {
    this.downloadNotificationEnable = enable;
  }

  /**
   * DownloadManagerBinder.clearDownloadNotifications(): the Downloads screen, once open, takes the
   * finished and failed rows down and starts the finished count again. The ongoing row stays.
   */
  clearDownloadNotifications(): void {
    const notifications: Notifications | null = this.notifications;
    if (notifications === null) {
      return;
    }
    this.downloadDoneNames = [];
    const cancels: Promise<void>[] = [notifications.cancel(DOWNLOAD_DONE_NOTIFICATION_ID)];
    for (let id: number = DOWNLOAD_DONE_NOTIFICATION_ID + 1; id < this.downloadFailedNotificationId;
      id++) {
      cancels.push(notifications.cancel(id));
    }
    this.failedDownloads.clear();
    this.downloadFailedNotificationId = DOWNLOAD_DONE_NOTIFICATION_ID + 1;
    Promise.all(cancels).catch((err: Error): void => {
      hilog.warn(0x0000, TAG, 'clear notifications: %{public}s', err.message);
    });
  }

  /** Holds the continuous task exactly while something transfers; calls are serialised. */
  private syncBackgroundWork(): void {
    const work: BackgroundWork | null = this.backgroundWork;
    if (work === null) {
      return;
    }
    this.backgroundSync = this.backgroundSync.then(async (): Promise<void> => {
      const wanted: boolean = this.getRunningMissionsCount() > 0;
      if (wanted === this.backgroundHeld) {
        return;
      }
      if (wanted) {
        this.backgroundHeld = await work.start(BackgroundWorkMode.DATA_TRANSFER);
      } else {
        await work.stop(BackgroundWorkMode.DATA_TRANSFER);
        this.backgroundHeld = false;
      }
    }).catch((err: Error): void => {
      hilog.warn(0x0000, TAG, 'background task: %{public}s', err.message);
    });
  }

  /**
   * Port of DownloadMission.notifyError(Exception): map a transport failure onto the source's
   * error codes, and stop enqueueing unless the failure is a transient network one.
   */
  private notifyError(mission: DownloadMission, code: number, err: Error | null): void {
    hilog.error(0x0000, TAG, 'mission error %{public}d: %{public}s',
      code, err === null ? '(no exception)' : err.message);
    mission.errCode = code;
    mission.errObject = err;

    const transientNetwork: boolean = code === ERROR_SSL_EXCEPTION
      || code === ERROR_UNKNOWN_HOST
      || code === ERROR_CONNECT_HOST
      || code === ERROR_TIMEOUT;
    if (!transientNetwork && (code < 500 || code > 599)) {
      // also checks for server errors: those keep their place in the queue
      mission.enqueued = false;
    }

    mission.running = false;
    this.writeMission(mission);
    this.emit(MissionEventKind.ERROR, mission);
    this.notifyFailedDownload(mission);
    // A failed mission must not hold the single running slot: the source's listener runs the
    // queue on ERROR exactly as it does on FINISHED.
    this.pumpQueue();
  }

  /**
   * Endpoint `download_size_probe` - port of DownloadMission.openConnection(headRequest=true)
   * plus DownloadInitializer: a HEAD request that resolves the resource length and whether the
   * server allows range requests at all.
   */
  private async probeSize(url: string): Promise<number> {
    const request: http.HttpRequest = http.createHttp();
    try {
      const header: Record<string, string> = {
        'User-Agent': USER_AGENT,
        'Accept': '*/*',
        'Accept-Encoding': '*'
      };
      const options: http.HttpRequestOptions = {
        method: http.RequestMethod.HEAD,
        header: header,
        connectTimeout: 30000,
        readTimeout: 30000
      };
      const response: http.HttpResponse = await request.request(url, options);
      if (response.responseCode < 200 || response.responseCode > 299) {
        DownloadManager.logRefusal('HEAD', response.responseCode, url, header);
        return -1;
      }
      const headers: Record<string, string> = response.header as Record<string, string>;
      const raw: string | undefined = headers['content-length'] === undefined
        ? headers['Content-Length']
        : headers['content-length'];
      if (raw === undefined) {
        return -1; // the source's `unknownLength` case
      }
      const parsed: number = parseInt(raw, 10);
      return isNaN(parsed) ? -1 : parsed;
    } finally {
      request.destroy();
    }
  }

  /**
   * Endpoint `download_range_get` - port of DownloadRunnable/DownloadRunnableFallback: one
   * ranged GET of the resource from `offset`, written to the file at `fileOffset + offset`.
   *
   * The two offsets are the source's `start` (the Range header, relative to the resource) and
   * `mission.offsets[current] + start` (where it lands in the file). They used to be one, so the
   * SECOND resource of a mission - the audio a video-only stream is muxed with - asked the server
   * for bytes past its own end, got 416, and was taken as complete with nothing written.
   *
   * DownloadRunnableFallback's case: a 200 instead of a 206 means the server ignored the range
   * (YouTube's caption urls do), so the body is the WHOLE resource from its first byte. It is
   * written there and reported as such; appending it at `offset` repeated the file for ever.
   */
  private async fetchRange(url: string, offset: number, length: number,
    target: StoredFile, fileOffset: number): Promise<RangeResult> {
    const request: http.HttpRequest = http.createHttp();
    let file: fileIo.File | null = null;
    try {
      const rangeEnd: number = length > 0 ? offset + length - 1 : 0;
      const range: string = rangeEnd > 0 ? `bytes=${offset}-${rangeEnd}` : `bytes=${offset}-`;
      const header: Record<string, string> = {
        'User-Agent': USER_AGENT,
        'Accept': '*/*',
        'Accept-Encoding': '*',
        'Range': range
      };
      const options: http.HttpRequestOptions = {
        method: http.RequestMethod.GET,
        header: header,
        expectDataType: http.HttpDataType.ARRAY_BUFFER,
        connectTimeout: 30000,
        readTimeout: 30000
      };
      const response: http.HttpResponse = await request.request(url, options);

      // the source treats 204/205/207 and any non-2xx as an HttpError; 416 ends the transfer
      if (response.responseCode === 416) {
        return new RangeResult(0, false);
      }
      if (response.responseCode < 200 || response.responseCode > 299
        || response.responseCode === 204) {
        DownloadManager.logRefusal('GET', response.responseCode, url, header);
        throw new Error(`HTTP ${response.responseCode}`);
      }
      if (!(response.result instanceof ArrayBuffer)) {
        return new RangeResult(0, false);
      }
      const body: ArrayBuffer = response.result as ArrayBuffer;
      if (body.byteLength === 0) {
        return new RangeResult(0, false);
      }

      const whole: boolean = response.responseCode === 200;
      file = fileIo.openSync(target.getUri(),
        fileIo.OpenMode.CREATE | fileIo.OpenMode.READ_WRITE);
      const written: number = fileIo.writeSync(file.fd, body,
        { offset: fileOffset + (whole ? 0 : offset) });
      if (whole) {
        // nothing of an earlier, ranged attempt may outlive the whole body
        fileIo.truncateSync(file.fd, fileOffset + written);
      }
      return new RangeResult(written, whole);
    } finally {
      if (file !== null) {
        fileIo.closeSync(file);
      }
      request.destroy();
    }
  }

  /**
   * Port of DownloadMission.start() + the runnables: transfer the current resource in chunks,
   * emitting progress, then move on to the next url or finish. `recovered`: this run already uses
   * a url doRecover() renewed, so a second 403 is final rather than another recovery.
   */
  private async runMission(mission: DownloadMission, recovered: boolean = false): Promise<void> {
    if (mission.running || mission.isFinished() || mission.urls.length < 1) {
      return;
    }
    if (mission.hasInvalidStorage()) {
      this.notifyError(mission, ERROR_FILE_CREATION, null);
      return;
    }
    if (mission.current >= mission.urls.length) {
      await this.completeMission(mission);
      return;
    }

    const url: string | null = mission.currentUrl();
    if (url === null) {
      this.notifyError(mission, ERROR_RESOURCE_GONE, null);
      return;
    }
    const target: StoredFile | null = mission.storage;
    if (target === null) {
      this.notifyError(mission, ERROR_FILE_CREATION, null);
      return;
    }

    mission.running = true;
    mission.errCode = ERROR_NOTHING;
    mission.errObject = null;
    this.emit(MissionEventKind.RUNNING, mission);

    try {
      if (!mission.isInitialized()) {
        const size: number = await this.probeSize(url);
        if (size < 0) {
          mission.unknownLength = true;
          mission.length = 0;
        } else {
          mission.unknownLength = false;
          mission.length = size;
        }
        mission.initialized = true;
        this.writeMission(mission);
      }

      let attempts: number = 0;
      // resume where the previous run stopped, which is the source's fallbackResumeOffset
      while (mission.running) {
        const left: number = mission.unknownLength
          ? TRANSFER_CHUNK_SIZE
          : mission.length - mission.done;
        if (!mission.unknownLength && left <= 0) {
          break;
        }
        // DownloadRunnable x threadCount: that many consecutive ranges in flight at once.
        const lanes: number = mission.unknownLength ? 1
          : Math.max(1, Math.min(mission.threadCount, Math.ceil(left / TRANSFER_CHUNK_SIZE)));
        const sizes: number[] = [];
        const requests: Promise<RangeResult>[] = [];
        for (let lane: number = 0; lane < lanes; lane++) {
          const start: number = mission.done + lane * TRANSFER_CHUNK_SIZE;
          const size: number = mission.unknownLength ? TRANSFER_CHUNK_SIZE
            : Math.min(TRANSFER_CHUNK_SIZE, mission.length - start);
          sizes.push(size);
          requests.push(this.fetchRange(url, start, size, target,
            mission.offsets[mission.current]));
        }

        let results: RangeResult[] = [];
        try {
          results = await Promise.all(requests);
          attempts = 0;
        } catch (err) {
          if (DownloadManager.errorCodeFor(err as Error) === ERROR_HTTP_FORBIDDEN) {
            // DownloadRunnable: "for youtube streams. The url has expired, recover" - a 403 is not
            // retried with the same url, which can only be refused again; the url is renewed.
            await this.doRecover(mission, recovered);
            return;
          }
          attempts++;
          if (attempts > mission.maxRetry) {
            this.notifyError(mission, DownloadManager.errorCodeFor(err as Error), err as Error);
            return;
          }
          continue;
        }

        const whole: RangeResult | undefined =
          results.find((result: RangeResult): boolean => result.whole);
        if (whole !== undefined) {
          // DownloadRunnableFallback: the whole resource arrived in one response.
          mission.done = whole.written;
          mission.length = whole.written;
          mission.unknownLength = false;
          this.writeMission(mission);
          this.emit(MissionEventKind.PROGRESS, mission);
          break;
        }
        // Only the unbroken run of complete ranges counts; a short one ends the run there.
        let written: number = 0;
        for (let lane: number = 0; lane < results.length; lane++) {
          written = written + Math.max(0, results[lane].written);
          if (results[lane].written < sizes[lane]) {
            break;
          }
        }
        if (written <= 0) {
          break; // the server has nothing more to give: the resource is complete
        }
        mission.done = mission.done + written;
        if (mission.unknownLength) {
          mission.length = mission.done;
        }
        this.writeMission(mission);
        this.emit(MissionEventKind.PROGRESS, mission);
      }

      if (!mission.running) {
        return; // paused mid-transfer; `done` is already persisted
      }

      // port of notifyFinished(): move to the next sub-mission, or finish
      mission.current = mission.current + 1;
      if (mission.current < mission.urls.length) {
        mission.offsets[mission.current] =
          mission.offsets[mission.current - 1] + mission.length;
        mission.done = 0;
        mission.initialized = false;
        mission.running = false;
        this.writeMission(mission);
        await this.runMission(mission);
        return;
      }
      await this.completeMission(mission);
    } catch (err) {
      this.notifyError(mission, DownloadManager.errorCodeFor(err as Error), err as Error);
    }
  }

  /**
   * Port of DownloadMission.doRecover(ERROR_HTTP_FORBIDDEN) + DownloadMissionRecover: re-extract
   * the page the mission came from, find the same stream (MissionRecoveryInfo) and carry on with
   * its fresh url. The port had no such path, so a YouTube url that had outlived its `expire=` -
   * any mission resumed hours later, or retried after a 403 - failed with HTTP 403 for good.
   * A mission without recovery info (made before it was recorded) fails as the source's does.
   */
  private async doRecover(mission: DownloadMission, alreadyRecovered: boolean): Promise<void> {
    const recovery: MissionRecoveryInfo | undefined = mission.recoveryInfo[mission.current];
    if (alreadyRecovered || recovery === undefined) {
      this.notifyError(mission, ERROR_HTTP_FORBIDDEN, null);
      return;
    }
    hilog.info(0x0000, TAG, 'recover: renewing url %{public}d of %{public}s',
      mission.current, mission.source);
    let info: StreamInfo | null = null;
    let failure: Error | null = null;
    for (let attempt: number = 0; attempt < Math.max(1, mission.maxRetry) && info === null;
      attempt++) {
      try {
        info = await ExtractorHelper.getStreamInfo(
          NewPipe.getServiceByUrl(mission.source).getServiceId(), mission.source, true);
      } catch (err) {
        failure = err as Error;
      }
    }
    if (!mission.running) {
      return; // paused while the page was re-extracted
    }
    if (info === null) {
      this.notifyError(mission, ERROR_HTTP_FORBIDDEN, failure);
      return;
    }
    const url: string | null = DownloadManager.resolveStream(info, recovery);
    if (url === null) {
      this.notifyError(mission, ERROR_RESOURCE_GONE, null);
      return;
    }
    mission.urls[mission.current] = url;
    // DownloadMissionRecover.resolve(): progress is kept unless the resource changed length.
    const size: number = await this.probeSize(url);
    if (size < 0 || size !== mission.length) {
      mission.done = 0;
      mission.initialized = false;
    }
    hilog.info(0x0000, TAG, 'recover: renewed, %{public}s', DownloadManager.describeUrl(url));
    mission.running = false;
    this.writeMission(mission);
    await this.runMission(mission, true);
  }

  /** DownloadMissionRecover.resolveStream(): the recorded stream in a fresh extraction. */
  private static resolveStream(info: StreamInfo, recovery: MissionRecoveryInfo): string | null {
    const candidates: Stream[] = [];
    if (recovery.kind === 'a') {
      for (const audio of info.getAudioStreams()) {
        if (audio.getAverageBitrate() === recovery.desiredBitrate) {
          candidates.push(audio);
        }
      }
    } else if (recovery.kind === 'v') {
      for (const video of recovery.desired2 ? info.videoOnlyStreams : info.getVideoStreams()) {
        if (video.getResolution() === recovery.desired) {
          candidates.push(video);
        }
      }
    } else if (recovery.kind === 's') {
      for (const subtitles of info.subtitles) {
        if (subtitles.getLanguageTag() === recovery.desired
          && subtitles.isAutoGenerated() === recovery.desired2) {
          candidates.push(subtitles);
        }
      }
    }
    for (const stream of candidates) {
      if (stream.getFormatId() === recovery.formatId
        && stream.getDeliveryMethod() === DeliveryMethod.PROGRESSIVE_HTTP) {
        return stream.getContent();
      }
    }
    return null;
  }

  /**
   * A refused transfer, logged so one device run tells an expired url from a refused client:
   * the host, the InnerTube client (`c=`), the itag, the seconds left before `expire=`, and the
   * request headers (no cookie is ever sent). The url itself is not logged.
   */
  private static logRefusal(method: string, code: number, url: string,
    header: Record<string, string>): void {
    hilog.warn(0x0000, TAG, '%{public}s answered HTTP %{public}d: %{public}s headers=%{public}s',
      method, code, DownloadManager.describeUrl(url), JSON.stringify(header));
  }

  private static describeUrl(url: string): string {
    const host: string = url.replace(/^[a-z]+:\/\//i, '').split('/')[0];
    const client: RegExpMatchArray | null = url.match(/[?&]c=([^&]*)/);
    const itag: RegExpMatchArray | null = url.match(/[?&]itag=([^&]*)/);
    const expire: RegExpMatchArray | null = url.match(/[?&]expire=(\d+)/);
    const left: string = expire === null ? '-'
      : `${parseInt(expire[1], 10) - Math.floor(Date.now() / 1000)}s`;
    return `host=${host} c=${client === null ? '-' : client[1]} `
      + `itag=${itag === null ? '-' : itag[1]} expiresIn=${left}`;
  }

  /** notifyFinished()'s tail: the muxing step when the mission has one, else finished. */
  private async completeMission(mission: DownloadMission): Promise<void> {
    if (mission.hasPsAlgorithm && mission.psState !== 2) {
      mission.running = false;
      await this.doPostprocessing(mission);
      return;
    }
    this.finishMission(mission);
  }

  /**
   * Port of DownloadMission.doPostprocessing(): run the algorithm on the downloaded parts. A
   * write that ran out of room HOLDs (Retry / Cancel); any other failure fails the mission.
   */
  private async doPostprocessing(mission: DownloadMission): Promise<void> {
    const postprocessor: Postprocessor | null = this.postprocessor;
    const target: StoredFile | null = mission.storage;
    if (postprocessor === null || target === null) {
      this.notifyError(mission, ERROR_POSTPROCESSING, null);
      return;
    }
    mission.errCode = ERROR_NOTHING;
    mission.errObject = null;
    mission.running = true;
    if (mission.psState === 0) {
      // Postprocessing.run(): length is what is being read (every part, the first time only -
      // a retried step already holds it), done how far the reading got.
      const last: number = mission.offsets.length - 1;
      mission.length = Math.max(mission.offsets[last] + mission.length - mission.offsets[0],
        mission.nearLength);
    }
    mission.psState = 1;
    mission.done = 0;
    this.writeMission(mission);
    this.emit(MissionEventKind.RUNNING, mission);

    const job: PostprocessingJob = new PostprocessingJob(mission.psName, mission.psArgs,
      target.getUri(), mission.offsets.slice(),
      `${this.requireFiles().cacheDir()}/${mission.timestamp}_ps.tmp`, mission.psStreamInfo);
    let outcome: string = '';
    try {
      outcome = await postprocessor(job, (done: number): void => {
        if (done > mission.done) {
          mission.done = done;
          this.emit(MissionEventKind.PROGRESS, mission);
        }
      });
    } catch (err) {
      outcome = 'fail:' + (err as Error).message;
    }
    hilog.info(0x0000, TAG, 'post-processing %{public}s: %{public}s', mission.psName, outcome);

    if (outcome.startsWith(RESULT_OK)) {
      const finalLength: number = Number(outcome.substring(RESULT_OK.length));
      if (finalLength >= 0) {
        mission.length = finalLength;
      }
      mission.done = mission.length;
      mission.psState = 2;
      this.finishMission(mission);
      return;
    }
    const why: Error = new Error(outcome.substring(outcome.indexOf(':') + 1));
    if (outcome.startsWith(RESULT_HOLD)) {
      mission.psState = 3;
      this.notifyError(mission, ERROR_POSTPROCESSING_HOLD, why);
      return;
    }
    mission.psState = 0;
    this.notifyError(mission, ERROR_POSTPROCESSING, why);
  }

  /** Port of the tail of notifyFinished(): the mission is fully finished. */
  private finishMission(mission: DownloadMission): void {
    hilog.info(0x0000, TAG, 'mission finished: %{public}d bytes', mission.done);
    mission.unknownLength = false;
    mission.enqueued = false;
    mission.running = false;
    this.deleteMissionFile(mission);
    this.setFinished(mission);
    this.emit(MissionEventKind.FINISHED, mission);
    this.notifyDownloadFinished(mission);
    // DownloadManagerService's mission listener calls runMissions() on FINISHED and on ERROR, and
    // this port called it from nowhere at all: with the queue limit on (the default) the FIRST
    // download ran and every later one sat at "(queued)" for ever. Measured on the handset: six
    // pending missions, none running, their percentages frozen where the app last had a turn.
    this.pumpQueue();
  }

  /**
   * runMissions() after anything that frees the single running slot.
   *
   * Fire-and-forget on purpose: the callers are synchronous event paths - a finished transfer, a
   * failure, a pause - and none of them can wait on the next mission's HEAD request.
   */
  private pumpQueue(): void {
    this.runMissions().catch((err: Error): void => {
      hilog.warn(0x0000, TAG, 'runMissions: %{public}s', err.message);
    });
  }

  /**
   * notifyFinishedDownload(name): ONE finished row for every download since the Downloads screen
   * was last opened. One file reads "Download finished" over its name; more read "N downloads
   * finished" over the list of names. Tapping it opens the Downloads screen, which clears it.
   */
  private notifyDownloadFinished(mission: DownloadMission): void {
    const notifications: Notifications | null = this.notifications;
    if (notifications === null || !this.downloadNotificationEnable) {
      return;
    }
    this.downloadDoneNames.push(DownloadManager.missionName(mission));
    notifications.publishDownloadsFinished(DOWNLOAD_DONE_NOTIFICATION_ID,
      Localization.downloadCount(this.downloadDoneNames.length), this.downloadDoneNames.join('\n'))
      .catch((err: Error): void => {
        hilog.warn(0x0000, TAG, 'finished notification: %{public}s', err.message);
      });
  }

  /**
   * notifyFailedDownload(mission): "Download failed" over the file name, a row of its own per
   * failure. It used to be the other way round and reused the finished row's id, so a failure
   * replaced the list of finished downloads.
   */
  private notifyFailedDownload(mission: DownloadMission): void {
    const notifications: Notifications | null = this.notifications;
    if (notifications === null || !this.downloadNotificationEnable
      || this.failedDownloads.has(mission)) {
      return;
    }
    this.failedDownloads.add(mission);
    const id: number = this.downloadFailedNotificationId++;
    notifications.publishDownloadProgress(id, Localization.getString('download_failed'),
      DownloadManager.missionName(mission), false)
      .catch((err: Error): void => {
        hilog.warn(0x0000, TAG, 'failed notification: %{public}s', err.message);
      });
  }

  /** The file the mission writes, which is what the shade should name it by. */
  private static missionName(mission: DownloadMission): string {
    const file: StoredFile | null = mission.storage;
    return file === null ? '' : file.getName();
  }

  /** Port of notifyError(Exception)'s exception-to-code mapping. */
  private static errorCodeFor(err: Error): number {
    const message: string = err.message;
    if (message.includes('HTTP 403')) {
      return ERROR_HTTP_FORBIDDEN;
    }
    if (message.includes('SSL')) {
      return ERROR_SSL_EXCEPTION;
    }
    // @ohos.net.http 2300006 reads "Couldn't resolve host name" / "Failed to resolve the host
    // name": it is the UnknownHostException arm, and reading it as ERROR_UNKNOWN_EXCEPTION
    // dequeued an offline mission instead of leaving it to resume when the network returns.
    if (message.includes('Unknown host') || message.includes('ENOENT host')
      || /resolve.*host/.test(message)) {
      return ERROR_UNKNOWN_HOST;
    }
    if (message.includes('timeout') || message.includes('Timeout')) {
      return ERROR_TIMEOUT;
    }
    if (message.includes('ENOSPC')) {
      return ERROR_INSUFFICIENT_STORAGE;
    }
    if (message.includes('connect') || message.includes('Connect')) {
      return ERROR_CONNECT_HOST;
    }
    const status: RegExpMatchArray | null = message.match(/HTTP (\d{3})/);
    if (status !== null) {
      return parseInt(status[1], 10);
    }
    return ERROR_UNKNOWN_EXCEPTION;
  }
}
