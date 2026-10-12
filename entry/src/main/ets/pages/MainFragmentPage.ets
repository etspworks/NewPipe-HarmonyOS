/**
 * S3 — MainFragment (screen_main), structure from fragment_main.xml + MainFragment.java.
 *
 * The cold-start content of MainActivity: it is ATTACHED into fragment_holder, never pushed as a
 * route, so MainActivityPage renders this struct directly (the file stays a registered page so the
 * deep link to MainFragment still resolves). A pure tab host — it owns NO list and makes NO
 * network call; every page's content belongs to the fragment behind that tab.
 *
 * fragment_main.xml is exactly two views: the ScrollableTabLayout `main_tab_layout` and the
 * ViewPager `pager`. setupTabs() rebuilds the SelectedTabsPagerAdapter whenever the persisted tab
 * set changed, then updateTabsIconAndDescription() gives each strip cell the tab's ICON with the
 * tab NAME as its contentDescription, and updateTitleForTab() drives the action-bar title from the
 * SELECTED tab.
 *
 * The tab SET is user-configurable at runtime (TabsManager, persisted as JSON), so it is modelled
 * as DATA, never a fixed bar. S4 binds loadTabs() to the real TabsManager; the body below is the
 * source's own default tab set, which is what TabsManager returns when the preference is unset.
 *
 * S5 — styled from results/traversal-source/pages/fragment_MainFragment/base.png and the app-level
 * style baseline in state.json generation.styleBaseline. The strip's own colour scheme lives in
 * ScrollableTabLayout, which belongs to another screen and is not edited here.
 */
import { router, promptAction } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';

import {
  Tab,
  TabJson,
  KioskTab,
  SubscriptionsTab,
  BookmarksTab,
  DefaultKioskTab,
  FeedTab
} from '../model/app/Tab';
import { ScrollableTabLayout } from '../components/ScrollableTabLayout';
import { SelectedTabsPagerAdapter, sameTabs } from '../components/SelectedTabsPagerAdapter';
import { AppPreferences } from '../common/prefs/Preferences';
import { Localization } from '../common/i18n/Localization';
import {
  saved_tabs_key,
  main_tabs_position_key,
  youtube_restricted_mode_enabled,
  current_service_key,
  default_service_value
} from '../common/prefs/SettingsKeys';
import { NewPipe } from '../common/extractor/core/NewPipe';
import { YouTube } from '../common/extractor/ServiceRegistry';

import { BlankFragmentPage } from './BlankFragmentPage';
import { SubscriptionFragmentPage } from './SubscriptionFragmentPage';
import { FeedFragmentPage } from './FeedFragmentPage';
import { BookmarkFragmentPage } from './BookmarkFragmentPage';
import { StatisticsPlaylistFragmentPage } from './StatisticsPlaylistFragmentPage';
import { KioskFragmentPage } from './KioskFragmentPage';
import { DefaultKioskFragmentPage } from './DefaultKioskFragmentPage';
import { ChannelFragmentPage } from './ChannelFragmentPage';
import { PlaylistFragmentPage } from './PlaylistFragmentPage';
import { LocalPlaylistFragmentPage } from './LocalPlaylistFragmentPage';
import { BLACK_THEME_KEY, themedBackground } from '../common/theme/ThemeBackground';

const TAG: string = 'MainFragmentPage';

/* The host toolbar's tokens (state.json generation.styleBaseline), reused verbatim so the bar this
   page draws for itself is the SAME bar the activity draws when it hosts this fragment. */
const TOOLBAR_HEIGHT: number = 56;
const TOOLBAR_TITLE_SIZE: number = 20;
const TOOLBAR_ACTION_SIZE: number = 48;
const TOOLBAR_ACTION_INSET: number = 12;
const TOOLBAR_TITLE_INSET: number = 16;
const COLOR_PRIMARY: Resource = $r('app.color.primary');
const COLOR_ON_PRIMARY: Resource = $r('app.color.on_primary');

/**
 * The two arguments NavigationHelper.openSearchFragment(getFM(), serviceId, searchString) takes.
 * A declared class, not an object literal: ArkTS refuses an untyped `{ ... }`.
 */
