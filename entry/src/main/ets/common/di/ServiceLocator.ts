/*
 * PORT of io.insert-koin:koin-compose-navigation3 / koin-compose-viewmodel / koin-annotations
 * 4.2.2, Rule 11. `port_io_insert_koin_...`
 *
 * A PLAIN TYPED SERVICE REGISTRY, not a DI container - which is what the plan's own port entry
 * asks for ("Ports to a hand-written typed ArkTS service registry, not a stub"), and what the
 * source actually needs. Koin's machinery is Kotlin reflection plus KSP-generated code
 * (`@Module`, `@ComponentScan`, `@Singleton`, `@Provided`): scope graphs, lazy resolution by
 * type, constructor injection discovered at compile time. ArkTS has no reflection and no
 * annotation processor, so none of that has an analogue - and nothing in this app needs it. What
 * NewPipe's four koin modules actually declare is a handful of singletons:
 *   - navModule()          -> a Navigator over a backstack: ArkUI's own NavPathStack (Phase 3).
 *   - SettingsModule       -> the key/value store: AppPreferences below.
 *   - SerializationModule  -> a configured kotlinx Json: ArkTS JSON.parse/stringify.
 *   - PlatformModule       -> the platform-specific implementations: the services below.
 * So the port is this file: one instance of each service, constructed once, handed out by name.
 *
 * WIRING ORDER MATTERS and is the reason this exists as one function rather than as a lazy
 * `get<T>()`: every service takes what it needs through `init`, so nothing reaches for a global
 * and there is no import cycle between a service and this registry.
 *
 * The three EXTENSION POINTS at the bottom are the seams to the other waves. The extractor and
 * the player are generated elsewhere; rather than import modules whose paths this file would
 * have to guess, EntryAbility passes them in once at startup.
 */

import { common } from '@kit.AbilityKit';
import { AppPreferences } from '../prefs/Preferences';
import { FileAccess, StoredDirectory, TAG_AUDIO, TAG_VIDEO } from '../file/FileAccess';
import { FilePicker } from '../file/FilePicker';
import { ExtractorHelper } from '../extractor/ExtractorHelper';
import { DownloadManager, Postprocessor } from '../download/DownloadManager';
import { BackupRestore } from '../settings/BackupRestore';
import { Notifications } from '../notify/Notifications';
import { BackgroundWork } from '../background/BackgroundWork';
import { ShareUtils } from '../share/ShareUtils';
import { ErrorReporter, ErrorPageOpener } from '../error/ErrorReporter';
import { UpdateCheck } from '../update/UpdateCheck';
import { DeepLinkRouter, LinkResolver, QueueSizeProvider } from '../router/DeepLinkRouter';
import { PermissionHelper } from '../perm/PermissionHelper';
import { Localization } from '../i18n/Localization';
import { download_path_audio_key, download_path_video_key } from '../prefs/SettingsKeys';
import { readPreferredImageQuality, setPreferredImageQuality } from '../image/ImageLoader';
import { setStreamInfoLoader, StreamInfoLoader } from '../../model/app/PlayQueueItem';
import { DefaultKioskIdProvider, setDefaultKioskIdProvider } from '../../model/app/Tab';

/** What EntryAbility must supply that this registry cannot build itself. */
export interface ServiceLocatorConfig {
  context: common.UIAbilityContext;
  bundleName: string;
  abilityName: string;
  /** This build's version code, for svc_update_check. */
  versionCode: number;
  /** Path of the live database file, for svc_settings_backup. */
  databasePath: string;
  /** Whether this is a debug build; the source's MainActivity.DEBUG. */
  debug: boolean;
  /** Opens the error page; EntryAbility owns the router. */
  openErrorPage: ErrorPageOpener;
  /** The download muxers' taskpool runner (an .ets module, so EntryAbility supplies it). */
  postprocessor?: Postprocessor;
}

export class ServiceLocator {
  private static instance: ServiceLocator | null = null;

  readonly preferences: AppPreferences = new AppPreferences();
  readonly fileAccess: FileAccess = new FileAccess();
  readonly filePicker: FilePicker = new FilePicker();
  readonly downloadManager: DownloadManager = new DownloadManager();
  readonly backupRestore: BackupRestore = new BackupRestore();
  readonly notifications: Notifications = new Notifications();
  readonly backgroundWork: BackgroundWork = new BackgroundWork();
  readonly share: ShareUtils = new ShareUtils();
  readonly errorReporter: ErrorReporter = new ErrorReporter();
  readonly updateCheck: UpdateCheck = new UpdateCheck();
  readonly deepLinkRouter: DeepLinkRouter = new DeepLinkRouter();
  readonly permissions: PermissionHelper = new PermissionHelper();

