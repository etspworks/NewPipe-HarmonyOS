import { AbilityConstant, bundleManager, common, ConfigurationConstant, UIAbility, Want }
  from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';
import { systemShare } from '@kit.ShareKit';
import { runPostprocessingInTaskpool } from '../common/download/postprocessing/PostprocessingTask';
import { NotificationWorker } from '../common/notify/NotificationWorker';
import { applyBlackTheme, isBlackThemeActive } from '../common/theme/ThemeBackground';
import { Configuration } from '@kit.AbilityKit';
import { ServiceLocator, ServiceLocatorConfig } from '../common/di/ServiceLocator';
import { PlayerService } from '../common/player/PlayerService';
import { MediaSessionService } from '../common/player/MediaSessionService';
import { ERROR_INFO_PARAM } from '../common/error/ErrorReporter';
import { ErrorInfoJson } from '../model/app/ErrorInfo';
import { AppDatabase } from '../common/db/AppDatabase';
import { Localization } from '../common/i18n/Localization';
import { NewPipe } from '../common/extractor/core/NewPipe';
import { Localization as ExtractorLocalization } from '../common/extractor/downloader/Localization';
import { ContentCountry } from '../common/extractor/localization/ContentCountry';
import { DownloaderImpl } from '../common/net/Downloader';
// Importing ServiceRegistry is what registers the 5 StreamingServices with NewPipe (see the
// deviation note at the top of ServiceRegistry.ts); `all()` is ServiceList.all().
import { all } from '../common/extractor/ServiceRegistry';
import { setDefaultKioskIdProvider } from '../model/app/Tab';
import { AppPreferences } from '../common/prefs/Preferences';
import {
  auto_device_theme_key,
  black_theme_key,
  current_service_key,
  dark_theme_key,
  default_service_value,
  light_theme_key,
  theme_key,
  youtube_restricted_mode_enabled
} from '../common/prefs/SettingsKeys';
import { ReCaptchaCookieStore } from '../common/net/ReCaptchaCookieStore';
import { PeertubeInstances } from '../common/extractor/PeertubeInstances';
import {
  LinkType as ServiceLinkType,
  MediaCapability as ServiceMediaCapability,
  StreamingService
} from '../common/extractor/core/StreamingService';
import { ExtractorHelper } from '../common/extractor/ExtractorHelper';
import { StreamInfo } from '../model/extractor/StreamInfo';
import { LinkType, MediaCapability, ResolvedLink } from '../common/router/DeepLinkRouter';
import { PlayQueue, currentPlayQueue } from '../model/app/PlayQueue';

const DOMAIN = 0x0000;

/** Cold-start page when no deep-link target is given (the app's journey root). */
const ROOT_PAGE: string = 'pages/MainActivityPage';
/** RouterActivity: where a link another app opened, or text it shared, is resolved. */
const ROUTER_PAGE: string = 'pages/RouterActivityPage';
const SEND_DATA_ACTION: string = 'ohos.want.action.sendData';
/** PanicResponderActivity.PANIC_TRIGGER_ACTION. */
const PANIC_TRIGGER_ACTION: string = 'info.guardianproject.panic.action.TRIGGER';

/** RouterActivity's VIEW filters: the link another app opened, '' when the want carries none. */
function linkOf(want: Want): string {
  const uri: string | undefined = want.uri;
  if (uri === undefined || uri === null || uri.length === 0) {
    return '';
  }
  return /^(https?|vnd\.youtube(\.launch)?):/i.test(uri) ? uri : '';
}

/**
 * Resolve `want.parameters.targetPage` into a registered page url.
 * The replay launches with `aa start ... --ps targetPage <RouteName>`, where RouteName is
 * the source screen name ('MainActivity'), while main_pages.json registers the generated
 * page file ('pages/MainActivityPage'). Both spellings, and a full url, resolve here.
 */
