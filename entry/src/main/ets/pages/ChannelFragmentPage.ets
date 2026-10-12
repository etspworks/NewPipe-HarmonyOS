/**
 * S3 - ChannelFragment (screen_channel).
 *
 * A BaseStateFragment, not a list fragment: it owns NO list. The collapsing header (banner, avatar,
 * title, subscriber count, subscribe toggle, parent-channel row) sits above a tab strip and a pager;
 * every list belongs to the ChannelTabFragment behind a tab.
 *
 * Three things this screen is, that a screenshot cannot show:
 *   1. The tab SET is dynamic - ChannelInfo.getTabs() filtered through ChannelTabHelper.showChannelTab
 *      (a user preference), plus a trailing About tab when show_channel_tabs_about is on. Never a
 *      literal array, and empty when the channel reports ContentNotSupportedException.
 *   2. The subscribe button is not a boolean toggle. Its state comes from the subscriptions table -
 *      so it stays right when another screen subscribes - and the click stream is debounced 100 ms
 *      before it writes, exactly as RxView.clicks(...).debounce(...) does in the source.
 *   3. menu_item_rss / menu_item_notify / menu_item_share / action_settings / menu_item_openInBrowser
 *      are ACTIVITY menu items in the source (a MenuProvider), so they are this page's own toolbar
 *      and overflow here; rss and notify are conditionally visible, as updateRssButton() and
 *      updateNotifyButton() make them.
 *
 * screen_channel_tab and screen_channel_about declare hostedBy: screen_channel, so their structs are
 * MOUNTED in the pager below - they are never pushed as routes from here.
 *
 * S5 styled this from the S0047 capture: the red app-bar band (?attr/colorPrimary =
 * @color/light_youtube_primary_color) over the light content background, white on-primary
 * text and icons, and the AppCompat metrics the source's own values/ carry.
 */
import { router, promptAction } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { userMessageFor } from '../common/error/ErrorMessages';

import { CompositeDisposable, Subject } from '../common/rx/Rx';
import { AppDatabase } from '../common/db/AppDatabase';
import { SubscriptionDao, SubscriptionManager } from '../common/db/SubscriptionManager';
import { ServiceLocator } from '../common/di/ServiceLocator';
import { ExtractorHelper } from '../common/extractor/ExtractorHelper';
import { InfoCacheType } from '../common/extractor/InfoCache';
import { ListLinkHandler } from '../common/extractor/linkhandler/LinkHandler';
import { ContentNotSupportedException } from '../common/extractor/exceptions/Exceptions';
import { Localization } from '../common/i18n/Localization';
import { choosePreferredImage, shouldLoadImages } from '../common/image/ImageLoader';
import { LinkType, ResolvedLink, RoutingDecision } from '../common/router/DeepLinkRouter';
import { ShareUtils } from '../common/share/ShareUtils';
import { Preferences } from '../common/prefs/Preferences';
import { show_channel_tabs_about } from '../common/prefs/SettingsKeys';
import { ChannelInfo } from '../model/extractor/ChannelInfo';
import { SubscriptionEntity } from '../model/db/entity/SubscriptionEntity';
import { NotificationMode } from '../model/enums/NotificationMode';

import { ChannelAboutFragmentPage } from './ChannelAboutFragmentPage';
import { ChannelTabFragmentPage } from './ChannelTabFragmentPage';
import { CustomCollapsingToolbarLayout } from '../components/CustomCollapsingToolbarLayout';
import { ScrollableTabLayout } from '../components/ScrollableTabLayout';
import { MiniPlayerBar } from '../components/MiniPlayerBar';
import { servicePrimaryColor } from '../common/theme/ServiceTheme';
import {
  ChannelTabItem,
  ChannelTabKind,
  TabAdapter,
  getTranslationKey,
  showChannelTab,
  showChannelTabForKey
} from '../components/TabAdapter';
import { BLACK_THEME_KEY, themedBackground } from '../common/theme/ThemeBackground';

const TAG: string = 'ChannelFragment';

/** ChannelFragment.BUTTON_DEBOUNCE_INTERVAL - ignore rapid subscribe clicks. */
const BUTTON_DEBOUNCE_INTERVAL: number = 100;

/* //////////////////////////////////////////////////////////////////////////
// S5 style tokens - read off the S0047 capture (1080 px wide, so 1 vp = 3 px)
// and off the source's own values/ (fragment_channel.xml, styles.xml, dimens.xml).
////////////////////////////////////////////////////////////////////////// */

/** Toolbar height: capture [0,72][1080,240] = 56 vp, the Material action-bar height. */
const TOOLBAR_HEIGHT: number = 56;
/** The glyph inside that 56 vp box, and the inset that centres it ((56 - 24) / 2). */
const TOOLBAR_ICON: number = 24;
const TOOLBAR_ICON_INSET: number = 16;
/** contentInsetStartWithNavigation: the title starts 72 vp in (capture: 216 px), so the gap
 * after the 24 vp Up glyph in its 16 vp inset is what carries it there. */
const TOOLBAR_TITLE_INSET: number = 72;
const TOOLBAR_NAV_GAP: number = TOOLBAR_TITLE_INSET - TOOLBAR_ICON_INSET - TOOLBAR_ICON;
/** textAppearance Toolbar.Title. */
const TOOLBAR_TITLE_SIZE: number = 20;
/** channel_banner_image: android:maxHeight="70dp" + adjustViewBounds. */
const BANNER_MAX_HEIGHT: number = 70;
/** The metadata row under the banner: capture [418,586] = 56 vp. */
const HEADER_ROW_HEIGHT: number = 56;
/**
 * How much of the 70 vp avatar hangs over the banner: it is bottom-anchored 8 vp above the
 * header's bottom edge, so only 48 vp of it belongs to the row (capture [352,562] vs [418,586]).
 */
const AVATAR_ROW_FOOTPRINT: number = 48;
const AVATAR_SIZE: number = 70;
const SUB_AVATAR_SIZE: number = 35;
/** app:strokeWidth="2dp" app:strokeColor="#ffffff" on both ShapeableImageViews. */
const AVATAR_STROKE: number = 2;
/*
 * Measured against the reference rather than guessed. With both devices on the same channel, the
 * header's text boxes were read off each layout tree and normalised by screen width (1216/1080):
 * the title came out at 0.83 of the reference's and the subscriber line at the same 0.83, so the
 * whole header was uniformly undersized. 16 -> 19 and 12 -> 14 put both back on the reference's
 * proportions; the sub-channel line scales with them.
 */
