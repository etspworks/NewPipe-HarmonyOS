/**
 * S3 - ChooseTabsFragment (screen_choose_tabs).
 *
 * fragment_choose_tabs.xml is three views: R.id.helpTextView, R.id.selectedTabs and the
 * R.id.addTabsButton FAB, under the activity toolbar that carries R.id.menu_item_restore_default
 * (menu_chooser_fragment.xml) and the "Navigate up" arrow. hostedBy screen_settings_activity,
 * which PUSHES this page.
 *
 * This screen DEFINES MainFragment's tab set, and it is the ONLY caller of the four picker
 * dialogs (SelectKioskFragment, SelectChannelFragment, SelectPlaylistFragment,
 * SelectFeedGroupFragment) - all four declare hostScreen: screen_choose_tabs, so they are
 * overlays mounted HERE, never routes, exactly as ChooseTabsFragment.addTab(tabId) switches on
 * Tab.Type (KIOSK / CHANNEL / PLAYLIST / FEEDGROUP each open their picker; every other type is
 * added straight to the list with no dialog).
 *
 * There is no TabsManager module in the ported data layer: getTabs()/saveTabs()/resetTabs() are
 * the three preference operations below, over the same `saved_tabs_key` JSON MainFragmentPage
 * reads. saveChanges() runs on onPageHide/aboutToDisappear (the source's onPause) through the
 * FLUSHING static AppPreferences.putString - the instance write does not flush and is lost on a
 * cold relaunch.
 *
 * The rows are NOT clickable: only the handle drags (SelectedTabsAdapter) and the row swipes away.
 */

import { router } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';

import { AppPreferences } from '../common/prefs/Preferences';
import { saved_tabs_key } from '../common/prefs/SettingsKeys';
import { Localization } from '../common/i18n/Localization';
import { DebounceSaver } from '../common/util/DebounceSaver';
import { LocalItemType } from '../model/enums/LocalItemLocalItemType';
import {
  BlankTab,
  BookmarksTab,
  ChannelTab,
  DefaultKioskTab,
  FeedGroupTab,
  FeedTab,
  HistoryTab,
  KioskTab,
  PlaylistTab,
  SubscriptionsTab,
  Tab,
  TabJson
} from '../model/app/Tab';
import { SelectedTabsAdapter, SelectedTabsDataSource } from '../components/SelectedTabsAdapter';
import {
  ChooseTabItemDataSource,
  ChooseTabListItem,
  DialogListAdapter
} from '../components/DialogListAdapter';
import { AddTabDialog, AddTabDialogHost } from '../components/AddTabDialog';
import { DIALOG_MASK_COLOR } from '../common/theme/ServiceTheme';
import { SelectKioskFragmentPage } from './SelectKioskFragmentPage';
import { SelectChannelFragmentPage } from './SelectChannelFragmentPage';
import { SelectPlaylistFragmentPage } from './SelectPlaylistFragmentPage';
import { SelectFeedGroupFragmentPage } from './SelectFeedGroupFragmentPage';
import { BLACK_THEME_KEY, themedBackground } from '../common/theme/ThemeBackground';

const TAG: string = 'ChooseTabsFragment';

/** DebounceSaver's window in the source's reorderable lists: a drag order is persisted. */
const SAVE_DEBOUNCE_MILLIS: number = 10000;

/** The on-disk shape of saved_tabs_key, as TabsJsonHelper writes it. */
interface SavedTabsJson {
  tabs?: TabJson[];
}

/**
 * The AppStorage key a changed tab list is published under, so the main shell can rebuild its
 * strip instead of waiting to be entered afresh. A plain literal key, as every other AppStorage
 * channel in this app is ('mainSelectedServiceId', 'listViewMode').
 */
const SAVED_TABS_SIGNAL: string = 'savedTabsRevision';

@Entry
@Component
export struct ChooseTabsFragmentPage {
  /** ThemeHelper's black theme: the window background follows it. */
  @StorageProp(BLACK_THEME_KEY) blackTheme: boolean = false;

