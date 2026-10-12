/**
 * screen_main_activity - MainActivity. Cold-start root and the app's navigation host.
 *
 * S3 built the STRUCTURE from the source code (every control controlInventory lists, the real
 * container tree of activity_main.xml / drawer_layout.xml / drawer_header.xml /
 * toolbar_layout.xml, the drawer's two mutually exclusive modes and the repeated kiosk/service
 * rows). S4 adds the STATE and the WIRING on top of it without restructuring anything: the
 * selected service now round-trips through svc_preferences, the kiosk rows carry their translated
 * names and icons, the mini-player slot follows the real player, and onDrawerClosed / onBackPress
 * / the PeerTube instance switch behave as MainActivity.java does. STILL NO VISUAL STYLE -
 * colours, spacing and typography are S5's, taken from the capture.
 *
 * SOURCE TREE (activity_main.xml):
 *   FocusAwareDrawerLayout
 *   +- FocusAwareCoordinator                       <- contentSlot
 *   |  +- FragmentContainerView fragment_holder    (exclusive-branch host - see below)
 *   |  +- include toolbar_layout                   (Toolbar id=toolbar, nav icon = hamburger)
 *   |  +- FragmentContainerView fragment_player_holder
 *   |        hideable BottomSheet, peekHeight 0 - VideoDetailFragment / mini player
 *   +- include drawer_layout                       <- drawerSlot
 *        NavigationView id=navigation, headerLayout=drawer_header
 *
 * THE DRAWER HAS TWO MUTUALLY EXCLUSIVE MODES (MainActivity.toggleServices, line 419). It removes
 * ALL FOUR menu groups and then shows EITHER menu_services_group OR
 * menu_tabs_group + menu_kiosks_group + menu_options_about_group. A capture only ever shows one
 * of them, which is why this branch is built from the source and not from the screenshot.
 *
 * The whole menu is built in code from negative ITEM_ID_* constants - there is no menu XML - so
 * the rows are data here too.
 *
 * fragment_holder is an EXCLUSIVE-BRANCH host, not a MainFragment-only slot:
 * NavigationHelper.openBookmarksFragment / openStatisticsPlaylistFragment /
 * openLocalPlaylistFragment / openSubscriptionsImportFragment all
 * `replace(R.id.fragment_holder, ...)` the SAME container MainFragment occupies by default.
 * BookmarkFragment and StatisticsPlaylistFragment are reached from this page's own drawer rows
 * (Bookmarks, History); LocalPlaylistFragment and SubscriptionsImportFragment are reached from
 * BookmarkFragmentPage / SubscriptionFragmentPage respectively - this page still declares and
 * mounts them as fragment_holder's other possible occupants, per the plan's hostedBy contract.
 *
 * THERE IS NO ServiceHelper MODULE (phase2-logic-contract.md 10.3 absorbed KioskTranslator into
 * Tab.ts and never planned one). ServiceHelper.getSelectedServiceId / setSelectedServiceId are
 * two preference accesses and are done here, through svc_preferences and the generated
 * SettingsKeys constants - never a bare string key. Note the source stores the service NAME under
 * `current_service_key`, not its id, and falls back to YouTube when the name does not resolve.
 */
import { router } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { deviceInfo, emitter } from '@kit.BasicServicesKit';
import { MainFragmentPage } from './MainFragmentPage';
import { BookmarkFragmentPage } from './BookmarkFragmentPage';
import { LocalPlaylistFragmentPage } from './LocalPlaylistFragmentPage';
import { StatisticsPlaylistFragmentPage } from './StatisticsPlaylistFragmentPage';
import { SubscriptionsImportFragmentPage } from './SubscriptionsImportFragmentPage';
import {
  ImportSource,
  subscriptionImportSources,
  openSubscriptionsImport,
  PREVIOUS_EXPORT_SERVICE_ID
} from './SubscriptionFragmentPage';
import { FocusAwareDrawerLayout } from '../components/FocusAwareDrawerLayout';
import { FocusOverlayView } from '../components/FocusOverlayView';
import { MiniPlayerBar } from '../components/MiniPlayerBar';
import { PoTokenWebView } from '../components/PoTokenWebView';
import { StreamingService } from '../common/extractor/core/StreamingService';
import { NewPipe } from '../common/extractor/core/NewPipe';
// Importing ServiceRegistry is what registers the 5 StreamingServices with NewPipe (see the
// deviation note at the top of ServiceRegistry.ts); `all()` is ServiceList.all().
import { all } from '../common/extractor/ServiceRegistry';
import { PeertubeInstances } from '../common/extractor/PeertubeInstances';
import { PeertubeInstance } from '../model/extractor/PeertubeInstance';
import { ServiceLocator } from '../common/di/ServiceLocator';
import { Localization } from '../common/i18n/Localization';
import { AppPreferences } from '../common/prefs/Preferences';
import {
  current_service_key,
  default_service_value,
  enable_watch_history_key
} from '../common/prefs/SettingsKeys';
// KioskTranslator lives in Tab.ts (phase2-logic-contract.md 10.3).
import { getKioskIcon, getTranslatedKioskName } from '../model/app/Tab';
import { PlayerService, PlayerStatus } from '../common/player/PlayerService';
import { CompositeDisposable } from '../common/rx/Rx';
import { PermissionHelper } from '../common/perm/PermissionHelper';
import { ErrorReporter } from '../common/error/ErrorReporter';
import { ErrorInfo } from '../model/app/ErrorInfo';
import { UserAction } from '../model/enums/UserAction';
import { UpdateCheckResult } from '../common/update/UpdateCheck';
import { servicePrimaryColor } from '../common/theme/ServiceTheme';
import { BLACK_THEME_KEY, themedBackground } from '../common/theme/ThemeBackground';
import { registerErrorSnackbar } from '../components/ErrorSnackbar';

const TAG: string = 'MainActivity';

/** PeerTube is the only service whose drawer row carries an instance spinner. */
const PEERTUBE_SERVICE_ID: number = 3;

/** ServiceHelper.DEFAULT_FALLBACK_SERVICE = ServiceList.YouTube. */
const DEFAULT_FALLBACK_SERVICE_ID: number = 0;

/**
 * VideoDetailFragment.ACTION_PLAYER_STARTED (App.PACKAGE_NAME + the suffix), the in-app broadcast
 * MainActivity.openMiniPlayerUponPlayerStarted() registers a BroadcastReceiver for. `emitter` is
 * the HarmonyOS equivalent of a process-local broadcast; the emit side belongs to the player lane.
 */
const ACTION_PLAYER_STARTED: string =
  'org.schabi.newpipe.VideoDetailFragment.ACTION_PLAYER_STARTED';

/** ITEM_ID_HISTORY's slug - the one tab row enable_watch_history_key can hide. */
const HISTORY_SLUG: string = 'item_id_history';

/** DeviceUtils.isTv(this) - UI_MODE_TYPE_TELEVISION / LEANBACK, i.e. deviceType 'tv' here. */
const TV_DEVICE_TYPE: string = 'tv';

/**
 * One code-built drawer row. `slug` is the source ITEM_ID_* constant or menu-group id - the
 * drawer has no XML ids of its own. An empty `route` means the row leaves the app instead of
 * pushing a page (ITEM_ID_DONATION -> ShareUtils.openUrlInBrowser).
 */
class DrawerRoute {
  slug: string;
  label: Resource;
  route: string;

  constructor(slug: string, label: Resource, route: string) {
    this.slug = slug;
    this.label = label;
    this.route = route;
  }
}

/** Params for NavigationHelper.openSearchFragment(fm, serviceId, searchString). */
class SearchParams {
  serviceId: number;
  searchString: string;

  constructor(serviceId: number, searchString: string) {
    this.serviceId = serviceId;
    this.searchString = searchString;
  }
}

/** Params for NavigationHelper.openKioskFragment(fm, serviceId, kioskId). */
class KioskParams {
  serviceId: number;
  kioskId: string;

  constructor(serviceId: number, kioskId: string) {
    this.serviceId = serviceId;
    this.kioskId = kioskId;
  }
}

/**
 * menu_tabs_group, in source order (addDrawerMenuForCurrentService, line 276). All five rows are
 * added unconditionally there; History is the one the source hides when enable_watch_history_key
 * is false, which is the `if` inside the row loop below.
 */
const TAB_ROUTES: DrawerRoute[] = [
  new DrawerRoute('menu_tabs_group', $r('app.string.tab_subscriptions'),
    'pages/SubscriptionFragmentPage'),
  new DrawerRoute('item_id_feed', $r('app.string.fragment_feed_title'), 'pages/FeedFragmentPage'),
  new DrawerRoute('item_id_bookmarks', $r('app.string.tab_bookmarks'),
    'pages/BookmarkFragmentPage'),
  new DrawerRoute('item_id_downloads', $r('app.string.downloads'), 'pages/DownloadActivityPage'),
  new DrawerRoute(HISTORY_SLUG, $r('app.string.action_history'),
    'pages/StatisticsPlaylistFragmentPage')
];

/** menu_options_about_group: Settings, Donate (leaves the app), About. */
const OPTION_ROUTES: DrawerRoute[] = [
  new DrawerRoute('settings', $r('app.string.settings'), 'pages/SettingsActivityPage'),
  new DrawerRoute('donate', $r('app.string.donation_title'), ''),
  new DrawerRoute('about', $r('app.string.tab_about'), 'pages/ComposeActivityPage')
];

/**
 * KioskTranslator.getKioskIcon() answers with a drawable NAME; `$r` only takes a literal, so the
 * names it can return are mapped to their resources once here.
 */