const CHANNEL_TITLE_SIZE: number = 19;
const SUB_CHANNEL_TITLE_SIZE: number = 17;
const CHANNEL_SUBSCRIBER_SIZE: number = 14;
/** AppCompatButton: 36 vp of visible background inside its 48 vp touch target. */
const BUTTON_HEIGHT: number = 36;
const BUTTON_MIN_WIDTH: number = 88;
const BUTTON_RADIUS: number = 2;
/** abc_button_padding_horizontal_material. Capture: a 74 vp label in a 90 vp button. */
const BUTTON_PADDING_H: number = 8;
/** The 4 vp inset Widget.AppCompat.Button keeps against layout_constraintEnd_toEndOf="parent". */
const BUTTON_INSET: number = 4;
/**
 * updateSubscribeButton(): the UNsubscribed background is
 * ColorUtils.blendARGB(colorPrimary, subscribed_background_color, 0.35f) - a computed blend, so
 * it has no name in colors.xml. #E53935 blended 35 percent toward #D6D6D6.
 */
const SUBSCRIBE_BACKGROUND: string = '#E0706D';
/** Material's popup-menu surface; the source's ToolbarPopupTheme is the DayNight light one. */
const MENU_SURFACE: Resource = $r('app.color.surface');
const MENU_TEXT: Resource = $r('app.color.on_surface');
const MENU_WIDTH: number = 200;
const MENU_ITEM_HEIGHT: number = 48;
const MENU_ITEM_TEXT_SIZE: number = 16;
/** abc_list_menu_item_checkbox's CheckBox: the framework's 20dp box at the row's end. */
const MENU_CHECKBOX_SIZE: number = 20;
/** Body text on the light content background (@color/light_background_color). */
const BODY_TEXT: Resource = $r('app.color.on_surface');
/** showContentNotSupportedIfNeeded() raises the kaomoji from the layout's 35sp to 45sp. */
const KAOMOJI_TEXT_SIZE: number = 45;
/** Material snackbar surface. */
const SNACKBAR_BACKGROUND: string = '#323232';
/**
 * MINI_PLAYER_HEIGHT from components/MiniPlayerBar.ets, which keeps it private. Only the docked
 * snackbar needs the number, to clear the bar while it is up.
 */
const MINI_PLAYER_BAR_HEIGHT: number = 54;
const SPACE_XS: number = 4;
const SPACE_S: number = 8;
const SPACE_M: number = 16;

@Entry
@Component
export struct ChannelFragmentPage {
  /** ThemeHelper's black theme: the window background follows it. */
  @StorageProp(BLACK_THEME_KEY) blackTheme: boolean = false;

  /**
   * TRUE when this screen is a CHILD component inside MainActivityPage - a MainFragment tab, or
   * the shell's own fragment_holder - rather than a page pushed on top of it. The shell docks
   * MiniPlayerBar itself, so a child must not dock a second one beside it; a pushed page covers
   * the shell and has to dock its own.
   *
   * `mainShellOwnsToolbar` cannot answer this: MainActivityPage sets it once in aboutToAppear and
   * never clears it, so it still reads true underneath a pushed page. The embedding hosts pass
   * this one explicitly instead - the same shape as the useAsFrontPage prop the kiosk and feed
   * screens already take, but named for what it gates, since this screen is not always a front
   * page when the shell hosts it.
   */
  @Prop hostedInMainShell: boolean = false;
  /**
   * Whether the docked bar is currently showing, reported by MiniPlayerBar itself. This page is
   * the only one that needs to know: showNotifySnackbar() docks its own row to the same bottom
   * edge of the root Stack, so without the lift the two would sit on top of each other.
   */
  @State playerBarVisible: boolean = false;
  /* //////////////////////////////////////////////////////////////////////////
  // State - the fields handleResult() and the subscription monitor write
  ////////////////////////////////////////////////////////////////////////// */

  /**
   * ThemeHelper.setTheme(context, serviceId): ?attr/colorPrimary follows the service the
   * drawer selected, not the service the channel happens to belong to. The reference keeps a
   * YouTube channel's screen Bandcamp-teal while Bandcamp is the selected service; this page
   * had named the YouTube colour directly, so it went red. Same channel as every other
   * ported screen - see ServiceTheme.
   */
  @StorageProp('mainSelectedServiceId') activeServiceId: number = 0;

  /** CoilHelper.loadBanner(result.getBanners()); '' when there is nothing to load. */
  @State banner: string = '';
  /** CoilHelper.loadAvatar(result.getAvatars()). */
  @State avatar: string = '';
  /** result.getName(), mirrored into the action-bar title. */
  @State title: string = '';
  /** getString(R.string.channel_created_by) formatted with the parent channel name. */
  @State parentChannelRow: string = '';
  /** Localization.shortSubscriberCount(), or @string/subscribers_count_not_available. */
  @State subscriberCount: string = '';
  /** The subscribe button label; driven by the subscriptions table, never by a local flag. */
  @State subscribeButtonState: string = '';
  /** menuNotifyButton.setChecked(subscription.getNotificationMode() == ENABLED). */
  @State notifyMenuItemState: boolean = false;
  /** The TabAdapter's entries - ChannelInfo.getTabs() after ChannelTabHelper filtering. */
  @State tabStrip: ChannelTabItem[] = [];
  /** currentInfo.getParentChannelName(); empty hides the whole "created by" row. */
  @State parentChannelName: string = '';
  /** shouldLoadImages() && !result.getBanners().isEmpty() - false collapses the header. */
  @State banners: boolean = false;
  /** currentInfo.getFeedUrl(); empty hides the RSS menu item. */
  @State feedUrl: string = '';
  /** The subscriptions row for this channel, or null - null hides the notify menu item. */
  @State channelSubscription: SubscriptionEntity | null = null;
  /** A ContentNotSupportedException among result.getErrors(): no tabs, sad kaomoji instead. */
  @State channelContentNotSupported: boolean = false;
  /** !subscriptionEntities.isEmpty(). */
  @State isSubscribed: boolean = false;
  @State isLoading: boolean = true;
  /** ErrorPanelHelper's message; null hides the panel. */
  @State errorInfo: string | null = null;

  /** One title per adapter entry, for the strip. */
  @State private tabTitles: string[] = [];
  /** The tab shared by strip and pager (setupWithViewPager). */
  @State @Watch('rememberSelectedTab') private selectedTabIndex: number = 0;
  /** CoilHelper.loadAvatar(binding.subChannelAvatarView, result.getParentChannelAvatars()). */
  @State private parentChannelAvatar: string = '';
  /** The overflow items (showAsAction="never"): notify, settings, open in browser. */
  @State private overflowOpen: boolean = false;
  /** showNotifySnackbar(). */
  @State private notifyPromptVisible: boolean = false;
  /**
   * AppBarLayout with `scroll|exitUntilCollapsed`: the header spends the content's scroll before
   * the content does. How much of it has been scrolled away, in vp, and what its full height is.
   */
  @State private headerCollapsed: number = 0;
  @State private headerNaturalHeight: number = 0;
  /** NotificationHelper.areNewStreamsNotificationsEnabled() - menuNotifyButton.setEnabled(). */
  @State private notificationsAllowed: boolean = false;
  /** The pull-to-refresh indicator; reloadContent() runs while it is up. */
  @State private isRefreshing: boolean = false;