function resolveTargetPage(want: Want): string {
  const params: Record<string, Object> | undefined = want.parameters;
  if (params === undefined || params === null) {
    return '';
  }
  const raw: Object | undefined = params['targetPage'];
  if (raw === undefined || raw === null) {
    return '';
  }
  let name: string = raw.toString().trim();
  if (name.length === 0) {
    return '';
  }
  if (name.startsWith('pages/')) {
    name = name.substring(6);
  }
  if (name.endsWith('.ets')) {
    name = name.substring(0, name.length - 4);
  }
  if (!name.endsWith('Page')) {
    name = name + 'Page';
  }
  return 'pages/' + name;
}

/**
 * Every other `want.parameter` the launch carried, as the page's router params.
 * The replay cold-starts an argument-driven state with the arguments the CAPTURE used
 * (`aa start ... --ps targetPage ChannelFragment --ps url <channel> --ps name <channel>`);
 * without them the page reads an empty route and renders nothing. Only plain string
 * parameters are forwarded — the framework's own `ohos.aafwk.*` / `component.*` keys carry
 * a dot, and `moduleName` is the launcher's own (`aa start -m entry`); neither is a route
 * argument, and dropping them is what keeps a launch WITHOUT arguments on its old path.
 */
function resolveRouteParams(want: Want): Record<string, string> {
  const out: Record<string, string> = {};
  const params: Record<string, Object> | undefined = want.parameters;
  if (params === undefined || params === null) {
    return out;
  }
  const keys: string[] = Object.keys(params);
  for (const key of keys) {
    if (key === 'targetPage' || key === 'moduleName' || key.includes('.')) {
      continue;
    }
    const value: Object = params[key];
    if (value !== undefined && value !== null && typeof value === 'string'
      && value.toString().length > 0) {
      out[key] = value.toString();
    }
  }
  return out;
}

export default class EntryAbility extends UIAbility {
  private pendingPage: string = '';
  /** The launch's route arguments, handed to the page once its content is loaded. */
  private pendingParams: Record<string, string> = {};
  private stage: window.WindowStage | null = null;
  /** Settles when the services are wired; no page content is loaded before it does. */
  private ready: Promise<void> = Promise.resolve();
  /** Settles once a shared text (SEND) has been read out of the launching want. */
  private shared: Promise<void> = Promise.resolve();
  /** The launch was a panic trigger: nothing is shown, the ability goes. */
  private panicked: boolean = false;

