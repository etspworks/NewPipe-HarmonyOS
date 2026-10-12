/*
 * S3 - port of org.schabi.newpipe.info_list.InfoListAdapter (a RecyclerView.Adapter).
 *
 * ArkUI has no adapter object, so the adapter's jobs split the same way LocalItemListAdapter's
 * did:
 *   1. the backing list + notify* mutations        -> InfoItemDataSource (IDataSource, below),
 *   2. getItemViewType() + onCreateViewHolder()    -> the `row` builder the owning page passes in,
 *      because it is the page that knows useMiniVariant and getItemViewMode(),
 *   3. the HEADER_TYPE / FOOTER_TYPE slots         -> the `header` / `footer` builders, gated by
 *      hasHeader() and showFooter(), exactly as getItemCount() counts them.
 *
 * Rule 7: an info list is unbounded (paged), so it renders through LazyForEach over IDataSource.
 * OnScrollBelowItemsListener -> loadMoreItems() becomes onReachEnd.
 */
import { hilog } from '@kit.PerformanceAnalysisKit';
import { InfoItem } from '../common/extractor/core/InfoItem';

/* getGridLayoutManager() divides by a column width it BUILDS, not by the raw dimen:
 *
 *   int width = resources.getDimensionPixelSize(R.dimen.video_item_grid_thumbnail_image_width);
 *   width += (24 * resources.getDisplayMetrics().density);
 *   final int spanCount = Math.floorDiv(resources.getDisplayMetrics().widthPixels, width);
 *
 * and video_item_grid_thumbnail_image_width is 164dp, so the divisor is 164 + 24 = 188, not 164.
 * At 164 this port fitted one column more than the source does at a whole band of widths - a
 * 360vp phone took two 180vp columns where floorDiv(360, 188) is one.
 *
 * lanes() counts the same way: a LengthConstrain sets the column count from minLength alone -
 * "the maximum number of columns whose width still satisfies minLength" - while maxLength is
 * only handed down to a child that sets no width of its own. Math.floorDiv has no maximum at
 * all, so this one is deliberately inert: a lane is always narrower than twice minLength
 * (width/floor(width/min) < 2*min for every width), so a maximum of twice minLength can never
 * bind, which is the closest LengthConstrain gets to not having one - both fields are required. */
export const GRID_LANE_MIN_WIDTH: number = 188;
export const GRID_LANE_MAX_WIDTH: number = GRID_LANE_MIN_WIDTH * 2;

/** Port of org.schabi.newpipe.info_list.ItemViewMode (ItemViewMode.kt). */
export enum ItemViewMode {
  LIST,
  GRID,
  CARD
}

/** The adapter's `infoItemList` ArrayList and the notify* calls that keep the list in sync. */
export class InfoItemDataSource implements IDataSource {
  private items: InfoItem[] = [];
  private listeners: DataChangeListener[] = [];

  totalCount(): number {
    return this.items.length;
  }