  /**
   * TRUE when this screen sits in SettingsActivityPage's settings_fragment_holder, which draws the
   * one toolbar for whatever it holds; FALSE when this page is the pushed route and nothing above
   * it carries a bar. The host passes it explicitly, the way ChannelFragmentPage takes
   * `hostedInMainShell`: a host-set AppStorage flag still reads true underneath a page the host
   * pushed, and MainSettingsFragmentPage pushes this very screen from inside that host. The
   * default is FALSE, so an unset value falls through to DRAWING the bar rather than to none.
   */
  @Prop hostDrawsToolbar: boolean = false;
  /** The fragment's tabList, loaded from saved_tabs_key and saved back on leave. */
  @State selectedTabsList: Tab[] = [];
  /** getAvailableTabs(context): rebuilt on every FAB click, and what the chooser list renders. */
  @State addTabDialogOptions: ChooseTabListItem[] = [];
  /** The payload last written to saved_tabs_key, so the two leave hooks write it only once. */
  @State persistedTabsOnLeave: string = '';
  /** addTab(tabId): the chosen tab id. KIOSK/CHANNEL/PLAYLIST/FEEDGROUP open their picker. */
  @State tabId: number = -1;
  /** tabsManager.getTabs() is read asynchronously off the preference store. */
  @State isLoading: boolean = false;
  /** ErrorUtil.showSnackbar(ErrorInfo(..., SOMETHING_ELSE, "Choosing tabs on settings")). */
  @State errorInfo: string = '';
  /** ChooseTabsFragment.addTab(): the "Choose Tab" chooser. */
  @State @Watch('onAddTabVisibility') showAddTab: boolean = false;
  private addTabDialog: CustomDialogController = new CustomDialogController({
    customStyle: true,
    maskColor: DIALOG_MASK_COLOR,
    cancel: (): void => {
      this.tabId = -1;
      this.pickerOpen = false;
      this.showAddTab = false;
    },
    builder: AddTabDialogHost({
      body: (): void => {
        this.addTabPicker();
      }
    })
  });
  /** The open picker's @Link dismiss flag; WHICH picker is open is `tabId`. */
  @State @Watch('onPickerVisibilityChanged') pickerOpen: boolean = false;

  /** getItemCount()/getItem(): what the two LazyForEach lists read. */
  private tabsSource: SelectedTabsDataSource = new SelectedTabsDataSource();
  private dialogSource: ChooseTabItemDataSource = new ChooseTabItemDataSource();
  /** feat_drag_reorder: a reorder/removal is persisted without waiting for onPause. */
  private debounceSaver: DebounceSaver = new DebounceSaver(SAVE_DEBOUNCE_MILLIS, (): void => {
    this.saveChanges();
  });

  aboutToAppear(): void {
    this.updateTabList();
  }

  /** onPause() -> saveChanges(). */
  onPageHide(): void {
    this.saveChanges();
  }

  aboutToDisappear(): void {
    this.saveChanges();
    this.debounceSaver.dispose();
  }

  onAddTabVisibility(): void {
    if (this.showAddTab) {
      this.addTabDialog.open();
    } else {
      this.addTabDialog.close();
    }
  }

  /** A picker dismisses itself with `show = false`; the chooser sheet goes with it. */
  onPickerVisibilityChanged(): void {
    if (!this.pickerOpen && this.tabId !== -1) {
      this.tabId = -1;
      this.showAddTab = false;
    }
  }

  /* //////////////////////////////////////////////////////////////////////////
  // TabsManager: getTabs() / saveTabs(tabList) / resetTabs()
  ////////////////////////////////////////////////////////////////////////// */

  /** updateTabList(): tabList.clear(); tabList.addAll(tabsManager.getTabs()). */
  private updateTabList(): void {
    this.isLoading = true;
    AppPreferences.getString(saved_tabs_key, '')
      .then((saved: string): void => {
        this.selectedTabsList = ChooseTabsFragmentPage.parseTabs(saved);
        this.isLoading = false;
        this.syncTabs();
      })
      .catch((err: Error): void => {
        hilog.error(0x0000, TAG, 'reading saved tabs: %{public}s', err.message);
        this.selectedTabsList = ChooseTabsFragmentPage.defaultTabs();
        this.isLoading = false;
        this.syncTabs();
      });
  }

