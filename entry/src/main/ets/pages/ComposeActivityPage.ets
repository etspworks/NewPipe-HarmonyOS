/**
 * S4 state - ComposeActivity (screen_compose_activity).
 *
 * The bridge from the legacy Activity/Fragment world into the KMP Compose world: a bare host
 * that decodes a serialized Destination out of its Intent and hands it to App(), which renders
 * NavDisplay. It draws no chrome of its own - the captured states S0001-S0003 are AboutScreen
 * rendering INSIDE it, and that content belongs to screen_about_screen.
 *
 * Containment: navModule() maps Destination.About -> AboutScreen() and
 * Destination.Settings -> SettingsHomeScreen(). That mapping is the host's, so it lives here as
 * the @Builder handed to NavDisplay's entryProvider slot.
 *
 * S4 adds the two stateVars and the DisposableEffect ComposeActivity.kt runs inside App {}:
 * the selected service's `isSchemeColorDensityLight` drives the status-bar content appearance
 * and is reverted to `false` when the page goes away. Not ported: testTagsAsResourceId (the
 * generated .id() slugs already do that job).
 *
 * S5 style - the only two visual things ComposeActivity itself owns:
 *   - enableEdgeToEdge(): the content draws behind the system bars, whose own backgrounds go
 *     transparent so whatever the mounted child paints there shows through (in the capture the
 *     child's red app bar, which is why S0001 has a red status-bar band).
 *   - AppTheme's surface: App.kt wraps NavDisplay in AppTheme, so the window background is the
 *     scheme background, not the ArkUI default white.
 * Everything visible in S0001-S0003 is AboutScreen rendering inside this host and is styled by
 * screen_about_screen; this page draws no chrome of its own.
 */
import { router, window } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { Destination } from '../model/enums/Destination';
import { NavDisplay, Navigator } from '../components/NavDisplay';
import { AboutScreenPage } from './AboutScreenPage';
import { SettingsHomeScreenPage } from './SettingsHomeScreenPage';
import { AppPreferences } from '../common/prefs/Preferences';
import { current_service_key } from '../common/prefs/SettingsKeys';

const TAG: string = 'ComposeActivityPage';

/** net.newpipe.Constants.INTENT_SCREEN_KEY = "SCREEN" (Constants.kt:10). */
const INTENT_SCREEN_KEY: string = 'SCREEN';

/**
 * AppTheme's window surface (Theme.kt:AppTheme -> lightScheme.background = Color.kt
 * `backgroundLight`, 0xFFFFF8F7). The captured content area is exactly this off-white.
 * The Compose Material3 scheme is not among the legacy colours the assets pass migrated into
 * color.json (that file carries res/values/colors.xml only), so it is a literal here.
 */
const APP_THEME_BACKGROUND: string = '#FFF8F7';

/**
 * enableEdgeToEdge() (ComposeActivity.kt:32) draws the app behind the system bars, which means
 * their own backgrounds must not paint over it.
 */
const SYSTEM_BAR_TRANSPARENT: string = '#00000000';

/**
 * Port of the two `Service` properties this screen uses (ServiceTheme.kt:79-116). The colour
 * schemes themselves belong to the theming pass; what ComposeActivity reads is the density flag.
 *
 * No entry sets `isSchemeColorDensityLight = true` today - the enum's default is `false` and no
 * service overrides it - but the flag is a per-service property in the source, so it stays one
 * here rather than being folded into a constant.
 */
class ServiceThemeInfo {
  readonly serviceName: string;
  readonly isSchemeColorDensityLight: boolean;

  constructor(serviceName: string, isSchemeColorDensityLight: boolean) {
    this.serviceName = serviceName;
    this.isSchemeColorDensityLight = isSchemeColorDensityLight;
  }
}

/** Service.entries, in declaration order - YOUTUBE first, which is the documented default. */
const SERVICE_ENTRIES: ServiceThemeInfo[] = [
  new ServiceThemeInfo('YouTube', false),
  new ServiceThemeInfo('SoundCloud', false),
  new ServiceThemeInfo('media.ccc.de', false),
  new ServiceThemeInfo('PeerTube', false),
  new ServiceThemeInfo('Bandcamp', false)
];

/**
 * currentService() (ServiceTheme.kt:121):
 *   Service.entries.find { it.serviceName == settings.getString(KEY_STREAMING_SERVICE,
 *                                                               Service.YOUTUBE.serviceName) }!!
 *
 * The preference holds the service NAME. `Constants.KEY_STREAMING_SERVICE = "service"` is the
 * same key the legacy ServiceHelper writes, i.e. the generated `current_service_key`.
 * The source's `!!` would throw on a name no Service matches; YouTube - already this read's
 * default - is returned instead rather than crashing the host activity.
 */
function currentService(): ServiceThemeInfo {
  const fallback: ServiceThemeInfo = SERVICE_ENTRIES[0];
  let name: string = fallback.serviceName;
  try {
    name = AppPreferences.instance().getStringSync(current_service_key, fallback.serviceName);
  } catch (err) {
    return fallback;
  }
  for (const service of SERVICE_ENTRIES) {
    if (service.serviceName === name) {
      return service;
    }
  }
  return fallback;
}

