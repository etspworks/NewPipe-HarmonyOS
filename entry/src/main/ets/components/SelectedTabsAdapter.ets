/*
 * S3 - port of ChooseTabsFragment.SelectedTabsAdapter (list_choose_tabs.xml).
 *
 * RecyclerView.Adapter over the fragment's `tabList`:
 *   onCreateViewHolder/onBindViewHolder -> the row below (tabIcon / tabName / handle),
 *   getItemCount()                      -> SelectedTabsDataSource (IDataSource),
 *   swapItems(from, to)                 -> onSwapItems, raised by the List's own drag-sort,
 *   ItemTouchHelper.onSwiped(holder)    -> onSwipeRemove, raised by the row swipe.
 *
 * The list OWNS no state: the fragment owns tabList, so every mutation is a callback up to the
 * page, which mutates and re-submits. The rows are NOT clickable in the source - only the handle
 * drags and the row swipes away.
 *
 * The drag is the List's, not ours. A PanGesture on the handle cannot outrank the List's own
 * scroll, so by touch these rows could not be reordered at all, and the row Images are draggable
 * by default, so a long press escaped into a system drag instead. The List's drag-sort takes the
 * press, animates the shuffle and reports one onMove on release - the same answer this repo has
 * reached four times now, and the shape InstanceListAdapter already carries.
 */

import { hilog } from '@kit.PerformanceAnalysisKit';
import { Localization } from '../common/i18n/Localization';
import { all as allServices } from '../common/extractor/ServiceRegistry';
import { StreamingService } from '../common/extractor/core/StreamingService';
import {
  BlankTab,
  ChannelTab,
  DefaultKioskTab,
  FeedGroupTab,
  KioskTab,
  PlaylistTab,
  Tab
} from '../model/app/Tab';

/** getTabIconRes() gives a drawable NAME, and the $r sugar only takes a literal. */
export function mediaByName(name: string): Resource {
  const resource: Resource = {
    bundleName: '',
    moduleName: '',
    id: -1,
    params: [`app.media.${name}`],
    type: 20000
  };
  return resource;
}

/** The source falls back to R.drawable.ic_whatshot wherever a tab reports no icon. */
export function tabIconResource(tab: Tab): Resource {
  const name: string = tab.getTabIconRes();
  return mediaByName(name.length === 0 ? 'ic_whatshot' : name);
}

/** Port of ServiceHelper.getNameOfServiceById(serviceId). */
export function getNameOfServiceById(serviceId: number): string {
  for (const service of allServices()) {
    if (service.getServiceId() === serviceId) {
      const found: StreamingService = service;
      return found.getServiceInfo().getName();
    }
  }
  return '<unknown>';
}

/**
 * Port of TabViewHolder.getTabName(type, tab) - the row label. Every branch is the source's, so
 * the label is derived from the tab, never a literal read off a screenshot.
 */
export function tabRowLabel(tab: Tab): string {
  if (tab instanceof BlankTab) {
    return Localization.getString('blank_page_summary');
  }
  if (tab instanceof DefaultKioskTab) {
    return Localization.getString('default_kiosk_page_summary');
  }
  if (tab instanceof KioskTab) {
    const kiosk: KioskTab = tab;
    return getNameOfServiceById(kiosk.getKioskServiceId()) + '/' + kiosk.getTabName();
  }
  if (tab instanceof ChannelTab) {
    const channel: ChannelTab = tab;
    return getNameOfServiceById(channel.getChannelServiceId()) + '/' + channel.getTabName();
  }
  if (tab instanceof PlaylistTab) {
    const playlist: PlaylistTab = tab;
    // The PLAYLIST branch's `serviceId == -1 -> R.string.local` half is a CONDITION on the row's
    // bound state, so it lives in the render (see build() below), not hidden in this switch.
    return getNameOfServiceById(playlist.getPlaylistServiceId()) + '/' + playlist.getTabName();
  }
  if (tab instanceof FeedGroupTab) {
    const group: FeedGroupTab = tab;
    return Localization.getString('feed_groups_header_title') + '/' + group.getFeedGroupName();
  }
  return tab.getTabName();
}