class SearchParams {
  serviceId: number;
  searchString: string;

  constructor(serviceId: number, searchString: string) {
    this.serviceId = serviceId;
    this.searchString = searchString;
  }
}

/** The `tabs` array TabsJsonHelper reads and writes. */
interface SavedTabsJson {
  tabs?: TabJson[];
}


@Entry
@Component
export struct MainFragmentPage {
  /** ThemeHelper's black theme: the window background follows it. */
  @StorageProp(BLACK_THEME_KEY) blackTheme: boolean = false;

  /** tabsList <- tabsManager.getTabs(), the persisted tab set. */
  @Prop tabStripItems: Tab[] = [];
  /** binding.pager.getCurrentItem(); onTabSelected/onTabReselected move it. */
  @State @Watch('onTabSelected') selectedTabIndex: number = 0;
  /**
   * updateTitleForTab(): setTitle(tabsList.get(position).getTabName()).
   *
   * The title is written INTO the host activity's toolbar, exactly as the source does — MainFragment
   * has no toolbar of its own (fragment_main.xml is a ScrollableTabLayout plus a ViewPager, and
   * S0157 shows one `toolbar_layout` at [0,72][1080,240] with `fragment_holder` starting below it
   * at y=240). AppStorage is the hand-off: MainActivityPage renders this value in the one toolbar.
   */
  @StorageLink('mainActionBarTitle') actionBarTitle: string = '';
  /**
   * Which fragment the selected tab hosts. A front-page fragment's menu is drawn by the ACTIVITY's
   * toolbar, so the activity has to know whose menu it is showing - the same hand-off as the title
   * above, one key along.
   */
  @StorageLink('mainActiveTabContent') activeTabContent: string = '';

  /**
   * onOptionsItemSelected(action_search) is dispatched by the ACTIVITY (it owns the toolbar view)
   * to the FRAGMENT, which performs the navigation — so the tap site lives in MainActivityPage's
   * toolbar and the push stays here, where the source puts it. The host bumps this counter; the
   * watch below runs MainFragment's own handler.
   */
  @StorageLink('mainSearchRequest') @Watch('onSearchRequested') mainSearchRequest: number = 0;
  /** The shell publishes the drawer's service choice here; a change rebuilds the tabs. */
  @StorageProp('mainSelectedServiceId') @Watch('onServiceChanged') activeServiceId: number = -1;
  /**
   * TC-SETTINGS-687: the tab list changed under us. This page is an @Entry hosted as a child of
   * MainActivityPage, so the routed page owns the lifecycle and onPageShow below does not fire
   * when the settings stack is popped back to the shell - the strip kept the order it was built
   * with until the app was restarted. ChooseTabsFragmentPage bumps this counter when it saves.
   */
  @StorageProp('savedTabsRevision') @Watch('onSavedTabsChanged') private savedTabsRevision: number = 0;

  /**
   * onTabReselected(tab). The list belongs to the fragment BEHIND the tab, two container
   * boundaries down, so the strip's second tap reaches it the way mainSearchRequest reaches this
   * page from the shell: a counter in AppStorage that the hosted page @Watch-es.
   */
  @StorageLink('mainTabReselectRequest') tabReselectRequest: number = 0;
  /**
   * MainFragment.onCreate calls setHasOptionsMenu(true) and onCreateOptionsMenu inflates
   * menu_main_fragment (MainFragment.java:75,162) — action_search is the FRAGMENT's menu item, not
   * the activity's, and the source renders it in whatever ActionBar is hosting the fragment. When
   * MainActivityPage hosts this struct it supplies that bar; when this file is reached as a ROUTE
   * (main_pages.json registers it, and the replay lands on pages/MainFragmentPage) there is no host
   * and the menu had nowhere to render, so the required action_search contract found nothing in the
   * tree. onPageShow is the discriminator: ArkUI runs page lifecycle on the routed page's @Entry
   * component only, so it fires here exactly when this page IS the route — never for the hosted
   * child, which keeps the id unique and stops a second 56vp band from stacking on the host's.
   */
  @StorageProp('mainShellOwnsToolbar') private shellOwnsToolbar: boolean = false;
  /**
   * prefs.getBoolean(main_tabs_position_key): the strip moves to ALIGN_PARENT_BOTTOM. Published to
   * AppStorage by aboutToAppear and by the appearance setting, so a hosted page (which never gets
   * onPageShow) follows the toggle without being left and re-entered.
   */
  @StorageProp('mainTabsPositionBottom') mainTabsPositionBottom: boolean = false;
  /** A change to this (or hasTabsChanged) makes onResume run setupTabs() again. */
  @State youtubeRestrictedModeEnabled: boolean = false;
  /** setupTabs() is reading the persisted set; the strip is empty until it answers. */
  @State isLoading: boolean = true;
  /**
   * getItem(position)'s catch(Throwable): a tab whose fragment cannot be built becomes a
   * BlankFragment carrying the ErrorInfo — this is that message.
   */
  @State errorInfo: string | null = null;

