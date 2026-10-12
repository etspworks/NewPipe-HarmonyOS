/*
 * S3 - port of org.schabi.newpipe.player.playqueue.PlayQueueAdapter, the RecyclerView.Adapter
 * behind both the player's items-list panel and PlayQueueActivity's list.
 *
 * ArkUI has no adapter object, so it splits exactly as InfoListAdapter's did:
 *   - the backing PlayQueueItem list + the notify* the PlayQueue event bus drives -> the
 *     IDataSource below,
 *   - onCreateViewHolder/onBindViewHolder -> the `row` builder the owning screen passes in,
 *     because it is the screen that knows what a tap on a row should do.
 *
 * Rule 7: a queue is unbounded, so it renders through LazyForEach over IDataSource.
 */
import { hilog } from '@kit.PerformanceAnalysisKit';
import { PlayQueueItem } from '../model/app/PlayQueueItem';

/** The adapter's backing list and the mutations the PlayQueue broadcast events apply to it. */
export class PlayQueueDataSource implements IDataSource {
  private items: PlayQueueItem[] = [];
  private listeners: DataChangeListener[] = [];

  totalCount(): number {
    return this.items.length;
  }

  getData(index: number): PlayQueueItem {
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

  getItems(): PlayQueueItem[] {
    return this.items;
  }

  isEmpty(): boolean {
    return this.items.length === 0;
  }

  /** InitEvent / ReorderEvent: the whole list is replaced. */
  setItems(items: PlayQueueItem[]): void {
    this.items = items.slice();
    this.notifyReloaded();
  }

  /** AppendEvent: notifyItemRangeInserted(). */
  appendItems(items: PlayQueueItem[]): void {
    if (items.length === 0) {
      return;
    }
    this.items = this.items.concat(items);
    this.notifyReloaded();
  }

  /** RemoveEvent: notifyItemRemoved(removeIndex). */
  removeAt(index: number): void {
    if (index < 0 || index >= this.items.length) {
      return;
    }
    this.items.splice(index, 1);
    this.notifyReloaded();
  }

  /** MoveEvent: notifyItemMoved(fromIndex, toIndex). */
  move(fromIndex: number, toIndex: number): void {
    if (fromIndex < 0 || fromIndex >= this.items.length
      || toIndex < 0 || toIndex >= this.items.length || fromIndex === toIndex) {
      return;
    }
    const moved: PlayQueueItem[] = this.items.splice(fromIndex, 1);
    this.items.splice(toIndex, 0, moved[0]);
    this.notifyReloaded();
  }

  private notifyReloaded(): void {
    this.listeners.forEach((listener: DataChangeListener) => {
      listener.onDataReloaded();
    });
  }
}

@Component
export struct PlayQueueAdapter {
  dataSource: PlayQueueDataSource = new PlayQueueDataSource();
  /** PlayQueue.getIndex() - the playing row, which the source highlights. */
  @Prop selectedIndex: number = 0;
  /** OnScrollBelowItemsListener -> PlayQueue.fetch(): a queue keeps extending past the screen. */
  onReachEnd: () => void = (): void => {
    hilog.debug(0x0000, 'NewPipe', 'PlayQueueAdapter: onReachEnd not bound');
  };
  /**
   * ItemTouchHelper.onMove(source, target) -> PlayQueue.move(). The reorder is the List's own
   * drag-sort (LazyForEach.onMove): a vertical PanGesture bound on a row or its handle never wins
   * against the List's scroll, so by touch the queue could not be reordered at all.
   */
  onItemMove: (fromIndex: number, toIndex: number) => void =
    (fromIndex: number, toIndex: number): void => {
      hilog.debug(0x0000, 'NewPipe', 'PlayQueueAdapter: move %{public}d->%{public}d not bound',
        fromIndex, toIndex);
    };
  /** The held row has started to travel: the row's long-press menu, if open, has to go. */
  onItemDragStart: (index: number) => void = (index: number): void => {
    hilog.debug(0x0000, 'NewPipe', 'PlayQueueAdapter: drag start %{public}d not bound', index);
  };
  @BuilderParam row: (item: PlayQueueItem, index: number) => void = this.defaultRow;

  @Builder
  defaultRow(item: PlayQueueItem, index: number) {
    Text(item.getTitle())
  }

  build() {
    List() {
      LazyForEach(this.dataSource, (item: PlayQueueItem, index: number) => {
        ListItem() {
          this.row(item, index)
        }
        // TC-PLAYER-399/400: keyed on the ITEM, never on its index. A drag-sort is precisely the
        // case where the index changes, so an index in the key makes every reordered row a
        // different row to ArkUI - it is destroyed and rebuilt instead of moved, which is the
        // "stuttering, and the animation not working correctly" the cards report. `uid` is stable
        // for the life of the item and unique even when a queue holds the same stream twice.
      }, (item: PlayQueueItem, index: number) => `${item.uid}`)
        .onMove((from: number, to: number): void => {
          this.onItemMove(from, to);
        }, {
          onDragStart: (index: number): void => {
            this.onItemDragStart(index);
          }
        })
    }
    .id('itemsList')
    .width('100%')
    .height('100%')
    .cachedCount(5)
    .onReachEnd(() => {
      this.onReachEnd();
    })
  }
}
