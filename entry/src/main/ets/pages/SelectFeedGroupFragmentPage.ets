/**
 * S2 shell - SelectFeedGroupFragment (screen_select_feed_group). presentation: modal.
 *
 * NOT a routed page: an OVERLAY whose hostScreen is screen_choose_tabs, mounted by
 * ChooseTabsFragmentPage on its showSelectFeedGroup flag (ChooseTabsFragment.addTab(tabId) case
 * FEEDGROUP). Deliberately absent from main_pages.json.
 *
 * The exact twin of SelectChannelFragment, over a different source. Read off
 * SelectFeedGroupFragment.java:38-197 (codegraph):
 *  - select_feed_group_fragment.xml: the select_a_feed_group title (NewPipeTextView, NO
 *    android:id), items_list, empty_state_view, progressBar.
 *  - onCreateView: progressBar VISIBLE, list and empty view GONE, then
 *    database.feedGroupDAO().getAll() (io -> main).
 *  - displayFeedGroups(): progressBar GONE; an EMPTY list shows empty_state_view and RETURNS.
 *  - The row is select_feed_group_item (itemThumbnailView + itemTitleView) whose icon comes from
 *    FeedGroupEntity.getIcon().getDrawableResource() - resolved at S5, not a literal glyph here.
 *    Repeated, so ONE shared slug: select_feed_group_itemroot (instrumenter-injected).
 *  - clickedItem(position) -> onFeedGroupSelected(uid, name, iconDrawableRes) then dismiss().
 *    The listener half (Tab.FeedGroupTab) is the HOST's, wired in S4; dismiss is `show = false`,
 *    which is this screen's only navOut edge (kind pop, back to screen_choose_tabs).
 *  - onCancel(DialogInterface) -> onCancelListener.onCancel(): the plan's implicit
 *    `select_feed_group_dialog_cancel` affordance is the sheet's own swipe-down / scrim dismiss
 *    on HarmonyOS and carries no addressable id (reported, not invented).
 *
 * The list is bound to svc_database / svc_feed_loader in S4 - never a literal set of groups.
 */


import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

import { FeedDatabase } from '../common/feed/FeedLoader';
import { FeedGroupEntity } from '../model/db/entity/FeedGroupEntity';
import { FeedGroupIcon, feedGroupIconDrawable } from '../model/enums/FeedGroupIcon';
import {
  SelectFeedGroupAdapter,
  SelectFeedGroupDataSource,
  SelectFeedGroupRow
} from '../components/SelectFeedGroupAdapter';

/** select_feed_group_fragment.xml: the LinearLayout's own 13dp padding. */
const DIALOG_PADDING: number = 13;
/** ?android:attr/textAppearanceLarge on the title, ?attr/textAppearanceListItem below it -
 *  S0223 measures the title line box at [1092..1180] of 2340 at density 3.0, i.e. 22fp. */
const TITLE_TEXT_SIZE: number = 22;
const LIST_ITEM_TEXT_SIZE: number = 16;
const COLOR_ON_SURFACE: Resource = $r('app.color.on_surface');
const COLOR_SECONDARY_TEXT: Resource = $r('app.color.on_surface_variant');

@Component
export struct SelectFeedGroupFragmentPage {
  /** Two-way with the host's visibility flag; clickedItem() dismisses. */
  @Link isShown: boolean;
  /** What feedGroupDAO().getAll() returned - the bound source, never a literal. */
  @Prop feedGroupList: FeedGroupEntity[] = [];
  /** holder.titleView.setText(entry.getName()), one per row. */
  @Prop rowTitle: string[] = [];
  /** entry.getIcon().getDrawableResource(), one per row - a LOCAL drawable name, no loader. */
  @Prop rowIcon: string[] = [];
  /** displayFeedGroups(newFeedGroups) - the list the adapter renders. */
  @Watch('onFeedGroupsChanged') @State feedGroups: SelectFeedGroupRow[] = [];
  /** progressBar: VISIBLE at onCreateView, GONE in displayFeedGroups(). */
  @State isLoading: boolean = true;
  /** onError -> ErrorUtil.showUiErrorSnackbar(this, "Loading Feed Groups", exception). As in the
   * source, displayFeedGroups() never runs on error, so the spinner is NOT hidden. */
  @State errorInfo: string = '';
  /**
   * setOnSelectedListener(...) - the OnSelectedListener return channel. The source hands back
   * (groupId, name, iconDrawableRes); this port hands back the migrated drawable's NAME, which
   * is what FeedGroupTab.iconId stores.
   */
  onFeedGroupSelected: (groupId: number, name: string, iconName: string) => void =
    (groupId: number, name: string, iconName: string): void => {
      console.info('SelectFeedGroupFragmentPage: no OnSelectedListener (' + name + ')');
    };