  aboutToAppear(): void {
    const store: AppPreferences = AppPreferences.instance();
    AppStorage.setOrCreate<boolean>('mainTabsPositionBottom',
      store.getBooleanSync(main_tabs_position_key, false));
    this.youtubeRestrictedModeEnabled = store.getBooleanSync(youtube_restricted_mode_enabled, false);
    this.setupTabs();
  }

  /**
   * onResume(): setupTabs() runs again when the restricted-mode preference changed or the saved
   * tab set did — the two things that make the pager adapter stale.
   */
  onPageShow(): void {
    const store: AppPreferences = AppPreferences.instance();
    const restricted: boolean = store.getBooleanSync(youtube_restricted_mode_enabled, false);
    const tabsChanged: boolean = !sameTabs(this.tabStripItems, this.loadTabs());
    if (this.youtubeRestrictedModeEnabled !== restricted || tabsChanged) {
      this.youtubeRestrictedModeEnabled = restricted;
      this.setupTabs();
    }
  }

  /**
   * setupTabs(): reload the tab list, rebuild the adapter when it differs, then retitle. In ArkUI
   * the children ARE the adapter, so `pagerAdapter == null || !sameTabs(...)` is the assignment
   * below: an unchanged list is left alone, which keeps the shown page.
   */
  /**
   * ActivityCompat.recreate() in the source; here the tab set is service-dependent (the kiosk
   * tabs are), so a service change has to rebuild it, and the pager keys below carry the service
   * so every tab's content is rebuilt with it rather than kept.
   */
  private onSavedTabsChanged(): void {
    this.setupTabs();
  }

  private onServiceChanged(): void {
    this.setupTabs();
  }

  private setupTabs(): void {
    this.isLoading = true;
    const tabs: Tab[] = this.loadTabs();
    if (this.selectedTabIndex >= tabs.length) {
      this.selectedTabIndex = 0;
    }
    // The source guards only the LIST assignment with `!tabsList.equals(tabs)`;
    // updateTabsIconAndDescription() runs unconditionally after it, because the tab SET can be
    // identical while its labels and icons change. A service switch is exactly that case:
    // DefaultKioskTab's name and icon are read from the newly selected service's default kiosk,
    // so the same four tabs mean Trending/flame on YouTube and Featured/star on Bandcamp.
    //
    // Here the strip IS the data - ScrollableTabLayout takes titles and icons by value - so the
    // port's `if (!sameTabs(...))` suppressed the refresh the source does outside it, and the
    // strip kept the icons of whichever service was selected when the page was built. Assigning
    // the array unconditionally is that unconditional update: a new identity is what makes
    // tabNames() and tabIcons() run again.
    this.tabStripItems = tabs;
    this.updateTitleForTab(this.selectedTabIndex);
    this.isLoading = false;
  }

