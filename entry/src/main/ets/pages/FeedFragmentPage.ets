/**
 * S4 — FeedFragment (screen_feed), structure from fragment_feed.xml + FeedFragment.kt.
 *
 * The only list screen here that does not use InfoListAdapter: a Groupie list of StreamItem over
 * the LOCAL database (StreamWithState), so rows carry a saved watch position. It is NOT
 * paginated — handleLoadedState() replaces the whole list in one updateAsync().
 *
 * THREE refresh affordances all route to reloadContent(): the refresh header (refresh_root_view),
 * swipe-to-refresh (swipeRefreshLayout) and the error panel's retry button.
 *
 * handleResult(result) is a three-way branch over FeedState — ProgressState (determinate bar +
 * counter), LoadedState (the list, or the empty state when it is empty) and ErrorState (the error
 * panel).
 *
 * S4 wiring: FeedViewModel has no port of its own — its two halves are the FeedDatabase query
 * (getStreams / oldestSubscriptionUpdate / notLoadedCount, filtered by the three visibility
 * preferences) and FeedLoader, which is what FeedLoadService started. onViewCreated only OBSERVES,
 * so opening the screen renders what the database already holds and starts no network load; only
 * reloadContent() does that.
 *
 * S5 — styled from results/traversal-source/pages/fragment_FeedFragment/*.png plus the source
 * layouts (fragment_feed.xml, list_empty_view.xml, error_panel.xml) and the app-level style
 * baseline in state.json generation.styleBaseline. Style only: no control was added, removed,
 * re-bound or re-presented.
 */
import { display, router, promptAction } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

import { GRID_LANE_MIN_WIDTH, GRID_LANE_MAX_WIDTH } from '../components/InfoListAdapter';
import { StreamItem as StreamItemData, ItemVersion, isAudioStream, isLiveStream }
  from '../model/app/StreamItem';
import { ItemViewMode } from '../components/InfoListAdapter';
import { resolveItemViewMode } from '../common/settings/ViewModeResolver';
import { LoadedState } from '../model/app/FeedState';
import { StreamItem, StreamItemDataSource } from '../components/StreamItem';
import { buildStreamMenuActions, DialogAction, InfoItemDialog, StreamMenuHandlers,
  StreamMenuTarget } from '../components/InfoItemDialog';
import { enqueueNextStream } from '../common/util/StreamRowActions';
import { PlaylistDialog } from '../components/PlaylistDialog';
import { PlaylistAppendDialog } from '../components/PlaylistAppendDialog';
import { PlaylistCreationDialog } from '../components/PlaylistCreationDialog';

import { AppDatabase } from '../common/db/AppDatabase';
import { FeedDatabase, FeedLoader, FeedLoadProgress } from '../common/feed/FeedLoader';
import { FeedUpdateInfo } from '../model/app/FeedUpdateInfo';
import { SubscriptionDao, SubscriptionManager } from '../common/db/SubscriptionManager';
import { HistoryRecordManager } from '../common/db/HistoryRecordManager';
import { LocalPlaylistManager, playlistAppendToast } from '../common/db/PlaylistManager';
import { enqueueOnCurrentPlayQueue } from '../model/app/PlayQueue';
import { PlayQueueItem } from '../model/app/PlayQueueItem';
import { ServiceLocator } from '../common/di/ServiceLocator';
import { ExtractorHelper } from '../common/extractor/ExtractorHelper';
import { StreamInfo } from '../model/extractor/StreamInfo';
import { PlayerService } from '../common/player/PlayerService';
import { PlayerPrefs } from '../common/player/PlayerPrefs';

import { MediaSessionService } from '../common/player/MediaSessionService';
import { openPopupOnSurface, PopupPlayerSurface } from '../components/PopupPlayerSurface';
import { DownloadDialogHost } from './DownloadDialogPage';
import { BackgroundWorkMode } from '../common/background/BackgroundWork';
import { CompositeDisposable, Disposable } from '../common/rx/Rx';
import {
  CancellableProgress, FEED_LOAD_CANCEL_EVENT, FEED_LOAD_NOTIFICATION_ID
} from '../common/notify/Notifications';
import { Localization } from '../common/i18n/Localization';
import { Preferences } from '../common/prefs/Preferences';
import {
  feed_show_watched_items_key,
  feed_show_partially_watched_items_key,
  feed_show_future_items_key,
  feed_use_dedicated_fetch_method_key,
  list_view_mode_key,
  list_view_mode_value,
} from '../common/prefs/SettingsKeys';
import { FeedGroupEntity } from '../model/db/entity/FeedGroupEntity';
import { StreamEntity } from '../model/db/entity/StreamEntity';
import { SubscriptionEntity } from '../model/db/entity/SubscriptionEntity';
import { StreamWithState } from '../model/db/view/StreamWithState';
import { PlaylistMetadataEntry } from '../model/db/view/PlaylistMetadataEntry';
import { servicePrimaryColor, DIALOG_MASK_COLOR } from '../common/theme/ServiceTheme';
import { MiniPlayerBar } from '../components/MiniPlayerBar';
import { BLACK_THEME_KEY, themedBackground } from '../common/theme/ThemeBackground';

const TAG: string = 'FeedFragmentPage';

/* S5 — baseline tokens (state.json generation.styleBaseline, source S0004). */
const C_ON_SURFACE: Resource = $r('app.color.on_surface');
const C_SECONDARY: Resource = $r('app.color.on_surface_variant');
/* AlertDialog metrics measured off menu_menu_item_feed_toggle_played_items.png. */
const DIALOG_WIDTH: string = '86%';
const DIALOG_PADDING: number = 24;
const DIALOG_RADIUS: number = 4;
const DIALOG_CHOICE_HEIGHT: number = 48;
const DIALOG_CHOICE_GAP: number = 24;
/**
 * What the dialog's padding and button bar take from the window: AlertDialog lets the message
 * grow until the whole window is the screen, and only then scrolls it.
 */
const DIALOG_CHROME_HEIGHT: number = 220;


/**
 * The fragment arguments NavigationHelper passes on: openVideoDetailFragment(serviceId, url,
 * title) and openChannelFragment(serviceId, url, name) take the same three. ArkTS has no untyped
 * object literals, so the router params are a declared class.
 */
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

/** FeedState's three shapes, as handleResult() switches on them. */
export enum FeedRenderState {
  PROGRESS,
  LOADED,
  ERROR
}

/**
 * The port's loader reports a failed subscription as `serviceId:url: message` (FeedLoader
 * loadStreams()'s catch), which is what handleItemsErrors() needs to find the row the source
 * looked up by `t.subscriptionId`.
 */
class SubscriptionRef {
  readonly serviceId: number;
  readonly url: string;

  constructor(serviceId: number, url: string) {
    this.serviceId = serviceId;
    this.url = url;
  }
}

/**
 * showStreamVisibilityDialog(): AlertDialog.setMultiChoiceItems over the three feed filters.
 * OK writes them back through the view model; Cancel is a null listener, so the page re-reads
 * the preferences and the live edits are discarded.
 */
@CustomDialog
struct FeedVisibilityDialog {
  /** ?attr/colorPrimary follows the service the drawer selected. */
  @StorageProp('mainSelectedServiceId') activeServiceId: number = 0;
  controller?: CustomDialogController;
  @Link showPlayed: boolean;
  @Link showPartiallyPlayed: boolean;
  @Link showFuture: boolean;
  onConfirm: () => void = (): void => {
    hilog.debug(0x0000, TAG, 'FeedVisibilityDialog: OK not bound');
  };
  onCancel: () => void = (): void => {
    hilog.debug(0x0000, TAG, 'FeedVisibilityDialog: Cancel not bound');
  };