  /**
   * TabsManager.getTabs() -> TabsJsonHelper.getTabsFromJson(saved_tabs_key): an empty, absent or
   * unparseable value falls back to the default set, and a tab with an unknown id is dropped.
   */
  private static parseTabs(saved: string): Tab[] {
    if (saved.length === 0) {
      return ChooseTabsFragmentPage.defaultTabs();
    }
    let entries: TabJson[] = [];
    try {
      const outer: SavedTabsJson = JSON.parse(saved) as SavedTabsJson;
      const raw: TabJson[] | undefined = outer.tabs;
      if (raw === undefined || raw === null) {
        // "JSON doesn't contain \"tabs\" array" - the InvalidJsonException branch.
        return ChooseTabsFragmentPage.defaultTabs();
      }
      entries = raw;
    } catch (err) {
      hilog.warn(0x0000, TAG, 'saved tabs unparseable: %{public}s', (err as Error).message);
      return ChooseTabsFragmentPage.defaultTabs();
    }

    const tabs: Tab[] = [];
    for (const entry of entries) {
      const tab: Tab | null = Tab.fromJson(entry);
      if (tab !== null) {
        tabs.push(tab);
      }
    }
    return tabs.length === 0 ? ChooseTabsFragmentPage.defaultTabs() : tabs;
  }

  /** TabsJsonHelper.FALLBACK_INITIAL_TABS_LIST (TabsJsonHelper.java:22-26):
   * DefaultKiosk, Feed, Subscriptions, Bookmarks. FEED is the app's "What's New"
   * tab; dropping it shipped a three-tab default the source never had. Kept in sync
   * with the identical list in MainFragmentPage. */
  private static defaultTabs(): Tab[] {
    return [new DefaultKioskTab(), new FeedTab(), new SubscriptionsTab(),
            new BookmarksTab()];
  }

  /** saveChanges() -> tabsManager.saveTabs(tabList): the whole list, serialised, flushed. */
  private saveChanges(): void {
    const records: TabJson[] = [];
    for (const tab of this.selectedTabsList) {
      records.push(tab.toJson());
    }
    const payload: SavedTabsJson = { tabs: records };
    const json: string = JSON.stringify(payload);
    if (json === this.persistedTabsOnLeave) {
      // onPageHide and aboutToDisappear both fire on the way out, and the debounce window can
      // land on an unchanged list.
      return;
    }
    this.persistedTabsOnLeave = json;
    this.debounceSaver.setNoChangesToSave();
    // The FLUSHING static write; the instance putString does not flush.
    // MainFragmentPage is hosted as a CHILD of MainActivityPage, so the page lifecycle belongs to
    // the host and its own onPageShow does not run when the settings stack is popped - which is
    // why a reordered strip only appeared after a restart (TC-SETTINGS-687). Publishing the change
    // is the signal it can observe, in the same AppStorage + @StorageProp/@Watch shape
    // AppearanceSettingsFragmentPage uses for list_view_mode.
    AppPreferences.putString(saved_tabs_key, json)
      .then((): void => {
        // AFTER the flush, never before: the shell re-reads the preference synchronously when it
        // sees this, so publishing first would hand it the value it already had.
        AppStorage.setOrCreate<number>(SAVED_TABS_SIGNAL,
          (AppStorage.get<number>(SAVED_TABS_SIGNAL) ?? 0) + 1);
      })
      .catch((err: Error) => {
        // Let the next save retry rather than believing this payload reached disk.
        this.persistedTabsOnLeave = '';
        hilog.error(0x0000, TAG, 'saving tabs: %{public}s', err.message);
      });
  }