const KIOSK_ICONS: Map<string, Resource> = new Map<string, Resource>([
  ['ic_whatshot', $r('app.media.ic_whatshot')],
  ['ic_home', $r('app.media.ic_home')],
  ['ic_add_circle_outline', $r('app.media.ic_add_circle_outline')],
  ['ic_thumb_up', $r('app.media.ic_thumb_up')],
  ['ic_live_tv', $r('app.media.ic_live_tv')],
  ['ic_stars', $r('app.media.ic_stars')],
  ['ic_radio', $r('app.media.ic_radio')],
  ['ic_videogame_asset', $r('app.media.ic_videogame_asset')],
  ['ic_music_note', $r('app.media.ic_music_note')],
  ['ic_movie', $r('app.media.ic_movie')],
  ['ic_podcasts', $r('app.media.ic_podcasts')]
]);

/**
 * addDrawerMenuForCurrentService() gives every tab / options row an icon (MainActivity.java
 * 276-319). They are the SOURCE's own drawables, carried over by the assets pass - never a
 * hand-drawn glyph and never a screenshot crop.
 */
const ROW_ICONS: Map<string, Resource> = new Map<string, Resource>([
  ['menu_tabs_group', $r('app.media.ic_tv')],
  ['item_id_feed', $r('app.media.ic_subscriptions')],
  ['item_id_bookmarks', $r('app.media.ic_bookmark')],
  ['item_id_downloads', $r('app.media.ic_file_download')],
  [HISTORY_SLUG, $r('app.media.ic_history')],
  ['settings', $r('app.media.ic_settings')],
  ['donate', $r('app.media.volunteer_activism_ic')],
  ['about', $r('app.media.ic_info_outline')]
]);

/* //////////////////////////////////////////////////////////////////////////
// S5 - STYLE BASELINE
//
// Every value below is either a MIGRATED SOURCE RESOURCE (values/colors.xml,
// values/dimens.xml, values/styles.xml -> Theme.NewPipe.Light) or a number MEASURED off the
// captured states S0006/S0008 (1080x2340 at density 3, so px / 3 = vp). Nothing here is
// eyeballed: where the two agree the resource is used, where only the capture knows the value
// (the Material-drawn divider, the DrawerLayout scrim) the measured literal is used.
////////////////////////////////////////////////////////////////////////// */

/*
 * ?attr/colorPrimary. The capture says #E53935, but that is the YouTube theme: ThemeHelper
 * .setTheme() swaps it with the drawer's service, so the toolbar and the drawer header read it
 * per service through servicePrimaryColor(this.selectedServiceId) rather than naming it here.
 */
/** ?android:attr/windowBackground = @color/light_background_color. Capture: #EEEEEE. */
const COLOR_SURFACE: Resource = $r('app.color.background');
/** @color/drawer_header_font_color - header title, service label and arrow tint (#F2FFFFFF). */
const COLOR_ON_HEADER: Resource = $r('app.color.drawer_header_font_color');
/** ToolbarTheme's on-primary: the title and the navigation icon over colorPrimary. */
const COLOR_ON_PRIMARY: Resource = $r('app.color.on_primary');
/** ?android:textColorPrimary (87% black). Over #EEEEEE that is the measured #1F1F1F. */
const COLOR_ON_SURFACE: Resource = $r('app.color.on_surface');
/** NavigationView itemIconTint = ?android:textColorSecondary (54%). Measured #6D6D6D. */
const COLOR_ICON_TINT: Resource = $r('app.color.on_surface_variant');
/** ?android:attr/listDivider between the drawer's menu groups. Measured #D1D1D1. */
const COLOR_DIVIDER: Resource = $r('app.color.separator');
/** DrawerLayout's default scrim over the content while the drawer is open (60% black). */
const COLOR_SCRIM: string = '#99000000';

/** ?attr/actionBarSize - toolbar [0,72][1080,240] = 168px. */
const TOOLBAR_HEIGHT: number = 56;
/** NavigationView measured width: drawer_layout [0,72][840,2340] = 840px. */
const DRAWER_WIDTH: number = 280;
/** drawer_header_padding_top (16) + drawer_header_content_min_height (120). */
const DRAWER_HEADER_HEIGHT: number = 136;
/** navigation_header_container is 8vp taller than the red header block itself. */
const DRAWER_HEADER_GAP: number = 8;
/** design_navigation_item: every drawer row measures 144px. */
const DRAWER_ROW_HEIGHT: number = 48;
/** Material menu-item horizontal inset. */
const DRAWER_ROW_PADDING: number = 16;
/** itemIconPadding: 16 padding + 24 icon + 32 gap puts every label at 72vp, as measured. */
const ICON_LABEL_GAP: number = 32;
const ICON_SIZE: number = 24;
/** One drawer selection per gesture; a second tap inside this window is a double tap, not a choice. */
const DRAWER_SELECTION_DEBOUNCE_MS: number = 700;
/**
 * How long the drawer takes to slide shut - the scrim's own fade, and the window the source spends
 * in DrawerLayout's close animation before onDrawerClosed fires its pendingRunnable.
 */
const DRAWER_CLOSE_ANIMATION_MS: number = 300;
/** drawer_header_newpipe_icon_size / _icon_title_space / autosize bounds. */
const HEADER_LOGO_SIZE: number = 48;
const HEADER_LOGO_GAP: number = 12;
const HEADER_TITLE_WIDTH: number = 176;
const HEADER_TITLE_MIN_SIZE: number = 18;
const HEADER_TITLE_MAX_SIZE: number = 32;
/** drawer_header_service_icon_size (16dp, fitCenter inside the 32dp bottom row). */
const HEADER_SERVICE_ICON_WIDTH: number = 16;
/** drawer_header_service_title_text_size. */
const HEADER_SERVICE_TEXT_SIZE: number = 14;
/** Body2 - design_menu_item_text and every drawer label. */
const LABEL_TEXT_SIZE: number = 14;
/** ToolbarTheme title. */
const TOOLBAR_TITLE_SIZE: number = 20;
/** The gap between the two drawer menu groups: 8 + 1 + 8 = 51px, as measured. */
const GROUP_GAP: number = 8;

/* //////////////////////////////////////////////////////////////////////////
// S6 - ACTION-CONTRACT MAP (results/plan/action-contracts.json, sids S0006/S0007/S0008)
//
// The contract's `control` strings are the ANALYST's labels for the source elements; the
// on-device matcher resolves each against a node's `.id()` or visible text (exact, then
// substring, either direction). Every required label below already has its control on this
// page - NOTHING was added to satisfy the list. This is the map, so the label a reader sees in
// the contract can be traced to the control that answers it:
//
//   'toolbar'                            -> .id('toolbar_tap_open_drawer')  (the hamburger)
//   'drawer_header_action_button'        -> .id('drawer_header_action_button')
//   'menu_tabs_group'                    -> the Subscriptions row, .id('menu_tabs_group')
//   'Subscriptions (drawer tab)'         -> the same row (text 'Subscriptions')
//   'What's New (feed)'                  -> .id('item_id_feed'), text "What's New"
//   'What's New / Feed (drawer tab)'     -> the same row
//   'Bookmarked playlists'               -> .id('item_id_bookmarks'), text 'Bookmarked Playlists'
//   'Bookmarked playlists (drawer tab)'  -> the same row
//   'Downloads'                          -> .id('item_id_downloads'), text 'Downloads'
//   'Downloads (drawer tab)'             -> the same row
//   'History'                            -> .id('item_id_history'), text 'History'
//   'History (drawer tab)'               -> the same row (hidden when watch history is off)
//   'menu_kiosks_group'                  -> the repeated kiosk row, .id('menu_kiosks_group_itemroot')
//   'Settings'                           -> .id('settings'), text 'Settings'
//   'Settings (drawer)'                  -> the same row
//   'Donate (drawer)'                    -> .id('donate'), text 'Donate'
//   'About (drawer)'                     -> .id('about'), text 'About & FAQ'
//   'menu_services_group'                -> the repeated service row, .id('menu_services_group_itemroot')
//   'instance_spinner'                   -> the PeerTube Select, .id('instance_spinner')
//
// The last two live in the drawer's SERVICES mode, which only 'drawer_header_action_button'
// opens - that is the source's own mutually exclusive branch, not a missing control.
////////////////////////////////////////////////////////////////////////// */

/** The reference's popup menus are square-cornered flat rectangles, not ArkUI bubbles. */
/**
 * The reference's popup menus are flat, square-cornered rectangles, not ArkUI bubbles.
 *
 * Its VERTICAL anchor could not be matched: the reference overlays its trigger - the first row
 * sits at y=153 on a 1080px screen while the toolbar still runs to 258 - and ArkUI drops the
 * menu below the trigger instead. MenuOptions.offset was tried and changed nothing, so the
 * difference is recorded on the card rather than faked with a no-op.
 */
const SQUARE_MENU_CORNERS: MenuOptions = { borderRadius: 0 };

/**
 * NavigationView's ?attr/selectableItemBackground: a menu row shows @color/light_ripple_color
 * while pressed and does NOT scale - the rows used to carry no press state, so the system's
 * default press effect was all a tap showed.
 */
@Styles
function drawerRowPressed() {
  .backgroundColor($r('app.color.ripple'))
}

@Entry
@Component
export struct MainActivityPage {
  /** ThemeHelper's black theme: the window background follows it. */
  @StorageProp(BLACK_THEME_KEY) blackTheme: boolean = false;