  /**
   * TabsManager.getTabs() -> TabsJsonHelper.getTabsFromJson(saved_tabs_key): an empty, absent or
   * unparseable value falls back to the default set, and a tab with an unknown id is dropped.
   */
  private loadTabs(): Tab[] {
    const saved: string = AppPreferences.instance().getStringSync(saved_tabs_key, '');
    if (saved.length === 0) {
      return MainFragmentPage.defaultTabs();
    }
    let entries: TabJson[] = [];
    try {
      const outer: SavedTabsJson = JSON.parse(saved) as SavedTabsJson;
      const raw: TabJson[] | undefined = outer.tabs;
      if (raw === undefined || raw === null) {
        // "JSON doesn't contain \"tabs\" array" — the InvalidJsonException branch.
        this.showInvalidJson();
        return MainFragmentPage.defaultTabs();
      }
      entries = raw;
    } catch (err) {
      hilog.warn(0x0000, TAG, 'saved tabs unparseable: %{public}s', (err as Error).message);
      this.showInvalidJson();
      return MainFragmentPage.defaultTabs();
    }

    const tabs: Tab[] = [];
    for (const entry of entries) {
      const tab: Tab | null = Tab.fromJson(entry);
      if (tab !== null) {
        tabs.push(tab);
      }
    }
    return tabs.length === 0 ? MainFragmentPage.defaultTabs() : tabs;
  }

  /** TabsJsonHelper.FALLBACK_INITIAL_TABS_LIST (TabsJsonHelper.java:22-26):
   * DefaultKiosk, Feed, Subscriptions, Bookmarks. FEED is the app's "What's New"
   * tab; dropping it shipped a three-tab default the source never had. Kept in sync
   * with the identical list in ChooseTabsFragmentPage. */
  private static defaultTabs(): Tab[] {
    return [new DefaultKioskTab(), new FeedTab(), new SubscriptionsTab(),
            new BookmarksTab()];
  }

  private showInvalidJson(): void {
    this.errorInfo = Localization.getString('saved_tabs_invalid_json');
    promptAction.showToast({
      message: $r('app.string.saved_tabs_invalid_json'),
      duration: 2000
    });
  }

  /** onTabSelected/onTabReselected(tab) -> updateTitleForTab(tab.getPosition()). */
  private onTabSelected(): void {
    this.updateTitleForTab(this.selectedTabIndex);
  }

  private updateTitleForTab(tabPosition: number): void {
    if (tabPosition >= 0 && tabPosition < this.tabStripItems.length) {
      this.actionBarTitle = this.tabStripItems[tabPosition].getTabName();
      this.activeTabContent = this.tabStripItems[tabPosition].getContentName();
    }
  }

  /** The strip cell labels — the contentDescription updateTabsIconAndDescription() sets. */
  private tabNames(): string[] {
    const names: string[] = [];
    for (const tab of this.tabStripItems) {
      names.push(tab.getTabName());
    }
    return names;
  }

  /**
   * updateTabsIconAndDescription(): `tab.setIcon(tabs.get(i).getTabIconRes(context))`. The strip
   * is icon-only — the S0157 capture's four cells carry a content description and no text.
   * `$r()` takes a literal, so the model's resource NAME is mapped here rather than built.
   */
  private tabIcons(): Resource[] {
    const icons: Resource[] = [];
    for (const tab of this.tabStripItems) {
      const name: string = tab.getTabIconRes();
      // The four fixed tabs.
      if (name === 'ic_tv') {
        icons.push($r('app.media.ic_tv'));
      } else if (name === 'ic_subscriptions') {
        icons.push($r('app.media.ic_subscriptions'));
      } else if (name === 'ic_bookmark') {
        icons.push($r('app.media.ic_bookmark'));
      } else if (name === 'ic_history') {
        icons.push($r('app.media.ic_history'));
      // KioskTranslator.getKioskIcon()'s whole range. A kiosk tab - and the DEFAULT kiosk tab,
      // which is the first tab of every service - resolves to one of these, and they were all
      // falling through to the blank-tab default below: YouTube's Trending showed a plain
      // rectangle instead of the flame, Bandcamp's Featured instead of the star.
      } else if (name === 'ic_whatshot') {
        icons.push($r('app.media.ic_whatshot'));
      } else if (name === 'ic_stars') {
        icons.push($r('app.media.ic_stars'));
      } else if (name === 'ic_radio') {
        icons.push($r('app.media.ic_radio'));
      } else if (name === 'ic_home') {
        icons.push($r('app.media.ic_home'));
      } else if (name === 'ic_add_circle_outline') {
        icons.push($r('app.media.ic_add_circle_outline'));
      } else if (name === 'ic_thumb_up') {
        icons.push($r('app.media.ic_thumb_up'));
      } else if (name === 'ic_live_tv') {
        icons.push($r('app.media.ic_live_tv'));
      } else if (name === 'ic_videogame_asset') {
        icons.push($r('app.media.ic_videogame_asset'));
      } else if (name === 'ic_music_note') {
        icons.push($r('app.media.ic_music_note'));
      } else if (name === 'ic_movie') {
        icons.push($r('app.media.ic_movie'));
      } else if (name === 'ic_podcasts') {
        icons.push($r('app.media.ic_podcasts'));
      } else {
        // BlankTab, getTabIconRes()'s own ic_crop_portrait default, and a kiosk id the source's
        // own switch has no icon for (getKioskIcon returns '' where it returned 0).
        icons.push($r('app.media.ic_crop_portrait'));
      }
    }
    return icons;
  }

