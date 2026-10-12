/**
 * S2 shell - SelectPlaylistFragment (screen_select_playlist). presentation: modal.
 *
 * NOT a routed page: an OVERLAY whose hostScreen is screen_choose_tabs, mounted by
 * ChooseTabsFragmentPage on its showSelectPlaylist flag (ChooseTabsFragment.addTab(tabId) case
 * PLAYLIST). Deliberately absent from main_pages.json.
 *
 * Read off SelectPlaylistFragment.java:38-188 (codegraph):
 *  - select_playlist_fragment.xml: the select_a_playlist title (NewPipeTextView, NO android:id),
 *    items_list, empty_state_view, progressBar.
 *  - loadPlaylists(): progressBar VISIBLE, list and empty view GONE, then
 *    MergedPlaylistManager.getMergedOrderedPlaylists(LocalPlaylistManager, RemotePlaylistManager)
 *    -> displayPlaylists / onError. displayPlaylists() toggles empty_state_view and items_list on
 *    newPlaylists.isEmpty() - a bound condition built as ArkUI `if` in S4. The Disposable is
 *    disposed in onDestroy, so S4's subscription is disposed in aboutToDisappear (Rule 8).
 *  - THE LIST IS POLYMORPHIC: PlaylistLocalItem is either a PlaylistMetadataEntry (local) or a
 *    PlaylistRemoteEntity (remote), and clickedItem dispatches to onLocalPlaylistSelected(uid,
 *    orderingName) or onRemotePlaylistSelected(serviceId, url, orderingName) accordingly. BOTH
 *    onBindViewHolder branches inflate the SAME list_playlist_mini_item and set the SAME click
 *    listener, so there is ONE row type, not two - itemTypes is a data discriminator, not a
 *    second row layout. S3/S4 keep the single row and branch only in the handler.
 *  - The row root is list_playlist_mini_item's own android:id `itemRoot`; repeated, so it stays
 *    shared (Rule 12 list-row exception). results/plan/action-contracts.json addresses this
 *    control as "Playlist row" instead of a slug - the source id is used, and that mismatch is
 *    reported rather than the id invented.
 *  - dismiss() is `show = false`, this screen's only navOut edge (kind pop, to screen_choose_tabs).
 *  - The plan's implicit `platform:dialog-outside-tap` dismiss is the sheet's own swipe-down /
 *    scrim on HarmonyOS and carries no addressable id.
 *
 * Bound to svc_playlist_manager over svc_database in S4 - never a literal playlist list.
 */


import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

import { LocalPlaylistManager, RemotePlaylistManager } from '../common/db/PlaylistManager';
import { LocalItemType } from '../model/enums/LocalItemLocalItemType';
import { PlaylistLocalItem } from '../model/db/view/PlaylistLocalItem';
import { PlaylistMetadataEntry } from '../model/db/view/PlaylistMetadataEntry';
import { PlaylistRemoteEntity } from '../model/db/entity/PlaylistRemoteEntity';
import {
  SelectPlaylistAdapter,
  SelectPlaylistDataSource,
  SelectPlaylistRow
} from '../components/SelectPlaylistAdapter';

/** select_playlist_fragment.xml: the LinearLayout's own 13dp padding. */
const DIALOG_PADDING: number = 13;
/** ?android:attr/textAppearanceLarge; S0225 puts the title line box at [1043..1131] of 2340
 *  at density 3.0, i.e. 22fp, with the row titles at ?attr/textAppearanceListItem below it. */
const TITLE_TEXT_SIZE: number = 22;
const LIST_ITEM_TEXT_SIZE: number = 16;
const COLOR_ON_SURFACE: Resource = $r('app.color.on_surface');
const COLOR_SECONDARY_TEXT: Resource = $r('app.color.on_surface_variant');

/* //////////////////////////////////////////////////////////////////////////
// MergedPlaylistManager.getMergedOrderedPlaylists(local, remote)
//
// The data layer still has no MergedPlaylistManager module (the same S1 gap BookmarkFragmentPage
// records), and its copy of this port is a file-private function in a page this call may not
// write, so the port is repeated here rather than reached for. Reported, not silently shared.
////////////////////////////////////////////////////////////////////////// */

function displayIndexOf(item: PlaylistLocalItem): number {
  return item.displayIndex === null ? 0 : item.displayIndex;
}

/** Port of MergedPlaylistManager.addItemsWithSameIndex(): CASE_INSENSITIVE_ORDER, nulls last. */
function addItemsWithSameIndex(result: PlaylistLocalItem[], items: PlaylistLocalItem[]): void {
  items.sort((a: PlaylistLocalItem, b: PlaylistLocalItem): number => {
    const an: string | null = a.orderingName;
    const bn: string | null = b.orderingName;
    if (an === null) {
      return bn === null ? 0 : 1;
    }
    if (bn === null) {
      return -1;
    }
    const al: string = an.toLowerCase();
    const bl: string = bn.toLowerCase();
    if (al < bl) {
      return -1;
    }
    return al > bl ? 1 : 0;
  });
  for (const item of items) {
    result.push(item);
  }
}