/**
 * PlaylistTab.getPlaylistServiceId() for a playlist row, 0 for every other tab type: the value
 * TabViewHolder.getTabName branches on (-1 = a LOCAL playlist, labelled R.string.local).
 */
export function playlistServiceIdOf(tab: Tab): number {
  if (tab instanceof PlaylistTab) {
    const playlist: PlaylistTab = tab;
    return playlist.getPlaylistServiceId();
  }
  return 0;
}

/** getItemCount() / the fragment's tabList, as the LazyForEach source. */
export class SelectedTabsDataSource implements IDataSource {
  private items: Tab[] = [];
  private listeners: DataChangeListener[] = [];
  /**
   * The LazyForEach key per row, derived from the tab's CONTENT so it travels with the row through
   * a reorder. An index-bearing key changes for every row a move touched, which leaves the List no
   * row to animate and the reorder lands as a jump.
   *
   * getAvailableTabs() offers KIOSK, CHANNEL, PLAYLIST and FEEDGROUP without the containsTab()
   * guard the plain tabs get, so identical content CAN sit in the list twice and content alone is
   * not unique. The occurrence ordinal separates them; two rows that would collide are identical,
   * so the ordinal moves only when one is dragged past the other, which looks like nothing
   * happened because nothing visible did.
   */
  private keys: string[] = [];

  keyAt(index: number): string {
    return index >= 0 && index < this.keys.length ? this.keys[index] : `tab-row-${index}`;
  }

  totalCount(): number {
    return this.items.length;
  }

  getData(index: number): Tab {
    return this.items[index];
  }

  /**
   * getBindingAdapterPosition(): where a row sits NOW. A row the List reordered keeps the index
   * its builder captured, because a key-matched child is reused rather than rebuilt, so anything
   * positional has to be asked for at the moment it is used.
   */
  indexOf(tab: Tab): number {
    return this.items.indexOf(tab);
  }

  registerDataChangeListener(listener: DataChangeListener): void {
    if (this.listeners.indexOf(listener) < 0) {
      this.listeners.push(listener);
    }
  }

  unregisterDataChangeListener(listener: DataChangeListener): void {
    const pos: number = this.listeners.indexOf(listener);
    if (pos >= 0) {
      this.listeners.splice(pos, 1);
    }
  }

  /** notifyDataSetChanged() / notifyItemRemoved() / notifyItemInserted(0): the page re-submits. */
  submitList(items: Tab[]): void {
    this.items = items;
    const seen: Map<string, number> = new Map();
    this.keys = items.map((tab: Tab): string => {
      const content: string = JSON.stringify(tab.toJson());
      const before: number | undefined = seen.get(content);
      const ordinal: number = before === undefined ? 0 : before;
      seen.set(content, ordinal + 1);
      return `${content}#${ordinal}`;
    });
    this.listeners.forEach((listener: DataChangeListener) => {
      listener.onDataReloaded();
    });
  }
}

@Component
export struct SelectedTabsAdapter {
  dataSource: SelectedTabsDataSource = new SelectedTabsDataSource();
  /** swapItems(fromPosition, toPosition) -> Collections.swap(tabList) in the page. */
  onSwapItems: (fromIndex: number, toIndex: number) => void =
    (fromIndex: number, toIndex: number): void => {
      hilog.debug(0x0000, 'NewPipe', 'SelectedTabsAdapter: onSwapItems not bound (%{public}d)',
        fromIndex);
    };
  /** ItemTouchHelper.onSwiped(viewHolder) -> tabList.remove(position) in the page. */
  onSwipeRemove: (index: number) => void = (index: number): void => {
    hilog.debug(0x0000, 'NewPipe', 'SelectedTabsAdapter: onSwipeRemove not bound (%{public}d)',
      index);
  };

  /**
   * What the swipe uncovers. ItemTouchHelper paints no button - the row is DISMISSED once the
   * swipe passes the threshold - so this is a label, never a second tap target.
   */
  @Builder
  swipeRemoveArea() {
    Row() {
      Text($r('app.string.delete'))
        .fontSize(14)
        .fontColor($r('app.color.on_primary'))
    }
    .height('100%')
    .padding({ left: 24, right: 24 })
    .justifyContent(FlexAlign.Center)
    .alignItems(VerticalAlign.Center)
    .backgroundColor($r('app.color.primary'))
  }