  /* //////////////////////////////////////////////////////////////////////////
  // Non-UI members
  ////////////////////////////////////////////////////////////////////////// */

  private serviceId: number = -1;
  private url: string = '';
  private name: string = '';
  private currentInfo: ChannelInfo | null = null;
  /** ChannelFragment.lastTab - the tab to restore after updateTabs(). */
  private lastTab: number = 0;
  private database: AppDatabase | null = null;
  private subscriptionManager: SubscriptionManager | null = null;
  private disposables: CompositeDisposable = new CompositeDisposable();
  /**
   * The subscription-table observers, held apart from `disposables` because handleResult()
   * re-subscribes them every load (the source's `disposables.clear()`), while the debounced click
   * stream is created once and must survive it.
   */
  private subscriptionMonitor: CompositeDisposable = new CompositeDisposable();
  /** RxView.clicks(binding.channelSubscribeButton) - debounced before it writes. */
  private subscribeClicks: Subject<number> = new Subject<number>();
  /** skip(1): the first read is the channel being opened, not a subscribe transition. */
  private subscriptionSeen: boolean = false;
  /** currentWorker.dispose(): a result from a superseded load is dropped, not rendered. */
  private workerGeneration: number = 0;

  /* //////////////////////////////////////////////////////////////////////////
  // Lifecycle
  ////////////////////////////////////////////////////////////////////////// */

  /** ChannelFragment.lastTab: whatever the user last looked at is restored by updateTabs(). */
  private rememberSelectedTab(): void {
    this.lastTab = this.selectedTabIndex;
  }

  aboutToAppear(): void {
    this.readArguments();
    // initViews(): the name from the arguments paints before the network answers.
    this.title = this.name;
    this.subscribeButtonState = Localization.getString('subscribe_button_title');

    // monitorSubscribeButton(): clicks debounced on their way to the database.
    this.disposables.add(this.subscribeClicks
      .debounce(BUTTON_DEBOUNCE_INTERVAL)
      .subscribeCallbacks((clickedAt: number): void => {
        this.toggleSubscription();
      }, (error: Error): void => {
        this.showSnackBarError(error.message);
      }));

    this.loadNotificationPermission();

    // A deep-link launch carries only the URI; RouterActivity is what turns one into
    // (serviceId, url) before it opens this fragment, so without a serviceId the same
    // resolution has to happen here or the extractor is handed NO_SERVICE_ID.
    if (this.serviceId < 0 && this.url.length > 0) {
      this.resolveDeepLinkThenLoad();
    } else {
      this.startLoading(false);
    }
  }

  /** onDestroy(): dispose the worker and every subscription (Rule 8). */
  aboutToDisappear(): void {
    this.workerGeneration++;
    this.subscriptionMonitor.dispose();
    this.disposables.dispose();
    this.subscribeClicks.onComplete();
  }

  /** Port of RouterActivity.handleUrl(url) for the CHANNEL link type, on the way in. */
  private resolveDeepLinkThenLoad(): void {
    ServiceLocator.get().deepLinkRouter.resolve(this.url)
      .then((decision: RoutingDecision): void => {
        const link: ResolvedLink | null = decision.link;
        if (link !== null && link.linkType === LinkType.CHANNEL) {
          this.serviceId = link.serviceId;
          this.url = link.url;
        }
        this.startLoading(false);
      })
      .catch((err: BusinessError): void => {
        // showUnsupportedUrlDialog(): the source gives up on the link; the error panel says so.
        this.showError(userMessageFor(err));
      });
  }

  /** ChannelFragment.getInstance(serviceId, url, name) - the fragment arguments. */
  private readArguments(): void {
    const params: Record<string, Object> | undefined =
      router.getParams() as Record<string, Object> | undefined;
    if (params === undefined || params === null) {
      return;
    }
    const sid: Object | undefined = params['serviceId'];
    if (sid !== undefined && sid !== null) {
      this.serviceId = Number(sid.toString());
    }
    const channelUrl: Object | undefined = params['url'];
    if (channelUrl !== undefined && channelUrl !== null) {
      this.url = channelUrl.toString();
    }
    const channelName: Object | undefined = params['name'];
    if (channelName !== undefined && channelName !== null) {
      this.name = channelName.toString();
    }
  }

  private loadNotificationPermission(): void {
    ServiceLocator.get().notifications.areNewStreamsNotificationsEnabled()
      .then((enabled: boolean): void => {
        this.notificationsAllowed = enabled;
      })
      .catch((err: BusinessError): void => {
        hilog.warn(0x0000, TAG, 'Notification state unreadable: %{public}s', err.message);
      });
  }

  /* //////////////////////////////////////////////////////////////////////////
  // Loading - ExtractorHelper.getChannelInfo(serviceId, url, forceLoad)
  ////////////////////////////////////////////////////////////////////////// */

  private startLoading(forceLoad: boolean): void {
    // showLoading() -> animate(emptyStateView, false, 150): the kaomoji block belongs to the
    // channel being replaced, so it goes before this load, not when the next result lands.
    this.channelContentNotSupported = false;
    if (this.url.length === 0) {
      this.isLoading = false;
      this.isRefreshing = false;
      this.errorInfo = Localization.getString('general_error');
      return;
    }
    // The channel being replaced goes first, and its tabs with it.
    this.currentInfo = null;
    this.updateTabs();
    // currentWorker.dispose(): a result from the load being superseded is no longer wanted.
    this.workerGeneration++;
    this.runWorker(forceLoad);
  }

  private runWorker(forceLoad: boolean): void {
    const generation: number = this.workerGeneration;
    // checkCache() emits a cached Info synchronously on subscribe, so the source never paints
    // the loading state for one.
    this.isLoading = !this.isCachedChannel(forceLoad);
    this.errorInfo = null;
    ExtractorHelper.getChannelInfo(this.serviceId, this.url, forceLoad)
      .then((result: ChannelInfo): void => {
        if (generation !== this.workerGeneration) {
          return;
        }
        this.isLoading = false;
        this.handleResult(result);
      })
      .catch((err: BusinessError): void => {
        if (generation !== this.workerGeneration) {
          return;
        }
        this.showError(userMessageFor(err));
      });
  }

  /** ExtractorHelper.isCached(serviceId, url, InfoCache.Type.CHANNEL). */
  private isCachedChannel(forceLoad: boolean): boolean {
    if (forceLoad || this.serviceId < 0) {
      return false;
    }
    try {
      return ExtractorHelper.isCached(this.serviceId, this.url, InfoCacheType.CHANNEL);
    } catch (err) {
      // an unknown service id: the load below will report it properly
      return false;
    }
  }