/** Port of MergedPlaylistManager.addItem(). */
function addMergedItem(result: PlaylistLocalItem[], item: PlaylistLocalItem,
  itemsWithSameIndex: PlaylistLocalItem[]): void {
  if (itemsWithSameIndex.length > 0
    && displayIndexOf(itemsWithSameIndex[0]) !== displayIndexOf(item)) {
    addItemsWithSameIndex(result, itemsWithSameIndex);
    itemsWithSameIndex.splice(0, itemsWithSameIndex.length);
  }
  itemsWithSameIndex.push(item);
}

/** Port of MergedPlaylistManager.merge(): a merge-sort pass over two display_index-ordered lists. */
function mergePlaylists(localPlaylists: PlaylistMetadataEntry[],
  remotePlaylists: PlaylistRemoteEntity[]): PlaylistLocalItem[] {
  const result: PlaylistLocalItem[] = [];
  const itemsWithSameIndex: PlaylistLocalItem[] = [];

  let i: number = 0;
  let j: number = 0;
  while (i < localPlaylists.length) {
    while (j < remotePlaylists.length
      && displayIndexOf(remotePlaylists[j]) <= displayIndexOf(localPlaylists[i])) {
      addMergedItem(result, remotePlaylists[j], itemsWithSameIndex);
      j++;
    }
    addMergedItem(result, localPlaylists[i], itemsWithSameIndex);
    i++;
  }
  while (j < remotePlaylists.length) {
    addMergedItem(result, remotePlaylists[j], itemsWithSameIndex);
    j++;
  }
  addItemsWithSameIndex(result, itemsWithSameIndex);

  return result;
}

@Component
export struct SelectPlaylistFragmentPage {
  /** Two-way with the host's visibility flag; clickedItem() dismisses. */
  @Link isShown: boolean;
  /** What getMergedOrderedPlaylists(local, remote) returned - the bound source, never a literal. */
  @Prop playlistList: PlaylistLocalItem[] = [];
  /** holder.titleView.setText(entry.getOrderingName()) in BOTH type branches, one per row. */
  @Prop rowTitle: string[] = [];
  /** CoilHelper.loadPlaylistThumbnail(holder.thumbnailView, entry.getThumbnailUrl()), per row. */
  @Prop rowThumbnail: string[] = [];
  /**
   * The `selectedItem instanceof PlaylistMetadataEntry / instanceof PlaylistRemoteEntity`
   * discriminator, one per row - what BOTH the bind branch and the click dispatch read.
   */
  @State localItemType: LocalItemType[] = [];
  /** displayPlaylists(newPlaylists) - the list the adapter renders. */
  @Watch('onPlaylistsChanged') @State playlists: SelectPlaylistRow[] = [];
  /** progressBar: VISIBLE in loadPlaylists(), GONE in displayPlaylists(). */
  @State isLoading: boolean = true;
  /** onError -> ErrorUtil.showSnackbar(ErrorInfo(e, UI_ERROR, "Loading playlists")). */
  @State errorInfo: string = '';
  /** OnSelectedListener.onLocalPlaylistSelected(id, name) - the LOCAL type branch. */
  onLocalPlaylistSelected: (playlistId: number, name: string) => void =
    (playlistId: number, name: string): void => {
      console.info('SelectPlaylistFragmentPage: no OnSelectedListener (local ' + name + ')');
    };
  /** OnSelectedListener.onRemotePlaylistSelected(serviceId, url, name) - the REMOTE branch. */
  onRemotePlaylistSelected: (serviceId: number, url: string, name: string) => void =
    (serviceId: number, url: string, name: string): void => {
      console.info('SelectPlaylistFragmentPage: no OnSelectedListener (remote ' + name + ')');
    };

  /** getItemCount()/getItem(): what LazyForEach reads inside SelectPlaylistAdapter. */
  private playlistSource: SelectPlaylistDataSource = new SelectPlaylistDataSource();

  onPlaylistsChanged(): void {
    this.playlistSource.submitList(this.playlists);
  }

  /**
   * loadPlaylists(): progressBar VISIBLE, list and empty view GONE, then
   *   disposable = getMergedOrderedPlaylists(localPlaylistManager, remotePlaylistManager)
   *       .observeOn(mainThread()).subscribe(this::displayPlaylists, this::onError)
   */
  aboutToAppear(): void {
    this.isLoading = true;
    this.errorInfo = '';
    const context: common.Context = getContext(this) as common.Context;
    this.loadPlaylists(context)
      .catch((err: Error): void => {
        // onError(e): ErrorUtil.showSnackbar(ErrorInfo(e, UI_ERROR, "Loading playlists")).
        // displayPlaylists() never ran, so the spinner stays up exactly as in the source.
        this.errorInfo = 'Loading playlists: ' + err.message;
        hilog.error(0x0000, 'SelectPlaylistFragment', 'Loading playlists: %{public}s', err.message);
      });
  }