  /**
   * DrawerLayout open/closed. @Watch is the DrawerLayout.SimpleDrawerListener the source installs
   * in setupDrawer(): onDrawerOpened remembers the service, onDrawerClosed acts on a change.
   */
  @State @Watch('onDrawerToggled') drawerOpen: boolean = false;
  /**
   * True from the moment a drawer selection is accepted until the panel has finished sliding shut.
   * It keeps the scrim in the tree - invisible, but still taking touches - so the second tap of a
   * double tap is swallowed instead of landing on whatever the closing drawer uncovers.
   */
  @State private drawerClosing: boolean = false;
  /** toggleServices(): the drawer swaps the tab/kiosk/options groups for the service list. */
  @State servicesShown: boolean = false;
  /** ServiceHelper.getSelectedServiceId(this), read from svc_preferences in aboutToAppear. */
  @State currentServiceId: number = DEFAULT_FALLBACK_SERVICE_ID;
  /** NewPipe.getService(id).getServiceInfo().getName() - drawer_header_service_view. */
  @State drawerHeaderServiceLabel: string = '';
  /** menu_tabs_group - the 5 ITEM_ID_* tab rows. */
  @State drawerTabGroup: DrawerRoute[] = TAB_ROUTES;
  /** service.getKioskList().getAvailableKiosks() - REBUILT per service. */
  @State drawerKioskGroup: string[] = [];
  /**
   * Which service menu_kiosks_group + menu_options_about_group were actually built for.
   * addDrawerMenuForCurrentService() (line 296) resolves NewPipe.getService(getSelectedServiceId())
   * BEFORE the kiosk loop and before the Settings/Donate/About adds, so an unresolvable service
   * leaves the drawer with the 5 tab rows and nothing else - toggleServices() (line 434-438)
   * swallows the throw into a snackbar. -1 means "no group belongs to the current service".
   */
  @State drawerGroupsServiceId: number = -1;
  /** NewPipe.getServices() - 5 (YouTube 0, SoundCloud 1, media.ccc.de 2, PeerTube 3, Bandcamp 4). */
  @State drawerServiceGroupExpanded: StreamingService[] = all();
  /** PeertubeHelper.getInstanceList(this) - the instance_spinner's items. */
  @State peertubeInstances: PeertubeInstance[] = [];
  @State peertubeOptions: SelectOption[] = [];
  @State peertubeSelectedIndex: number = 0;
  /** enhancePeertubeMenu(): the PeerTube ROW is retitled to the current instance name. */
  @State peertubeInstanceName: string = '';
  /** sharedPreferences.getBoolean(enable_watch_history_key, true). */
  @State watchHistoryEnabled: boolean = true;
  /** PlayerHolder.getInstance().isPlayerOpen() - drives fragment_player_holder's bottom sheet. */
  @State miniPlayerSlot: boolean = false;
  /** bottomSheetHiddenOrCollapsed(): false while the player sheet owns the Back press. */
  @State playerExpanded: boolean = false;
  /** DeviceUtils.isTv(this) - the source installs FocusOverlayView only on TV. */
  @State isTv: boolean = false;
  /** In flight: the drawer rebuild and the newpipe_update_check request. */
  @State isLoading: boolean = false;
  /** ErrorUtil's ErrorInfo for the last failure on this screen (S6 renders the panel). */
  @State errorInfo: ErrorInfo | null = null;
  /**
   * fragment_holder's current occupant. NavigationHelper.open*Fragment(fm) replaces the SAME
   * slot MainFragment defaults to occupy - 'main' is that default, the rest are the plan's other
   * declared hostedBy children of this screen.
   */
  @State activeFragment: string = 'main';

  /**
   * Whether anything has asked for a poToken yet (requestPoTokenWebView()). MainActivity does
   * NOT own a PoTokenWebView in the source - PoTokenProviderImpl creates one lazily on the first
   * getWebClientPoToken() that needs it - so mounting `Web` in this page's first frame booted the
   * whole ArkWeb/chromium engine on every cold start for a screen that never mints a token.
   */
  @StorageLink('poTokenWebViewNeeded') poTokenWebViewNeeded: boolean = false;

  /**
   * The hosted fragment's title, written into THIS activity's toolbar — the source's own division:
   * toolbar_layout.xml belongs to the activity and the fragment calls setTitle() on it
   * (MainFragment.updateTitleForTab -> the selected tab's name; S0157 shows that title inside the
   * single toolbar at [216,115][329,196]). Empty falls back to the activity label.
   */
  @StorageLink('mainActionBarTitle') mainActionBarTitle: string = '';
  /** Bumped by the toolbar's action_search tap; MainFragmentPage watches it and does the push. */
  @StorageLink('mainSearchRequest') mainSearchRequest: number = 0;
  /**
   * menu_history.xml's action_history_clear, published the same way the search request is.
   *
   * A hosted fragment's onCreateOptionsMenu inflates into the ACTIVITY's toolbar in the source.
   * The port draws the shell's toolbar here and the fragment's own toolbar only when the fragment
   * is not hosted, so a hosted fragment's menu had nowhere to go: the History screen came up with
   * a title and no overflow at all, and Clear watch history was unreachable.
   */
  @StorageLink('mainHistoryClearRequest') historyClearRequest: number = 0;
  /**
   * The service the drawer last selected, published the same way the search request is. The
   * source restarts the whole Activity on a service change; here the tabbed fragment is a live
   * child that has to be told, or it keeps the previous service's tabs and content.
   */
  @StorageLink('mainSelectedServiceId') selectedServiceId: number = -1;

  /** SimpleDrawerListener.lastService - captured on open, compared on close. */
  private lastService: number = DEFAULT_FALLBACK_SERVICE_ID;
  /** Rule 8: every subscription is disposed in aboutToDisappear. */
  private disposables: CompositeDisposable = new CompositeDisposable();

  aboutToAppear(): void {
    this.shellOwnsToolbar = true;
    this.isTv = deviceInfo.deviceType === TV_DEVICE_TYPE;
    this.currentServiceId = this.readSelectedServiceId();
    this.selectedServiceId = this.currentServiceId;
    this.lastService = this.currentServiceId;
    this.watchHistoryEnabled =
      AppPreferences.instance().getBooleanSync(enable_watch_history_key, true);
    this.observePlayer();
    this.openMiniPlayerUponPlayerStarted();
    this.loadDrawerForCurrentService();
    this.checkForNewVersion();
    // ErrorUtil.showSnackbar() needs a root view; this window's UIContext is that.
    registerErrorSnackbar(this.getUIContext());
  }

  aboutToDisappear(): void {
    this.disposables.dispose();
    emitter.off(ACTION_PLAYER_STARTED);
  }

  onPageShow(): void {
    // onResume(): the selected service and the watch-history setting can both have been changed
    // by another screen (the service list, ContentSettings) while this page sat in the back stack.
    this.watchHistoryEnabled =
      AppPreferences.instance().getBooleanSync(enable_watch_history_key, true);
    const selected: number = this.readSelectedServiceId();
    if (selected !== this.currentServiceId) {
      this.currentServiceId = selected;
      this.lastService = selected;
      this.loadDrawerForCurrentService();
    }

    const params: Record<string, Object> | undefined =
      router.getParams() as Record<string, Object> | undefined;
    if (params === undefined || params === null) {
      return;
    }
    const link: Object | undefined = params['linkType'];
    if (link !== undefined && link !== null) {
      this.openDeepLink(link.toString());
      return;
    }
    // handleIntent()'s SECOND branch, in the source's own order:
    // `else if (intent.hasExtra(Constants.KEY_OPEN_SEARCH))` ->
    // NavigationHelper.openSearchFragment(fm, serviceId, searchString) (MainActivity.java:848-855).
    // RouterActivity.handleText() is the sender: a share that carries text but no URL starts
    // MainActivity and then calls NavigationHelper.openSearch(ctx, serviceId, searchString),
    // which is exactly this extra. Without this branch a shared-text intent landed on a blank
    // main screen and the text was dropped.
    const shared: Object | undefined = params['searchString'];
    if (shared !== undefined && shared !== null) {
      const sid: Object | undefined = params['serviceId'];
      router.pushUrl({
        url: 'pages/SearchFragmentPage',
        params: new SearchParams(sid === undefined || sid === null ? 0 : Number(sid.toString()),
                                 shared.toString())
      });
    }
  }

  /* //////////////////////////////////////////////////////////////////////////
  // ServiceHelper - two preference accesses, no module of its own
  ////////////////////////////////////////////////////////////////////////// */

  /**
   * ServiceHelper.getSelectedServiceId(): the preference holds the service NAME; an unresolvable
   * name falls back to DEFAULT_FALLBACK_SERVICE (YouTube), exactly as `runCatching{}.getOrNull()`
   * does there. `default_service_value` is `@string/youtube`, which getStringResolvedSync resolves
   * against the migrated string resources.
   */
  private readSelectedServiceId(): number {
    const name: string = AppPreferences.instance()
      .getStringResolvedSync(current_service_key, default_service_value);
    try {
      return NewPipe.getServiceByName(name).getServiceId();
    } catch (err) {
      return DEFAULT_FALLBACK_SERVICE_ID;
    }
  }

  /** ServiceHelper.setSelectedServiceId() -> setSelectedServicePreferences(name). */
  private writeSelectedServiceId(serviceId: number): void {
    let serviceName: string;
    try {
      serviceName = NewPipe.getService(serviceId).getServiceInfo().getName();
    } catch (err) {
      serviceName = NewPipe.getService(DEFAULT_FALLBACK_SERVICE_ID).getServiceInfo().getName();
    }
    const prefs: AppPreferences = AppPreferences.instance();
    // putString writes through to the in-memory store synchronously (so the read in
    // onDrawerClosed sees it); flush() is what makes it survive a restart.
    prefs.putString(current_service_key, serviceName);
    prefs.flush().catch((err: Error): void => {
      hilog.error(0x0000, TAG, 'Persisting the selected service failed: %{public}s', err.message);
    });
  }