  /** restoreDefaults(): confirm, then tabsManager.resetTabs() + updateTabList(). */
  private restoreDefaults(): void {
    const cancelButton: AlertDialogButtonBaseOptions = {
      value: $r('app.string.cancel'),
      // setNegativeButton(R.string.cancel, null): dismiss and change nothing.
      action: (): void => {
        hilog.debug(0x0000, TAG, 'restore defaults cancelled');
      }
    };
    const okButton: AlertDialogButtonBaseOptions = {
      value: $r('app.string.ok'),
      action: (): void => {
        this.resetTabs();
      }
    };
    const params: AlertDialogParamWithButtons = {
      title: $r('app.string.restore_defaults'),
      message: $r('app.string.restore_defaults_confirmation'),
      // primaryButton is the FIRST (left) button and secondaryButton the second, so this is the
      // capture's CANCEL / OK order (menu_menu_item_restore_default.png), not the reverse.
      primaryButton: cancelButton,
      secondaryButton: okButton
    };
    AlertDialog.show(params);
  }

  /** resetTabs(): the preference is REMOVED, so getTabs() answers with the default set. */
  private resetTabs(): void {
    const store: AppPreferences = AppPreferences.instance();
    store.remove(saved_tabs_key);
    this.persistedTabsOnLeave = '';
    store.flush()
      .then((): void => {
        this.updateTabList();
      })
      .catch((err: Error) => {
        hilog.error(0x0000, TAG, 'resetting tabs: %{public}s', err.message);
      });
  }

  /* //////////////////////////////////////////////////////////////////////////
  // The list
  ////////////////////////////////////////////////////////////////////////// */

  /**
   * The list is the one input: tabRowLabel(tab) and playlistServiceIdOf(tab) are pure functions
   * of the row's own tab, so the adapter calls them per item rather than reading two arrays this
   * page kept index-parallel. Those arrays were read by the row's captured index, which a
   * key-reused row no longer updates once the List reorders it.
   */
  private syncTabs(): void {
    this.tabsSource.submitList(this.selectedTabsList);
  }

  /**
   * swapItems(from, to) -> Collections.swap(tabList) + notifyItemMoved.
   *
   * A MOVE, not a swap. ItemTouchHelper called the source once per row of travel, so each call
   * was an adjacent swap and the two spellings agreed; the List reports the ONE move on release
   * instead, and swapping its ends would scramble every row between them. The splice folds all
   * the adjacent swaps the source would have made into the single move that was actually asked
   * for. Applied to a COPY, because assigning back through the @State field is what re-renders.
   */
  private swapItems(fromIndex: number, toIndex: number): void {
    if (fromIndex === toIndex || fromIndex < 0 || toIndex < 0
      || fromIndex >= this.selectedTabsList.length || toIndex >= this.selectedTabsList.length) {
      return;
    }
    const list: Tab[] = this.selectedTabsList.slice(0);
    list.splice(toIndex, 0, list.splice(fromIndex, 1)[0]);
    this.selectedTabsList = list;
    this.syncTabs();
    this.debounceSaver.setHasChangesToSave();
  }

  /**
   * onSwiped(): remove the row, and - when that empties the list - put a BLANK tab back at 0, so
   * at least one tab always remains.
   */
  private removeTab(index: number): void {
    if (index < 0 || index >= this.selectedTabsList.length) {
      return;
    }
    this.selectedTabsList.splice(index, 1);
    if (this.selectedTabsList.length === 0) {
      this.selectedTabsList.unshift(new BlankTab());
    }
    this.syncTabs();
    this.debounceSaver.setHasChangesToSave();
  }

  /* //////////////////////////////////////////////////////////////////////////
  // The FAB and the chooser
  ////////////////////////////////////////////////////////////////////////// */

  /** List.contains(tab) over Tab.equals(). */
  private containsTab(tab: Tab): boolean {
    return this.selectedTabsList.some((existing: Tab) => existing.equalsTab(tab));
  }

