/*
 * S3 — port of org.schabi.newpipe.fragments.list.search.SuggestionListAdapter, a
 * ListAdapter<SuggestionItem> + DiffUtil.
 *
 * ArkUI has no adapter object, so it splits the way InfoListAdapter's did:
 *   submitList()/DiffUtil  -> SuggestionItemDataSource (IDataSource, below),
 *   onCreateViewHolder()   -> SuggestionItemHolder,
 *   onBindViewHolder()'s
 *   three setOn*Listener   -> the `row` builder the owning page passes in, because it is the
 *                             page that owns the OnSuggestionItemSelected listener.
 *
 * Rule 7: the suggestion list is unbounded (up to 25 history rows plus the service's remote
 * list), so it renders through LazyForEach over IDataSource.
 */
import { hilog } from '@kit.PerformanceAnalysisKit';
import { SuggestionItem } from '../model/app/SuggestionItem';

/** S5 — AppCompat textColorPrimary in the LightTheme; no migrated resource carries it. */
const COLOR_ON_SURFACE: Resource = $r('app.color.on_surface');

/** The adapter's current list plus submitList(), which REPLACES it (ListAdapter semantics). */
export class SuggestionItemDataSource implements IDataSource {
  private items: SuggestionItem[] = [];
  private listeners: DataChangeListener[] = [];

  totalCount(): number {
    return this.items.length;
  }

  getData(index: number): SuggestionItem {
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

  /** getCurrentList(). */
  getCurrentList(): SuggestionItem[] {
    return this.items;
  }

  /** submitList(newList). */
  submitList(items: SuggestionItem[]): void {
    this.items = items;
    this.listeners.forEach((listener: DataChangeListener) => {
      listener.onDataReloaded();
    });
  }
}

@Component
export struct SuggestionListAdapter {
  dataSource: SuggestionItemDataSource = new SuggestionItemDataSource();
  @BuilderParam row: (item: SuggestionItem) => void = this.defaultRow;
  /**
   * The ItemTouchHelper's onSwiped(viewHolder) — the owning page deletes that query from
   * history. Only rows getSuggestionMovementFlags() gives LEFT|RIGHT to can reach it.
   */
  onSwiped: (item: SuggestionItem) => void = (item: SuggestionItem): void => {
    hilog.debug(0x0000, 'NewPipe', 'SuggestionListAdapter: onSwiped not bound for %{public}s',
      item.query);
  };

  @Builder
  defaultRow(item: SuggestionItem) {
    Text(item.query)
  }

  /**
   * What the swipe uncovers. ItemTouchHelper has no button — the row is DISMISSED once the
   * swipe passes the threshold — so this is a label, never a second tap target.
   */
  @Builder
  deleteArea() {
    Row() {
      // A label, not a control: ItemTouchHelper paints no background of its own in the source,
      // so this only carries the list's own body text style.
      Text($r('app.string.delete'))
        .fontSize(14)
        .fontColor(COLOR_ON_SURFACE)
    }
    .height('100%')
    .padding({ left: 16, right: 16 })
    .justifyContent(FlexAlign.Center)
  }

  build() {
    List() {
      LazyForEach(this.dataSource, (item: SuggestionItem) => {
        // getSuggestionMovementFlags(): a history row swipes away LEFT or RIGHT, a remote
        // suggestion returns 0 flags and cannot be swiped at all.
        if (item.fromHistory) {
          ListItem() {
            this.row(item)
          }
          .swipeAction({
            start: {
              builder: (): void => {
                this.deleteArea();
              },
              onAction: (): void => {
                this.onSwiped(item);
              }
            },
            end: {
              builder: (): void => {
                this.deleteArea();
              },
              onAction: (): void => {
                this.onSwiped(item);
              }
            }
          })
        } else {
          ListItem() {
            this.row(item)
          }
        }
      }, (item: SuggestionItem, index: number) => `${item.fromHistory}-${item.query}-${index}`)
    }
    .id('suggestions_list')
    .width('100%')
    .height('100%')
    .cachedCount(5)
  }
}