  /* //////////////////////////////////////////////////////////////////////////
  // Drawer contents
  ////////////////////////////////////////////////////////////////////////// */

  /**
   * addDrawerMenuForCurrentService() (line 276) + enhancePeertubeMenu() (line 460): the kiosk
   * rows, the header service name and the PeerTube instance list are all per-service, so they are
   * rebuilt whenever the selected service changes.
   */
  private loadDrawerForCurrentService(): void {
    this.isLoading = true;
    try {
      const service: StreamingService = NewPipe.getService(this.currentServiceId);
      this.drawerHeaderServiceLabel = service.getServiceInfo().getName();
      this.drawerKioskGroup = service.getKioskList().getAvailableKiosks();
      this.drawerGroupsServiceId = this.currentServiceId;
      this.errorInfo = null;
    } catch (err) {
      // ErrorUtil.showUiErrorSnackbar(this, "Showing main page tabs", e): the groups after
      // line 297 were never added, so nothing below the tab rows belongs to this service.
      this.drawerKioskGroup = [];
      this.drawerGroupsServiceId = -1;
      this.reportUiError('Showing main page tabs', err as Object);
    } finally {
      this.isLoading = false;
    }
    this.loadPeertubeInstances();
  }

  private loadPeertubeInstances(): void {
    try {
      const instances: PeertubeInstance[] = PeertubeInstances.getInstanceList();
      const current: PeertubeInstance = PeertubeInstances.currentInstance();
      const options: SelectOption[] = [];
      let selected: number = 0;
      for (let i: number = 0; i < instances.length; i++) {
        const option: SelectOption = { value: instances[i].getName() };
        options.push(option);
        if (instances[i].getUrl() === current.getUrl()) {
          selected = i;
        }
      }
      this.peertubeInstances = instances;
      this.peertubeOptions = options;
      this.peertubeSelectedIndex = selected;
      this.peertubeInstanceName = current.getName();
    } catch (err) {
      this.reportUiError('Reading the PeerTube instance list', err as Object);
    }
  }

  /** ErrorUtil.showUiErrorSnackbar() + the ErrorInfo the panel and the report are built from. */
  private reportUiError(request: string, err: Object): void {
    const throwable: Error = err instanceof Error ? err as Error : new Error(request + ' failed');
    const reporter: ErrorReporter = ServiceLocator.get().errorReporter;
    reporter.showUiErrorSnackbar(request, throwable);
    this.errorInfo = ErrorInfo.fromThrowable(throwable, UserAction.SOMETHING_ELSE, request,
      this.currentServiceId);
  }

  /* //////////////////////////////////////////////////////////////////////////
  // Player - fragment_player_holder
  ////////////////////////////////////////////////////////////////////////// */

  /** PlayerHolder.getInstance().isPlayerOpen(): a player exists inside the service. */
  private isPlayerOpen(): boolean {
    const status: PlayerStatus | null = PlayerService.getInstance().state.getValue();
    return status !== null && status !== PlayerStatus.IDLE;
  }

  /**
   * Keeps the mini-player slot in step with the player for its whole lifetime, both ways. What
   * the bar SHOWS is MiniPlayerBar's own subscription now - this page only still needs to know
   * whether a player exists, because bottomSheetHiddenOrCollapsed() decides the Back press on it.
   */
  private observePlayer(): void {
    this.disposables.add(PlayerService.getInstance().state
      .subscribeCallbacks((status: PlayerStatus): void => {
        this.miniPlayerSlot = status !== PlayerStatus.IDLE;
        if (status === PlayerStatus.IDLE) {
          this.playerExpanded = false;
        }
      }));
  }

  /**
   * openMiniPlayerUponPlayerStarted(): if the player is already open just show the mini player,
   * otherwise listen for ACTION_PLAYER_STARTED once and unregister as soon as it arrives.
   */
  private openMiniPlayerUponPlayerStarted(): void {
    if (this.isPlayerOpen()) {
      this.miniPlayerSlot = true;
      return;
    }
    emitter.on(ACTION_PLAYER_STARTED, (): void => {
      if (this.isPlayerOpen()) {
        this.miniPlayerSlot = true;
        // "At this point the player is added 100%, we can unregister."
        emitter.off(ACTION_PLAYER_STARTED);
      }
    });
  }

  /* //////////////////////////////////////////////////////////////////////////
  // Update check - endpoint newpipe_update_check
  ////////////////////////////////////////////////////////////////////////// */

  /** CheckForNewAppVersion: a non-manual check, so svc_update_check applies its own throttle. */
  private checkForNewVersion(): void {
    ServiceLocator.get().updateCheck.checkNewVersion(false)
      .then((result: UpdateCheckResult): void => {
        const failure: Error | null = result.error;
        if (failure !== null) {
          hilog.warn(0x0000, TAG, 'Could not fetch the NewPipe API: %{public}s', failure.message);
          return;
        }
        if (!result.updateAvailable) {
          return;
        }
        // compareAppVersionAndShowNotification()
        ServiceLocator.get().notifications
          .publishUpdateAvailable(result.versionName, result.apkLocationUrl)
          .catch((err: Error): void => {
            hilog.error(0x0000, TAG, 'Update notification failed: %{public}s', err.message);
          });
      })
      .catch((err: Error): void => {
        hilog.error(0x0000, TAG, 'Update check failed: %{public}s', err.message);
      });
  }

  /* //////////////////////////////////////////////////////////////////////////
  // Drawer listener, navigation and Back
  ////////////////////////////////////////////////////////////////////////// */

  /** DrawerLayout.SimpleDrawerListener, installed in setupDrawer() (line 248). */
  onDrawerToggled(): void {
    if (this.drawerOpen) {
      this.lastService = this.readSelectedServiceId();
    } else {
      this.onDrawerClosed();
    }
  }

  /** onDrawerClosed() (line 257). */
  private onDrawerClosed(): void {
    if (this.servicesShown) {
      this.toggleServices();
    }
    if (this.lastService !== this.readSelectedServiceId()) {
      this.recreateForServiceChange();
    }
  }

  /**
   * ActivityCompat.recreate(MainActivity.this): the source restarts the activity so the kiosk
   * rows, the header and the tabs rebuild for the newly selected service, popping the
   * fragment_holder back stack on the way. Here that is the in-page equivalent - fragment_holder
   * back to its default occupant and the per-service state re-read. `router.clear()` is
   * deliberately NOT used: the routed pages (Settings, About, Downloads) are separate Activities
   * in the source too, and recreate() does not touch them.
   */
  private recreateForServiceChange(): void {
    this.currentServiceId = this.readSelectedServiceId();
    this.lastService = this.currentServiceId;
    this.activeFragment = 'main';
    AppStorage.setOrCreate('mainHostedFragment', 'main');
    // What recreate() really buys in the source is a rebuilt MainFragment. Resetting this page's
    // own state does not touch the live child, so without this the tab strip and every tab's
    // content stayed on the previous service - "after selecting SoundCloud the YouTube template
    // is still displayed".
    this.selectedServiceId = this.currentServiceId;
    this.loadDrawerForCurrentService();
  }

  /** Constants.KEY_LINK_TYPE / KEY_OPEN_SEARCH intents MainActivity resolves itself. */
  private openDeepLink(linkType: string): void {
    if (linkType === 'CHANNEL') {
      router.pushUrl({ url: 'pages/ChannelFragmentPage' });
    } else if (linkType === 'PLAYLIST') {
      router.pushUrl({ url: 'pages/PlaylistFragmentPage' });
    } else if (linkType === 'STREAM') {
      router.pushUrl({ url: 'pages/VideoDetailFragmentPage' });
    }
    // No SEARCH case: StreamingService.LinkType is NONE/STREAM/CHANNEL/PLAYLIST and the source's
    // KEY_LINK_TYPE switch has exactly the three above (MainActivity.java:823-845). A search
    // arrives through KEY_OPEN_SEARCH instead, handled in onPageShow().
  }

  /**
   * onBackPressed() (line 597), in its source order. It NEVER swallows a press it does not
   * handle: the last branch returns false so the system pops the page / leaves the app, which is
   * `getBackStackEntryCount() == 1 ? finish() : super.onBackPressed()` there.
   */
  onBackPress(): boolean {
    return this.handleBackPressed();
  }

  private handleBackPressed(): boolean {
    // DeviceUtils.isTv(this): Back closes the drawer before anything else.
    if (this.isTv && this.drawerOpen) {
      this.drawerOpen = false;
      return true;
    }
    if (this.bottomSheetHiddenOrCollapsed()) {
      // The fragment inside fragment_holder handles the press if it can.
      if (this.activeFragment !== 'main') {
        this.showMainFragment();
        return true;
      }
      return false;
    }
    // The player fragment owns the press: collapse the sheet instead of leaving the page.
    this.playerExpanded = false;
    return true;
  }

  /** bottomSheetHiddenOrCollapsed(): the sheet is hidden (no player) or collapsed (mini). */
  private bottomSheetHiddenOrCollapsed(): boolean {
    return !this.miniPlayerSlot || !this.playerExpanded;
  }

  /* //////////////////////////////////////////////////////////////////////////
  // Drawer item handlers
  ////////////////////////////////////////////////////////////////////////// */

  /** toggleServices() (line 419): flips the mode and the header arrow. */
  private toggleServices(): void {
    this.servicesShown = !this.servicesShown;
    if (!this.servicesShown) {
      // line 434: leaving the service list re-adds the tab/kiosk/options groups by re-reading
      // getSelectedServiceId(), so a service just picked in the list is the one they belong to.
      this.loadDrawerForCurrentService();
    }
  }