  getData(index: number): InfoItem {
    return this.items[index];
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

  /** Port of getItemsList(). */
  getItemsList(): InfoItem[] {
    return this.items;
  }

  isEmpty(): boolean {
    return this.items.length === 0;
  }

  /** Port of addInfoItemList(List<InfoItem>): a loaded page is APPENDED, never replaces. */
  addItems(items: InfoItem[]): void {
    if (items.length === 0) {
      return;
    }
    this.items = this.items.concat(items);
    this.notifyReloaded();
  }

  /**
   * Port of notifyItemChanged(position). A row whose RENDER state changed (the comment
   * TextEllipsizer's expand/collapse) but whose data did not: LazyForEach reuses the cached
   * child for an unchanged key on onDataReloaded(), so only onDataChange(index) rebuilds it.
   */
  notifyItemChanged(index: number): void {
    if (index < 0 || index >= this.items.length) {
      return;
    }
    this.listeners.forEach((listener: DataChangeListener) => {
      listener.onDataChange(index);
    });
  }

  /** Port of clearStreamItemList(). */
  clearItems(): void {
    if (this.items.length === 0) {
      return;
    }
    this.items = [];
    this.notifyReloaded();
  }

  private notifyReloaded(): void {
    this.listeners.forEach((listener: DataChangeListener) => {
      listener.onDataReloaded();
    });
  }
}

@Component
export struct InfoListAdapter {
  dataSource: InfoItemDataSource = new InfoItemDataSource();
  /**
   * hasHeader(): headerSupplier != null. A @Prop, so a header that becomes available after the
   * list is built (RelatedItemsFragment's autoplay row, once its StreamInfo arrives) appears.
   */
  @Prop hasHeader: boolean = false;
  /** showFooter(show): the pignate_footer progress row while more pages remain. */
  showFooter: boolean = false;
  /** OnScrollBelowItemsListener -> loadMoreItems(). */
  onReachEnd: () => void = (): void => {
    hilog.debug(0x0000, 'NewPipe', 'InfoListAdapter: onReachEnd not bound');
  };
  /**
   * The vertical distance this list just moved, in vp, positive when the content moves up.
   *
   * NestedScrollingChild: in the source a RecyclerView reports its scroll to the CoordinatorLayout
   * above it, which is how AppBarLayout knows to collapse. ArkUI has no equivalent across a pager
   * boundary, so the host passes this in and the list hands the delta back.
   */
  onScrolled: (delta: number) => void = (): void => {
  };
  /**
   * RecyclerView.scrollToPosition(0) has no ArkUI analogue without a Scroller, and the host is
   * the one that knows WHEN to scroll (onTabReselected). Every instance gets its own by default,
   * so a host that does not care is unaffected.
   */
  scroller: Scroller = new Scroller();
  /**
   * ThemeHelper.getItemViewMode(): the source hands GRID and CARD a GridLayoutManager with
   * getGridSpanCount() columns, where LIST gets a LinearLayoutManager. lanes() is ArkUI's
   * span count, and without it a grid row holder simply stacked one per row - 'Grid' meant
   * 'a different row template', not a grid. The host passes the mode it already resolves.
   */
  viewMode: ItemViewMode = ItemViewMode.LIST;
  @BuilderParam header: () => void = this.emptySlot;
  @BuilderParam footer: () => void = this.emptySlot;
  @BuilderParam row: (item: InfoItem) => void = this.defaultRow;

  @Builder
  emptySlot() {
    Row()
  }

  @Builder
  defaultRow(item: InfoItem) {
    Text(item.getName())
  }

  build() {
    List({ scroller: this.scroller }) {
      // A header is ONE ListItem, and a ListItem takes ONE lane once the list is laned, where
      // the source's SpanSizeLookup spans it across the row. A ListItemGroup fills the List's
      // width whatever the lane count, and its header slot fills the group - so the row spans
      // again. sticky() is never set on this list, so the group header is not sticky either.
      if (this.hasHeader) {
        ListItemGroup({ header: this.header })
      }
      LazyForEach(this.dataSource, (item: InfoItem) => {
        ListItem() {
          this.row(item)
        }
      }, (item: InfoItem, index: number) => `${item.getUrl()}-${index}`)
      // Same lane problem, same fix: the pignate_footer spinner spans the row, not one lane.
      if (this.showFooter) {
        ListItemGroup({ footer: this.footer })
      }
    }
    .id('items_list')
    .width('100%')
    .height('100%')
    .cachedCount(5)
    // NestedScrollingChild, for the one host that is a CoordinatorLayout: VideoDetailFragmentPage
    // scrolls the player + metadata header above this pager, so an upward swipe has to collapse
    // that header FIRST (PARENT_FIRST) and a downward one has to return this list to its top
    // before the header comes back (SELF_FIRST). Every other host mounts this list with no
    // scrollable parent, where nestedScroll has nothing to hand to and changes nothing.
    .nestedScroll({
      scrollForward: NestedScrollMode.PARENT_FIRST,
      scrollBackward: NestedScrollMode.SELF_FIRST
    })
    // getGridSpanCount(): floor(available width / video_item_grid_thumbnail_image_width), at
    // least one. A minLength lets the list do that division itself, so a wider screen gets
    // more columns with no measurement of our own.
    //
    // GRID ONLY. refreshItemViewMode() reads
    //   itemsList.setLayoutManager(mode == ItemViewMode.GRID ? getGridLayoutManager()
    //                                                        : getListLayoutManager())
    // so CARD is a LINEAR list of card-shaped rows, one per row, and only GRID is columned.
    .lanes(this.viewMode === ItemViewMode.GRID
      ? { minLength: GRID_LANE_MIN_WIDTH, maxLength: GRID_LANE_MAX_WIDTH } : 1)
    .onReachEnd(() => {
      this.onReachEnd();
    })
    .onDidScroll((scrollOffset: number) => {
      this.onScrolled(scrollOffset);
    })
  }
}