  /**
   * ServiceHelper.getSelectedServiceId(activity): the `service` preference holds the service
   * NAME, resolved through the registry to the id that is persisted in the database. An
   * unresolvable name falls back to the registry's first service, exactly as the source does.
   */
  private selectedServiceId(): number {
    const name: string = AppPreferences.instance()
      .getStringResolvedSync(current_service_key, default_service_value);
    try {
      return NewPipe.getServiceByName(name).getServiceId();
    } catch (err) {
      return YouTube.getServiceId();
    }
  }

  /**
   * onOptionsItemSelected(action_search) -> NavigationHelper.openSearchFragment(getFM(),
   * ServiceHelper.getSelectedServiceId(activity), "") (MainFragment.java:174-175). The service
   * id is the SOURCE's second argument and is carried here as a router param; SearchFragmentPage
   * is still a Stage-0 shell and ignores it until screen_search is authored.
   */
  private onSearchRequested(): void {
    // The initial 0 is the AppStorage default, not a tap.
    if (this.mainSearchRequest > 0) {
      this.openSearch();
    }
  }

  private openSearch(): void {
    router.pushUrl({
      url: 'pages/SearchFragmentPage',
      params: new SearchParams(this.selectedServiceId(), '')
    });
  }

  /**
   * SelectedTabsPagerAdapter.getItem(position): the Fragment Tab.getFragment(context) returns,
   * with useAsFrontPage(true) applied. A tab whose getFragment throws becomes a BlankFragment
   * carrying the ErrorInfo, which is the LAST branch here.
   */
  @Builder
  pagerPages() {
    // The key carries the restricted-mode flag: flipping it changes every key, which is how the
    // source's "rebuild the whole pager adapter on resume" reaches ArkUI, where the children ARE
    // the adapter and a same-keyed child would be kept.
    ForEach(this.tabStripItems, (tab: Tab) => {
      this.pageForTab(tab);
    }, (tab: Tab) => this.youtubeRestrictedModeEnabled
      ? `${tab.getTabId()}-${this.activeServiceId}-restricted`
      : `${tab.getTabId()}-${this.activeServiceId}`)
  }

  @Builder
  pageForTab(tab: Tab) {
    if (tab.getContentName() === 'SubscriptionFragment') {
      // setUseAsFrontPage(true) - the activity toolbar carries the title and the Import/Export menu.
      SubscriptionFragmentPage({ useAsFrontPage: true })
    } else if (tab.getContentName() === 'FeedFragment') {
      // setUseAsFrontPage(true) - the activity's toolbar carries the title and menu_feed_fragment.
      FeedFragmentPage({ useAsFrontPage: true })
    } else if (tab.getContentName() === 'BookmarkFragment') {
      BookmarkFragmentPage()
    } else if (tab.getContentName() === 'StatisticsPlaylistFragment') {
      StatisticsPlaylistFragmentPage()
    } else if (tab.getContentName() === 'DefaultKioskFragment') {
      DefaultKioskFragmentPage({ hostedInMainShell: true })
    } else if (tab.getContentName() === 'KioskFragment') {
      // KioskTab carries the kiosk it was configured for; getFragment() passes both on.
      KioskFragmentPage({
        serviceId: (tab as KioskTab).getKioskServiceId(),
        kioskId: (tab as KioskTab).getKioskId(),
        useAsFrontPage: true
      })
    } else if (tab.getContentName() === 'ChannelFragment') {
      ChannelFragmentPage({ hostedInMainShell: true })
    } else if (tab.getContentName() === 'LocalPlaylistFragment') {
      LocalPlaylistFragmentPage({ hostedInMainShell: true })
    } else if (tab.getContentName() === 'PlaylistFragment') {
      PlaylistFragmentPage({ hostedInMainShell: true })
    } else {
      // BlankTab, and getItem()'s catch(Throwable) fallback.
      BlankFragmentPage()
    }
  }