  /**
   * tabSelected() / optionsAboutSelected(), then drawerItemSelected()'s closeDrawers().
   * Bookmarks and History go through NavigationHelper.openBookmarksFragment /
   * openStatisticsPlaylistFragment - fragment_holder replacements, so they select the branch
   * instead of pushing a route. Downloads goes through NavigationHelper.openDownloads(this),
   * which runs PermissionHelper.checkStoragePermissions FIRST and only then starts the activity.
   */
  /** The tab title the shell was showing before a drawer fragment took the bar over. */
  private titleBeforeFragment: string = '';
  /**
   * Whether this shell's toolbar is the one carrying the page name. Every fragment mounted inside
   * it - the main tabbed fragment included - reads this and skips drawing a bar of its own, which
   * is what MainActivity does in the source: one toolbar, fragments call setTitle() into it.
   *
   * It is true for as long as the shell is mounted, not just while a drawer fragment is showing.
   *
   * It travels through AppStorage rather than as a @Prop because those fragments are @Entry
   * components and ArkTS rejects @Prop on those - a @Prop there compiles, is silently never
   * written, and the fix looks applied while doing nothing. Page lifecycle is no better a
   * discriminator: onPageShow fires on an @Entry child too, which is exactly how the main
   * fragment ended up drawing a second title bar.
   *
   * Known limit: a fragment pushed as its OWN route while the shell is still mounted underneath
   * would also skip its bar. Nothing takes that path today - the drawer intercepts both routes -
   * but it is the thing to change first if one ever does.
   */
  @StorageLink('mainShellOwnsToolbar') shellOwnsToolbar: boolean = false;
  /** Which fragment MainFragment's selected tab hosts - it is that fragment's menu in this bar. */
  @StorageProp('mainActiveTabContent') activeTabContent: string = '';
  /** menu_feed_fragment's two items, dispatched to the hosted FeedFragmentPage. */
  @StorageLink('mainFeedVisibilityRequest') feedVisibilityRequest: number = 0;
  /** SubscriptionFragment's Export entry: only that page holds the manager that can run it. */
  @StorageLink('mainSubscriptionsExportRequest') subscriptionsExportRequest: number = 0;
  @StorageLink('mainSubscriptionsImportPreviousRequest')
  subscriptionsImportPreviousRequest: number = 0;
  @StorageLink('mainFeedHelpRequest') feedHelpRequest: number = 0;

  /**
   * MainActivity has ONE toolbar and its fragments call setTitle() into it. Swapping
   * fragment_holder's occupant without doing that left the previous tab's title in the bar while
   * the fragment drew a second bar of its own underneath - "the page information at the top shows
   * both Trending and Bookmarked Playlist". The host owns the bar, so the host sets the title and
   * the fragment is told not to draw one.
   */
  private showFragment(fragment: string, titleKey: string): void {
    if (this.activeFragment === 'main') {
      this.titleBeforeFragment = this.mainActionBarTitle;
    }
    this.activeFragment = fragment;
    AppStorage.setOrCreate('mainHostedFragment', fragment);
    this.mainActionBarTitle = Localization.getString(titleKey);
  }

  /** Up / Back out of a drawer fragment: the tab title the shell had comes back with it. */
  private showMainFragment(): void {
    this.activeFragment = 'main';
    AppStorage.setOrCreate('mainHostedFragment', 'main');
    if (this.titleBeforeFragment.length > 0) {
      this.mainActionBarTitle = this.titleBeforeFragment;
      this.titleBeforeFragment = '';
    }
  }

  /**
   * A drawer row closes the drawer and navigates. Neither is instant, so a rapid second tap was
   * still delivered - to this row again, or to whatever slid under the finger while the panel was
   * closing, which is how "Subscriptions opened, then What's New opened" happens. One selection
   * per gesture: a second one inside the window is dropped.
   *
   * A timestamp rather than an in-flight flag on purpose. A flag has to be cleared by something,
   * and a push that fails silently would leave the drawer permanently dead.
   */
  private lastDrawerSelectionAt: number = 0;

  private drawerSelectionAccepted(): boolean {
    const nowMs: number = Date.now();
    if (nowMs - this.lastDrawerSelectionAt < DRAWER_SELECTION_DEBOUNCE_MS) {
      return false;
    }
    this.lastDrawerSelectionAt = nowMs;
    return true;
  }

  /**
   * drawerItemSelected() in the source does NOT navigate. It stores the work in `pendingRunnable`
   * and calls closeDrawers(); the DrawerListener runs it from onDrawerClosed, once the panel is
   * shut. That ordering is the whole reason a double tap is harmless there: the second tap happens
   * while the drawer is still on screen, so it hits the drawer - where the debounce catches it -
   * and never the incoming screen.
   *
   * The port navigated straight away, so the second tap landed on whatever the closing drawer
   * uncovered: on media.ccc.de it fell on the Subscriptions page's "All" channel-group tile and
   * opened the feed, which is what T-0154 and T-0132 report. No debounce can catch that, because
   * the tap never reaches the drawer at all.
   */
  private drawerItemSelected(item: DrawerRoute): void {
    if (!this.drawerSelectionAccepted()) {
      return;
    }
    this.drawerOpen = false;
    this.drawerClosing = true;
    setTimeout(() => {
      this.drawerClosing = false;
      this.runDrawerSelection(item);
    }, DRAWER_CLOSE_ANIMATION_MS);
  }

  /** The pendingRunnable itself: what onDrawerClosed runs once the panel is shut. */
  private runDrawerSelection(item: DrawerRoute): void {
    if (item.slug === 'item_id_bookmarks') {
      this.showFragment('bookmark', 'tab_bookmarks');
      return;
    }
    if (item.slug === HISTORY_SLUG) {
      this.showFragment('statisticsPlaylist', 'title_activity_history');
      return;
    }
    if (item.route.length === 0) {
      this.openDonation();
      return;
    }
    if (item.slug === 'item_id_downloads') {
      const permissions: PermissionHelper = ServiceLocator.get().permissions;
      if (!permissions.checkStoragePermissions()) {
        hilog.warn(0x0000, TAG, 'Downloads: storage permission not granted');
        return;
      }
    }
    router.pushUrl({ url: item.route });
  }

  /** ITEM_ID_DONATION: ShareUtils.openUrlInBrowser(getString(R.string.donation_url)). */
  private openDonation(): void {
    ServiceLocator.get().share.openUrlInBrowser(Localization.getString('donation_url'))
      .catch(() => {
        hilog.error(0x0000, TAG, 'Opening the donation url failed');
      });
  }

  /** kioskSelected() (line 374) -> NavigationHelper.openKioskFragment(fm, serviceId, kioskId). */
  private kioskSelected(kioskId: string): void {
    if (!this.drawerSelectionAccepted()) {
      return;
    }
    this.drawerOpen = false;
    router.pushUrl({
      url: 'pages/KioskFragmentPage',
      params: new KioskParams(this.currentServiceId, kioskId)
    });
  }

  /**
   * changeService() (line 344) -> ServiceHelper.setSelectedServiceId(), then
   * drawerItemSelected()'s closeDrawers(). The rebuild is NOT done here: the source defers it to
   * onDrawerClosed, which compares lastService and recreates only if it really changed.
   */
  private changeService(serviceId: number): void {
    this.writeSelectedServiceId(serviceId);
    this.currentServiceId = serviceId;
    this.drawerOpen = false;
  }

  /**
   * enhancePeertubeMenu()'s OnItemSelectedListener: PeertubeHelper.selectInstance(),
   * changeService(), closeDrawers(), then popBackStack + recreate after 300 ms. The delayed
   * recreate is the source's own: selecting a new instance while PeerTube is ALREADY the selected
   * service leaves onDrawerClosed with nothing to compare, so the rebuild has to be explicit.
   */
  private peertubeInstanceSelected(index: number): void {
    if (index < 0 || index >= this.peertubeInstances.length) {
      return;
    }
    const instance: PeertubeInstance = this.peertubeInstances[index];
    if (instance.getUrl() === PeertubeInstances.currentInstance().getUrl()) {
      return;
    }
    PeertubeInstances.selectInstance(instance);
    this.peertubeInstanceName = instance.getName();
    this.peertubeSelectedIndex = index;
    this.changeService(PEERTUBE_SERVICE_ID);
    setTimeout((): void => {
      this.recreateForServiceChange();
    }, 300);
  }

  /** ServiceHelper.getIcon(serviceId) - one drawer icon per StreamingService. */
  private serviceIcon(serviceId: number): Resource {
    if (serviceId === 1) {
      return $r('app.media.ic_cloud');
    }
    if (serviceId === 2) {
      return $r('app.media.ic_placeholder_media_ccc');
    }
    if (serviceId === PEERTUBE_SERVICE_ID) {
      return $r('app.media.ic_placeholder_peertube');
    }
    if (serviceId === 4) {
      return $r('app.media.ic_placeholder_bandcamp');
    }
    return $r('app.media.ic_smart_display');
  }

  /**
   * The drawable addDrawerMenuForCurrentService() sets on each tab / options row
   * (MainActivity.java 276-319), keyed by the same slug the row's `.id()` carries.
   */
  private rowIcon(slug: string): Resource {
    const icon: Resource | undefined = ROW_ICONS.get(slug);
    return icon === undefined ? $r('app.media.ic_asterisk') : icon;
  }

  /** KioskTranslator.getKioskIcon() returned 0 for an unknown kiosk - no icon on that row. */
  private hasKioskIcon(kioskId: string): boolean {
    return KIOSK_ICONS.has(getKioskIcon(kioskId));
  }

