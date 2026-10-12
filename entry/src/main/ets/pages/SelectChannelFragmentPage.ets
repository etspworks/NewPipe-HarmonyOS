/**
 * S2 shell - SelectChannelFragment (screen_select_channel). presentation: modal.
 *
 * NOT a routed page: an OVERLAY whose hostScreen is screen_choose_tabs, mounted by
 * ChooseTabsFragmentPage on its showSelectChannel flag (ChooseTabsFragment.addTab(tabId) case
 * CHANNEL). Deliberately absent from main_pages.json.
 *
 * select_channel_fragment.xml is four views: the select_a_channel title (a NewPipeTextView with
 * NO android:id), items_list, empty_state_view and progressBar. Read off
 * SelectChannelFragment.java:38-196 (codegraph):
 *  - onCreateView starts with progressBar VISIBLE and BOTH items_list and empty_state_view GONE,
 *    then subscribes to SubscriptionManager.subscriptions() (io -> main).
 *  - displayChannels(): progressBar GONE; an EMPTY list shows empty_state_view and RETURNS
 *    without ever showing the list. Three states, one bound condition - built as ArkUI `if` in S4.
 *  - The row is select_channel_item (itemThumbnailView + itemTitleView), avatar loaded by
 *    CoilHelper.loadAvatar; svc_image_loader replaces Coil. Repeated, so it keeps ONE shared slug
 *    (Rule 12 list-row exception) - select_channel_itemroot, the instrumenter's injected id.
 *  - clickedItem(position) -> onChannelSelected(serviceId, url, name) then dismiss(). The
 *    listener half (adding the Tab.ChannelTab to the host's tab list) belongs to the HOST and is
 *    wired in S4; the dismiss half is `show = false` here, which is also this screen's only
 *    navOut edge (kind pop, back to screen_choose_tabs).
 *  - onCancel(DialogInterface) -> onCancelListener.onCancel(). The plan records that as the
 *    implicit `select_channel_dialog_cancel` affordance; on HarmonyOS it is the sheet's own
 *    swipe-down / scrim dismiss, which carries no addressable id (reported, not invented).
 *
 * The list is bound to svc_subscription_manager over svc_database in S4 - never a literal.
 */

import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

import { SubscriptionManager } from '../common/db/SubscriptionManager';
import { SubscriptionEntity } from '../model/db/entity/SubscriptionEntity';
import {
  SelectChannelAdapter,
  SelectChannelDataSource,
  SelectChannelRow
} from '../components/SelectChannelAdapter';

/** select_channel_fragment.xml: the LinearLayout's own 13dp padding. */
const DIALOG_PADDING: number = 13;
/** ?android:attr/textAppearanceLarge on the title, ?attr/textAppearanceListItem on the rows. */
const TITLE_TEXT_SIZE: number = 22;
const LIST_ITEM_TEXT_SIZE: number = 16;
/** The theme's 87%/54% black-on-light text pair (styleBaseline color.onSurface/secondaryText). */
const COLOR_ON_SURFACE: Resource = $r('app.color.on_surface');
const COLOR_SECONDARY_TEXT: Resource = $r('app.color.on_surface_variant');

@Component
export struct SelectChannelFragmentPage {
  /** Two-way with the host's visibility flag; clickedItem() dismisses. */
  @Link isShown: boolean;
  /** What subscriptionManager.subscriptions() returned - the bound source, never a literal. */
  @Prop channelList: SubscriptionEntity[] = [];
  /** holder.titleView.setText(entry.getName()), one per row. */
  @Prop rowTitle: string[] = [];
  /** CoilHelper.loadAvatar(holder.thumbnailView, entry.getAvatarUrl()), one per row. */
  @Prop rowAvatar: string[] = [];
  /** displayChannels(newSubscriptions) - the list the adapter renders. */
  @Watch('onSubscriptionsChanged') @State subscriptions: SelectChannelRow[] = [];
  /** progressBar: VISIBLE at onCreateView, GONE in displayChannels(). */
  @State isLoading: boolean = true;
  /** onError -> ErrorUtil.showUiErrorSnackbar(this, "Loading subscription", exception). NOTE the
   * source leaves the progress bar UP on error (displayChannels is never reached), so isLoading
   * deliberately stays true here too. */
  @State errorInfo: string = '';
  /**
   * setOnSelectedListener(...) - the OnSelectedListener return channel the plan calls for. A
   * DialogFragment hands its result back through this listener, not through a route, so the
   * HOST (ChooseTabsFragment) passes one in and builds the Tab from it.
   */
  onChannelSelected: (serviceId: number, url: string, name: string) => void =
    (serviceId: number, url: string, name: string): void => {
      console.info('SelectChannelFragmentPage: no OnSelectedListener (' + name + ')');
    };

  /** getItemCount()/getItem(): what LazyForEach reads inside SelectChannelAdapter. */
  private channelSource: SelectChannelDataSource = new SelectChannelDataSource();

