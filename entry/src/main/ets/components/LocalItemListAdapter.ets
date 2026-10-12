/*
 * S3 — port of org.schabi.newpipe.local.LocalItemListAdapter (a RecyclerView.Adapter).
 *
 * ArkUI has no adapter object: the adapter's TWO jobs split into
 *   1. the backing list + its mutations  -> LocalItemDataSource (IDataSource, below), which is
 *      addItems() / removeItem() / swapItems() / getItemsList(),
 *   2. the row dispatch (getItemViewType + onCreateViewHolder) -> the `row` builder the owning
 *      page passes in, because it is the page that knows `useItemHandle`.
 *
 * Rule 7: a bookmark list is unbounded, so it renders through LazyForEach over this IDataSource.
 */
import { PlaylistLocalItem } from '../model/db/view/PlaylistLocalItem';
import { PlaylistMetadataEntry } from '../model/db/view/PlaylistMetadataEntry';
import { PlaylistRemoteEntity } from '../model/db/entity/PlaylistRemoteEntity';

/**
 * Port of the type guard in BookmarkFragment.getItemTouchCallback().onMove(): a swap normally
 * needs both rows to be the SAME view type, but a LocalBookmarkPlaylistItemHolder and a
 * RemoteBookmarkPlaylistItemHolder may swap with each other even though their view types differ.
 */
function isBookmarkPlaylistHolder(item: PlaylistLocalItem): boolean {
  return item instanceof PlaylistMetadataEntry || item instanceof PlaylistRemoteEntity;
}

/** The adapter's `localItems` ArrayList and the notify* calls that keep the list in sync. */
export class LocalItemDataSource implements IDataSource {
  private items: PlaylistLocalItem[] = [];
  private listeners: DataChangeListener[] = [];

  totalCount(): number {
    return this.items.length;
  }

  getData(index: number): PlaylistLocalItem {
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

  /** Port of getItemsList(): what saveImmediate() renumbers the display indexes from. */
  getItemsList(): PlaylistLocalItem[] {
    return this.items;
  }

  /** Port of clearStreamItemList() + addItems(): handleResult() replaces the whole list. */
  setItems(items: PlaylistLocalItem[]): void {
    this.items = items;
    this.notifyReloaded();
  }

  /** Port of removeItem(LocalItem), used by deleteItem(). */
  removeItem(item: PlaylistLocalItem): boolean {
    const index: number = this.items.indexOf(item);
    if (index < 0) {
      return false;
    }
    this.items.splice(index, 1);
    this.notifyReloaded();
    return true;
  }

  /** Port of swapItems(from, to), called by the ItemTouchHelper onMove callback. */
  swapItems(sourceIndex: number, targetIndex: number): boolean {
    if (sourceIndex < 0 || targetIndex < 0
      || sourceIndex >= this.items.length || targetIndex >= this.items.length) {
      return false;
    }
    const moved: PlaylistLocalItem = this.items[sourceIndex];
    const against: PlaylistLocalItem = this.items[targetIndex];
    // onMove() refuses a swap across view types, with the bookmark-playlist exception above.
    if (moved.localItemType !== against.localItemType
      && !(isBookmarkPlaylistHolder(moved) && isBookmarkPlaylistHolder(against))) {
      return false;
    }
    this.items[sourceIndex] = against;
    this.items[targetIndex] = moved;
    this.notifyReloaded();
    return true;
  }

  private notifyReloaded(): void {
    for (const listener of this.listeners) {
      listener.onDataReloaded();
    }
  }
}

@Component
export struct LocalItemListAdapter {
  dataSource: LocalItemDataSource = new LocalItemDataSource();
  @BuilderParam row: (item: PlaylistLocalItem) => void = this.defaultRow;
  /**
   * ItemTouchHelper's drag, where the host has one (a local playlist): rows are dragged by their
   * handle, never by a long press (isLongPressDragEnabled() is false in the source). The host
   * does the swapping; this list only reports how tall one row is, so one step of the handle is
   * one real row, and is undefined for every other list.
   */
  onRowHeight?: (height: number) => void;
  /**
   * True while a handle is held: the List does not scroll then, or its scroll recognizer takes
   * the vertical move from the handle's pan.
   */
  @Prop scrollLocked: boolean = false;
  /**
   * A row key that survives a move. `type-uid` repeats when a playlist holds the same stream
   * twice, and two rows under one key cannot be told apart by the drag-sort.
   */
  rowKey?: (item: PlaylistLocalItem) => string;

  @Builder
  defaultRow(item: PlaylistLocalItem) {
    Text(item.orderingName === null ? '' : item.orderingName)
  }

  private keyOf(item: PlaylistLocalItem): string {
    const key: ((item: PlaylistLocalItem) => string) | undefined = this.rowKey;
    return key !== undefined ? key(item) : `${item.localItemType}-${item.uid}`;
  }

  build() {
    List() {
      if (this.onRowHeight !== undefined) {
        LazyForEach(this.dataSource, (item: PlaylistLocalItem) => {
          ListItem() {
            this.row(item)
          }
          // One drag step is one ListItem, measured, not the row's inner Row.
          .onAreaChange((oldValue: Area, newValue: Area) => {
            const report: ((height: number) => void) | undefined = this.onRowHeight;
            const measured: number =
              typeof newValue.height === 'number' ? newValue.height as number : 0;
            if (report !== undefined && measured > 0) {
              report(measured);
            }
          })
        }, (item: PlaylistLocalItem) => this.keyOf(item))
      } else {
        LazyForEach(this.dataSource, (item: PlaylistLocalItem) => {
          ListItem() {
            this.row(item)
          }
        }, (item: PlaylistLocalItem) => this.keyOf(item))
      }
    }
    .id('items_list')
    .width('100%')
    .height('100%')
    // The inner scrollbar's touch zone covers the handle at the right edge, so a reorderable
    // list has none (BookmarkFragmentPage's itemsList does the same).
    .scrollBar(this.onRowHeight !== undefined ? BarState.Off : BarState.Auto)
    .enableScrollInteraction(!this.scrollLocked)
  }
}