  private kioskIcon(kioskId: string): Resource {
    const icon: Resource | undefined = KIOSK_ICONS.get(getKioskIcon(kioskId));
    return icon === undefined ? $r('app.media.ic_whatshot') : icon;
  }

  /* //////////////////////////////////////////////////////////////////////////
  // Content - FocusAwareCoordinator (activity_main.xml child 1)
  ////////////////////////////////////////////////////////////////////////// */

  @Builder
  contentArea(): void {
    Stack({ alignContent: Alignment.Bottom }) {
      Column() {
        this.toolbarBar()
        // fragment_holder: exclusive branch over its declared occupants - mutually exclusive,
        // never two branches mounted at once.
        if (this.activeFragment === 'bookmark') {
          BookmarkFragmentPage()
            .layoutWeight(1)
        } else if (this.activeFragment === 'statisticsPlaylist') {
          StatisticsPlaylistFragmentPage()
            .layoutWeight(1)
        } else if (this.activeFragment === 'localPlaylist') {
        // A child of the shell: MainActivityPage docks MiniPlayerBar itself, so this screen
        // must not dock a second one. See its hostedInMainShell doc.
          LocalPlaylistFragmentPage({ hostedInMainShell: true })
            .layoutWeight(1)
        } else if (this.activeFragment === 'subscriptionsImport') {
          SubscriptionsImportFragmentPage()
            .layoutWeight(1)
        } else {
          MainFragmentPage()
            .layoutWeight(1)
        }
      }
      .width('100%')
      .height('100%')
      .backgroundColor(themedBackground(this.blackTheme))

      // fragment_player_holder: a hideable BottomSheet with peekHeight 0 that carries
      // VideoDetailFragment / the mini player. The container was here from the start but nothing
      // ever filled it, so the bar was never drawn and nothing could be tapped.
      if (this.miniPlayerSlot) {
        MiniPlayerBar()
      }

      // DrawerLayout's scrim - the content dims to 60% black behind an open drawer (S0008:
      // #EEEEEE reads #5F5F5F and #E53935 reads #5C1715 under it, i.e. black at 0.60). It lives
      // INSIDE the content so SideBarContainer still draws the sidebar above it, is rendered
      // only while the drawer is open (static_guard's overlay-swallows-touch rule), and closes
      // the drawer on tap the way DrawerLayout's own scrim does.
      if (this.drawerOpen || this.drawerClosing) {
        Column()
          .width('100%')
          .height('100%')
          .backgroundColor(COLOR_SCRIM)
          // DrawerLayout fades its scrim in step with the panel's slide instead of popping it on;
          // SideBarContainer animates the panel, so the scrim gets the matching fade. Fading by
          // OPACITY rather than by removing the node is what lets it keep TAKING TOUCHES all the
          // way through the close - DrawerLayout's scrim absorbs them too, which is why a double
          // tap costs the source nothing.
          .opacity(this.drawerOpen ? 1 : 0)
          .animation({ duration: DRAWER_CLOSE_ANIMATION_MS })
          .onClick(() => {
            this.drawerOpen = false;
          })
      }
    }
    .width('100%')
    .height('100%')
  }

  /** toolbar_layout.xml - Toolbar id=toolbar, its navigation icon opens the start drawer. */
  /**
   * SubscriptionFragment's two runtime-built submenus (SubscriptionFragment.kt:125-148). The
   * fragment is a front page here, so its options menu belongs in THIS bar - the fragment drawing
   * its own stacked a second toolbar under this one, and this one had no overflow at all.
   */
  @Builder
  subscriptionImportSourcesMenu() {
    Menu() {
      ForEach(subscriptionImportSources(), (source: ImportSource) => {
        MenuItem({ content: source.label })
          .id(source.idSlug)
          .onClick(() => {
            // "Previous export" opens the file picker on the subscriptions screen itself - it is
            // the one entry that pushes nothing - and only that screen holds the dialog and the
            // manager, so the host dispatches it the way it already dispatches Export.
            if (source.serviceId === PREVIOUS_EXPORT_SERVICE_ID) {
              this.subscriptionsImportPreviousRequest = this.subscriptionsImportPreviousRequest + 1;
              return;
            }
            openSubscriptionsImport(source);
          })
      }, (source: ImportSource) => source.idSlug)
    }
  }

  @Builder
  subscriptionExportTargetsMenu() {
    Menu() {
      MenuItem({ content: $r('app.string.file') })
        .id('file')
        .onClick(() => {
          this.subscriptionsExportRequest = this.subscriptionsExportRequest + 1;
        })
    }
  }

  @Builder
  subscriptionImportExportMenu() {
    Menu() {
      MenuItem({ content: $r('app.string.import_from'), builder: this.subscriptionImportSourcesMenu })
        .id('import_from')
      MenuItem({ content: $r('app.string.export_to'), builder: this.subscriptionExportTargetsMenu })
        .id('export_to')
    }
    // The reference opens its submenu STACKED OVER the parent, in the same column. ArkUI's
    // default is SIDE_EXPAND, which anchors the child to the side of its parent - and with this
    // overflow already right-aligned there is no room on the right, so "File" flipped to the far
    // left of the screen, which is the misplaced button this case reports.
    //
    // The mode is a MENU ATTRIBUTE, `subMenuExpandingMode`, not a MenuOptions field; the earlier
    // attempt put it in MenuOptions, which is why it would not compile and the API was recorded
    // as missing from this SDK. It is present - API 12 and up - and this build is API 24.
    .subMenuExpandingMode(SubMenuExpandingMode.STACK_EXPAND)
    // ArkUI's default menu is a rounded, pale-gradient bubble with a tail. The reference's
    // overflow is a flat white rectangle anchored under the icon, so the surface is set here and
    // the corners are squared through the bind options - the same MenuOptions the downloads row
    // menu already uses.
    .backgroundColor($r('app.color.surface'))
  }