  /** notifyDataSetChanged(): the adapter reads the fragment's list, so re-submit it on change. */
  onSubscriptionsChanged(): void {
    this.channelSource.submitList(this.subscriptions);
  }

  /**
   * onCreateView(): progressBar VISIBLE, then
   *   new SubscriptionManager(requireContext()).subscriptions().toObservable()
   *     .subscribeOn(io()).observeOn(mainThread()).subscribe(getSubscriptionObserver())
   * The observer's onNext is displayChannels(), its onError the snackbar below.
   */
  aboutToAppear(): void {
    this.isLoading = true;
    this.errorInfo = '';
    const context: common.Context = getContext(this) as common.Context;
    SubscriptionManager.of(context)
      .then((manager: SubscriptionManager): Promise<SubscriptionEntity[]> => manager.subscriptions())
      .then((entities: SubscriptionEntity[]): void => {
        this.displayChannels(entities);
      })
      .catch((err: Error): void => {
        // onError: the snackbar only - displayChannels() never runs, so the spinner stays up.
        this.errorInfo = 'Loading subscription: ' + err.message;
        hilog.error(0x0000, 'SelectChannelFragment', 'Loading subscription: %{public}s',
          err.message);
      });
  }

  /** displayChannels(newSubscriptions): hide the spinner and publish the rows. */
  private displayChannels(entities: SubscriptionEntity[]): void {
    this.channelList = entities;
    this.rowTitle = entities.map((e: SubscriptionEntity): string => e.name === null ? '' : e.name);
    this.rowAvatar = entities.map((e: SubscriptionEntity): string =>
      e.avatarUrl === null ? '' : e.avatarUrl);
    const rows: SelectChannelRow[] = [];
    for (let i: number = 0; i < entities.length; i++) {
      const entity: SubscriptionEntity = entities[i];
      rows.push(new SelectChannelRow(entity.uid, entity.serviceId,
        entity.url === null ? '' : entity.url, this.rowTitle[i], this.rowAvatar[i]));
    }
    this.subscriptions = rows;
    this.isLoading = false;
  }

  /** clickedItem(position): call the listener with the entry, then dismiss(). */
  private clickedItem(item: SelectChannelRow): void {
    this.onChannelSelected(item.serviceId, item.url, item.name);
    this.isShown = false;
  }

  build() {
    Column() {
      // A NewPipeTextView with NO android:id; the plan's slug for it is select_a_channel_title.
      Text($r('app.string.select_a_channel'))
        .id('select_a_channel_title')
        .width('100%')
        .fontSize(TITLE_TEXT_SIZE)
        .fontColor(COLOR_ON_SURFACE)
        .margin({ left: 10, top: 5, right: 5, bottom: 10 })

      /*
       * displayChannels() drives THREE mutually exclusive states, and the empty branch RETURNS
       * before the RecyclerView is ever made visible:
       *   onCreateView  -> progressBar VISIBLE, items_list GONE, empty_state_view GONE
       *   empty result  -> progressBar GONE,    items_list GONE, empty_state_view VISIBLE
       *   non-empty     -> progressBar GONE,    items_list VISIBLE
       */
      if (this.isLoading) {
        LoadingProgress()
          .id('progressBar')
          .width(48)
          .height(48)
          .color($r('app.color.settings_accent'))
          .margin(5)
      } else if (this.subscriptions.length === 0) {
        Text($r('app.string.no_channel_subscribed_yet'))
          .id('empty_state_view')
          .width('100%')
          .fontSize(LIST_ITEM_TEXT_SIZE)
          .fontColor(COLOR_ON_SURFACE)
          .margin(10)
      } else {
        Column() {
          SelectChannelAdapter({
            dataSource: this.channelSource,
            onItemClicked: (item: SelectChannelRow): void => {
              this.clickedItem(item);
            }
          })
        }
        .id('items_list')
        .width('100%')
        .layoutWeight(1)
      }

      // ErrorUtil.showUiErrorSnackbar("Loading subscription", exception): the source posts a
      // snackbar over the dialog. HarmonyOS has no snackbar, so the same message is rendered
      // in place - and, as in the source, the spinner above it is NOT hidden.
      if (this.errorInfo.length > 0) {
        Text(this.errorInfo)
          .width('100%')
          .fontSize(14)
          .fontColor(COLOR_SECONDARY_TEXT)
          .margin({ top: 8 })
      }
    }
    .id('SelectChannelFragmentPage')
    .width('100%')
    .height('100%')
    .padding(DIALOG_PADDING)
    // getMinWidthDialogTheme(): the MinWidth dialog window paints ?attr/dialogBackground,
    // #EEEEEE in the light theme - S0222 samples the panel at exactly (238,238,238).
    .backgroundColor($r('app.color.dialog_background'))
    .alignItems(HorizontalAlign.Start)
  }
}