  /**
   * The colour mode is NOT set here. The DevEco template's
   * setColorMode(COLOR_MODE_NOT_SET) used to run on this line, and setColorMode persists, so every
   * cold start silently threw away whatever Settings > Appearance had chosen and put the app back
   * on "follow the device". The stored theme is applied in applyStoredColorMode() instead, which
   * runs as soon as the preference store is open.
   */
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    if (want.action === PANIC_TRIGGER_ACTION) {
      this.respondToPanic();
      return;
    }
    this.pendingPage = resolveTargetPage(want);
    this.pendingParams = resolveRouteParams(want);
    if (this.pendingPage.length === 0) {
      // RouterActivity's VIEW / SEND filters: a link opened or shared from another app.
      const link: string = linkOf(want);
      if (link.length > 0) {
        this.pendingPage = ROUTER_PAGE;
        this.pendingParams = { 'uri': link };
      } else if (want.action === SEND_DATA_ACTION) {
        this.pendingPage = ROUTER_PAGE;
        this.shared = this.readSharedText(want).then((text: string): void => {
          this.pendingParams = { 'sharedText': text };
        });
      }
    }
    hilog.info(DOMAIN, 'testTag', 'Ability onCreate targetPage=%{public}s params=%{public}s',
      this.pendingPage, JSON.stringify(this.pendingParams));
  }

  onNewWant(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    if (want.action === PANIC_TRIGGER_ACTION) {
      this.respondToPanic();
      return;
    }
    const url: string = resolveTargetPage(want);
    const routeParams: Record<string, string> = resolveRouteParams(want);
    hilog.info(DOMAIN, 'testTag', 'Ability onNewWant targetPage=%{public}s params=%{public}s',
      url, JSON.stringify(routeParams));
    if (url.length === 0) {
      // A link or a share while the app is open: the router goes on top of what is showing.
      const link: string = linkOf(want);
      if (link.length > 0) {
        this.openRouter({ 'uri': link });
      } else if (want.action === SEND_DATA_ACTION) {
        this.readSharedText(want).then((text: string): void => {
          this.openRouter({ 'sharedText': text });
        });
      }
      return;
    }
    this.pendingPage = url;
    this.pendingParams = routeParams;
    this.loadPage(url);
  }

  async onDestroy(): Promise<void> {
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onDestroy');
    // PlayerService.onTaskRemoved(): swiping the app away from the recents list stops the MAIN
    // player; the popup and the background player are left alone (FL-046). HarmonyOS has no
    // onTaskRemoved - removing the mission from recents destroys this UIAbility, so this is that
    // moment. Awaited: the async lifecycle holds the exit until the player is released.
    const player: PlayerService = PlayerService.getInstance();
    if (player.isMainVideoPlayer()) {
      await player.release();
      await MediaSessionService.getInstance().stop();
    }
    if (ServiceLocator.isInitialized()) {
      ServiceLocator.get().release().catch((err: BusinessError) => {
        hilog.error(DOMAIN, 'testTag', 'ServiceLocator.release failed: %{public}s', err.message);
      });
    }
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    this.stage = windowStage;
    if (this.panicked) {
      return;
    }
    const shared: Promise<void> = this.shared;
    this.ready = this.initServices().then((): Promise<void> => shared).catch((err: BusinessError) => {
      // Never swallowed: startup continues so the failure is visible on the device, and this
      // line names the reason it half-wired instead of leaving a silent screen of empty data.
      hilog.error(DOMAIN, 'testTag', 'ServiceLocator.init failed: %{public}s | %{public}s',
        err.message, err.stack !== undefined ? err.stack : '');
    });
    this.loadPage(this.pendingPage.length > 0 ? this.pendingPage : ROOT_PAGE);
  }

  /**
   * The source's App.onCreate: ServiceLocator.init() wires preferences -> Localization -> the
   * rest, then NewPipe.init() gives the extractor its downloader and the user's content
   * language/country. Every page reads those in aboutToAppear, so this must finish first.
   */
  private async initServices(): Promise<void> {
    const context: common.UIAbilityContext = this.context;
    const config: ServiceLocatorConfig = {
      context: context,
      bundleName: context.abilityInfo.bundleName,
      abilityName: context.abilityInfo.name,
      versionCode: bundleManager
        .getBundleInfoForSelfSync(bundleManager.BundleFlag.GET_BUNDLE_INFO_DEFAULT).versionCode,
      // ponytail: relationalStore keeps its files at <databaseDir>/rdb/<name>. Only the settings
      // backup reads this, and it access-checks the path first; revisit if a backup ships no db.
      databasePath: `${context.databaseDir}/rdb/${AppDatabase.DATABASE_NAME}`,
      debug: context.applicationInfo.debug,
      openErrorPage: (info: ErrorInfoJson) => this.openErrorPage(info),
      postprocessor: runPostprocessingInTaskpool
    };
    await ServiceLocator.init(config);
    this.applyStoredColorMode();

    const localization: ExtractorLocalization | null =
      ExtractorLocalization.fromLocalizationCode(Localization.getPreferredLocalization());
    const country: string = Localization.getPreferredContentCountry();
    NewPipe.init(DownloaderImpl.getInstance(),
      localization !== null ? localization : ExtractorLocalization.DEFAULT,
      country.length > 0 ? new ContentCountry(country) : null);
    // App.setCookiesToDownloader(): a solved reCaptcha and YouTube's Restricted Mode both live in
    // cookies, and both were written by their settings but never handed back after a restart.
    ReCaptchaCookieStore.getInstance().restoreToDownloader();
    DownloaderImpl.getInstance().updateYoutubeRestrictedModeCookies(
      AppPreferences.instance().getBooleanSync(youtube_restricted_mode_enabled, false));
    // ServiceHelper.initServices(): the PeerTube instance the user selected, not the default one.
    PeertubeInstances.initFromPreferences();
    // MainActivity.onCreate(): NotificationWorker.initialize(this) - the periodic new-streams
    // check is scheduled while the app and the device both allow its notifications.
    ServiceLocator.get().notifications.areNotificationsEnabledOnDevice()
      .then((deviceAllows: boolean): Promise<void> => NotificationWorker.initialize(
        context.abilityInfo.bundleName, AppPreferences.instance(), deviceAllows))
      .catch((err: BusinessError) => {
        hilog.error(DOMAIN, 'testTag', 'NotificationWorker.initialize: %{public}s', err.message);
      });
    // Tab.DefaultKioskTab.getDefaultKioskId(context): ServiceHelper.getSelectedServiceId(ctx),
    // then NewPipe.getService(id).getKioskList().getDefaultKioskId(). Tab.ts is the model
    // layer and does not import the extractor, so the lookup is injected here - and until it
    // WAS, currentDefaultKioskId() returned '' for the life of the app and DefaultKioskTab's
    // row fell through tabIconResource()'s ic_whatshot fallback. The pinned extractor sets
    // YouTube's default kiosk to YoutubeLiveLinkHandlerFactory.KIOSK_ID ('live'), whose glyph
    // is ic_live_tv - which is what the Android capture renders and the device did not.
    // Registered AFTER NewPipe.init so the services are resolvable when the tab first draws.
    // ServiceLocator.wireExtractor() hands the extractor's three lookups to the layers that may
    // not import it: PlayQueueItem's stream loader, DeepLinkRouter's service/link-type resolver,
    // and Tab's default-kiosk id. **It was declared and never called**, which left
    // DeepLinkRouter.resolver null - and resolve() returns an empty decision when it is, so
    // RouterActivityPage answered "Unsupported URL" for EVERY url, whatever it was. That is
    // TC-LIBRARY-185: Show info on a download whose source is a perfectly good page url.
    ServiceLocator.get().wireExtractor(
      // ExtractorHelper.getStreamInfo(serviceId, url, forceLoad) - the signature StreamInfoLoader
      // is written against.
      (serviceId: number, url: string, forceLoad: boolean): Promise<StreamInfo> =>
        ExtractorHelper.getStreamInfo(serviceId, url, forceLoad),

      // RouterActivity's own lookup: the service that claims the url, then its link type.
      // getServiceByUrl THROWS when no service claims it, which is the NONE case, so the catch
      // is the "unsupported" answer rather than an error.
      async (url: string): Promise<ResolvedLink | null> => {
        let service: StreamingService;
        try {
          service = NewPipe.getServiceByUrl(url);
        } catch (err) {
          // getServiceByUrl THROWS when no service claims the url; that is the NONE case, not an
          // error, and the router turns a null link into its unsupported-url dialog.
          return null;
        }
        const serviceLinkType: ServiceLinkType = service.getLinkTypeByUrl(url);
        const linkType: LinkType = EntryAbility.toRouterLinkType(serviceLinkType);
        if (linkType === LinkType.NONE) {
          return null;
        }
        return new ResolvedLink(service.getServiceId(), linkType, url,
          EntryAbility.toRouterCapabilities(service.getServiceInfo().getMediaCapabilities()));
      },

      // PlayerHolder.getQueueSize(): the live queue's size while a player is open, else 0. The
      // "Enqueue" choice is gated on `sizeProvider() > 0`; a queue left behind by a released
      // player does not count, as PlayerHolder reads it through the bound service.
      (): number => {
        const queue: PlayQueue | null = currentPlayQueue.getValue();
        return queue !== null && PlayerService.getInstance().hasPlayer() ? queue.size() : 0;
      },

      () => this.defaultKioskId());
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Extractor lookups wired');
    hilog.info(DOMAIN, 'testTag', 'Services wired, %{public}d streaming services registered',
      all().length);
  }

  /**
   * The router declares its OWN LinkType ("Port of StreamingService.LinkType") rather than
   * importing the extractor's, so the two are distinct types even though their members line up.
   * Mapping them by hand is what keeps that separation honest - and what stops a silent break if
   * either list ever grows.
   */
  private static toRouterLinkType(type: ServiceLinkType): LinkType {
    if (type === ServiceLinkType.STREAM) {
      return LinkType.STREAM;
    }
    if (type === ServiceLinkType.CHANNEL) {
      return LinkType.CHANNEL;
    }
    if (type === ServiceLinkType.PLAYLIST) {
      return LinkType.PLAYLIST;
    }
    return LinkType.NONE;
  }

  /**
   * The router's MediaCapability is the two values RouterActivity reads - AUDIO and VIDEO - while
   * the extractor's also carries LIVE and COMMENTS. Anything outside the pair is dropped rather
   * than coerced.
   */
  private static toRouterCapabilities(
    capabilities: Set<ServiceMediaCapability>): MediaCapability[] {
    const mapped: MediaCapability[] = [];
    capabilities.forEach((capability: ServiceMediaCapability): void => {
      if (capability === ServiceMediaCapability.AUDIO) {
        mapped.push(MediaCapability.AUDIO);
      } else if (capability === ServiceMediaCapability.VIDEO) {
        mapped.push(MediaCapability.VIDEO);
      }
    });
    return mapped;
  }

  /**
   * Tab.DefaultKioskTab.getDefaultKioskId(context): ServiceHelper.getSelectedServiceId(ctx), then
   * NewPipe.getService(id).getKioskList().getDefaultKioskId(). Tab.ts is the model layer and does
   * not import the extractor, so the lookup is injected - and until it WAS, currentDefaultKioskId()
   * returned '' for the life of the app and DefaultKioskTab's row fell through
   * tabIconResource()'s ic_whatshot fallback. The pinned extractor sets YouTube's default kiosk to
   * YoutubeLiveLinkHandlerFactory.KIOSK_ID ('live'), whose glyph is ic_live_tv.
   *
   * Called only after NewPipe.init(), so the services are resolvable when the tab first draws.
   */
  private defaultKioskId(): string {
    const name: string = AppPreferences.instance()
      .getStringResolvedSync(current_service_key, default_service_value);
    let serviceId: number = 0;
    try {
      serviceId = NewPipe.getServiceByName(name).getServiceId();
    } catch (err) {
      serviceId = 0;            // ServiceHelper's own fallback: the first registered service
    }
    const service: StreamingService = NewPipe.getService(serviceId);
    const kioskId: string | null = service.getKioskList().getDefaultKioskId();
    return kioskId !== null ? kioskId : '';
  }

  /**
   * MainActivity's ThemeHelper.setDayNightMode(getSelectedThemeString()): the stored theme is
   * re-applied on every launch, which is what makes a theme chosen in Settings > Appearance
   * survive a cold start. Same mapping AppearanceSettingsFragmentPage.setDayNightMode uses -
   * auto_device_theme leaves the mode unset so the device decides.
   *
   * Called after ServiceLocator.init() (the preference store is not open before it) and before
   * loadPage(), which waits on the same promise.
   */
  private applyStoredColorMode(): void {
    const theme: string =
      AppPreferences.instance().getStringSync(theme_key, auto_device_theme_key);
    let mode: ConfigurationConstant.ColorMode = ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET;
    if (theme === light_theme_key) {
      mode = ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT;
    } else if (theme === dark_theme_key || theme === black_theme_key) {
      mode = ConfigurationConstant.ColorMode.COLOR_MODE_DARK;
    }
    try {
      this.context.getApplicationContext().setColorMode(mode);
    } catch (err) {
      hilog.error(DOMAIN, 'testTag', 'Failed to set colorMode. Cause: %{public}s',
        JSON.stringify(err));
    }
    this.applyBlackThemeFor(mode === ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET
      ? this.context.config.colorMode : mode);
  }

  /** The black theme's window background, for the colour mode now in force. */
  private applyBlackThemeFor(colorMode: ConfigurationConstant.ColorMode | undefined): void {
    applyBlackTheme(isBlackThemeActive(AppPreferences.instance(),
      colorMode === undefined ? ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET : colorMode));
  }

  /**
   * The device switching between light and dark: with the theme following it, the night theme
   * decides whether night is dark or black (the source recreates its activities for this).
   */
  onConfigurationUpdate(newConfig: Configuration): void {
    if (ServiceLocator.isInitialized()) {
      this.applyBlackThemeFor(newConfig.colorMode);
    }
  }

  /**
   * PanicResponderActivity -> ExitActivity.exitAndRemoveFromRecentApps(): the app closes and,
   * with removeMissionAfterTerminate, leaves the recent-apps list.
   */
  private respondToPanic(): void {
    this.panicked = true;
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'panic trigger: exiting');
    this.context.terminateSelf().catch((err: BusinessError) => {
      hilog.error(DOMAIN, 'testTag', 'terminateSelf failed: %{public}s', err.message);
    });
  }

  /**
   * RouterActivity.getUrl(intent)'s EXTRA_TEXT half: the shared records' text, one per line, for
   * DeepLinkRouter.extractUrl() to find the link in.
   */
  private async readSharedText(want: Want): Promise<string> {
    try {
      const data: systemShare.SharedData = await systemShare.getSharedData(want);
      const parts: string[] = [];
      for (const record of data.getRecords()) {
        if (record.content !== undefined && record.content.length > 0) {
          parts.push(record.content);
        } else if (record.uri !== undefined && /^https?:/i.test(record.uri)) {
          parts.push(record.uri);
        }
      }
      return parts.join('\n');
    } catch (err) {
      hilog.error(DOMAIN, 'testTag', 'getSharedData failed: %{public}s',
        (err as BusinessError).message);
      return '';
    }
  }

  /** startActivity(RouterActivity) over the running app. */
  private openRouter(params: Record<string, string>): void {
    const stage: window.WindowStage | null = this.stage;
    if (stage === null) {
      return;
    }
    this.ready.then((): Promise<void> =>
      stage.getMainWindowSync().getUIContext().getRouter().pushUrl({ url: ROUTER_PAGE, params: params })
    ).catch((err: BusinessError) => {
      hilog.error(DOMAIN, 'testTag', 'open router failed: %{public}s', err.message);
    });
  }

  /** ErrorUtil's startActivity(ErrorActivity): the ability owns the router, not a page. */
  private openErrorPage(info: ErrorInfoJson): void {
    const stage: window.WindowStage | null = this.stage;
    if (stage === null) {
      hilog.error(DOMAIN, 'testTag', '%{public}s', 'Error page requested before the window stage');
      return;
    }
    const params: Record<string, ErrorInfoJson> = {};
    params[ERROR_INFO_PARAM] = info;
    stage.getMainWindowSync().getUIContext().getRouter()
      .pushUrl({ url: 'pages/ErrorActivityPage', params: params })
      .catch((err: BusinessError) => {
        hilog.error(DOMAIN, 'testTag', 'Failed to open the error page: %{public}s', err.message);
      });
  }

  private loadPage(url: string): void {
    const stage: window.WindowStage | null = this.stage;
    if (stage === null) {
      return;
    }
    // A page reads the wired services in aboutToAppear, so content never loads before init().
    this.ready.then(() => {
      stage.loadContent(url, (err) => {
        if (err.code) {
          hilog.error(DOMAIN, 'testTag', 'Failed to load %{public}s. Cause: %{public}s', url, JSON.stringify(err));
          return;
        }
        hilog.info(DOMAIN, 'testTag', 'Loaded %{public}s', url);
        this.applyRouteParams(url, 0);
      });
    }).catch((err: BusinessError) => {
      hilog.error(DOMAIN, 'testTag', 'Failed to start %{public}s. Cause: %{public}s', url,
        err.message);
    });
  }

  /**
   * `loadContent` takes no router params, so a page deep-linked WITH arguments is re-entered
   * once through the router to hand them over — `router.getParams()` is where every page
   * already reads its arguments. `replaceUrl` swaps the argument-less instance for one that
   * has them, so the stack stays one entry deep and Back behaves exactly as it does for a
   * plain deep link. A launch carrying no extra parameters (every launch outside the replay)
   * returns immediately and loads exactly as before.
   *
   * THE ORDERING IS THE WHOLE TRICK. `loadContent`'s own page is created a tick AFTER its
   * callback runs, and the LAST page created is the one on top. Handing the params over from
   * inside that callback therefore puts the argument-less instance on top of the loaded one:
   * measured on device as an error panel with a fully rendered channel — title, subscriber
   * count, tabs — sitting one Back press underneath it. So wait for the router to actually
   * report a page before replacing it.
   */
  private applyRouteParams(url: string, attempt: number): void {
    const routeParams: Record<string, string> = this.pendingParams;
    if (Object.keys(routeParams).length === 0) {
      return;
    }
    const stage: window.WindowStage | null = this.stage;
    if (stage === null) {
      return;
    }
    let pages: number = 0;
    try {
      pages = Number(stage.getMainWindowSync().getUIContext().getRouter().getLength());
    } catch (err) {
      pages = 0;                                   // no page in the stack yet
    }
    // Always yield at least one macrotask (attempt 0 never acts): the stack can report the
    // page before it is the one on screen, and the gap measured on device was ~30 ms.
    if (attempt === 0 || pages < 1) {
      if (attempt < 40) {
        setTimeout(() => {
          this.applyRouteParams(url, attempt + 1);
        }, 50);
      } else {
        hilog.error(DOMAIN, 'testTag',
          'Router never took %{public}s — it loads without its arguments', url);
      }
      return;
    }
    // Consumed once: a later loadPage() must not re-apply this launch's arguments.
    this.pendingParams = {};
    stage.getMainWindowSync().getUIContext().getRouter()
      .replaceUrl({ url: url, params: routeParams })
      .then(() => {
        hilog.info(DOMAIN, 'testTag', 'Route params handed to %{public}s (stack was %{public}d)',
          url, pages);
      })
      .catch((err: BusinessError) => {
        hilog.error(DOMAIN, 'testTag', 'Failed to hand %{public}s its route params: %{public}s',
          url, err.message);
      });
  }

  onWindowStageDestroy(): void {
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onWindowStageDestroy');
  }

  /**
   * ErrorReporter.openActivity() shows the error page when the app is in front and falls back to
   * a notification when it is not - the port's stand-in for the source's `context.startActivity`,
   * which a HarmonyOS ability cannot do without a live window stage.
   *
   * The flag it reads, `inBackground`, is initialised TRUE and nothing ever set it back, so the
   * fallback was the only branch that ever ran: the error panel's REPORT button posted a
   * notification instead of opening the report page, and with notifications denied it produced a
   * toast reading "An error occurred, see the notification" and nothing else. These two callbacks
   * are where the answer already lives.
   */
  onForeground(): void {
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onForeground');
    EntryAbility.setErrorReporterBackground(false);
  }

  onBackground(): void {
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onBackground');
    EntryAbility.setErrorReporterBackground(true);
  }

  /** The locator is not up yet during the first onForeground, so the call is guarded. */
  private static setErrorReporterBackground(inBackground: boolean): void {
    if (!ServiceLocator.isInitialized()) {
      return;
    }
    ServiceLocator.get().errorReporter.setInBackground(inBackground);
  }
}