  @Builder
  toolbarBar(): void {
    Row() {
      // ActionBarDrawerToggle's navigation icon: the hamburger opens the drawer while
      // MainFragment shows; with any other fragment in fragment_holder the drawer is
      // LOCK_MODE_LOCKED_CLOSED and the same icon is Up (onHomeButtonPressed).
      Row() {
        // ActionBarDrawerToggle draws BOTH of its states with one DrawerArrowDrawable - a
        // framework drawable, so the source app has no asset for the hamburger to carry over,
        // and this SDK's ArkTS compiler rejects $r('sys.media.ohos_ic_public_drawer') as an
        // unknown resource name even though id_defined.json lists it. The two states are
        // therefore drawn/loaded separately, and they are mutually exclusive - never both.
        if (this.activeFragment === 'main') {
          // Three bars: same affordance, no resource dependency, exact colour control. Measured
          // off S0006's hamburger (bars at y 136-141 / 152-157 / 168-173 px, x 56-111): each bar
          // 6px = 2vp thick with a 10px = 3vp gap, 56px = 18vp long - i.e. DrawerArrowDrawable's
          // own barThickness 2dp / gapSize 3dp / barLength 18dp.
          // Non-interactive decoration inside the already-declared clickable Row.
          Column({ space: 3 }) {
            Divider().strokeWidth(2).color(COLOR_ON_PRIMARY).width(18)
            Divider().strokeWidth(2).color(COLOR_ON_PRIMARY).width(18)
            Divider().strokeWidth(2).color(COLOR_ON_PRIMARY).width(18)
          }
          .width(ICON_SIZE)
          .height(ICON_SIZE)
          .justifyContent(FlexAlign.Center)
          .alignItems(HorizontalAlign.Center)
        } else {
          // onHomeButtonPressed(): with anything but MainFragment in fragment_holder the drawer
          // is LOCK_MODE_LOCKED_CLOSED and ActionBarDrawerToggle shows Up. The arrow is a real
          // source asset (ic_arrow_back), so it is loaded, never drawn.
          Image($r('app.media.ic_arrow_back'))
            .width(ICON_SIZE)
            .height(ICON_SIZE)
            .objectFit(ImageFit.Contain)
            .fillColor(COLOR_ON_PRIMARY)
        }
      }
      .id('toolbar_tap_open_drawer')
      .width(TOOLBAR_HEIGHT)
      .height(TOOLBAR_HEIGHT)
      .justifyContent(FlexAlign.Center)
      .alignItems(VerticalAlign.Center)
      // ActionBarDrawerToggle's contentDescription (R.string.drawer_open / drawer_close) is
      // what the capture matched this control by (target.matchedBy = "desc"), so it is carried
      // over here. It does NOT replace .id() - accessibilityText never surfaces in a uitest
      // dump, which is why the id above stays the addressable handle.
      .accessibilityText(this.drawerOpen ? 'Close Drawer' : 'Open Drawer')
      .onClick(() => {
        if (this.activeFragment === 'main') {
          this.drawerOpen = true;
        } else {
          this.showMainFragment();
        }
      })
      // Widget.AppCompat.Toolbar.Title. The hosted fragment sets it (MainFragment writes the
      // selected tab's name); with nothing set the activity label shows, as it does before the
      // first fragment transaction.
      if (this.mainActionBarTitle.length > 0) {
        Text(this.mainActionBarTitle)
          .id('main_title')
          .fontSize(TOOLBAR_TITLE_SIZE)
          .fontWeight(FontWeight.Medium)
          .fontColor(COLOR_ON_PRIMARY)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .margin({ left: DRAWER_ROW_PADDING })
          .layoutWeight(1)
      } else {
        Text($r('app.string.app_name'))
          .fontSize(TOOLBAR_TITLE_SIZE)
          .fontWeight(FontWeight.Medium)
          .fontColor(COLOR_ON_PRIMARY)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .margin({ left: DRAWER_ROW_PADDING })
          .layoutWeight(1)
      }

      // menu_main.xml's action_search, showAsAction="ifRoom". It is MainFragment's menu, so it is
      // in the bar only while MainFragment is in fragment_holder (onCreateOptionsMenu is the
      // fragment's). The tap is dispatched to the fragment, which performs the navigation.
      if (this.activeFragment === 'statisticsPlaylist') {
        // menu_history.xml's action_history_clear has showAsAction="never", so it lives in the
        // ActionBar overflow rather than on the bar.
        Image($r('app.media.ic_more_vert'))
          .id('more_options')
          .width(ICON_SIZE + 24)
          .height(ICON_SIZE + 24)
          .padding(12)
          .objectFit(ImageFit.Contain)
          .fillColor(COLOR_ON_PRIMARY)
          .bindMenu(this.historyOverflowMenu, SQUARE_MENU_CORNERS)
      }

      // MainFragment's own action_search is emitted BEFORE the hosted fragment's items, so the
      // fragment's last item keeps the edge. The ActionBar orders a hosted fragment's menu AFTER
      // the host's, which is why the reference's What's New bar ends on menu_item_feed_help
      // ([936,114][1080,258], flush to its 1080 px edge) while this port ended on action_search
      // and pushed help one slot in - the whole of "the Help button should be displayed at the
      // far right".
      if (this.activeFragment === 'main') {
        // width/height set the COMPONENT area; the content area is that minus padding, so
        // ICON_SIZE with a 12vp inset left a 0x0 glyph. Size the component to glyph + inset.
        Image($r('app.media.ic_search'))
          .id('action_search')
          .accessibilityText($r('app.string.search'))
          .width(ICON_SIZE + 24)
          .height(ICON_SIZE + 24)
          .padding(12)
          .objectFit(ImageFit.Contain)
          .fillColor(COLOR_ON_PRIMARY)
          .onClick(() => {
            this.mainSearchRequest = this.mainSearchRequest + 1;
          })
      }

      if (this.activeFragment === 'main' && this.activeTabContent === 'FeedFragment') {
        Image($r('app.media.ic_visibility_on'))
          .id('menu_item_feed_toggle_played_items')
          .accessibilityText($r('app.string.feed_show_hide_streams'))
          .width(ICON_SIZE + 24)
          .height(ICON_SIZE + 24)
          .padding(12)
          .objectFit(ImageFit.Contain)
          .fillColor(COLOR_ON_PRIMARY)
          .onClick(() => {
            this.feedVisibilityRequest = this.feedVisibilityRequest + 1;
          })

        Image($r('app.media.ic_help'))
          .id('menu_item_feed_help')
          .accessibilityText($r('app.string.fast_mode'))
          .width(ICON_SIZE + 24)
          .height(ICON_SIZE + 24)
          .padding(12)
          .objectFit(ImageFit.Contain)
          .fillColor(COLOR_ON_PRIMARY)
          .onClick(() => {
            this.feedHelpRequest = this.feedHelpRequest + 1;
          })
      }

      // The OVERFLOW is always the bar's last item: in the ActionBar the ⋮ button is drawn after
      // every action icon, whichever fragment contributed them - so Subscriptions' import/export
      // menu sits to the RIGHT of MainFragment's search, not to its left. The port had it the
      // other way round, which is the only thing that differs from the reference's own bar here.
      if (this.activeFragment === 'main' && this.activeTabContent === 'SubscriptionFragment') {
        Image($r('app.media.ic_more_vert'))
          .id('more_options')
          .accessibilityText($r('app.string.more_options'))
          .width(ICON_SIZE + 24)
          .height(ICON_SIZE + 24)
          .padding(12)
          .objectFit(ImageFit.Contain)
          .fillColor(COLOR_ON_PRIMARY)
          .bindMenu(this.subscriptionImportExportMenu, SQUARE_MENU_CORNERS)
      }

    }
    .width('100%')
    .height(TOOLBAR_HEIGHT)
    .alignItems(VerticalAlign.Center)
    .backgroundColor(servicePrimaryColor(this.selectedServiceId))
  }

  /* //////////////////////////////////////////////////////////////////////////
  // Drawer - drawer_layout.xml (activity_main.xml child 2)
  ////////////////////////////////////////////////////////////////////////// */