  private appContext: common.UIAbilityContext | null = null;

  private constructor() {
  }

  /**
   * Builds and wires every service, once. Called from EntryAbility.onWindowStageCreate, before
   * the first page loads.
   */
  static async init(config: ServiceLocatorConfig): Promise<ServiceLocator> {
    const existing: ServiceLocator | null = ServiceLocator.instance;
    if (existing !== null) {
      return existing;
    }

    const locator: ServiceLocator = new ServiceLocator();
    locator.appContext = config.context;

    // 1. the preference store: everything else reads it
    locator.preferences.init(config.context);

    // 2. localization: needs the context (resources) and the preferences (app language)
    Localization.init(config.context, locator.preferences, config.debug);
    Localization.migrateAppLanguageSettingIfNecessary();

    // 3. the image strategy's quality, from the user's preference
    setPreferredImageQuality(readPreferredImageQuality(locator.preferences));

    // 4. file access and the picker
    locator.fileAccess.init(config.context);
    ExtractorHelper.cacheDir = locator.fileAccess.cacheDir();
    locator.filePicker.init(config.context);

    // 5. notifications, then the error reporter that escalates to them
    locator.notifications.init(config.bundleName, config.abilityName, locator.preferences);
    locator.errorReporter.init(locator.notifications, config.openErrorPage);

    // 6. background work, and the download manager that runs inside it
    locator.backgroundWork.init(config.context, config.bundleName, config.abilityName);
    // DownloadManagerService hands the manager the two save directories the user picked
    // (download_path / download_path_audio); the port passed null for both, so getMainStorage()
    // always answered null and tryRecover() had nowhere to recreate a lost file into. The
    // preference store is already initialised above, so read them here, where the source does.
    const videoPath: string = await AppPreferences.getString(download_path_video_key, '');
    const audioPath: string = await AppPreferences.getString(download_path_audio_key, '');
    // Set before init(): init() resumes the queue, which may go straight to a muxing step.
    const postprocessor: Postprocessor | undefined = config.postprocessor;
    locator.downloadManager.postprocessor = postprocessor === undefined ? null : postprocessor;
    await locator.downloadManager.init(locator.fileAccess, locator.preferences,
      videoPath.length === 0 ? null : new StoredDirectory(videoPath, TAG_VIDEO),
      audioPath.length === 0 ? null : new StoredDirectory(audioPath, TAG_AUDIO),
      locator.notifications, locator.backgroundWork);

    // 7. the rest
    locator.backupRestore.init(locator.preferences, locator.fileAccess, config.databasePath);
    locator.share.init(config.context);
    locator.updateCheck.init(locator.preferences, config.versionCode);
    locator.permissions.init(config.context);

    ServiceLocator.instance = locator;
    return locator;
  }

  /** The registry, once init() has run. */
  static get(): ServiceLocator {
    const locator: ServiceLocator | null = ServiceLocator.instance;
    if (locator === null) {
      throw new Error('ServiceLocator.get() before ServiceLocator.init()');
    }
    return locator;
  }

  static isInitialized(): boolean {
    return ServiceLocator.instance !== null;
  }

  getContext(): common.UIAbilityContext {
    const context: common.UIAbilityContext | null = this.appContext;
    if (context === null) {
      throw new Error('ServiceLocator used before init()');
    }
    return context;
  }

  /* //////////////////////////////////////////////////////////////////////////
  // Extension points - the seams to the extractor and player waves
  ////////////////////////////////////////////////////////////////////////// */

  /**
   * Supplies the extractor's ExtractorHelper.getStreamInfo to PlayQueueItem.getStream(), and the
   * service/link-type lookup plus the current queue size to the deep-link router.
   */
  wireExtractor(streamInfoLoader: StreamInfoLoader, linkResolver: LinkResolver,
    queueSize: QueueSizeProvider, defaultKioskId: DefaultKioskIdProvider): void {
    setStreamInfoLoader(streamInfoLoader);
    setDefaultKioskIdProvider(defaultKioskId);
    this.deepLinkRouter.init(this.preferences, linkResolver, queueSize);
  }

  /**
   * Releases what holds a native handle or an OS registration (Rule 8). Called from
   * EntryAbility.onDestroy.
   */
  async release(): Promise<void> {
    await this.errorReporter.release();
    await this.backgroundWork.releaseAll();
  }
}