  build() {
    List() {
      LazyForEach(this.dataSource, (item: Tab) => {
        ListItem() {
          Row() {
            Image(tabIconResource(item))
              .id('tabIcon')
              .width(24)
              .height(24)
              .objectFit(ImageFit.Contain)
              // An Image is draggable by default, and that SYSTEM drag lifts a pixelmap out of
              // the row instead of letting the List's drag-sort have the long press.
              .draggable(false)

            // ?textAppearanceListItem, 16dp past the icon (tabName's layout_marginLeft).
            // Derived from the row's OWN tab, never from an index-parallel array: the List reuses
            // a key-matched row through a reorder without rebuilding it, so the index this
            // builder captured is the one it had before the move.
            Text(playlistServiceIdOf(item) === -1
              ? Localization.getString('local') + '/' + item.getTabName()
              : tabRowLabel(item))
              .id('tabName')
              .fontSize(16)
              .fontColor($r('app.color.on_surface'))
              .maxLines(2)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .layoutWeight(1)
              .margin({ left: 16 })

            // The handle's 16dp/12dp padding around the 24dp glyph: a 56x48 target flush to
            // the card's end, exactly as base.ui.json measures it ([897,..][1065,..] at 3.0).
            Image($r('app.media.ic_drag_handle'))
              .id('handle')
              .width(56)
              .height(48)
              .padding({ left: 16, right: 16, top: 12, bottom: 12 })
              .objectFit(ImageFit.Contain)
              .draggable(false)
          }
          // The RelativeLayout inside the card: what ItemTouchHelper swipes away. It carries the
          // CardView's own surface (cardCornerRadius 5dp) - the baseline's radius.card 0 was
          // derived on a screen with no card, and this screen's layout is explicit.
          .id('choose_tabs_row_swipe')
          .width('100%')
          .height(48)
          .padding({ left: 16 })
          .alignItems(VerticalAlign.Center)
          .backgroundColor($r('app.color.surface'))
          .borderRadius(5)
          // cardElevation 4dp. The shadow sits on the node that carries the surface and the
          // radius, so it follows the card's rounded outline and travels with the swipe.
          .shadow({ radius: 8, color: '#29000000', offsetX: 0, offsetY: 2 })
        }
        // Rule 12 list-row exception: every row shares one id, resolved by index.
        .id('selected_tab_itemroot')
        // CardView: layout_margin 5dp/3dp (base.ui.json: [15,402][1065,546], 18px between cards).
        .margin({ left: 5, right: 5, top: 3, bottom: 3 })
        .swipeAction({
          start: {
            builder: (): void => {
              this.swipeRemoveArea();
            },
            onAction: (): void => {
              this.onSwipeRemove(this.dataSource.indexOf(item));
            }
          },
          end: {
            builder: (): void => {
              this.swipeRemoveArea();
            },
            onAction: (): void => {
              this.onSwipeRemove(this.dataSource.indexOf(item));
            }
          }
        })
      }, (item: Tab, index: number) => this.dataSource.keyAt(index))
        // ItemTouchHelper's drag, as ArkUI spells it: the List lifts the held row, shuffles the
        // rest under it and clamps it to both ends by itself, then reports the ONE move on
        // release. The PanGesture this replaces never beat the List's own scroll, so by touch
        // these rows could not be reordered at all - and the source reported a swap per row of
        // travel where this reports one move, which is why the page splices instead of swapping.
        .onMove((from: number, to: number): void => {
          this.onSwapItems(from, to);
        })
    }
    .id('selectedTabs')
    .width('100%')
    .height('100%')
    // The inner scrollbar's touch zone covers the handle at the row's end, and a finger that
    // lands on it grabs the bar instead of the row (AceScrollBar). The RecyclerView draws no
    // scrollbar here either.
    .scrollBar(BarState.Off)
  }
}