  /**
   * getAvailableTabs(context), in Tab.Type.values() order: BLANK, DEFAULT_KIOSK and the four
   * plain tabs are offered only while the list does not already hold them; KIOSK, CHANNEL,
   * PLAYLIST and FEEDGROUP are ALWAYS offered, because each can be added more than once.
   */
  private getAvailableTabs(): ChooseTabListItem[] {
    const out: ChooseTabListItem[] = [];

    const blank: Tab = new BlankTab();
    if (!this.containsTab(blank)) {
      out.push(new ChooseTabListItem(blank.getTabId(),
        Localization.getString('blank_page_summary'), blank.getTabIconRes()));
    }

    const defaultKiosk: Tab = new DefaultKioskTab();
    if (!this.containsTab(defaultKiosk)) {
      out.push(new ChooseTabListItem(defaultKiosk.getTabId(),
        Localization.getString('default_kiosk_page_summary'), 'ic_whatshot'));
    }

    // The default branch: ChooseTabListItem(context, tab) - the tab's own name and icon.
    const plainTabs: Tab[] = [
      new SubscriptionsTab(), new FeedTab(), new BookmarksTab(), new HistoryTab()
    ];
    for (const tab of plainTabs) {
      if (!this.containsTab(tab)) {
        out.push(new ChooseTabListItem(tab.getTabId(), tab.getTabName(), tab.getTabIconRes()));
      }
    }

    const kiosk: Tab = new KioskTab();
    out.push(new ChooseTabListItem(kiosk.getTabId(),
      Localization.getString('kiosk_page_summary'), 'ic_whatshot'));

    const channel: Tab = new ChannelTab();
    out.push(new ChooseTabListItem(channel.getTabId(),
      Localization.getString('channel_page_summary'), channel.getTabIconRes()));

    const playlist: Tab = new PlaylistTab();
    out.push(new ChooseTabListItem(playlist.getTabId(),
      Localization.getString('playlist_page_summary'), playlist.getTabIconRes()));

    const feedGroup: Tab = new FeedGroupTab();
    out.push(new ChooseTabListItem(feedGroup.getTabId(),
      Localization.getString('feed_group_page_summary'), feedGroup.getTabIconRes()));

    return out;
  }

  /** The FAB: build the chooser, and return SILENTLY when there is nothing left to add. */
  private onAddTabsClicked(): void {
    const availableTabs: ChooseTabListItem[] = this.getAvailableTabs();
    if (availableTabs.length === 0) {
      return;
    }
    this.errorInfo = '';
    this.tabId = -1;
    this.pickerOpen = false;
    this.addTabDialogOptions = availableTabs;
    this.dialogSource.submitList(this.addTabDialogOptions);
    this.showAddTab = true;
  }

  /** addTab(tabId): the four picker types open their dialog; every other type is added here. */
  private addTabById(tabId: number): void {
    const type: Tab | null = Tab.typeFrom(tabId);
    if (type === null) {
      // ErrorUtil.showSnackbar(new ErrorInfo(new IllegalStateException("Tab id not found: " +
      // tabId), UserAction.SOMETHING_ELSE, "Choosing tabs on settings")) - and NO tab is added.
      hilog.error(0x0000, TAG, 'Tab id not found: %{public}d', tabId);
      this.errorInfo = `Choosing tabs on settings: Tab id not found: ${tabId}`;
      return;
    }
    this.tabId = tabId;
    if (type instanceof KioskTab || type instanceof ChannelTab
      || type instanceof PlaylistTab || type instanceof FeedGroupTab) {
      // The picker REPLACES the chooser, as show(getParentFragmentManager(), ...) does.
      this.pickerOpen = true;
      return;
    }
    // default: addTab(type.getTab()).
    this.addTab(type);
    this.tabId = -1;
    this.showAddTab = false;
  }

  /** addTab(tab): tabList.add(tab) + notifyDataSetChanged(). */
  private addTab(tab: Tab): void {
    this.selectedTabsList.push(tab);
    this.syncTabs();
    this.debounceSaver.setHasChangesToSave();
  }

  /** setAdapter(new DialogListAdapter(context, availableTabs), actionListener). */
  @Builder
  addTabList() {
    DialogListAdapter({
      dataSource: this.dialogSource,
      onItemSelected: (tabId: number): void => {
        this.addTabById(tabId);
      }
    })
  }