  @Builder
  drawerPanel(): void {
    Column() {
      this.drawerHeader()
      Scroll() {
        Column() {
          // toggleServices(): the two modes are mutually exclusive - the source removes all four
          // groups and re-adds only one side of this branch.
          if (this.servicesShown) {
            ForEach(this.drawerServiceGroupExpanded, (service: StreamingService) => {
              this.serviceRow(service);
            }, (service: StreamingService) => service.getServiceId().toString())
          } else {
            ForEach(this.drawerTabGroup, (item: DrawerRoute) => {
              // ITEM_ID_HISTORY is hidden entirely when enable_watch_history_key is false.
              if (item.slug !== HISTORY_SLUG || this.watchHistoryEnabled) {
                this.drawerRow(item)
              }
            }, (item: DrawerRoute) => item.slug)
            // addDrawerMenuForCurrentService(): menu_kiosks_group is one row per the CURRENT
            // service's getAvailableKiosks() (line 301) and menu_options_about_group is added
            // after it (line 310). Both sit behind NewPipe.getService(getSelectedServiceId())
            // at line 297, so a service that cannot be resolved contributes neither.
            if (this.drawerGroupsServiceId === this.currentServiceId) {
              // NavigationView rules a divider between two NON-EMPTY menu groups (S0008:
              // 8vp space, a 1vp #D1D1D1 line, 8vp space - 51px in all).
              if (this.drawerKioskGroup.length > 0) {
                this.groupDivider()
              }
              ForEach(this.drawerKioskGroup, (kioskId: string) => {
                this.kioskRow(kioskId);
              }, (kioskId: string) => kioskId)
              this.groupDivider()
              ForEach(OPTION_ROUTES, (item: DrawerRoute) => {
                this.drawerRow(item);
              }, (item: DrawerRoute) => item.slug)
            } else {
              // S6 - the error state of the two groups above. addDrawerMenuForCurrentService()
              // resolves the service BEFORE adding them, so a getService/getKioskList throw
              // leaves the drawer with the tab rows and a silent hole where the kiosks and
              // Settings/Donate/About should be. The source explains that hole with
              // ErrorUtil.showUiErrorSnackbar (ported as the toast reportUiError already
              // raises); this is its in-place half, on the SAME text resource the snackbar
              // uses. It is the `else` of the branch above, so it can never render beside the
              // groups, and the drawer header + tab rows - the screen's chrome - stay put.
              this.drawerGroupsUnavailable()
            }
          }
        }
        .width('100%')
      }
      .layoutWeight(1)
      .width('100%')
      .scrollBar(BarState.Off)
      // A Scroll CENTRES a child shorter than its viewport. The drawer's row list is shorter than
      // the panel for every service except YouTube's tab list, so the rows were pushed down by
      // half the slack - 621px in services mode, and 20/98/254px in tabs mode under PeerTube,
      // media.ccc.de and SoundCloud, which is exactly the white band this card reports. A
      // NavigationView fills from the top, so pin the content there.
      .align(Alignment.Top)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(themedBackground(this.blackTheme))
  }

  /**
   * The kiosk + options groups could not be built for the current service. Display-only: the
   * source's snackbar has a "Report" action, but no controlInventory entry covers it here and
   * an extra tappable node on the drawer is an invented control, so this carries the message
   * only. Laid out on the same 72vp menu-item text inset as every drawer row.
   */
  @Builder
  drawerGroupsUnavailable(): void {
    Text($r('app.string.error_snackbar_message'))
      .width('100%')
      .fontSize(LABEL_TEXT_SIZE)
      .fontColor(COLOR_ICON_TINT)
      .maxLines(2)
      .textOverflow({ overflow: TextOverflow.Ellipsis })
      .padding({
        left: DRAWER_ROW_PADDING + ICON_SIZE + ICON_LABEL_GAP,
        right: DRAWER_ROW_PADDING,
        top: GROUP_GAP,
        bottom: GROUP_GAP
      })
  }

  /** The rule between two menu groups: ?android:attr/listDivider inset by 8vp top and bottom. */
  @Builder
  groupDivider(): void {
    Divider()
      .width('100%')
      .strokeWidth(1)
      .color(COLOR_DIVIDER)
      .margin({ top: GROUP_GAP, bottom: GROUP_GAP })
  }

  /**
   * drawer_header.xml. The ConstraintLayout stacks a background image, the two info rows, and a
   * full-bleed Button (drawer_header_action_button) on top - the Button is what carries the
   * click, everything under it is display-only.
   */
  @Builder
  drawerHeader(): void {
    Stack() {
      // android:background="?colorPrimary" with the background_header bitmap centerCrop over it.
      Image($r('app.media.background_header'))
        .width('100%')
        .height('100%')
        .objectFit(ImageFit.Cover)

      Column() {
        Row() {
          Image($r('app.media.splash_foreground'))
            .width(HEADER_LOGO_SIZE)
            .height(HEADER_LOGO_SIZE)
            .objectFit(ImageFit.Contain)
          // autoSizeTextType="uniform" between drawer_header_newpipe_title_min/max_text_size.
          Text($r('app.string.app_name'))
            .id('drawer_header_newpipe_title')
            .width(HEADER_TITLE_WIDTH)
            .fontSize(HEADER_TITLE_MAX_SIZE)
            .minFontSize(HEADER_TITLE_MIN_SIZE)
            .maxFontSize(HEADER_TITLE_MAX_SIZE)
            .maxLines(2)
            .heightAdaptivePolicy(TextHeightAdaptivePolicy.MAX_LINES_FIRST)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .fontWeight(FontWeight.Bold)
            .fontColor(COLOR_ON_HEADER)
            .textAlign(TextAlign.Start)
            .margin({ left: HEADER_LOGO_GAP, right: HEADER_LOGO_GAP })
        }
        .width('100%')
        .height(72)
        .padding({ left: DRAWER_ROW_PADDING, right: DRAWER_ROW_PADDING })
        .justifyContent(FlexAlign.Center)
        .alignItems(VerticalAlign.Center)

        Row() {
          Row() {
            Image(this.serviceIcon(this.currentServiceId))
              .id('drawer_header_service_icon')
              .width(HEADER_SERVICE_ICON_WIDTH)
              .height(ICON_SIZE)
              .objectFit(ImageFit.Contain)
              .fillColor(COLOR_ON_HEADER)
              .margin({ left: 6, right: 6 })
            Text(this.drawerHeaderServiceLabel)
              .id('drawer_header_service_view')
              .fontSize(HEADER_SERVICE_TEXT_SIZE)
              .fontColor(COLOR_ON_HEADER)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }
          .layoutWeight(1)
          .height(32)
          .justifyContent(FlexAlign.Center)
          .alignItems(VerticalAlign.Center)

          // toggleServices() swaps ic_arrow_drop_up / ic_arrow_drop_down.
          Image(this.servicesShown
            ? $r('app.media.ic_arrow_drop_up')
            : $r('app.media.ic_arrow_drop_down'))
            .id('drawer_arrow')
            .width(ICON_SIZE)
            .height(ICON_SIZE)
            .objectFit(ImageFit.Contain)
            .fillColor(COLOR_ON_HEADER)
            .margin({ left: 4 })
        }
        .width('100%')
        .padding({ left: 6, right: 6 })
        .margin({ top: 12 })
        .alignItems(VerticalAlign.Center)
        // @drawable/drawer_header_bottom_background: a 90-degree shape gradient, i.e. #4D000000
        // at the BOTTOM fading to transparent going up.
        .linearGradient({
          angle: 180,
          colors: [['#00000000', 0.0], ['#4D000000', 1.0]]
        })
      }
      .width('100%')
      .height('100%')
      .padding({ top: 16 })
      // android:gravity="bottom" on a column whose minHeight is drawer_header_content_min_height.
      .justifyContent(FlexAlign.End)

      // R.id.drawer_header_action_button: match_parent x 0dp constrained top-to-bottom, i.e. an
      // invisible full-header hit target laid over the icon/label/arrow.
      Row()
        .id('drawer_header_action_button')
        .accessibilityText(Localization.getString('drawer_header_description') + ' '
          + this.drawerHeaderServiceLabel)
        .width('100%')
        .height('100%')
        .onClick(() => {
          this.toggleServices();
        })
    }
    .width('100%')
    .height(DRAWER_HEADER_HEIGHT)
    .margin({ bottom: DRAWER_HEADER_GAP })
    .backgroundColor(servicePrimaryColor(this.selectedServiceId))
  }

  /** menu_history.xml's single overflow row, dispatched to the hosted fragment. */
  @Builder
  historyOverflowMenu() {
    Column() {
      Text($r('app.string.clear_views_history_title'))
        .id('action_history_clear')
        .width('100%')
        .fontSize(16)
        .fontColor($r('app.color.black'))
        .padding({ left: 16, right: 16, top: 12, bottom: 12 })
        .onClick(() => {
          this.historyClearRequest = this.historyClearRequest + 1;
        })
    }
    .width(220)
  }

  /** menu_tabs_group and menu_options_about_group rows: single-type, one row per ITEM_ID_*. */
  @Builder
  drawerRow(item: DrawerRoute): void {
    Row() {
      Image(this.rowIcon(item.slug))
        .width(ICON_SIZE)
        .height(ICON_SIZE)
        .objectFit(ImageFit.Contain)
        .fillColor(COLOR_ICON_TINT)
      Text(item.label)
        .fontSize(LABEL_TEXT_SIZE)
        .fontColor(COLOR_ON_SURFACE)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .margin({ left: ICON_LABEL_GAP })
        .layoutWeight(1)
    }
    .id(item.slug)
    .width('100%')
    .height(DRAWER_ROW_HEIGHT)
    .padding({ left: DRAWER_ROW_PADDING, right: DRAWER_ROW_PADDING })
    .alignItems(VerticalAlign.Center)
    .clickEffect(null)
    .stateStyles({ pressed: drawerRowPressed })
    .onClick(() => {
      this.drawerItemSelected(item);
    })
  }

  /**
   * menu_kiosks_group: REPEATED, one row per getAvailableKiosks() entry of the current service -
   * the count and the labels change with the service. The label is
   * KioskTranslator.getTranslatedKioskName(ks), never the raw kiosk id. Rule 12's list-row
   * exception: every row root shares one id ending in `itemroot` so the replay can resolve
   * tap-card-N by index.
   */
  @Builder
  kioskRow(kioskId: string): void {
    Row() {
      if (this.hasKioskIcon(kioskId)) {
        Image(this.kioskIcon(kioskId))
          .width(ICON_SIZE)
          .height(ICON_SIZE)
          .objectFit(ImageFit.Contain)
          .fillColor(COLOR_ICON_TINT)
      } else {
        // getKioskIcon() answered 0: the row has no glyph, but the label still sits on the
        // 72vp menu-item inset with every other row.
        Row()
          .width(ICON_SIZE)
          .height(ICON_SIZE)
      }
      Text(getTranslatedKioskName(kioskId))
        .fontSize(LABEL_TEXT_SIZE)
        .fontColor(COLOR_ON_SURFACE)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .margin({ left: ICON_LABEL_GAP })
        .layoutWeight(1)
    }
    .id('menu_kiosks_group_itemroot')
    .width('100%')
    .height(DRAWER_ROW_HEIGHT)
    .padding({ left: DRAWER_ROW_PADDING, right: DRAWER_ROW_PADDING })
    .alignItems(VerticalAlign.Center)
    .clickEffect(null)
    .stateStyles({ pressed: drawerRowPressed })
    .onClick(() => {
      this.kioskSelected(kioskId);
    })
  }

  /**
   * menu_services_group: REPEATED, one row per NewPipe.getServices(). The PeerTube row (id 3)
   * alone is retitled to the current instance name and carries the instance spinner as its
   * action view (enhancePeertubeMenu, line 460).
   */
  @Builder
  serviceRow(service: StreamingService): void {
    Row() {
      Image(this.serviceIcon(service.getServiceId()))
        .width(ICON_SIZE)
        .height(ICON_SIZE)
        .objectFit(ImageFit.Contain)
        .fillColor(COLOR_ICON_TINT)
      Text(service.getServiceId() === PEERTUBE_SERVICE_ID
        ? this.peertubeInstanceName
        : service.getServiceInfo().getName())
        .fontSize(LABEL_TEXT_SIZE)
        .fontColor(COLOR_ON_SURFACE)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .margin({ left: ICON_LABEL_GAP })
        .layoutWeight(1)
      if (service.getServiceId() === PEERTUBE_SERVICE_ID) {
        Select(this.peertubeOptions)
          .id('instance_spinner')
          .selected(this.peertubeSelectedIndex)
          // The ROW's own label above already IS the instance name (enhancePeertubeMenu retitles
          // it), so the spinner must contribute ONLY its drop-down arrow - giving it a value too
          // printed the name twice, "tchncs  tchncs v". ArkUI falls back to the selected option's
          // text when `value` is unset, so the empty string is set explicitly rather than omitted.
          .value('')
          .font({ size: LABEL_TEXT_SIZE })
          .fontColor(COLOR_ON_SURFACE)
          .onSelect((index: number) => {
            this.peertubeInstanceSelected(index);
          })
      }
    }
    .id('menu_services_group_itemroot')
    .width('100%')
    .height(DRAWER_ROW_HEIGHT)
    .padding({ left: DRAWER_ROW_PADDING, right: DRAWER_ROW_PADDING })
    .alignItems(VerticalAlign.Center)
    // changeService(): setChecked(true) on the newly-selected service item / setChecked(false)
    // on the old one - the NavigationView highlights the checked row. app.color.light_selected_
    // color is the app's own checked/selected-item colour (colors.xml, paired with
    // selector_checked_light.xml's android:state_checked item).
    .backgroundColor(service.getServiceId() === this.currentServiceId
      ? $r('app.color.selected')
      : Color.Transparent)
    .clickEffect(null)
    .stateStyles({ pressed: drawerRowPressed })
    .onClick(() => {
      this.changeService(service.getServiceId());
    })
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      // The slots are wrapped in arrow functions on purpose: passing `this.contentArea` directly
      // rebinds `this` to the CHILD, and both builders read this page's own state.
      FocusAwareDrawerLayout({
        drawerOpen: $drawerOpen,
        drawerLocked: this.activeFragment !== 'main',
        contentSlot: () => {
          this.contentArea();
        },
        drawerSlot: () => {
          this.drawerPanel();
        }
      })

      // FocusOverlayView.setupFocusObserver(this) - decor-view overlay, TV builds only.
      FocusOverlayView({ isTv: this.isTv })

      // PoTokenWebView: an off-screen WebView, never part of the visible hierarchy, and
      // created only once a poToken is actually needed (PoTokenProviderImpl.kt:80).
      if (this.poTokenWebViewNeeded) {
        PoTokenWebView()
          .hitTestBehavior(HitTestMode.Transparent)
      }
    }
    .id('MainActivityPage')
    .width('100%')
    .height('100%')
  }
}