  /** ErrorPanelHelper -> reloadContent() -> startLoading(true); also the pull-to-refresh. */
  private reloadContent(): void {
    this.startLoading(true);
  }

  private showError(message: string): void {
    // BaseStateFragment.showError() -> handleError(): the empty state and the loading bar come
    // down before the error panel goes up, so the three status layers are never stacked.
    this.channelContentNotSupported = false;
    this.isLoading = false;
    this.isRefreshing = false;
    this.errorInfo = message.length === 0 ? Localization.getString('general_error') : message;
    hilog.error(0x0000, TAG, 'Loading the channel failed: %{public}s', message);
  }

  /** showSnackBarError(): the source keeps the content and only reports; so does this. */
  private showSnackBarError(message: string): void {
    hilog.error(0x0000, TAG, '%{public}s', message);
    promptAction.showToast({ message: message, duration: 3000 });
  }

  /** handleResult(result): every binding this screen has, filled from the ChannelInfo. */
  private handleResult(result: ChannelInfo): void {
    this.currentInfo = result;
    this.serviceId = result.getServiceId();
    this.url = result.getUrl();
    this.name = result.getName();

    // "do not waste space for the banner, if the user disabled images or there is not one"
    const bannerUrl: string | null =
      shouldLoadImages() && result.getBanners().length > 0
        ? choosePreferredImage(result.getBanners()) : null;
    this.banner = bannerUrl === null ? '' : bannerUrl;
    this.banners = this.banner.length > 0;

    const avatarUrl: string | null = choosePreferredImage(result.getAvatars());
    this.avatar = avatarUrl === null ? '' : avatarUrl;
    const parentAvatarUrl: string | null =
      choosePreferredImage(result.getParentChannelAvatars());
    this.parentChannelAvatar = parentAvatarUrl === null ? '' : parentAvatarUrl;

    this.title = result.getName();
    // A negative count is "no count": the render branch below puts
    // @string/subscribers_count_not_available in its place.
    this.subscriberCount = result.getSubscriberCount() >= 0
      ? Localization.shortSubscriberCount(result.getSubscriberCount()) : '';

    this.parentChannelName = result.getParentChannelName();
    this.parentChannelRow = this.parentChannelName.length === 0 ? ''
      : Localization.getStringArgs('channel_created_by', [this.parentChannelName]);

    // updateRssButton(): visible only while the channel has a feed.
    const feed: string | null = result.getFeedUrl();
    this.feedUrl = feed === null ? '' : feed;

    // showContentNotSupportedIfNeeded().
    this.channelContentNotSupported = false;
    for (const throwable of result.getErrors()) {
      if (throwable instanceof ContentNotSupportedException) {
        this.channelContentNotSupported = true;
        break;
      }
    }

    this.isLoading = false;
    this.isRefreshing = false;
    this.errorInfo = null;

    // disposables.clear() + subscribeButtonMonitor.dispose(): the previous channel's observers
    // go before this one's are attached, or every reload doubles them.
    this.subscriptionMonitor.clear();

    this.updateTabs();
    this.updateSubscription(result);
    this.monitorSubscription();
  }

  /* //////////////////////////////////////////////////////////////////////////
  // Tabs - updateTabs()
  ////////////////////////////////////////////////////////////////////////// */

  /**
   * ChannelTabFragment.getInstance(serviceId, linkHandler, name) is handed the tab's own
   * ListLinkHandler OBJECT, not its URL. For Bandcamp that object is a
   * ReadyChannelTabListLinkHandler carrying the discography this page already fetched, and the
   * pager page below was given only getUrl() - so the tab rebuilt a plain handler from a URL
   * ending in /album, BandcampService took its non-ready branch, and the extractor asked
   * band_details for a band_id that was really that URL. Both Bandcamp tabs came back empty.
   *
   * Looked up by tab key instead of captured in the builder's closure, because the pager's
   * ForEach is keyed by that same tab name and reuses a child across two channels that share it.
   */
  private tabLinkHandlerFor(key: string): ListLinkHandler | null {
    for (const item of this.tabStrip) {
      if (item.key === key) {
        return item.linkHandler;
      }
    }
    return null;
  }

  private updateTabs(): void {
    const entries: ChannelTabItem[] = [];

    const info: ChannelInfo | null = this.currentInfo;
    if (info !== null && !this.channelContentNotSupported) {
      const prefs: Preferences = ServiceLocator.get().preferences;

      for (const linkHandler of info.getTabs()) {
        const filters: string[] = linkHandler.getContentFilters();
        if (filters.length === 0) {
          continue;
        }
        const tab: string = filters[0];
        if (showChannelTab(prefs, tab)) {
          entries.push(new ChannelTabItem(ChannelTabKind.CONTENT,
            Localization.getString(getTranslationKey(tab)), linkHandler, tab));
        }
      }

      // The About tab is always last, and only when the preference allows it.
      if (showChannelTabForKey(prefs, show_channel_tabs_about)) {
        entries.push(new ChannelTabItem(ChannelTabKind.ABOUT,
          Localization.getString('channel_tab_about'), null, 'about'));
      }
    }

    // notifyDataSetUpdate(), then the strip titles, then "restore previously selected tab".
    this.tabStrip = entries;
    this.tabTitles = entries.map((item: ChannelTabItem): string => item.title);
    this.selectedTabIndex = this.lastTab < this.tabStrip.length ? this.lastTab : 0;
  }

  /* //////////////////////////////////////////////////////////////////////////
  // Subscription
  ////////////////////////////////////////////////////////////////////////// */

  private async ensureServices(): Promise<SubscriptionManager | null> {
    const existing: SubscriptionManager | null = this.subscriptionManager;
    if (existing !== null) {
      return existing;
    }
    try {
      const context: common.Context = getContext(this) as common.Context;
      const db: AppDatabase = await AppDatabase.getInstance(context);
      this.database = db;
      const manager: SubscriptionManager = new SubscriptionManager(db);
      this.subscriptionManager = manager;
      return manager;
    } catch (err) {
      const failure: BusinessError = err as BusinessError;
      this.showSnackBarError(failure.message);
      return null;
    }
  }

  /**
   * monitorSubscription(info): the source observes a Room Flowable over this channel's row. The
   * port's writers announce themselves on SubscriptionManager.changes instead, so a subscribe made
   * on ANY screen still repaints this button.
   */
  private monitorSubscription(): void {
    this.ensureServices()
      .then((manager: SubscriptionManager | null): void => {
        if (manager === null) {
          return;
        }
        this.subscriptionMonitor.add(manager.changes.subscribeCallbacks((revision: number): void => {
          this.refreshSubscriptionSafely();
        }, (error: Error): void => {
          this.showSnackBarError(error.message);
        }));
        this.refreshSubscriptionSafely();
      })
      .catch((err: BusinessError): void => {
        this.showSnackBarError(err.message);
      });
  }