  @Builder
  tabStrip() {
    // The wrapper carries the SOURCE id; ScrollableTabLayout is a shared component with its own.
    Column() {
      ScrollableTabLayout({
        titles: this.tabNames(),
        icons: this.tabIcons(),
        selectedIndex: $selectedTabIndex,
        onTabReselected: (): void => {
          this.tabReselectRequest += 1;
        }
      })
    }
    .id('main_tab_layout')
    .width('100%')
  }

  @Builder
  tabPager() {
    SelectedTabsPagerAdapter({
      count: this.tabStripItems.length,
      selectedIndex: $selectedTabIndex,
      // An arrow keeps `this` on this page; `this.pagerPages` would re-bind it to the child.
      pages: (): void => {
        this.pagerPages();
      }
    })
  }

  /**
   * The fragment's own options menu, drawn only when nothing else is hosting it. Contents match
   * what the source puts in the bar over MainFragment: updateTitleForTab()'s title plus
   * menu_main_fragment's single action_search item.
   */
  @Builder
  ownActionBar(): void {
    Row() {
      Text(this.actionBarTitle.length > 0 ? this.actionBarTitle : Localization.getString('app_name'))
        .id('main_title')
        .fontSize(TOOLBAR_TITLE_SIZE)
        .fontWeight(FontWeight.Medium)
        .fontColor(COLOR_ON_PRIMARY)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .margin({ left: TOOLBAR_TITLE_INSET })
        .layoutWeight(1)

      // width/height are the COMPONENT area and the content area is that minus padding, so the
      // glyph size alone would leave a 0x0 image: size the component to glyph + inset.
      Image($r('app.media.ic_search'))
        .id('action_search')
        .width(TOOLBAR_ACTION_SIZE)
        .height(TOOLBAR_ACTION_SIZE)
        .padding(TOOLBAR_ACTION_INSET)
        .objectFit(ImageFit.Contain)
        .fillColor(COLOR_ON_PRIMARY)
        .onClick(() => {
          this.openSearch();
        })
    }
    .width('100%')
    .height(TOOLBAR_HEIGHT)
    .alignItems(VerticalAlign.Center)
    .backgroundColor(COLOR_PRIMARY)
  }

  build() {
    Column() {
      // fragment_main.xml is a ScrollableTabLayout plus a ViewPager and nothing else, so there is
      // no bar of this fragment's own while MainActivityPage hosts it — it writes its title and its
      // search action into the activity's one toolbar. Reached as a route there is no host, and the
      // fragment's menu renders here instead (see shellOwnsToolbar above).
      // The host's single toolbar carries the title and the search action whenever the shell is
      // mounted. onPageShow used to be the discriminator, on the assumption that page lifecycle
      // skips a hosted @Entry child; it does not, so this bar was drawn on top of the host's and
      // the tab name appeared twice on every tab.
      if (!this.shellOwnsToolbar) {
        this.ownActionBar()
      }

      // main_tabs_position_key: the strip is ALIGN_PARENT_BOTTOM with the pager ABOVE it.
      if (this.mainTabsPositionBottom) {
        Column() {
          this.tabPager()
        }
        .width('100%')
        .layoutWeight(1)

        this.tabStrip()
      } else {
        this.tabStrip()

        Column() {
          this.tabPager()
        }
        .width('100%')
        .layoutWeight(1)
      }
    }
    .id('MainFragmentPage')
    .width('100%')
    .height('100%')
    // ?attr/windowBackground = @color/light_background_color in the light theme.
    .backgroundColor(themedBackground(this.blackTheme))
  }
}