  build() {
    Column() {
      // AlertDialog title: 20sp, 24dp inset, 24dp above the choice list.
      Text($r('app.string.feed_hide_streams_title'))
        .id('feed_hide_streams_title')
        .width('100%')
        .fontSize(20)
        .fontColor(C_ON_SURFACE)
        .margin({ bottom: 16 })

      Row({ space: DIALOG_CHOICE_GAP }) {
        // Decoration only: out of the a11y tree and out of the hit test, so the ROW below
        // stays the choice's single interactive node — as setMultiChoiceItems' row is.
        Checkbox()
          .width(20)
          .height(20)
          .shape(CheckBoxShape.ROUNDED_SQUARE)
          .selectedColor(servicePrimaryColor(this.activeServiceId))
          .select(this.showPlayed)
          .hitTestBehavior(HitTestMode.None)
          .accessibilityLevel('no')
        Text($r('app.string.feed_show_watched'))
          .fontSize(16)
          .fontColor(C_ON_SURFACE)
      }
      .id('feed_show_watched')
      .width('100%')
      .height(DIALOG_CHOICE_HEIGHT)
      .alignItems(VerticalAlign.Center)
      .onClick(() => {
        this.showPlayed = !this.showPlayed;
      })

      Row({ space: DIALOG_CHOICE_GAP }) {
        // Decoration only: out of the a11y tree and out of the hit test, so the ROW below
        // stays the choice's single interactive node — as setMultiChoiceItems' row is.
        Checkbox()
          .width(20)
          .height(20)
          .shape(CheckBoxShape.ROUNDED_SQUARE)
          .selectedColor(servicePrimaryColor(this.activeServiceId))
          .select(this.showPartiallyPlayed)
          .hitTestBehavior(HitTestMode.None)
          .accessibilityLevel('no')
        Text($r('app.string.feed_show_partially_watched'))
          .fontSize(16)
          .fontColor(C_ON_SURFACE)
      }
      .id('feed_show_partially_watched')
      .width('100%')
      .height(DIALOG_CHOICE_HEIGHT)
      .alignItems(VerticalAlign.Center)
      .onClick(() => {
        this.showPartiallyPlayed = !this.showPartiallyPlayed;
      })

      Row({ space: DIALOG_CHOICE_GAP }) {
        // Decoration only: out of the a11y tree and out of the hit test, so the ROW below
        // stays the choice's single interactive node — as setMultiChoiceItems' row is.
        Checkbox()
          .width(20)
          .height(20)
          .shape(CheckBoxShape.ROUNDED_SQUARE)
          .selectedColor(servicePrimaryColor(this.activeServiceId))
          .select(this.showFuture)
          .hitTestBehavior(HitTestMode.None)
          .accessibilityLevel('no')
        Text($r('app.string.feed_show_upcoming'))
          .fontSize(16)
          .fontColor(C_ON_SURFACE)
      }
      .id('feed_show_upcoming')
      .width('100%')
      .height(DIALOG_CHOICE_HEIGHT)
      .alignItems(VerticalAlign.Center)
      .onClick(() => {
        this.showFuture = !this.showFuture;
      })

      // AlertDialog button bar: borderless, end-aligned, ?attr/colorAccent text.
      Row({ space: 8 }) {
        Button($r('app.string.cancel'))
          .id('Cancel')
          .type(ButtonType.Normal)
          .backgroundColor(Color.Transparent)
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.accent'))
          .padding({ left: 8, right: 8, top: 8, bottom: 8 })
          .onClick(() => {
            this.onCancel();
            this.controller?.close();
          })
        Button($r('app.string.ok'))
          .id('OK')
          .type(ButtonType.Normal)
          .backgroundColor(Color.Transparent)
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.accent'))
          .padding({ left: 8, right: 8, top: 8, bottom: 8 })
          .onClick(() => {
            this.onConfirm();
            this.controller?.close();
          })
      }
      .width('100%')
      .margin({ top: 8 })
      .justifyContent(FlexAlign.End)
    }
    .width(DIALOG_WIDTH)
    .padding(DIALOG_PADDING)
    .backgroundColor($r('app.color.dialog_surface'))
    .borderRadius(DIALOG_RADIUS)
    .alignItems(HorizontalAlign.Start)
  }
}

/**
 * menu_item_feed_help: the fast-mode explanation, with a neutral button that flips the
 * feed_use_dedicated_fetch_method preference and a positive OK with a null listener.
 */
@CustomDialog
struct FastModeHelpDialog {
  controller?: CustomDialogController;
  @Link usingDedicatedMethod: boolean;
  onToggleFastMode: () => void = (): void => {
    hilog.debug(0x0000, TAG, 'FastModeHelpDialog: neutral button not bound');
  };

  build() {
    Column() {
      // AlertDialog message body: 16sp, secondary-weight ink. AlertDialog puts the message in a
      // ScrollView and caps the window at the screen, so a message longer than the screen scrolls
      // INSIDE the dialog. Drawn as a bare Text the dialog grew to the text's full height, and on
      // a folded device that is taller than the screen: the title and the whole button bar were
      // pushed off, which is what "cannot be displayed at the correct size" means - and why
      // unfolding it looked correct. A single-row List is this screen's shrink-to-content-then-
      // scroll container (PlaylistAppendDialog uses the same one for its rows).
      List() {
        ListItem() {
          Text($r('app.string.feed_use_dedicated_fetch_method_help_text'))
            .id('feed_use_dedicated_fetch_method_help_text')
            .width('100%')
            // Left at 16 deliberately. The first line wraps at the same word as the reference's
            // ("...is too"), so the glyphs are the right size for this column; raising it to 18
            // was tried and made the port show LESS of the message, not more. What actually
            // differs is measured on the card: a narrower column, and a clamped, scrolling block
            // where the reference shows the whole text.
            .fontSize(16)
            // The reference's message reads #212121 - the primary ink, not the secondary grey.
            .fontColor(C_ON_SURFACE)
        }
      }
      .width('100%')
      .constraintSize({
        maxHeight: this.getUIContext().px2vp(display.getDefaultDisplaySync().height)
          - DIALOG_CHROME_HEIGHT
      })
      // AlertDialog's ScrollView draws no bar over the message.
      .scrollBar(BarState.Off)

      Row({ space: 8 }) {
        // setNeutralButton(enable/disable fast mode) — start-aligned in the button bar.
        // android:textAllCaps: the reference reads ENABLE FAST MODE and OK.
        Button(this.usingDedicatedMethod
          ? Localization.buttonLabel('feed_use_dedicated_fetch_method_disable_button')
          : Localization.buttonLabel('feed_use_dedicated_fetch_method_enable_button'))
          .id('feed_use_dedicated_fetch_method_toggle_button')
          .type(ButtonType.Normal)
          .backgroundColor(Color.Transparent)
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.accent'))
          .padding({ left: 8, right: 8, top: 8, bottom: 8 })
          .onClick(() => {
            this.onToggleFastMode();
            this.controller?.close();
          })

        Blank()

        // setPositiveButton(ok, null): the source passes NO listener — dismiss only.
        // android:textAllCaps: measured on the reference as OK.
        Button(Localization.buttonLabel('ok'))
          .id('OK')
          .type(ButtonType.Normal)
          .backgroundColor(Color.Transparent)
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.accent'))
          .padding({ left: 8, right: 8, top: 8, bottom: 8 })
          .onClick(() => {
            this.controller?.close();
          })
      }
      .width('100%')
      .margin({ top: 16 })
    }
    .width(DIALOG_WIDTH)
    .padding(DIALOG_PADDING)
    .backgroundColor($r('app.color.dialog_surface'))
    .borderRadius(DIALOG_RADIUS)
    .alignItems(HorizontalAlign.Start)
  }
}

/**
 * The per-subscription dialog handleFeedNotAvailable() raises for a load error whose cause is a
 * ContentNotAvailableException: Unsubscribe / Cancel, plus the disable-fast-mode neutral button
 * only while fast mode is on.
 */
@CustomDialog
struct FeedLoadErrorDialog {
  controller?: CustomDialogController;
  @Link message: string;
  @Link fastModeOn: boolean;
  onUnsubscribe: () => void = (): void => {
    hilog.debug(0x0000, TAG, 'FeedLoadErrorDialog: unsubscribe not bound');
  };
  onDisableFastMode: () => void = (): void => {
    hilog.debug(0x0000, TAG, 'FeedLoadErrorDialog: disable fast mode not bound');
  };
  onCancel: () => void = (): void => {
    hilog.debug(0x0000, TAG, 'FeedLoadErrorDialog: cancel not bound');
  };