  private refreshSubscriptionSafely(): void {
    this.refreshSubscription().catch((err: BusinessError): void => {
      hilog.error(0x0000, TAG, 'Get subscription status failed: %{public}s', err.message);
    });
  }

  /** getSubscribeUpdateMonitor() + updateSubscribeButton(!isEmpty) + updateNotifyButton(). */
  private async refreshSubscription(): Promise<void> {
    const db: AppDatabase | null = this.database;
    if (db === null || this.url.length === 0) {
      return;
    }
    const entity: SubscriptionEntity | null =
      await SubscriptionDao.getSubscription(db, this.serviceId, this.url);
    const wasSubscribed: boolean = this.isSubscribed;

    this.channelSubscription = entity;
    this.isSubscribed = entity !== null;
    this.subscribeButtonState = Localization.getString(
      this.isSubscribed ? 'subscribed_button_title' : 'subscribe_button_title');
    this.notifyMenuItemState =
      entity !== null && entity.notificationMode === NotificationMode.ENABLED;

    // skip(1) + filter(notifications enabled): only the empty -> non-empty transition.
    if (this.subscriptionSeen && !wasSubscribed && this.isSubscribed
      && this.notificationsAllowed) {
      this.notifyPromptVisible = true;
    }
    this.subscriptionSeen = true;
  }

  /** mapOnSubscribe / mapOnUnsubscribe - which one runs is the DB row, not a local flag. */
  private toggleSubscription(): void {
    const info: ChannelInfo | null = this.currentInfo;
    const manager: SubscriptionManager | null = this.subscriptionManager;
    if (info === null || manager === null) {
      return;
    }
    const existing: SubscriptionEntity | null = this.channelSubscription;
    const written: Promise<number> = existing === null
      ? manager.insertSubscription(SubscriptionEntity.fromChannelInfo(info))
      : manager.deleteSubscription(existing.serviceId,
        existing.url === null ? '' : existing.url);
    // The button repaints from manager.changes, exactly as the Flowable repaints the source.
    written.catch((err: BusinessError): void => {
      this.showSnackBarError(err.message);
    });
  }

  /** updateSubscription(info): keep the stored row in step with what was just fetched. */
  private updateSubscription(info: ChannelInfo): void {
    this.ensureServices()
      .then((manager: SubscriptionManager | null): void => {
        if (manager === null) {
          return;
        }
        manager.updateChannelInfo(info).catch((err: BusinessError): void => {
          this.showSnackBarError(err.message);
        });
      })
      .catch((err: BusinessError): void => {
        this.showSnackBarError(err.message);
      });
  }

  /** setNotify(isEnabled). */
  private setNotify(isEnabled: boolean): void {
    const info: ChannelInfo | null = this.currentInfo;
    const manager: SubscriptionManager | null = this.subscriptionManager;
    this.notifyPromptVisible = false;
    if (info === null || manager === null) {
      return;
    }
    manager.updateNotificationMode(info.getServiceId(), info.getUrl(),
      isEnabled ? NotificationMode.ENABLED : NotificationMode.DISABLED)
      .catch((err: BusinessError): void => {
        this.showSnackBarError(err.message);
      });
  }

  /* //////////////////////////////////////////////////////////////////////////
  // Menu actions (the source's MenuProvider.onMenuItemSelected)
  ////////////////////////////////////////////////////////////////////////// */

  /** openSubChannel: NavigationHelper.openChannelFragment(parentChannelUrl); empty url = no-op. */
  /**
   * The CoordinatorLayout half of `scroll|exitUntilCollapsed`. A NestedScrollingChild reports its
   * scroll upwards and AppBarLayout consumes it into its own height; ArkUI has no such channel
   * across a pager, so the tab's List hands its delta here instead.
   *
   * NOT identical to the source: there the header consumes the gesture FIRST and the list only
   * starts moving once the header has fully collapsed. Here the list has already scrolled by the
   * time the delta arrives, so the two move together. The header still narrows on scroll and
   * re-expands on scroll-back, which is what this screen was missing entirely.
   */
  private onContentScrolled(delta: number): void {
    const range: number = this.headerNaturalHeight;
    if (range <= 0) {
      return;
    }
    let next: number = this.headerCollapsed + delta;
    if (next < 0) {
      next = 0;
    } else if (next > range) {
      next = range;
    }
    if (next !== this.headerCollapsed) {
      this.headerCollapsed = next;
    }
  }

  private openSubChannel(): void {
    const info: ChannelInfo | null = this.currentInfo;
    if (info === null || info.getParentChannelUrl().length === 0) {
      return;
    }
    const params: Record<string, Object> = {
      'serviceId': info.getServiceId(),
      'url': info.getParentChannelUrl(),
      'name': info.getParentChannelName()
    };
    router.pushUrl({ url: 'pages/ChannelFragmentPage', params: params })
      .catch((err: BusinessError): void => {
        this.showSnackBarError(err.message);
      });
  }

  /** menu_item_rss: ShareUtils.openUrlInApp(currentInfo.getFeedUrl()). */
  private openFeedUrl(): void {
    if (this.feedUrl.length === 0) {
      return;
    }
    const share: ShareUtils = ServiceLocator.get().share;
    share.openUrlInBrowser(this.feedUrl)
      .catch((err: BusinessError): void => {
        this.showSnackBarError(err.message);
      });
  }

  /** menu_item_share: ShareUtils.shareText(name, currentInfo.getOriginalUrl(), avatars). */
  private shareChannel(): void {
    const info: ChannelInfo | null = this.currentInfo;
    if (info === null) {
      return;
    }
    const share: ShareUtils = ServiceLocator.get().share;
    share.shareText(this.name, info.getOriginalUrl())
      .catch((err: BusinessError): void => {
        this.showSnackBarError(err.message);
      });
  }

  /** menu_item_openInBrowser: ShareUtils.openUrlInBrowser(currentInfo.getOriginalUrl()). */
  private openInBrowser(): void {
    // The loaded channel's own url when there is one - and the REQUESTED url when there is not.
    //
    // The error panel's OPEN IN BROWSER entry shares this handler, and on that panel currentInfo
    // is null by definition: the load is what failed. Returning early left the button inert in
    // the one situation where opening the page outside the app is the user's only way to reach it.
    //
    // BaseListInfoFragment, which ChannelFragment inherits from, passes exactly this url as the
    // ErrorInfo's openInBrowserUrl:
    //     showError(new ErrorInfo(throwable, errorUserAction, "Start loading: " + url,
    //                             serviceId, url));
    const info: ChannelInfo | null = this.currentInfo;
    const target: string = info === null ? this.url : info.getOriginalUrl();
    if (target.length === 0) {
      return;
    }
    const share: ShareUtils = ServiceLocator.get().share;
    share.openUrlInBrowser(target)
      .catch((err: BusinessError): void => {
        this.showSnackBarError(err.message);
      });
  }