  private async loadPlaylists(context: common.Context): Promise<void> {
    const local: LocalPlaylistManager = await LocalPlaylistManager.of(context);
    const remote: RemotePlaylistManager = await RemotePlaylistManager.of(context);
    const localPlaylists: PlaylistMetadataEntry[] = await local.getPlaylists();
    const remotePlaylists: PlaylistRemoteEntity[] = await remote.getPlaylists();
    this.displayPlaylists(mergePlaylists(localPlaylists, remotePlaylists));
  }

  /** displayPlaylists(newPlaylists): hide the spinner and publish the merged rows. */
  private displayPlaylists(merged: PlaylistLocalItem[]): void {
    this.playlistList = merged;
    this.rowTitle = merged.map((item: PlaylistLocalItem): string =>
      item.orderingName === null ? '' : item.orderingName);
    this.rowThumbnail = merged.map((item: PlaylistLocalItem): string =>
      item.thumbnailUrl === null ? '' : item.thumbnailUrl);
    this.localItemType = merged.map((item: PlaylistLocalItem): LocalItemType =>
      item.localItemType);

    const rows: SelectPlaylistRow[] = [];
    for (let i: number = 0; i < merged.length; i++) {
      const item: PlaylistLocalItem = merged[i];
      // clickedItem(position) dispatches on the SAME distinction, so the callback arguments are
      // carried per type: uid for a local playlist, serviceId + url for a remote one.
      let serviceId: number = 0;
      let url: string = '';
      if (item instanceof PlaylistRemoteEntity) {
        serviceId = item.serviceId;
        url = item.url === null ? '' : item.url;
      }
      rows.push(new SelectPlaylistRow(
        this.localItemType[i].toString() + '/' + item.uid.toString(),
        this.localItemType[i], this.rowTitle[i], this.rowThumbnail[i],
        item.uid, serviceId, url));
    }
    this.playlists = rows;
    this.isLoading = false;
  }

  build() {
    Column() {
      // A NewPipeTextView with NO android:id; the plan's slug is select_a_playlist_title.
      Text($r('app.string.select_a_playlist'))
        .id('select_a_playlist_title')
        .width('100%')
        .fontSize(TITLE_TEXT_SIZE)
        .fontColor(COLOR_ON_SURFACE)
        .margin({ left: 10, top: 5, right: 5, bottom: 10 })

      /*
       * displayPlaylists() - and UNLIKE the channel and feed-group pickers this branch does NOT
       * return early, so the source really does toggle emptyView VISIBLE / recyclerView GONE:
       *   loadPlaylists() -> progressBar VISIBLE
       *   empty result    -> progressBar GONE, empty_state_view VISIBLE, items_list GONE
       *   non-empty       -> progressBar GONE, items_list VISIBLE
       */
      if (this.isLoading) {
        LoadingProgress()
          .id('progressBar')
          .width(48)
          .height(48)
          .color($r('app.color.settings_accent'))
          .margin(5)
      } else if (this.playlists.length === 0) {
        Text($r('app.string.no_playlist_bookmarked_yet'))
          .id('empty_state_view')
          .width('100%')
          .fontSize(LIST_ITEM_TEXT_SIZE)
          .fontColor(COLOR_ON_SURFACE)
          .margin(10)
      } else {
        Column() {
          SelectPlaylistAdapter({
            dataSource: this.playlistSource,
            onLocalItemClicked: (item: SelectPlaylistRow): void => {
              this.onLocalPlaylistSelected(item.uid, item.orderingName);
              this.isShown = false;
            },
            onRemoteItemClicked: (item: SelectPlaylistRow): void => {
              this.onRemotePlaylistSelected(item.serviceId, item.url, item.orderingName);
              this.isShown = false;
            }
          })
        }
        .id('items_list')
        .width('100%')
        .layoutWeight(1)
      }

      // ErrorUtil.showSnackbar(ErrorInfo(e, UI_ERROR, "Loading playlists")) - rendered in place,
      // HarmonyOS having no snackbar; the spinner above stays up as it does in the source.
      if (this.errorInfo.length > 0) {
        Text(this.errorInfo)
          .width('100%')
          .fontSize(14)
          .fontColor(COLOR_SECONDARY_TEXT)
          .margin({ top: 8 })
      }
    }
    .id('SelectPlaylistFragmentPage')
    .width('100%')
    .height('100%')
    .padding(DIALOG_PADDING)
    // The ONE picker that does NOT setStyle(getMinWidthDialogTheme(...)): it keeps the plain
    // DialogFragment window, so its panel is ?attr/colorSurface white, not #EEEEEE - S0225
    // samples it at (255,255,255) where S0222/S0223/S0224 all sample (238,238,238).
    .backgroundColor($r('app.color.dialog_surface'))
    .alignItems(HorizontalAlign.Start)
  }
}