  build() {
    Column() {
      Text($r('app.string.feed_load_error'))
        .id('feed_load_error_title')
        .width('100%')
        .fontSize(20)
        .fontColor(C_ON_SURFACE)
        .margin({ bottom: 16 })

      Text(this.message)
        .id('feed_load_error_message')
        .width('100%')
        .fontSize(16)
        .fontColor(C_SECONDARY)

      Row({ space: 8 }) {
        // setNegativeButton(cancel, null) still continues with the remaining errors.
        Button($r('app.string.cancel'))
          .id('Cancel')
          .type(ButtonType.Normal)
          .backgroundColor(Color.Transparent)
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.accent'))
          .padding({ left: 8, right: 8, top: 8, bottom: 8 })
          .onClick(() => {
            this.onCancel();
            this.controller?.close();
          })

        if (this.fastModeOn) {
          Button($r('app.string.feed_use_dedicated_fetch_method_disable_button'))
            .id('feed_use_dedicated_fetch_method_disable_button')
            .type(ButtonType.Normal)
            .backgroundColor(Color.Transparent)
            .fontSize(14)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.accent'))
            .padding({ left: 8, right: 8, top: 8, bottom: 8 })
            .onClick(() => {
              this.onDisableFastMode();
              this.controller?.close();
            })
        }

        Button($r('app.string.unsubscribe'))
          .id('Unsubscribe')
          .type(ButtonType.Normal)
          .backgroundColor(Color.Transparent)
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.accent'))
          .padding({ left: 8, right: 8, top: 8, bottom: 8 })
          .onClick(() => {
            this.onUnsubscribe();
            this.controller?.close();
          })
      }
      .width('100%')
      .margin({ top: 16 })
      .justifyContent(FlexAlign.End)
    }
    .width(DIALOG_WIDTH)
    .padding(DIALOG_PADDING)
    .backgroundColor($r('app.color.dialog_surface'))
    .borderRadius(DIALOG_RADIUS)
    .alignItems(HorizontalAlign.Start)
  }
}


@Entry
@Component
export struct FeedFragmentPage {
  /** ThemeHelper's black theme: the window background follows it. */
  @StorageProp(BLACK_THEME_KEY) blackTheme: boolean = false;

  /** groupAdapter's backing list — FeedState.LoadedState.items, filled by loadFeed(). */
  @State feedList: StreamItemDataSource = new StreamItemDataSource();

  /** handleResult(): which of the three FeedState shapes is rendering. */
  @State feedState: FeedRenderState = FeedRenderState.PROGRESS;
  @State isLoading: boolean = true;
  @State errorInfo: string | null = null;
  /** loadedState.items.isEmpty() -> showEmptyState() instead of hideLoading(). */
  @State items: number = 0;
  /** ProgressState.currentProgress / maxProgress; -1/-1 means indeterminate. */
  @State loadProgress: number = -1;
  @State loadProgressMax: number = -1;
  /** ProgressState.progressMessage: shown INSTEAD of the counter while indeterminate. */
  @State progressMessage: string = '';
  /** getString(feed_oldest_subscription_update, relativeTime(oldestUpdate) ?: em dash). */
  @State oldestSubscriptionUpdate: string = '';
  /** refresh_subtitle_text is VISIBLE only while notLoadedCount > 0. */
  @State notLoadedCount: number = 0;
  /** KEY_GROUP_NAME — the feed group this instance shows, '' for the all-subscriptions feed. */
  @State groupName: string = '';
  /**
   * setUseAsFrontPage(true): MainFragment's pager sets it on the fragment it hosts. A front-page
   * fragment has no bar of its own - its title and its menu go into the ACTIVITY's toolbar, which
   * is the one ActionBar onCreateOptionsMenu writes into either way. Reached from the drawer this
   * page IS the whole screen, so it keeps its own toolbar and its Up button.
   *
   * Not `mainShellOwnsToolbar`: that flag stays true under a pushed page, so the drawer route
   * would lose its bar as well.
   */
  @Prop useAsFrontPage: boolean = false;
  /**
   * menu_feed_fragment's two items while the shell owns the bar. The shell draws them and bumps
   * a counter here, the same channel mainSearchRequest and mainHistoryClearRequest already use.
   */
  @StorageProp('mainFeedVisibilityRequest') @Watch('onVisibilityRequested')
  private visibilityRequest: number = 0;
  @StorageProp('mainFeedHelpRequest') @Watch('onHelpRequested')
  private helpRequest: number = 0;
  /** supportActionBar.subtitle = groupName, cleared again in onDestroyOptionsMenu. */
  @State actionBarSubtitle: string = '';
  /** highlightCount > 0 slides the new-items button up; it hides on scroll-to-top. */
  @State lastNewItemsCount: number = 0;
  /** showLoading/hideLoading drive it; row taps are IGNORED while it is true. */
  @State isRefreshing: boolean = false;
  /** setupListViewMode(): the user's list/grid preference picks the StreamItem.ItemVersion. */
  @State itemVersion: ItemVersion = ItemVersion.NORMAL;
  /**
   * AppearanceSettingsFragmentPage publishes the chosen list_view_mode here right after it writes
   * the preference, so a page that is ALREADY drawn re-reads it instead of keeping the template it
   * was built with. @Watch never fires on init, so aboutToAppear's own read still stands.
   */
  @StorageProp('listViewMode') @Watch('setupListViewMode')
  private listViewModeSignal: string = '';
  /** The fast-mode preference, read by both the help dialog and the load-error dialog. */
  @State usingDedicatedMethod: boolean = false;
  /**
   * highlightNewItemsAfter(updateTime): the upload-date cut-off each row is compared against —
   * the oldest subscription update as it was BEFORE this load. -1 means there was none, and the
   * source then highlights nothing.
   */
  @State uploadDate: number = -1;
  /** getShowPlayedItemsFromPreferences() and its two siblings — all default true. */
  @State showPlayed: boolean = true;
  @State showPartiallyPlayed: boolean = true;
  @State showFuture: boolean = true;
  /** handleFeedNotAvailable(): the message built for the subscription that failed. */
  @State loadErrorMessage: string = '';
  /** ?attr/colorPrimary follows the drawer's service; see servicePrimaryColor(). */
  @StorageProp('mainSelectedServiceId') activeServiceId: number = 0;

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

  /** showInfoItemDialog(item): the long-press menu the row opens. */
  @State menuTitle: string = '';
  @State menuActions: DialogAction[] = [];
  /** PlaylistDialog: the append branch exists only when there is a playlist to append to. */
  @State hasPlaylists: boolean = false;
  @State appendPlaylists: PlaylistMetadataEntry[] = [];

  /** newInstance(groupId, groupName) — the fragment arguments. */
  private groupId: number = FeedGroupEntity.GROUP_ALL_ID;
  /** oldestSubscriptionUpdate, kept unformatted for the next highlight pass. */
  private oldestUpdate: number | null = null;

  private database: AppDatabase | null = null;
  private feedDatabase: FeedDatabase | null = null;
  private feedLoader: FeedLoader | null = null;
  /**
   * FeedLoadService.loadingDisposable: non-null while a load runs, and onStartCommand returns
   * START_NOT_STICKY without starting a second one. See startFeedLoad().
   */
  private feedLoadInFlight: boolean = false;
  /**
   * hideNewItemsLoadedHandler: the source posts hideNewItemsLoaded(true) ten seconds after the
   * button appears, so the banner goes away on its own even if the user never scrolls back up.
   * -1 when nothing is pending.
   */
  private hideNewItemsTimer: number = -1;
  private subscriptionManager: SubscriptionManager | null = null;
  private historyRecordManager: HistoryRecordManager | null = null;
  private playlistManager: LocalPlaylistManager | null = null;
  private disposables: CompositeDisposable = new CompositeDisposable();

  /** FeedResultsHolder.itemsErrors, and where handleItemsErrors() got to in them. */
  private itemsErrors: Error[] = [];
  private pendingErrorIndex: number = 0;
  private pendingSubscription: SubscriptionEntity | null = null;
  /** The row the long-press menu is acting on. */
  private menuTarget: StreamEntity | null = null;

  /**
   * onOptionsItemSelected(menu_item_feed_toggle_played_items). Only the hosted instance answers:
   * a feed page sitting under a pushed route still holds its own bar and must not react to the
   * shell's.
   */
  private onVisibilityRequested(): void {
    if (this.useAsFrontPage && this.visibilityRequest > 0) {
      this.visibilityDialog.open();
    }
  }

  /** onOptionsItemSelected(menu_item_feed_help). */
  private onHelpRequested(): void {
    if (this.useAsFrontPage && this.helpRequest > 0) {
      this.fastModeDialog.open();
    }
  }

  private listScroller: Scroller = new Scroller();
  /**
   * The first visible row of items_list, as of the last onScrollIndex. The source's hide-on-top
   * rule is an OnScrollListener, which fires only when the user actually SCROLLS; ArkUI's
   * onScrollIndex also fires when the data source is replaced, so the index has to be compared
   * with the previous one to tell a scroll back to the top from a re-layout that was already
   * there. Not @State: nothing renders from it.
   */
  private firstVisibleIndex: number = 0;