  /** action_settings: NavigationHelper.openSettings(context). */
  private openSettings(): void {
    this.overflowOpen = false;
    router.pushUrl({ url: 'pages/SettingsActivityPage' })
      .catch((err: BusinessError): void => {
        this.showSnackBarError(err.message);
      });
  }

  /* //////////////////////////////////////////////////////////////////////////
  // build
  ////////////////////////////////////////////////////////////////////////// */

  /** channel_metadata - the collapsing header's content. */
  @Builder
  channelMetadata() {
    Column() {
      // channel_banner_image carries @drawable/placeholder_channel_banner until a real banner
      // arrives, so the header keeps its band. The port dropped the whole image when the channel
      // had no banner yet - device-checked against the reference, which still shows the striped
      // placeholder band while a channel that failed to load sits behind an error panel.
      if (this.banners || this.errorInfo !== null) {
        Image(this.banners ? this.banner : $r('app.media.placeholder_channel_banner'))
          .id('channel_banner_image')
          // adjustViewBounds + scaleType="fitCenter" + maxHeight="70dp": the banner keeps its
          // own aspect ratio and is only capped, which is what the capture's 59 vp band is.
          .width('100%')
          .constraintSize({ maxHeight: BANNER_MAX_HEIGHT })
          .objectFit(ImageFit.Contain)
      }

      Row() {
        Stack({ alignContent: Alignment.BottomEnd }) {
          Image(this.avatar.length === 0 ? $r('app.media.placeholder_person') : this.avatar)
            .id('channel_avatar_view')
            .width($r('app.float.channel_avatar_size'))
            .height($r('app.float.channel_avatar_size'))
            .padding(1)
            .borderRadius(AVATAR_SIZE / 2)
            .borderWidth(AVATAR_STROKE)
            .borderColor($r('app.color.on_primary'))
            .clip(true)
            .objectFit(ImageFit.Cover)
            .backgroundColor(servicePrimaryColor(this.activeServiceId))

          // sub_channel_avatar_view: gone until there is a parent channel.
          if (this.parentChannelName.length > 0) {
            Image(this.parentChannelAvatar.length === 0
              ? $r('app.media.placeholder_person') : this.parentChannelAvatar)
              .id('sub_channel_avatar_view')
              .width($r('app.float.sub_channel_avatar_size'))
              .height($r('app.float.sub_channel_avatar_size'))
              .padding(1)
              .borderRadius(SUB_AVATAR_SIZE / 2)
              .borderWidth(AVATAR_STROKE)
              .borderColor($r('app.color.on_primary'))
              .clip(true)
              .objectFit(ImageFit.Cover)
              .backgroundColor(servicePrimaryColor(this.activeServiceId))
              .onClick(() => {
                this.openSubChannel();
              })
          }
        }
        // layout_constraintVertical_bias="1.0" + marginVertical 8dp: the avatar is anchored to
        // the header's bottom edge and the top 22 vp of it overhangs the banner, so only its
        // lower 48 vp take part in the row's height.
        .width(AVATAR_SIZE)
        .height(AVATAR_ROW_FOOTPRINT)
        .margin({ left: SPACE_S, bottom: SPACE_S })

        Column() {
          // The header title wraps: the row is a constraintSize minHeight precisely so this
          // block can grow, and the capture shows a name cut to "Ruhi Cenet ..." with room to
          // spare beside SUBSCRIBE. Only the TOOLBAR title is meant to ellipsise on one line.
          Text(this.title)
            .id('channel_title_view')
            .maxLines(2)
            .width('100%')
            .fontSize(CHANNEL_TITLE_SIZE)
            // ToolbarTheme sets android:textColorPrimary to ?attr/actionColor = @color/white.
            .fontColor($r('app.color.on_primary'))
            .textOverflow({ overflow: TextOverflow.Ellipsis })

          if (this.parentChannelName.length > 0) {
            Text(this.parentChannelRow)
              .id('sub_channel_title_view')
              .maxLines(1)
              .width('100%')
              .fontSize(SUB_CHANNEL_TITLE_SIZE)
              .fontColor($r('app.color.on_primary'))
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .onClick(() => {
                this.openSubChannel();
              })
          }

          // Both this line and the subscribe button are populated by handleResult() and start
          // GONE, so a channel that never loaded shows NEITHER on the reference - only the banner,
          // the avatar and the name it was opened with. The port drew them regardless, so a
          // network failure still advertised "Subscriber count unavailable" and an actionable
          // SUBSCRIBE for a channel it knew nothing about.
          if (this.errorInfo === null) {
            // result.getSubscriberCount() < 0 -> @string/subscribers_count_not_available.
            Text(this.subscriberCount.length > 0
              ? this.subscriberCount
              : Localization.getString('subscribers_count_not_available'))
              .id('channel_subscriber_view')
            .width('100%')
            .fontSize(CHANNEL_SUBSCRIBER_SIZE)
            .fontColor($r('app.color.on_primary'))
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .margin({ top: 2 })
          }
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
        .margin({ left: SPACE_S, right: SPACE_XS, bottom: SPACE_S })

        // updateSubscribeButton(isSubscribed): the label follows the subscriptions table. S5 adds
        // the background/text-colour crossfade the source animates alongside it.
        if (this.errorInfo === null) {
          Text(this.isSubscribed
            ? Localization.getString('subscribed_button_title')
            : this.subscribeButtonState)
            .id('channel_subscribe_button')
          .fontSize($r('app.float.channel_rss_title_size'))
          .fontWeight(FontWeight.Medium)
          .textCase(TextCase.UpperCase)
          .textAlign(TextAlign.Center)
          .height(BUTTON_HEIGHT)
          .constraintSize({ minWidth: BUTTON_MIN_WIDTH })
          .padding({ left: BUTTON_PADDING_H, right: BUTTON_PADDING_H })
          .borderRadius(BUTTON_RADIUS)
          .alignSelf(ItemAlign.Center)
          .margin({ left: SPACE_XS, right: BUTTON_INSET })
          .fontColor(this.isSubscribed
            ? $r('app.color.subscribed_text_color') : $r('app.color.subscribe_text_color'))
          .backgroundColor(this.isSubscribed
            ? $r('app.color.subscribed_background_color') : SUBSCRIBE_BACKGROUND)
          // animateBackgroundColor(300) / animateTextColor(200) in updateSubscribeButton().
          .animation({ duration: 300, curve: Curve.Linear })
            .onClick(() => {
              this.subscribeClicks.onNext(Date.now());
            })
        }
      }
      .width('100%')
      // 56 vp in the capture; a constraint rather than a fixed height so the parent-channel
      // variant (which adds sub_channel_title_view) grows instead of clipping.
      .constraintSize({ minHeight: HEADER_ROW_HEIGHT })
      .alignItems(VerticalAlign.Bottom)
    }
    .id('channel_metadata')
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  /**
   * The adapter's items: ChannelTabFragment.getInstance(...) per enabled tab, and the trailing
   * `new ChannelAboutFragment(currentInfo)`. Both are hostedBy this screen, so they are MOUNTED.
   */
  @Builder
  pagerPages() {
    ForEach(this.tabStrip, (item: ChannelTabItem) => {
      if (item.kind === ChannelTabKind.ABOUT) {
        // `new ChannelAboutFragment(currentInfo)`: the About tab loads nothing itself, so the
        // host has to hand it the ChannelInfo. handleResult() sets currentInfo before
        // updateTabs() fills tabStrip, so it is never null by the time this ForEach runs.
        ChannelAboutFragmentPage({ channelInfo: this.currentInfo })
      } else {
        // ChannelTabFragment.getInstance(serviceId, linkHandler, name): the tab loads its own
        // items, so the host hands it only those identifying arguments.
        ChannelTabFragmentPage({
          hostServiceId: this.serviceId,
          hostChannelUrl: item.linkHandler === null ? this.url : item.linkHandler.getUrl(),
          hostTabFilter: item.key,
          hostChannelName: this.name,
          hostLinkHandler: (key: string): ListLinkHandler | null => {
            return this.tabLinkHandlerFor(key);
          },
          hostOnScrolled: (delta: number): void => {
            this.onContentScrolled(delta);
          }
        })
      }
    }, (item: ChannelTabItem) => item.key)
  }

  build() {
    Stack({ alignContent: Alignment.Bottom }) {
      Column() {
        // The activity toolbar the MenuProvider adds its items to.
        Row() {
          // ToolbarTheme sets tint/iconTint to ?attr/actionColor = @color/white, which is why
          // every one of these black source SVGs renders white in the capture.
          Image($r('app.media.ic_arrow_back'))
            .id('toolbar_back')
            .accessibilityText($r('app.string.navigate_back'))
            .width(TOOLBAR_ICON)
            .height(TOOLBAR_ICON)
            .fillColor($r('app.color.on_primary'))
            .margin({ left: TOOLBAR_ICON_INSET, right: TOOLBAR_NAV_GAP })
            .onClick(() => {
              router.back();
            })

          Text(this.title)
            .maxLines(1)
            .layoutWeight(1)
            .fontSize(TOOLBAR_TITLE_SIZE)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.on_primary'))
            .textOverflow({ overflow: TextOverflow.Ellipsis })

          // updateRssButton(): visible only while the channel has a feed url.
          if (this.feedUrl.length > 0) {
            Image($r('app.media.ic_rss_feed'))
              .id('menu_item_rss')
              .accessibilityText($r('app.string.rss_button_title'))
              .width(TOOLBAR_ICON)
              .height(TOOLBAR_ICON)
              .fillColor($r('app.color.on_primary'))
              .margin({ left: 12, right: 12 })
              .onClick(() => {
                this.openFeedUrl();
              })
          }

          Image($r('app.media.ic_share'))
            .id('menu_item_share')
            .accessibilityText($r('app.string.share'))
            .width(TOOLBAR_ICON)
            .height(TOOLBAR_ICON)
            .fillColor($r('app.color.on_primary'))
            .margin({ left: 12, right: 12 })
            .onClick(() => {
              this.shareChannel();
            })

          Image($r('app.media.ic_more_vert'))
            .id('toolbar_overflow')
            .accessibilityText($r('app.string.more_options'))
            .width(TOOLBAR_ICON)
            .height(TOOLBAR_ICON)
            .fillColor($r('app.color.on_primary'))
            .margin({ left: SPACE_S, right: SPACE_S })
            .onClick(() => {
              this.overflowOpen = !this.overflowOpen;
            })
        }
        .width('100%')
        .height(TOOLBAR_HEIGHT)
        .alignItems(VerticalAlign.Center)
        .backgroundColor(servicePrimaryColor(this.activeServiceId))

        // The showAsAction="never" items, which live behind the overflow in the source too.
        if (this.overflowOpen) {
          Column() {
            // updateNotifyButton(): present only with a subscription, enabled only when new-stream
            // notifications are on.
            if (this.channelSubscription !== null) {
              Row() {
                Text($r('app.string.get_notified'))
                  .layoutWeight(1)
                  .fontSize(MENU_ITEM_TEXT_SIZE)
                  .fontColor(MENU_TEXT)
                // menu_item_notify is android:checkable="true", and a checkable item in a
                // PopupMenu is drawn by ListMenuItemView.insertCheckBox(): a real CheckBox,
                // appended after the title, whose checked state is setChecked(). A tick
                // character in its place is the "notification box marking" this card is about.
                // The row owns the click, so the box itself does not take the hit.
                Checkbox()
                  .width(MENU_CHECKBOX_SIZE)
                  .height(MENU_CHECKBOX_SIZE)
                  .shape(CheckBoxShape.ROUNDED_SQUARE)
                  .selectedColor(servicePrimaryColor(this.activeServiceId))
                  .select(this.notifyMenuItemState)
                  .hitTestBehavior(HitTestMode.None)
                  .accessibilityLevel('no')
              }
              .id('menu_item_notify')
              .width('100%')
              .height(MENU_ITEM_HEIGHT)
              .padding({ left: SPACE_M, right: SPACE_M })
              .opacity(this.notificationsAllowed ? 1 : 0.38)
              .enabled(this.notificationsAllowed)
              .onClick(() => {
                this.overflowOpen = false;
                this.setNotify(!this.notifyMenuItemState);
              })
            }

            Text($r('app.string.settings'))
              .id('action_settings')
              .width('100%')
              .height(MENU_ITEM_HEIGHT)
              .padding({ left: SPACE_M, right: SPACE_M })
              .fontSize(MENU_ITEM_TEXT_SIZE)
              .fontColor(MENU_TEXT)
              .onClick(() => {
                this.openSettings();
              })

            Text($r('app.string.open_in_browser'))
              .id('menu_item_openInBrowser')
              .width('100%')
              .height(MENU_ITEM_HEIGHT)
              .padding({ left: SPACE_M, right: SPACE_M })
              .fontSize(MENU_ITEM_TEXT_SIZE)
              .fontColor(MENU_TEXT)
              .onClick(() => {
                this.overflowOpen = false;
                this.openInBrowser();
              })
          }
          // showAsAction="never" is a PopupMenu in the source: a floating card under the
          // overflow icon, not a band that pushes the header down. position() takes it out of
          // the column's flow without moving it in the tree.
          .width(MENU_WIDTH)
          .position({ top: TOOLBAR_HEIGHT, right: SPACE_S })
          .zIndex(2)
          .padding({ top: SPACE_S, bottom: SPACE_S })
          .backgroundColor(MENU_SURFACE)
          .borderRadius(SPACE_XS)
          .shadow({ radius: 12, color: '#33000000', offsetY: 3 })
        }

        CustomCollapsingToolbarLayout({
          collapsed: this.headerCollapsed,
          onMeasured: (height: number): void => {
            this.headerNaturalHeight = height;
          }
        }) {
          this.channelMetadata()
        }

        ScrollableTabLayout({ titles: this.tabTitles, selectedIndex: $selectedTabIndex })

        // The pull-to-refresh the channel content hangs under: reloadContent(), the same entry
        // point the error panel's Retry uses.
        Refresh({ refreshing: $$this.isRefreshing }) {
          Stack() {
            // view_pager: one ChannelTabFragment per enabled tab, plus the trailing About page.
            TabAdapter({ count: this.tabStrip.length, selectedIndex: $selectedTabIndex }) {
              this.pagerPages()
            }

            if (this.isLoading) {
              LoadingProgress()
                .id('loading_progress_bar')
                .width(48)
                .height(48)
                // an indeterminate ProgressBar takes ?attr/colorAccent.
                .color($r('app.color.accent'))
            }

            // showContentNotSupportedIfNeeded(): the sad kaomoji block, in place of any tabs.
            if (this.channelContentNotSupported) {
              Column() {
                Text('(︶︹︺)')
                  .id('channel_kaomoji')
                  .fontSize(KAOMOJI_TEXT_SIZE)
                  .fontFamily('monospace')
                  .fontColor(BODY_TEXT)
                  .margin({ bottom: 10 })
                Text($r('app.string.content_not_supported'))
                  .id('error_content_not_supported')
                  .fontSize(15)
                  .fontColor(BODY_TEXT)
                  .textAlign(TextAlign.Center)
                  .margin({ top: 20 })
              }
              .id('empty_state_view')
              .alignItems(HorizontalAlign.Center)
              .padding({ top: 90, left: SPACE_M, right: SPACE_M })
            }

            if (this.errorInfo !== null) {
              Column() {
                Text(this.errorInfo)
                  .id('error_message_view')
                  .fontSize(16)
                  .fontWeight(FontWeight.Bold)
                  .fontColor(BODY_TEXT)
                  .textAlign(TextAlign.Center)
                // ServiceColoredButton: colorButtonNormal=?attr/colorPrimary, text
                // @color/subscribe_text_color, textAllCaps.
                Text(Localization.buttonLabel('retry'))
                  .id('error_retry_button')
                  .fontSize(16)
                  .textCase(TextCase.UpperCase)
                  .textAlign(TextAlign.Center)
                  .fontColor($r('app.color.subscribe_text_color'))
                  .backgroundColor(servicePrimaryColor(this.activeServiceId))
                  .borderRadius(BUTTON_RADIUS)
                  .height(BUTTON_HEIGHT)
                  .constraintSize({ minWidth: BUTTON_MIN_WIDTH })
                  .padding({ left: SPACE_M, right: SPACE_M })
                  .margin({ top: SPACE_XS })
                  .onClick(() => {
                    this.reloadContent();
                  })
                Text(Localization.buttonLabel('open_in_browser'))
                  .id('error_open_in_browser')
                  .fontSize(16)
                  .textCase(TextCase.UpperCase)
                  .textAlign(TextAlign.Center)
                  .fontColor($r('app.color.subscribe_text_color'))
                  .backgroundColor(servicePrimaryColor(this.activeServiceId))
                  .borderRadius(BUTTON_RADIUS)
                  .height(BUTTON_HEIGHT)
                  .constraintSize({ minWidth: BUTTON_MIN_WIDTH })
                  .padding({ left: SPACE_M, right: SPACE_M })
                  .margin({ top: SPACE_XS, bottom: SPACE_S })
                  .onClick(() => {
                    this.openInBrowser();
                  })
              }
              .id('error_panel')
              .alignItems(HorizontalAlign.Center)
              .padding(SPACE_M)
            }
          }
          .width('100%')
          .height('100%')
          .backgroundColor(themedBackground(this.blackTheme))
        }
        .width('100%')
        .layoutWeight(1)
        .onRefreshing(() => {
          this.reloadContent();
        })

        // fragment_player_holder, docked. This screen is a pushUrl target, so MainActivityPage's
        // own bar is underneath it in the stack and cannot draw here. It goes inside the content
        // Column rather than into the root Stack so that the Refresh above it - which carries
        // layoutWeight(1) - shrinks by the bar's height instead of having its last row covered.
        // Skipped when the shell embeds this screen as a tab, where the shell's own bar is showing.
        if (!this.hostedInMainShell) {
          MiniPlayerBar({
            idPrefix: 'channel_',
            onVisibilityChange: (visible: boolean): void => {
              this.playerBarVisible = visible;
            }
          })
        }
      }
      .width('100%')
      .height('100%')

      // showNotifySnackbar(): offered once, right after subscribing.
      if (this.notifyPromptVisible) {
        Row() {
          Text($r('app.string.you_successfully_subscribed'))
            .layoutWeight(1)
            .fontSize(14)
            .fontColor($r('app.color.white'))
          Text($r('app.string.get_notified'))
            .id('Get notified')
            .fontSize(14)
            .fontWeight(FontWeight.Medium)
            .textCase(TextCase.UpperCase)
            .fontColor($r('app.color.white'))
            .padding(SPACE_S)
            .onClick(() => {
              this.setNotify(true);
            })
        }
        .width('100%')
        .constraintSize({ minHeight: 48 })
        .padding({ left: SPACE_M, right: SPACE_S, top: SPACE_S, bottom: SPACE_S })
        .alignItems(VerticalAlign.Center)
        .backgroundColor(SNACKBAR_BACKGROUND)
        // The snackbar is docked to the same bottom edge of the root Stack as the player bar, so
        // it is lifted clear of it for as long as the bar is up. MINI_PLAYER_HEIGHT is private to
        // MiniPlayerBar.ets; this mirrors its value.
        .offset({ y: this.playerBarVisible ? -MINI_PLAYER_BAR_HEIGHT : 0 })
      }
    }
    .id('ChannelFragmentPage')
    .width('100%')
    .height('100%')
    .backgroundColor(themedBackground(this.blackTheme))
  }
}