  /** getItemCount()/getItem(): what LazyForEach reads inside SelectFeedGroupAdapter. */
  private feedGroupSource: SelectFeedGroupDataSource = new SelectFeedGroupDataSource();

  /** notifyDataSetChanged(): the adapter reads the fragment's list, so re-submit it on change. */
  onFeedGroupsChanged(): void {
    this.feedGroupSource.submitList(this.feedGroups);
  }

  /**
   * onCreateView(): progressBar VISIBLE, then
   *   database.feedGroupDAO().getAll().toObservable().subscribeOn(io())
   *     .observeOn(mainThread()).subscribe(getFeedGroupObserver())
   * FeedDatabase.groups() is the port of that DAO call.
   */
  aboutToAppear(): void {
    this.isLoading = true;
    this.errorInfo = '';
    const context: common.Context = getContext(this) as common.Context;
    FeedDatabase.of(context)
      .then((database: FeedDatabase): Promise<FeedGroupEntity[]> => database.groups())
      .then((entities: FeedGroupEntity[]): void => {
        this.displayFeedGroups(entities);
      })
      .catch((err: Error): void => {
        this.errorInfo = 'Loading Feed Groups: ' + err.message;
        hilog.error(0x0000, 'SelectFeedGroupFragment', 'Loading Feed Groups: %{public}s',
          err.message);
      });
  }

  /** displayFeedGroups(newFeedGroups): hide the spinner and publish the rows. */
  private displayFeedGroups(entities: FeedGroupEntity[]): void {
    this.feedGroupList = entities;
    this.rowTitle = entities.map((e: FeedGroupEntity): string => e.name);
    this.rowIcon = entities.map((e: FeedGroupEntity): string => feedGroupIconDrawable(e.icon));
    const rows: SelectFeedGroupRow[] = [];
    for (let i: number = 0; i < entities.length; i++) {
      const icon: FeedGroupIcon = entities[i].icon;
      rows.push(new SelectFeedGroupRow(entities[i].uid, this.rowTitle[i], icon));
    }
    this.feedGroups = rows;
    this.isLoading = false;
  }

  /** clickedItem(position): call the listener with the entry, then dismiss(). */
  private clickedItem(item: SelectFeedGroupRow): void {
    this.onFeedGroupSelected(item.uid, item.name, item.drawableName());
    this.isShown = false;
  }

  build() {
    Column() {
      // A NewPipeTextView with NO android:id; the plan's slug is select_a_feed_group_title.
      Text($r('app.string.select_a_feed_group'))
        .id('select_a_feed_group_title')
        .width('100%')
        .fontSize(TITLE_TEXT_SIZE)
        .fontColor(COLOR_ON_SURFACE)
        .margin({ left: 10, top: 5, right: 5, bottom: 10 })

      /*
       * displayFeedGroups() drives THREE mutually exclusive states, and - exactly as the channel
       * picker does - the empty branch RETURNS before the RecyclerView is made visible:
       *   onCreateView -> progressBar VISIBLE, items_list GONE, empty_state_view GONE
       *   empty result -> progressBar GONE,    items_list GONE, empty_state_view VISIBLE
       *   non-empty    -> progressBar GONE,    items_list VISIBLE
       */
      if (this.isLoading) {
        LoadingProgress()
          .id('progressBar')
          .width(48)
          .height(48)
          .color($r('app.color.settings_accent'))
          .margin(5)
      } else if (this.feedGroups.length === 0) {
        Text($r('app.string.no_feed_group_created_yet'))
          .id('empty_state_view')
          .width('100%')
          .fontSize(LIST_ITEM_TEXT_SIZE)
          .fontColor(COLOR_ON_SURFACE)
          .margin(10)
      } else {
        Column() {
          SelectFeedGroupAdapter({
            dataSource: this.feedGroupSource,
            onItemClicked: (item: SelectFeedGroupRow): void => {
              this.clickedItem(item);
            }
          })
        }
        .id('items_list')
        .width('100%')
        .layoutWeight(1)
      }

      // ErrorUtil.showUiErrorSnackbar("Loading Feed Groups", exception) - no snackbar on
      // HarmonyOS, so the same message is rendered in place; the spinner stays up as it does
      // in the source.
      if (this.errorInfo.length > 0) {
        Text(this.errorInfo)
          .width('100%')
          .fontSize(14)
          .fontColor(COLOR_SECONDARY_TEXT)
          .margin({ top: 8 })
      }
    }
    .id('SelectFeedGroupFragmentPage')
    .width('100%')
    .height('100%')
    .padding(DIALOG_PADDING)
    // getMinWidthDialogTheme(): ?attr/dialogBackground, #EEEEEE in light - S0223 samples the
    // panel at exactly (238,238,238).
    .backgroundColor($r('app.color.dialog_background'))
    .alignItems(HorizontalAlign.Start)
  }
}