  private visibilityDialog: CustomDialogController = new CustomDialogController({
    maskColor: DIALOG_MASK_COLOR,
    builder: FeedVisibilityDialog({
      showPlayed: $showPlayed,
      showPartiallyPlayed: $showPartiallyPlayed,
      showFuture: $showFuture,
      onConfirm: (): void => {
        this.applyStreamVisibility();
      },
      onCancel: (): void => {
        // setNegativeButton(cancel, null): the edits were never applied, so re-read them.
        this.loadVisibilityPreferences();
      }
    }),
    // S5: the panel itself is drawn by the struct (white, 4vp radius) so it matches the
    // AlertDialog in menu_menu_item_feed_toggle_played_items.png rather than the system shell.
    customStyle: true,
    alignment: DialogAlignment.Center
  });

  private fastModeDialog: CustomDialogController = new CustomDialogController({
    maskColor: DIALOG_MASK_COLOR,
    builder: FastModeHelpDialog({
      usingDedicatedMethod: $usingDedicatedMethod,
      onToggleFastMode: (): void => {
        this.setFastMode(!this.usingDedicatedMethod);
      }
    }),
    customStyle: true,
    alignment: DialogAlignment.Center
  });

  private loadErrorDialog: CustomDialogController = new CustomDialogController({
    maskColor: DIALOG_MASK_COLOR,
    builder: FeedLoadErrorDialog({
      message: $loadErrorMessage,
      fastModeOn: $usingDedicatedMethod,
      onUnsubscribe: (): void => {
        this.unsubscribeFailedSubscription();
      },
      onDisableFastMode: (): void => {
        this.setFastMode(false);
      },
      onCancel: (): void => {
        // handleFeedNotAvailable() carries on with the errors it was handed either way.
        this.handleItemsErrors(this.pendingErrorIndex + 1);
      }
    }),
    customStyle: true,
    alignment: DialogAlignment.Center
  });

  /** onItemLongClick -> showInfoItemDialog(stream.toStreamInfoItem()). */
  private infoItemDialog: CustomDialogController = new CustomDialogController({
    maskColor: DIALOG_MASK_COLOR,
    builder: InfoItemDialog({ title: this.menuTitle, actions: this.menuActions })
  });