  /**
   * The chooser and the four pickers share ONE overlay, because the source replaces the chooser
   * dialog with the picker dialog rather than stacking them.
   */
  @Builder
  addTabPicker() {
    Column() {
      // addTab(tabId) switches on the tab TYPE: these four ids open a picker, everything else
      // was already added straight to the list. A DialogFragment returns its result through an
      // OnSelectedListener, not through a route, so each picker takes its listener as a callback
      // prop here and this host builds the Tab from it - exactly as ChooseTabsFragment does.
      if (this.tabId === KioskTab.ID) {
        // setOnSelectedListener((serviceId, kioskId, kioskName) ->
        //     addTab(new Tab.KioskTab(serviceId, kioskId))) - the display name is NOT stored;
        // KioskTab.getTabName() re-derives it from kioskId.
        SelectKioskFragmentPage({
          isShown: this.pickerOpen,
          onKioskSelected: (serviceId: number, kioskId: string, kioskName: string): void => {
            const tab: KioskTab = new KioskTab();
            tab.kioskServiceId = serviceId;
            tab.kioskId = kioskId;
            this.addTab(tab);
          }
        })
      } else if (this.tabId === ChannelTab.ID) {
        // setOnSelectedListener((serviceId, url, name) ->
        //     addTab(new Tab.ChannelTab(serviceId, url, name)))
        SelectChannelFragmentPage({
          isShown: this.pickerOpen,
          onChannelSelected: (serviceId: number, url: string, name: string): void => {
            const tab: ChannelTab = new ChannelTab();
            tab.channelServiceId = serviceId;
            tab.channelUrl = url;
            tab.channelName = name;
            this.addTab(tab);
          }
        })
      } else if (this.tabId === PlaylistTab.ID) {
        // The anonymous OnSelectedListener with TWO methods: a LOCAL playlist becomes
        // new Tab.PlaylistTab(id, name), a REMOTE one new Tab.PlaylistTab(serviceId, url, name).
        SelectPlaylistFragmentPage({
          isShown: this.pickerOpen,
          onLocalPlaylistSelected: (playlistId: number, name: string): void => {
            const tab: PlaylistTab = new PlaylistTab();
            tab.playlistId = playlistId;
            tab.playlistName = name;
            tab.playlistType = LocalItemType.PLAYLIST_LOCAL_ITEM;
            tab.playlistServiceId = -1;
            this.addTab(tab);
          },
          onRemotePlaylistSelected: (serviceId: number, url: string, name: string): void => {
            const tab: PlaylistTab = new PlaylistTab();
            tab.playlistServiceId = serviceId;
            tab.playlistUrl = url;
            tab.playlistName = name;
            tab.playlistType = LocalItemType.PLAYLIST_REMOTE_ITEM;
            tab.playlistId = -1;
            this.addTab(tab);
          }
        })
      } else if (this.tabId === FeedGroupTab.ID) {
        // setOnSelectedListener((groupId, name, iconId) ->
        //     addTab(new Tab.FeedGroupTab(groupId, name, iconId)))
        SelectFeedGroupFragmentPage({
          isShown: this.pickerOpen,
          onFeedGroupSelected: (groupId: number, name: string, iconName: string): void => {
            const tab: FeedGroupTab = new FeedGroupTab();
            tab.feedGroupId = groupId;
            tab.feedGroupName = name;
            tab.iconId = iconName;
            this.addTab(tab);
          }
        })
      } else {
        AddTabDialog({
          body: (): void => {
            this.addTabList();
          }
        })
      }
    }
    .width('100%')
    .height('100%')
  }