/**
 * ComposeActivity.onCreate:
 *   Json.decodeFromString<Destination>(intent.getStringExtra(Constants.INTENT_SCREEN_KEY)!!)
 *
 * The Intent extra is this page's router param of the same key. When it is absent - the cold
 * deep-link launch goes through EntryAbility's loadContent(url), which carries no params - the
 * value falls back to About because App.kt declares exactly that as its own default:
 * `startDestination: Destination = Destination.About`. Source-grounded, not an invented default.
 */
function readStartDestination(): Destination {
  const params: Record<string, Object> | undefined =
    router.getParams() as Record<string, Object> | undefined;
  if (params !== undefined && params !== null) {
    const screen: Object | undefined = params[INTENT_SCREEN_KEY];
    if (screen !== undefined && screen !== null) {
      // The two @Serializable data objects of the sealed Destination interface.
      const raw: string = screen.toString();
      if (raw === Destination.Settings) {
        return Destination.Settings;
      }
      if (raw === Destination.About) {
        return Destination.About;
      }
    }
  }
  return Destination.About;
}

@Entry
@Component
export struct ComposeActivityPage {
  /** App(startDestination = ...) - read from the Intent extra, never a literal. */
  @State startDestination: Destination = readStartDestination();

  /**
   * `service.isSchemeColorDensityLight` of the currently selected service, i.e. the value
   * DisposableEffect(service) writes to the window. Re-read whenever the page is shown, which is
   * what makes it follow a service change made on the Settings screen (the source recomposes
   * currentService() and the effect re-runs).
   */
  @State isSchemeColorDensityLight: boolean = false;

  /**
   * Koin builds the Navigator with parametersOf(startDestination, onCloseRequest); it is seeded
   * with the same INTENT_SCREEN_KEY value as `startDestination` above.
   * onCloseRequest is ComposeActivity's ::finish - popping this page off the router stack returns
   * to whatever pushed it, which is what finishing the activity does.
   */
  @State navigator: Navigator = new Navigator(readStartDestination(), () => {
    router.back();
  });

  /**
   * entryProvider = koinEntryProvider(), i.e. navModule()'s navigation<Destination.X> { Screen() }
   * bindings. Both hosted children (hostedBy: screen_compose_activity) are mounted here.
   */
  @Builder
  entryFor(startDestination: Destination) {
    // The stack's top entry, which is App.kt's startDestination while nothing pushes onto it.
    if (startDestination === Destination.Settings) {
      SettingsHomeScreenPage()
    } else {
      AboutScreenPage()
    }
  }

  /**
   * DisposableEffect(service) in ComposeActivity.kt:53:
   *   windowController.isAppearanceLightStatusBars = service.isSchemeColorDensityLight
   * A light status-bar appearance means dark content drawn on it, which on HarmonyOS is the
   * status bar's content colour rather than a boolean.
   */
  private applyStatusBarAppearance(isAppearanceLight: boolean): void {
    const context: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
    window.getLastWindow(context)
      .then((win: window.Window): Promise<void> => {
        const properties: window.SystemBarProperties = {
          statusBarColor: SYSTEM_BAR_TRANSPARENT,
          statusBarContentColor: isAppearanceLight ? '#000000' : '#FFFFFF'
        };
        return win.setWindowSystemBarProperties(properties);
      })
      .catch((err: BusinessError): void => {
        hilog.error(0x0000, TAG, 'Status bar appearance not applied: %{public}s', err.message);
      });
  }

  /** The effect's body: read the selected service, push its density flag to the window. */
  onPageShow(): void {
    this.isSchemeColorDensityLight = currentService().isSchemeColorDensityLight;
    this.applyStatusBarAppearance(this.isSchemeColorDensityLight);
  }

  /** onDispose { windowController.isAppearanceLightStatusBars = false }. */
  aboutToDisappear(): void {
    this.isSchemeColorDensityLight = false;
    this.applyStatusBarAppearance(false);
  }

  /**
   * NavDisplay(onBack = { navigator.navigateUp() }) - the implicit platform Back of this
   * screen's controlInventory. It pops the compose back stack, or closes the host when only
   * the root entry is left.
   */
  onBackPress(): boolean {
    return this.navigator.navigateUp();
  }

  build() {
    Column() {
      // App { AppTheme { NavDisplay(startDestination, onCloseRequest) } }
      NavDisplay({
        navigator: this.navigator,
        entry: (destination: Destination): void => this.entryFor(destination)
      })
    }
    .id('ComposeActivityPage')
    .width('100%')
    .height('100%')
    .backgroundColor(APP_THEME_BACKGROUND)
    // enableEdgeToEdge(), page-scoped: the window-level equivalent
    // (setWindowLayoutFullScreen) would outlive this page and change every other screen's
    // layout, and the source scopes it to this Activity.
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }
}