  /**
   * The InfoItemDialog's "append to playlist" branch: the chooser, then either the picker over
   * the user's local playlists or straight to creation when there are none.
   */
  private playlistDialog: CustomDialogController = new CustomDialogController({
    maskColor: DIALOG_MASK_COLOR,
    builder: PlaylistDialog({
      hasPlaylists: this.hasPlaylists,
      onAppend: (): void => {
        this.openAppendDialog();
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
      playlists: this.appendPlaylists,
      onSelected: (playlist: PlaylistMetadataEntry): void => {
        this.appendToPlaylist(playlist);
      },
      onNewPlaylist: (): void => {
        this.creationDialog.open();
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
        this.createPlaylistWithTarget(name);
      }
    })
  });

  /* //////////////////////////////////////////////////////////////////////////
  // Lifecycle
  ////////////////////////////////////////////////////////////////////////// */

  aboutToAppear(): void {
    this.readArguments();
    this.startUp();
  }

  /** onDestroy(): dispose the loader subscription and cancel a load in flight (Rule 8). */
  aboutToDisappear(): void {
    const loader: FeedLoader | null = this.feedLoader;
    if (loader !== null) {
      loader.cancel();
    }
    this.disposables.dispose();
    this.clearHideNewItemsTimer();
  }

  /** newInstance(groupId, groupName): KEY_GROUP_ID and KEY_GROUP_NAME. */
  private readArguments(): void {
    const params: Record<string, Object> | undefined =
      router.getParams() as Record<string, Object> | undefined;
    if (params === undefined || params === null) {
      return;
    }
    const id: Object | undefined = params['groupId'];
    if (id !== undefined && id !== null) {
      this.groupId = Number(id.toString());
    }
    const name: Object | undefined = params['groupName'];
    if (name !== undefined && name !== null) {
      this.groupName = name.toString();
      // activity.supportActionBar?.subtitle = groupName.
      this.actionBarSubtitle = this.groupName;
    }
  }

  /**
   * onViewCreated(): the view model is created and OBSERVED. Its first emission is whatever the
   * database already holds, so opening the screen starts no network load.
   */
  private async startUp(): Promise<void> {
    await this.setupListViewMode();
    await this.loadVisibilityPreferences();
    this.usingDedicatedMethod =
      await Preferences.getBoolean(feed_use_dedicated_fetch_method_key, false);
    await this.loadFeed();
  }

  /**
   * setupListViewMode() -> ThemeHelper.getItemViewMode(): GRID and CARD pick their own
   * StreamItem.ItemVersion, everything else stays NORMAL.
   */
  private async setupListViewMode(): Promise<void> {
    const mode: string = await Preferences.getString(list_view_mode_key,
      Preferences.instance().resolveDefault(list_view_mode_value));
    // The decision is the shared one; only the enum this screen draws with differs.
    const resolved: ItemViewMode = resolveItemViewMode(mode);
    if (resolved === ItemViewMode.GRID) {
      this.itemVersion = ItemVersion.GRID;
    } else if (resolved === ItemViewMode.CARD) {
      this.itemVersion = ItemVersion.CARD;
    } else {
      this.itemVersion = ItemVersion.NORMAL;
    }
  }

  /** FeedViewModel.getShow*ItemsFromPreferences() — every one of them defaults to true. */
  private async loadVisibilityPreferences(): Promise<void> {
    this.showPlayed = await Preferences.getBoolean(feed_show_watched_items_key, true);
    this.showPartiallyPlayed =
      await Preferences.getBoolean(feed_show_partially_watched_items_key, true);
    this.showFuture = await Preferences.getBoolean(feed_show_future_items_key, true);
  }

  /* //////////////////////////////////////////////////////////////////////////
  // Services
  ////////////////////////////////////////////////////////////////////////// */

  private async ensureServices(): Promise<FeedDatabase | null> {
    const existing: FeedDatabase | null = this.feedDatabase;
    if (existing !== null) {
      return existing;
    }
    try {
      const context: common.Context = getContext(this) as common.Context;
      const db: AppDatabase = await AppDatabase.getInstance(context);
      this.database = db;
      const feedDb: FeedDatabase = new FeedDatabase(db);
      this.feedDatabase = feedDb;
      this.subscriptionManager = new SubscriptionManager(db);
      this.historyRecordManager = new HistoryRecordManager(db);
      this.playlistManager = new LocalPlaylistManager(db);
      return feedDb;
    } catch (err) {
      const failure: BusinessError = err as BusinessError;
      this.handleErrorState(new Error(failure.message));
      return null;
    }
  }

  /** FeedLoadService — the loader plus the ProgressEvents the service published. */
  private async ensureLoader(): Promise<FeedLoader | null> {
    const existing: FeedLoader | null = this.feedLoader;
    if (existing !== null) {
      return existing;
    }
    if (await this.ensureServices() === null) {
      return null;
    }
    const database: AppDatabase | null = this.database;
    if (database === null) {
      return null;
    }
    const loader: FeedLoader = new FeedLoader(database);
    this.feedLoader = loader;
    // handleProgressState(): the counter and the determinate/indeterminate bar.
    this.disposables.add(loader.progress.subscribeCallbacks((progress: FeedLoadProgress): void => {
      this.loadProgress = progress.currentProgress;
      this.loadProgressMax = progress.maxProgress;
      this.progressMessage = '';
      this.feedState = FeedRenderState.PROGRESS;
    }, (error: Error): void => {
      this.handleErrorState(error);
    }));
    return loader;
  }

  /* //////////////////////////////////////////////////////////////////////////
  // Load
  ////////////////////////////////////////////////////////////////////////// */

  /**
   * The view model's own query: FeedDAO.getStreams() filtered by the three visibility
   * preferences, plus the two counters the header shows.
   */
  private async loadFeed(): Promise<void> {
    const feedDb: FeedDatabase | null = await this.ensureServices();
    if (feedDb === null) {
      return;
    }
    try {
      const streams: StreamWithState[] = await feedDb.getStreams(this.groupId, this.showPlayed,
        this.showPartiallyPlayed, this.showFuture);
      const rows: StreamItemData[] = [];
      for (const stream of streams) {
        rows.push(new StreamItemData(stream, this.itemVersion));
      }
      const oldest: number | null = await feedDb.oldestSubscriptionUpdate(this.groupId);
      const notLoaded: number = await feedDb.notLoadedCount(this.groupId);
      this.handleLoadedState(new LoadedState(rows, oldest, notLoaded, this.itemsErrors));
    } catch (err) {
      const failure: BusinessError = err as BusinessError;
      this.handleErrorState(new Error(failure.message));
    }
  }

  /** setOnClickListener { reloadContent() } — the header, the swipe and retry all land here. */
  private reloadContent(): void {
    this.hideNewItemsLoaded();
    this.showLoading();
    this.startFeedLoad();
  }

  /** showLoading(): the list is hidden, the progress text appears, isRefreshing goes true. */
  private showLoading(): void {
    this.isLoading = true;
    this.isRefreshing = true;
    this.errorInfo = null;
    this.loadProgress = -1;
    this.loadProgressMax = -1;
    this.progressMessage = '';
    this.feedState = FeedRenderState.PROGRESS;
  }

  /**
   * startService(FeedLoadService) for this group, then re-read what it wrote.
   *
   * `FeedLoadService.onStartCommand` returns START_NOT_STICKY when `loadingDisposable != null`,
   * so a second startService while a load runs is a NO-OP on Android. The port had no such guard,
   * and a second refresh re-entered the same FeedLoader over the same AppDatabase: the two
   * overlapping runInTransaction() calls join one shared transaction object, the first commits it
   * out from under the second, and the second's next read raises "The RdbStore or ResultSet is
   * already closed" — which killed the process on every double refresh.
   */
  private async startFeedLoad(): Promise<void> {
    if (this.feedLoadInFlight) {
      return;
    }
    const loader: FeedLoader | null = await this.ensureLoader();
    if (loader === null) {
      return;
    }
    this.feedLoadInFlight = true;
    // FeedLoadService's "Loading feed…" row, whose Cancel calls feedLoadManager.cancel().
    const notification: CancellableProgress = new CancellableProgress(
      ServiceLocator.get().notifications, FEED_LOAD_NOTIFICATION_ID, FEED_LOAD_CANCEL_EVENT);
    await notification.start((): void => {
      loader.cancel();
    });
    const notificationUpdates: Disposable = loader.progress.subscribeCallbacks(
      (progress: FeedLoadProgress): void => {
        notification.update(Localization.getString('feed_notification_loading'),
          FeedFragmentPage.notificationText(progress));
      });
    try {
      try {
        // FeedLoadService is a foreground service: the load holds the DATA_TRANSFER continuous
        // task so it survives the app going to the background, and releases it in finally.
        await ServiceLocator.get().backgroundWork.runWithBackgroundTask(
          BackgroundWorkMode.DATA_TRANSFER, (): Promise<FeedUpdateInfo[]> => {
            return loader.startLoading(this.groupId, true);
          });
        this.itemsErrors = loader.errors();
      } catch (err) {
        const failure: BusinessError = err as BusinessError;
        this.handleErrorState(new Error(failure.message));
        return;
      } finally {
        notificationUpdates.dispose();
        await notification.finish();
      }
      const processed: boolean = await this.postProcessFeed();
      if (!processed) {
        // The source's subscribe() error path stops at handleError(): no LoadedState follows.
        return;
      }
      await this.loadFeed();
    } finally {
      // stopService(): the disposable is cleared however the load ended, so the next
      // reloadContent() may start one.
      this.feedLoadInFlight = false;
    }
  }

  /**
   * updateNotificationProgress(state)'s content text: the description, with "(current/max)"
   * appended while the count is known; the processing step has none.
   */
  private static notificationText(progress: FeedLoadProgress): string {
    if (progress.maxProgress === -1) {
      return Localization.getString('feed_processing_message');
    }
    const count: string = `${progress.currentProgress}/${progress.maxProgress}`;
    return progress.description.length > 0 ? `${progress.description}  (${count})` : count;
  }

  /**
   * postProcessFeed(): the tail of startLoading(), run after EVERY load — including one that
   * found no outdated subscription, since it is flatMapped onto the chain, not onto the item
   * stream. It posts ProgressEvent(feed_processing_message), so the bar goes indeterminate and
   * the counter is replaced by that message, prunes the feed/stream tables, then finishes.
   * The port went straight from the loader to loadFeed(), so a refresh with nothing outdated
   * to fetch did no work and showed no state at all.
   */
  private async postProcessFeed(): Promise<boolean> {
    const feedDb: FeedDatabase | null = await this.ensureServices();
    if (feedDb === null) {
      return false;
    }
    this.loadProgress = -1;
    this.loadProgressMax = -1;
    this.progressMessage = Localization.getString('feed_processing_message');
    this.feedState = FeedRenderState.PROGRESS;
    try {
      await feedDb.removeOrphansOrOlderStreams();
    } catch (err) {
      const failure: BusinessError = err as BusinessError;
      this.handleErrorState(new Error(failure.message));
      return false;
    }
    return true;
  }

  /* //////////////////////////////////////////////////////////////////////////
  // Handling
  ////////////////////////////////////////////////////////////////////////// */

  private handleLoadedState(loaded: LoadedState): void {
    // "This need to be saved in a variable as the update occurs async".
    const previousOldest: number = this.oldestUpdate === null ? -1 : this.oldestUpdate;

    this.feedList.setItems(loaded.items);
    this.items = loaded.items.length;
    this.notLoadedCount = loaded.notLoadedCount;

    // highlightNewItemsAfter(oldOldestSubscriptionUpdate), which the source runs only when there
    // WAS a previous update to compare against.
    this.uploadDate = previousOldest;
    this.lastNewItemsCount = FeedFragmentPage.countNewItems(loaded.items, previousOldest);
    if (this.lastNewItemsCount > 0) {
      this.showNewItemsLoaded();
    }

    // "ignore errors if they have already been handled for the current update".
    if (this.oldestUpdate !== loaded.oldestUpdate ||
      (this.oldestUpdate === null && loaded.oldestUpdate === null)) {
      this.handleItemsErrors(0);
    }
    this.oldestUpdate = loaded.oldestUpdate;
    this.updateRefreshViewState();

    this.errorInfo = null;
    this.progressMessage = '';
    this.feedState = FeedRenderState.LOADED;
    this.isLoading = false;
    this.isRefreshing = false;
  }

  /** handleErrorState(): a non-null error shows the panel; showError() ends the load. */
  private handleErrorState(error: Error): void {
    hilog.error(0x0000, TAG, 'feed load failed: %{public}s', error.message);
    this.errorInfo = error.message;
    this.feedState = FeedRenderState.ERROR;
    this.isLoading = false;
    this.isRefreshing = false;
  }

  /**
   * highlightNewItemsAfter(): the items are newest-first, so the scan stops at the first one
   * that is NOT after the previous update.
   */
  private static countNewItems(items: StreamItemData[], since: number): number {
    if (since < 0) {
      return 0;
    }
    let count: number = 0;
    for (const item of items) {
      const uploadDate: number | null = item.getStream().uploadDate;
      if (uploadDate !== null && uploadDate <= since) {
        break;
      }
      count++;
    }
    return count;
  }

  /** updateRefreshViewState(): relativeTime(oldestSubscriptionUpdate), or an em dash. */
  private updateRefreshViewState(): void {
    const oldest: number | null = this.oldestUpdate;
    this.oldestSubscriptionUpdate = Localization.getStringArgs(
      'feed_oldest_subscription_update',
      [oldest === null ? '—' : Localization.relativeTime(oldest)]);
  }

  /**
   * showNewItemsLoaded(): the button animates in and a ten-second timer is armed to take it
   * back down. removeCallbacksAndMessages(null) first, so a second load restarts the countdown
   * rather than letting the first one hide a button that has only just reappeared.
   */
  private showNewItemsLoaded(): void {
    this.clearHideNewItemsTimer();
    this.hideNewItemsTimer = setTimeout((): void => {
      this.hideNewItemsTimer = -1;
      this.hideNewItemsLoaded();
    }, 10000);
  }

  /** hideNewItemsLoaded(): state only — the button's own handler also scrolls to the top. */
  private hideNewItemsLoaded(): void {
    this.clearHideNewItemsTimer();
    this.lastNewItemsCount = 0;
  }

  private clearHideNewItemsTimer(): void {
    if (this.hideNewItemsTimer !== -1) {
      clearTimeout(this.hideNewItemsTimer);
      this.hideNewItemsTimer = -1;
    }
  }

  /* //////////////////////////////////////////////////////////////////////////
  // Item errors
  ////////////////////////////////////////////////////////////////////////// */

  /**
   * handleItemsErrors(): the FIRST content-not-available error opens the per-subscription
   * dialog, and the rest are handled from there; anything else is one snackbar.
   */
  private handleItemsErrors(from: number): void {
    const errors: Error[] = this.itemsErrors;
    for (let i: number = from; i < errors.length; i++) {
      const ref: SubscriptionRef | null = FeedFragmentPage.parseSubscriptionRef(errors[i].message);
      if (ref !== null) {
        this.pendingErrorIndex = i;
        this.showFeedNotAvailable(ref, errors[i]);
        return;
      }
    }
    if (from < errors.length) {
      // ErrorUtil.showSnackbar(this, ErrorInfo(errors, REQUESTED_FEED, "")).
      this.showSnackBarError(errors[errors.length - 1].message);
    }
  }

  /** `serviceId:url: message`, as FeedLoader.loadStreams() writes a failure. */
  private static parseSubscriptionRef(message: string): SubscriptionRef | null {
    const firstColon: number = message.indexOf(':');
    if (firstColon <= 0) {
      return null;
    }
    const serviceId: number = Number.parseInt(message.substring(0, firstColon), 10);
    if (Number.isNaN(serviceId)) {
      return null;
    }
    const rest: string = message.substring(firstColon + 1);
    const separator: number = rest.indexOf(': ');
    if (separator <= 0) {
      return null;
    }
    return new SubscriptionRef(serviceId, rest.substring(0, separator));
  }

  /** handleFeedNotAvailable(subscriptionEntity, cause, nextItemsErrors). */
  private showFeedNotAvailable(ref: SubscriptionRef, error: Error): void {
    const db: AppDatabase | null = this.database;
    if (db === null) {
      this.showSnackBarError(error.message);
      return;
    }
    SubscriptionDao.getSubscription(db, ref.serviceId, ref.url)
      .then((entity: SubscriptionEntity | null): void => {
        if (entity === null) {
          this.showSnackBarError(error.message);
          return;
        }
        this.pendingSubscription = entity;
        let message: string = Localization.getStringArgs('feed_load_error_account_info',
          [entity.name === null ? '' : entity.name]);
        if (this.usingDedicatedMethod) {
          message = message + '\n' + Localization.getString('feed_load_error_fast_unknown');
        } else {
          message = message + '\n' + error.message;
        }
        this.loadErrorMessage = message;
        this.loadErrorDialog.open();
      })
      .catch((err: BusinessError): void => {
        hilog.error(0x0000, TAG, 'Unable to process: %{public}s', err.message);
      });
  }

  /**
   * setPositiveButton(unsubscribe): deleteSubscription(...).subscribe(), then the remaining
   * errors are handled.
   */
  private async unsubscribeFailedSubscription(): Promise<void> {
    const entity: SubscriptionEntity | null = this.pendingSubscription;
    const manager: SubscriptionManager | null = this.subscriptionManager;
    if (entity === null || manager === null) {
      return;
    }
    const url: string | null = entity.url;
    if (url === null) {
      return;
    }
    try {
      await manager.deleteSubscription(entity.serviceId, url);
      await this.loadFeed();
    } catch (err) {
      const failure: BusinessError = err as BusinessError;
      this.showSnackBarError(failure.message);
    }
    this.pendingSubscription = null;
    this.handleItemsErrors(this.pendingErrorIndex + 1);
  }

  /** showSnackBarError(): the source keeps the content and only reports; so does this. */
  private showSnackBarError(message: string): void {
    hilog.error(0x0000, TAG, '%{public}s', message);
    promptAction.showToast({ message: message, duration: 3000 });
  }

  /* //////////////////////////////////////////////////////////////////////////
  // Menu
  ////////////////////////////////////////////////////////////////////////// */

  /** setPositiveButton(ok): the three view-model setters, each of which persists its flag. */
  private async applyStreamVisibility(): Promise<void> {
    // The flushing statics: an instance putSync would not survive a cold relaunch.
    await Preferences.putBoolean(feed_show_watched_items_key, this.showPlayed);
    await Preferences.putBoolean(feed_show_partially_watched_items_key, this.showPartiallyPlayed);
    await Preferences.putBoolean(feed_show_future_items_key, this.showFuture);
    // The view model re-queries on every filter change, and so does this.
    await this.loadFeed();
  }

  /** The help dialog's neutral button, and the load-error dialog's disable button. */
  private async setFastMode(enabled: boolean): Promise<void> {
    await Preferences.putBoolean(feed_use_dedicated_fetch_method_key, enabled);
    this.usingDedicatedMethod = enabled;
  }

  /* //////////////////////////////////////////////////////////////////////////
  // Items
  ////////////////////////////////////////////////////////////////////////// */

  /** onItemClick -> openVideoDetailFragment, ignored while isRefreshing. */
  private openStream(item: StreamItemData): void {
    if (this.isRefreshing) {
      return;
    }
    const stream: StreamEntity = item.getStream();
    router.pushUrl({
      url: 'pages/VideoDetailFragmentPage',
      params: new ItemParams(stream.serviceId, stream.url, stream.title)
    });
  }

  /** onItemLongClick -> showInfoItemDialog(stream.toStreamInfoItem()), also ignored refreshing. */
  private showInfoItemDialog(item: StreamItemData): void {
    if (this.isRefreshing) {
      return;
    }
    const stream: StreamEntity = item.getStream();
    this.menuTarget = stream;
    this.menuTitle = stream.title;

    // InfoItemDialog.Builder owns the entry list and its order; this screen only says what each
    // one does. The list used to be written out here, which is how search results and History
    // ended up with three and four entries against this screen's nine.
    const target: StreamMenuTarget = new StreamMenuTarget();
    target.serviceId = stream.serviceId;
    target.url = stream.url;
    target.title = stream.title;
    target.uploader = stream.uploader;
    const uploaderUrl: string | null = stream.uploaderUrl;
    target.uploaderUrl = uploaderUrl === null ? '' : uploaderUrl;
    target.audioOnly = isAudioStream(stream.streamType);
    target.live = isLiveStream(stream.streamType);

    const handlers: StreamMenuHandlers = new StreamMenuHandlers();
    handlers.onEnqueue = (): void => {
      // NavigationHelper.enqueueOnPlayer(): toast and APPEND to the live queue, leaving whatever
      // is playing alone.
      promptAction.showToast({ message: $r('app.string.enqueued'), duration: 2000 });
      enqueueOnCurrentPlayQueue([PlayQueueItem.fromStreamInfoItem(stream.toStreamInfoItem())]);
    };
    handlers.onEnqueueNext = (): void => {
      // NavigationHelper.enqueueNextOnPlayer(): straight after the playing stream.
      enqueueNextStream(stream.toStreamInfoItem());
    };
    handlers.onBackground = (): void => {
      // NavigationHelper.playOnBackgroundPlayer() toasts before it hands the stream over.
      promptAction.showToast({
        message: $r('app.string.background_player_playing_toast'),
        duration: 2000
      });
      this.startPlayer(stream, true);
    };
    handlers.onPopup = (): void => {
      // T-0197: this used to start the stream in the DOCKED player, on the reasoning that a
      // list screen carries no XComponent surface for PiP. It carries none by default - but
      // PopupPlayerSurface is exactly the surface a list mounts to get one, and four screens
      // already do it. Without it `prepare()` ran with `audioOnly` false and no surfaceId, so
      // AVPlayer had no render target and the decoder reported `width 0, height 0`: a popup entry
      // that played sound and drew nothing.
      // A burst of taps must open ONE popup: the surface's onLoad fires once, so a second
      // item set behind a mounted surface would simply never be played.
      if (this.popupSurfaceMounted) {
        return;
      }
      promptAction.showToast({ message: $r('app.string.popup_playing_toast'), duration: 2000 });
      this.popupServiceId = stream.serviceId;
      this.popupUrl = stream.url;
      this.popupSurfaceMounted = true;
    };
    handlers.onDownload = (): void => {
      this.downloadServiceId = stream.serviceId;
      this.downloadUrl = stream.url;
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
        params: new ItemParams(stream.serviceId, target.uploaderUrl, stream.uploader)
      });
    };