  build() {
    Stack({ alignContent: Alignment.BottomEnd }) {
      Column() {
        if (!this.hostDrawsToolbar) {
          // The activity toolbar: navigate-up, the title, and the menu action.
          Row() {
            // The 24dp glyph centred in a 56dp (?attr/actionBarSize) target; the SVG ships with a
            // black fill, so the toolbar's ?attr/actionColor tint is applied here.
            Image($r('app.media.ic_arrow_back'))
              .id('navigate_up')
              .accessibilityText($r('app.string.navigate_back'))
              .width(56)
              .height(56)
              .padding(16)
              .objectFit(ImageFit.Contain)
              .fillColor($r('app.color.on_primary'))
              .onClick((): void => {
                router.back();
              })

            // Widget.AppCompat.Toolbar.Title: 20sp medium, 16dp past the navigation button
            // (base.ui.json puts the title at x=216 of 1080 - 72vp at density 3.0).
            Text($r('app.string.main_page_content'))
              .fontSize(20)
              .fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.on_primary'))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .margin({ left: 16 })
              .layoutWeight(1)

            // menu_chooser_fragment.xml: a 48dp action item, flush to the bar's end.
            Image($r('app.media.ic_settings_backup_restore'))
              .id('menu_item_restore_default')
              .accessibilityText($r('app.string.restore_defaults'))
              .width(48)
              .height(48)
              .padding(12)
              .objectFit(ImageFit.Contain)
              .fillColor($r('app.color.on_primary'))
              .onClick((): void => {
                this.restoreDefaults();
              })
          }
          .width('100%')
          .height(56)
          .alignItems(VerticalAlign.Center)
          .backgroundColor($r('app.color.primary'))
        }

        // gravity=center, 16dp below the bar, 8dp of horizontal padding; an unstyled TextView,
        // so 14sp at the secondary-text alpha (#6D6D6D over #EEEEEE in the capture).
        Text($r('app.string.main_page_content_swipe_remove'))
          .id('helpTextView')
          .fontSize(14)
          .fontColor($r('app.color.on_surface_variant'))
          .textAlign(TextAlign.Center)
          .width('100%')
          .padding({ left: 8, right: 8 })
          .margin({ top: 16 })

        // The snackbar's state: set when addTab(tabId) found no type for the id, empty otherwise.
        if (this.errorInfo.length > 0) {
          Text(this.errorInfo)
            .fontSize(14)
            .fontColor($r('app.color.primary'))
            .textAlign(TextAlign.Center)
            .width('100%')
            .padding({ left: 16, right: 16 })
            .margin({ top: 8 })
        }

        Column() {
          if (this.isLoading) {
            // tabsManager.getTabs() is read off the preference store before the list exists.
            LoadingProgress()
              .width(48)
              .height(48)
              .color($r('app.color.primary'))
              .margin({ top: 24 })
          } else {
            SelectedTabsAdapter({
              dataSource: this.tabsSource,
              onSwapItems: (fromIndex: number, toIndex: number): void => {
                this.swapItems(fromIndex, toIndex);
              },
              onSwipeRemove: (index: number): void => {
                this.removeTab(index);
              }
            })
          }
        }
        .width('100%')
        .layoutWeight(1)
        // selectedTabs: layout_marginTop 16dp below helpTextView.
        .margin({ top: 16 })
      }
      .width('100%')
      .height('100%')

      // The FAB, over the list at the bottom end.
      Row() {
        Image($r('app.media.ic_add'))
          .width(24)
          .height(24)
          .objectFit(ImageFit.Contain)
          .fillColor($r('app.color.on_primary'))
      }
      .id('addTabsButton')
      .accessibilityText($r('app.string.add'))
      // FloatingActionButton, fabSize auto: a 56dp circle on ?attr/colorPrimary, 16dp in from
      // the end and the bottom (base.ui.json: [864,2124][1032,2292] at density 3.0).
      .width(56)
      .height(56)
      .borderRadius(28)
      .backgroundColor($r('app.color.primary'))
      .justifyContent(FlexAlign.Center)
      .alignItems(VerticalAlign.Center)
      .shadow({ radius: 12, color: '#40000000', offsetX: 0, offsetY: 3 })
      .margin({ right: 16, bottom: 16 })
      .onClick((): void => {
        this.onAddTabsClicked();
      })
    }
    .id('ChooseTabsFragmentPage')
    .width('100%')
    .height('100%')
    .backgroundColor(themedBackground(this.blackTheme))
  }
}