    this.menuActions = buildStreamMenuActions(target, handlers);
    this.infoItemDialog.open();
  }

  /**
   * The in-place start the playlist and history screens use: resolve the stream, hand it to the
   * shared player, and start the session so the audio survives the app being backgrounded.
   */
  private async startPlayer(stream: StreamEntity, audioOnly: boolean): Promise<void> {
    try {
      const info: StreamInfo = await ServiceLocator.get().backgroundWork.runWithBackgroundTask(
        BackgroundWorkMode.DATA_TRANSFER,
        (): Promise<StreamInfo> =>
          ExtractorHelper.getStreamInfo(stream.serviceId, stream.url, false));
      await PlayerService.getInstance().prepare(info, audioOnly,
      audioOnly ? 0 : PlayerPrefs.defaultPlaybackHeight());
      await MediaSessionService.getInstance()
        .startDetached(getContext(this) as common.UIAbilityContext, info);
    } catch (err) {
      const failure: BusinessError = err as BusinessError;
      promptAction.showToast({ message: failure.message, duration: 2000 });
    }
  }

  /** StreamDialogDefaultEntry.MARK_AS_WATCHED -> HistoryRecordManager.markAsWatched(item). */
  private async markAsWatched(stream: StreamEntity): Promise<void> {
    const history: HistoryRecordManager | null = this.historyRecordManager;
    if (history === null) {
      return;
    }
    try {
      await history.markAsWatched(stream.toStreamInfoItem());
      // A watched stream disappears from the feed when played items are hidden.
      await this.loadFeed();
    } catch (err) {
      const failure: BusinessError = err as BusinessError;
      this.showSnackBarError(failure.message);
    }
  }

  /**
   * PlaylistDialog.createCorrespondingDialog(): a FACTORY in the source, not a dialog of its own.
   * It asks whether any local playlist exists and then shows PlaylistAppendDialog or
   * PlaylistCreationDialog. The port made it a visible intermediate dialog carrying one unstyled
   * Text, which is what rendered as a chromeless pill with its label clipped - and the append
   * dialog behind it was never opened at all, which is why rewriting THAT one changed nothing.
   */
  private async openPlaylistDialog(): Promise<void> {
    const manager: LocalPlaylistManager | null = this.playlistManager;
    if (manager === null) {
      return;
    }
    try {
      this.hasPlaylists = await manager.hasPlaylists();
    } catch (err) {
      const failure: BusinessError = err as BusinessError;
      hilog.warn(0x0000, TAG, 'hasPlaylists: %{public}s', failure.message);
      this.hasPlaylists = false;
    }
    if (this.hasPlaylists) {
      this.openAppendDialog();
    } else {
      this.creationDialog.open();
    }
  }

  private async openAppendDialog(): Promise<void> {
    const manager: LocalPlaylistManager | null = this.playlistManager;
    if (manager === null) {
      return;
    }
    const held: StreamEntity | null = this.menuTarget;
    try {
      // getPlaylistDuplicates(streamUrl) rather than getPlaylists(): the rows then carry
      // timesStreamIsContained, which is what lets PlaylistAppendDialog grey out a
      // playlist that already holds this stream and refuse a second append.
      this.appendPlaylists = held === null
        ? await manager.getPlaylists()
        : await manager.getPlaylistDuplicates(held.url);
      this.appendDialog.open();
    } catch (err) {
      const failure: BusinessError = err as BusinessError;
      this.showSnackBarError(failure.message);
    }
  }

  private async appendToPlaylist(playlist: PlaylistMetadataEntry): Promise<void> {
    const manager: LocalPlaylistManager | null = this.playlistManager;
    const stream: StreamEntity | null = this.menuTarget;
    if (manager === null || stream === null) {
      return;
    }
    try {
      await manager.appendToPlaylist(playlist.uid, [stream]);
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

  private async createPlaylistWithTarget(name: string): Promise<void> {
    const manager: LocalPlaylistManager | null = this.playlistManager;
    const stream: StreamEntity | null = this.menuTarget;
    if (manager === null || stream === null || name.length === 0) {
      return;
    }
    try {
      await manager.createPlaylist(name, [stream]);
      // PlaylistCreationDialog: Toast @string/playlist_creation_success.
      promptAction.showToast({ message: $r('app.string.playlist_creation_success'),
        duration: 2000 });
    } catch (err) {
      const failure: BusinessError = err as BusinessError;
      this.showSnackBarError(failure.message);
    }
  }

  /* //////////////////////////////////////////////////////////////////////////
  // Render
  ////////////////////////////////////////////////////////////////////////// */

  @Builder
  feedRow(item: StreamItemData) {
    StreamItem({
      item: item,
      itemVersion: this.itemVersion,
      // execBindEnd: a row is highlighted when its uploadDate is null, or after the previous
      // oldestSubscriptionUpdate — and never when there was no previous update at all.
      highlighted: this.uploadDate < 0
        ? false
        : (item.getStream().uploadDate === null
          ? true
          : (item.getStream().uploadDate as number) > this.uploadDate),
      onSelected: (): void => {
        this.openStream(item);
      },
      onHeld: (): void => {
        this.showInfoItemDialog(item);
      }
    })
  }


  /**
   * toolbar_layout with the fixed @string/fragment_feed_title, the group name as the SUBTITLE and
   * menu_feed_fragment's two items. Drawn ONLY when this page is the whole screen: hosted in
   * MainFragment's pager the activity already has a toolbar above the tab strip, and drawing this
   * one underneath it put a second red bar - with its own Up arrow - between the tabs and the
   * list, which is where the eye icon was found.
   */
  @Builder
  ownActionBar() {
    Row() {
      // toolbar_layout's ToolbarTheme tints every glyph ?attr/actionColor = @color/white and
      // centres the 24dp icon in a 56dp (?attr/actionBarSize) touch target.
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

      Column() {
        // Widget.AppCompat.Toolbar.Title: 20sp medium, 16dp past the navigation button.
        Text($r('app.string.fragment_feed_title'))
          .id('feed_title')
          .maxLines(1)
          .fontSize(20)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.on_primary'))

        // supportActionBar.subtitle = groupName — shown only for a named feed group.
        if (this.groupName.length > 0) {
          Text(this.actionBarSubtitle)
            .id('feed_subtitle')
            .maxLines(1)
            .fontSize(14)
            .fontColor($r('app.color.white_secondary'))
        }
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      .margin({ left: 16 })

      Image($r('app.media.ic_visibility_on'))
        .id('menu_item_feed_toggle_played_items')
        .accessibilityText($r('app.string.feed_show_hide_streams'))
        .width(48)
        .height(48)
        .padding(12)
        .objectFit(ImageFit.Contain)
        .fillColor($r('app.color.on_primary'))
        .onClick(() => {
          this.visibilityDialog.open();
        })

      Image($r('app.media.ic_help'))
        .id('menu_item_feed_help')
        .accessibilityText($r('app.string.fast_mode'))
        .width(48)
        .height(48)
        .padding(12)
        .objectFit(ImageFit.Contain)
        .fillColor($r('app.color.on_primary'))
        .onClick(() => {
          this.fastModeDialog.open();
        })
    }
    .width('100%')
    // Toolbar: ?attr/actionBarSize tall, android:background="?attr/colorPrimary".
    .height(56)
    .alignItems(VerticalAlign.Center)
    .backgroundColor(servicePrimaryColor(this.activeServiceId))
  }

  /** PopupPlayerSurface is mounted only while a popup is being opened or is open (T-0197). */
  @State popupSurfaceMounted: boolean = false;
  /** The row the popup was raised for; read once the surface is bound. */
  private popupServiceId: number = 0;
  private popupUrl: string = '';
  private popupSurfaceController: XComponentController = new XComponentController();

  /** The surface is bound: the shared launcher prepares the stream and hands it to PiP. */
  private async onPopupSurfaceReady(): Promise<void> {
    const url: string = this.popupUrl;
    if (url.length === 0) {
      return;
    }
    this.popupUrl = '';
    await openPopupOnSurface(getContext(this) as common.UIAbilityContext, this.popupServiceId,
      url, this.popupSurfaceController, (): void => {
        this.popupSurfaceMounted = false;
      });
  }

  build() {
    Column() {
      // setUseAsFrontPage(true) means the ACTIVITY's toolbar carries this fragment's title and
      // menu_feed_fragment, so there is no second bar to draw here.
      if (!this.useAsFrontPage) {
        this.ownActionBar()
      }

      Stack() {
        Column() {
          // refresh_root_view: the whole header is one click target for reloadContent().
          Row() {
            Column() {
              // refresh_text: TextAppearance.AppCompat.Body1 at 14sp.
              Text(this.oldestSubscriptionUpdate)
                .id('refresh_text')
                .maxLines(2)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .width('100%')
                .fontSize(14)
                .fontColor(C_ON_SURFACE)

              // VISIBLE only when notLoadedCount > 0. Caption, 12sp.
              if (this.notLoadedCount > 0) {
                Text(Localization.getStringArgs('feed_subscription_not_loaded_count',
                  [this.notLoadedCount]))
                  .id('refresh_subtitle_text')
                  .maxLines(1)
                  .width('100%')
                  .fontSize(12)
                  .fontColor(C_SECONDARY)
              }
            }
            .id('refresh_info_container')
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)
            .justifyContent(FlexAlign.Center)
            // android:layout_marginStart="12dp".
            .margin({ left: 12 })

            Image($r('app.media.ic_refresh'))
              .id('refreshIcon')
              .width(24)
              .height(24)
              .objectFit(ImageFit.Contain)
              .fillColor($r('app.color.defaultIconTint'))
              .margin({ left: 6, right: 12 })
          }
          .id('refresh_root_view')
          .accessibilityText($r('app.string.refresh'))
          .width('100%')
          .alignItems(VerticalAlign.Center)
          // android:paddingTop="8dp".
          .padding({ top: 8 })
          .onClick(() => {
            this.reloadContent();
          })

          // The 1dp ?attr/separator_color rule under refresh_info_container.
          Divider()
            .strokeWidth(1)
            .color($r('app.color.separator'))
            .margin({ left: 8, right: 8, top: 8 })

          // SwipeRefreshLayout wrapping items_list.
          Refresh({ refreshing: $$this.isRefreshing }) {
            List({ scroller: this.listScroller }) {
              LazyForEach(this.feedList, (item: StreamItemData) => {
                ListItem() {
                  this.feedRow(item)
                }
              }, (item: StreamItemData) => `${item.getId()}`)
            }
            .id('items_list')
            .width('100%')
            .height('100%')
            .cachedCount(5)
            // GRID ONLY. refreshItemViewMode() reads
            //   itemsList.setLayoutManager(mode == ItemViewMode.GRID ? getGridLayoutManager()
            //                                                        : getListLayoutManager())
            // so CARD is a LINEAR list of card-shaped rows, one per row, and only GRID is
            // columned. Without a lane count the GRID cells would still sit one per row.
            .lanes(this.itemVersion === ItemVersion.GRID
              ? { minLength: GRID_LANE_MIN_WIDTH, maxLength: GRID_LANE_MAX_WIDTH } : 1)
            // showLoading(): animateHideRecyclerViewAllowingScrolling() — the list is hidden
            // while a refresh runs, which is also why a row tap is ignored then.
            .visibility(this.isRefreshing ? Visibility.Hidden : Visibility.Visible)
            .onScrollIndex((first: number) => {
              // The OnScrollListener that hides the button once the list is back at the top.
              // It must be a SCROLL back to the top, not merely being at the top: handleLoadedState
              // replaces the list's items and then sets lastNewItemsCount, and the re-layout that
              // follows calls this handler with first === 0 - which cleared the count again before
              // the banner could ever be drawn. Requiring the index to come DOWN to 0 from a lower
              // row restores the source's meaning.
              const scrolledBackToTop: boolean = first === 0 && this.firstVisibleIndex > 0;
              this.firstVisibleIndex = first;
              if (scrolledBackToTop && this.lastNewItemsCount > 0) {
                this.hideNewItemsLoaded();
              }
            })
          }
          .id('swipeRefreshLayout')
          .width('100%')
          .layoutWeight(1)
          .onRefreshing(() => {
            this.reloadContent();
          })
        }
        .width('100%')
        .height('100%')

        // handleProgressState(): the centred determinate/indeterminate bar plus its counter.
        if (this.feedState === FeedRenderState.PROGRESS) {
          Column() {
            if (this.loadProgress < 0 && this.loadProgressMax < 0) {
              LoadingProgress()
                .id('loading_progress_bar')
                .width(48)
                .height(48)
                .color(servicePrimaryColor(this.activeServiceId))
                .margin({ top: 8 })
            } else {
              Progress({
                value: this.loadProgress,
                total: this.loadProgressMax,
                type: ProgressType.Linear
              })
                .id('loading_progress_bar')
                // android:minWidth="128dp", android:layout_marginTop="8dp".
                .width(128)
                .color(servicePrimaryColor(this.activeServiceId))
                .margin({ top: 8 })
            }

            // TextAppearance.AppCompat.Title at 16sp, 8dp under the bar.
            Text(this.loadProgress < 0 && this.loadProgressMax < 0
              ? (this.progressMessage.length > 0 ? this.progressMessage : '∞/∞')
              : `${this.loadProgress}/${this.loadProgressMax}`)
              .id('loading_progress_text')
              .fontSize(16)
              .fontColor(C_ON_SURFACE)
              .margin({ top: 8 })
          }
          .alignItems(HorizontalAlign.Center)
        }

        // handleErrorState(): the error_panel include, with its retry button.
        if (this.feedState === FeedRenderState.ERROR) {
          Column() {
            Text(this.errorInfo === null ? '' : this.errorInfo)
              .id('error_message_view')
              .fontSize(16)
              .fontWeight(FontWeight.Bold)
              .fontColor(C_ON_SURFACE)
              .textAlign(TextAlign.Center)

            // ServiceColoredButton: colorButtonNormal = ?attr/colorPrimary,
            // textColor = @color/subscribe_text_color, textAllCaps.
            Button(Localization.buttonLabel('retry'))
              .id('error_retry_button')
              .type(ButtonType.Normal)
              .backgroundColor(servicePrimaryColor(this.activeServiceId))
              .fontSize(16)
              .fontColor($r('app.color.subscribe_text_color'))
              .borderRadius(2)
              .margin({ top: 4 })
              .padding({ left: 16, right: 16, top: 6, bottom: 6 })
              .onClick(() => {
                this.reloadContent();
              })
          }
          .id('error_panel')
          .padding(16)
          .alignItems(HorizontalAlign.Center)
        }

        // showEmptyState(): list_empty_view — shown INSTEAD of the list, never beside it.
        if (this.feedState === FeedRenderState.LOADED && this.items === 0) {
          Column() {
            Text('¯\\_(ツ)_/¯')
              .fontSize(22)
              .fontColor(C_ON_SURFACE)
            Text($r('app.string.empty_list_subtitle'))
              .fontSize(14)
              .fontColor(C_ON_SURFACE)
              .textAlign(TextAlign.Center)
              .margin({ top: 6 })
              .padding({ left: 16, right: 16 })
          }
          .id('empty_state_view')
          // android:minHeight="128dp", gravity center.
          .constraintSize({ minHeight: 128 })
          .justifyContent(FlexAlign.Center)
          .alignItems(HorizontalAlign.Center)
        }

        // new_items_loaded_button: slides up over the list bottom while new items were found.
        if (this.lastNewItemsCount > 0) {
          Column() {
            // MaterialComponents.Button is textAllCaps: the banner reads "NEW FEED ITEMS",
            // while the resource itself stays sentence case. $r() renders it raw, so the label
            // goes through Localization.buttonLabel() like every other ported button.
            Button(Localization.buttonLabel('feed_new_items'))
              .id('new_items_loaded_button')
              .type(ButtonType.Normal)
              .backgroundColor(servicePrimaryColor(this.activeServiceId))
              .fontSize(12)
              .fontColor($r('app.color.subscribe_text_color'))
              .borderRadius(2)
              .padding({ left: 16, right: 16, top: 6, bottom: 6 })
              .onClick(() => {
                this.hideNewItemsLoaded();
                this.listScroller.scrollToIndex(0);
              })
          }
          .width('100%')
          .height('100%')
          .justifyContent(FlexAlign.End)
          .alignItems(HorizontalAlign.Center)
          .padding({ bottom: 5 })
          // The overlay must not swallow taps meant for the list underneath it.
          .hitTestBehavior(HitTestMode.Transparent)
        }
      }
      .width('100%')
      .layoutWeight(1)

      // fragment_player_holder, docked. A pushed feed has no shell underneath it that can draw
      // the bar, so it mounts its own; as a front-page TAB the shell is the host and already
      // docks one, and a second copy here would sit beside it. Last child of the root Column, so
      // it shortens the layoutWeight(1) list instead of covering its last row, and Visibility.None
      // while the player is IDLE gives that height straight back.
      if (!this.useAsFrontPage) {
        MiniPlayerBar({ idPrefix: 'feed_' })
      }

      // The popup's surface, mounted only while one is being opened or is open. 1x1 and
      // transparent: PiP composites the video into its own window (T-0197).
      if (this.popupSurfaceMounted) {
        PopupPlayerSurface({
          controller: this.popupSurfaceController,
          onSurfaceReady: (): void => {
            this.onPopupSurfaceReady();
          }
        })
      }
    }
    .id('FeedFragmentPage')
    .width('100%')
    .height('100%')
    // ?attr/windowBackground = @color/light_background_color in the light theme.
    .backgroundColor(themedBackground(this.blackTheme))
  }
}
