/**
 * S4 — FeedGroupReorderDialog (screen_feed_group_reorder_dialog). presentation: modal.
 *
 * NOT a routed page: an OVERLAY mounted by its hostScreen screen_subscription
 * (SubscriptionFragmentPage) through FeedGroupReorderDialogHost, a CustomDialogController, and it
 * is opened from header_sort. Its routeTable row exists for the skeleton contract only and must
 * never be pushed; it is deliberately absent from main_pages.json.
 *
 * dialog_feed_group_reorder.xml is the whole tree: feed_groups_list (weight 1, 6dp padding, a
 * vertical RecyclerView of feed_group_reorder_item), a 1dp separator, then confirm_button on the
 * end edge. Source facts this pass honours (FeedGroupReorderDialog.kt):
 *  - The order lives ONLY IN MEMORY until OK is pressed - dismissing the sheet discards it.
 *  - confirm_button calls viewModel.updateOrder(groupOrderedIdList) ->
 *    FeedDatabaseManager.updateGroupsOrder(); the dialog closes on the resulting SuccessEvent,
 *    NOT on the click, so `isShown` is cleared inside doAction() and never by the handler.
 *  - The row has NO click listener. Only `handle` is interactive: ACTION_DOWN starts the drag,
 *    TouchCallback.onMove notifies the adapter and Collections.swap(groupOrderedIdList).
 *    isLongPressDragEnabled and isItemViewSwipeEnabled both return false, so the handle is the
 *    ONLY reorder affordance - which is why the drag is driven by the handle's own touch stream.
 *  - handleGroups(): when groupOrderedIdList is empty the DB order is taken as-is and seeds it;
 *    otherwise the incoming list is re-sorted by groupOrderedIdList.indexOf(uid) so an
 *    in-progress reorder survives a DB emission. That is the render branch on `sortOrder`.
 *
 * S5 owns every colour, size and glyph.
 */
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { FeedGroupEntity } from '../model/db/entity/FeedGroupEntity';
import { FeedDatabase } from '../common/feed/FeedLoader';
import { DebounceSaver } from '../common/util/DebounceSaver';
import { FeedGroupReorderItem } from '../components/FeedGroupReorderItem';
import { display } from '@kit.ArkUI';

const TAG: string = 'FeedGroupReorderDialogPage';

/** feat_drag_reorder: the window a burst of drag steps is coalesced over. */
const REORDER_DEBOUNCE_MILLIS: number = 300;

/** One drag step: the travel the handle must cover before a swap (SelectedTabsAdapter's rule). */
const ROW_DRAG_STEP: number = 48;

/** How long a swapped pair takes to change places. ItemTouchHelper's own move animation. */
const REORDER_SWAP_MILLIS: number = 200;

/**
 * One row's pitch: feed_group_reorder_item's 48vp minimum plus its 3vp margins top and bottom.
 * A row is swapped once the finger has carried the dragged card past half of it, which is where
 * ItemTouchHelper swaps - not after a fixed 48vp of travel, which is what the port did.
 */
const ROW_PITCH_VP: number = 54;

/**
 * A share of the window's height in vp. The card is a CustomDialogController's content, and a
 * dialog has no parent height for a percentage to resolve against.
 */
function windowHeightVp(context: UIContext, fraction: number): string {
  return (context.px2vp(display.getDefaultDisplaySync().height) * fraction).toString() + 'vp';
}

@Component
export struct FeedGroupReorderDialogPage {
  /** Two-way with the host's visibility flag; cleared only on the SuccessEvent. */
  @Link isShown: boolean;
  /** groupsLiveData: the feed groups in DB sort order. Loaded, never a literal. */
  @Prop groupList: FeedGroupEntity[] = [];
  /** pendingOrder mirrors groupOrderedIdList once a drag burst has settled. */
  @Prop pendingOrder: number[] = [];
  /** groupOrderedIdList: the in-memory order, empty until the first emission seeds it. */
  @State sortOrder: number[] = [];
  /** The same rows re-sorted by sortOrder.indexOf(uid) - handleGroups()'s else branch. */
  @State orderedGroups: FeedGroupEntity[] = [];
  @State isLoading: boolean = true;
  @State errorInfo: string | null = null;
  /** dialogEventLiveData == ProcessingEvent -> disableInput(): confirm disabled, not cancelable. */
  @State isProcessing: boolean = false;
  /** The row the handle picked up, so the touch stream knows what it is swapping. */
  @State draggingIndex: number = -1;

  /** How far the dragged card has been carried from its resting place, in vp. */
  @State dragOffset: number = 0;

  private feedDatabase: FeedDatabase | null = null;
  private dragBaselineY: number = 0;
  /**
   * feat_drag_reorder: a burst of handle drags is coalesced before pendingOrder - the value
   * updateGroupsOrder() is handed - is recomputed from the live sortOrder.
   */
  private debounceSaver: DebounceSaver = new DebounceSaver(REORDER_DEBOUNCE_MILLIS, (): void => {
    this.pendingOrder = this.sortOrder.slice();
  });

  aboutToAppear(): void {
    this.loadGroups();
  }

  aboutToDisappear(): void {
    this.debounceSaver.dispose();
  }

  /* //////////////////////////////////////////////////////////////////////////
  // FeedGroupReorderDialogViewModel
  ////////////////////////////////////////////////////////////////////////// */

  private async ensureDatabase(): Promise<FeedDatabase | null> {
    const existing: FeedDatabase | null = this.feedDatabase;
    if (existing !== null) {
      return existing;
    }
    try {
      const database: FeedDatabase = await FeedDatabase.of(getContext(this) as common.Context);
      this.feedDatabase = database;
      return database;
    } catch (err) {
      this.errorInfo = (err as BusinessError).message;
      this.isLoading = false;
      return null;
    }
  }

  /** groupsLiveData.observe(::handleGroups). */
  private async loadGroups(): Promise<void> {
    this.isLoading = true;
    const database: FeedDatabase | null = await this.ensureDatabase();
    if (database === null) {
      return;
    }
    try {
      this.handleGroups(await database.groups());
    } catch (err) {
      this.errorInfo = (err as BusinessError).message;
    }
    this.isLoading = false;
  }

  /** handleGroups(list) verbatim: seed the order, or re-sort the emission by it. */
  private handleGroups(list: FeedGroupEntity[]): void {
    this.groupList = list;
    if (this.sortOrder.length === 0) {
      const seeded: number[] = list.map((group: FeedGroupEntity): number => group.uid);
      this.sortOrder = seeded;
      this.pendingOrder = seeded.slice();
      this.orderedGroups = list;
      return;
    }
    this.orderedGroups = this.sortByPendingOrder(list);
  }

  /** list.sortedBy { groupOrderedIdList.indexOf(it.uid) }. */
  private sortByPendingOrder(list: FeedGroupEntity[]): FeedGroupEntity[] {
    const copy: FeedGroupEntity[] = list.slice();
    copy.sort((left: FeedGroupEntity, right: FeedGroupEntity): number =>
      this.sortOrder.indexOf(left.uid) - this.sortOrder.indexOf(right.uid));
    return copy;
  }

  /** TouchCallback.onMove: notifyItemMoved + Collections.swap(groupOrderedIdList). */
  private swapItems(fromIndex: number, toIndex: number): void {
    const rows: FeedGroupEntity[] = this.renderedGroups().slice();
    if (fromIndex < 0 || toIndex < 0 || fromIndex >= rows.length || toIndex >= rows.length
      || fromIndex === toIndex) {
      return;
    }
    const moved: FeedGroupEntity = rows[fromIndex];
    rows[fromIndex] = rows[toIndex];
    rows[toIndex] = moved;

    const order: number[] = this.sortOrder.slice();
    const fromId: number = order[fromIndex];
    order[fromIndex] = order[toIndex];
    order[toIndex] = fromId;

    // The rows MOVE rather than jumping. The source's ItemTouchHelper animates the swap, and the
    // case reports its absence as "the sorting operation cannot be performed with the correct
    // animation" - the port reassigned the array and the two rows changed places in one frame.
    animateTo({ duration: REORDER_SWAP_MILLIS, curve: Curve.Friction }, () => {
      this.sortOrder = order;
      this.orderedGroups = rows;
      this.draggingIndex = toIndex;
    });
    this.debounceSaver.setHasChangesToSave();
  }

  /** The rows on screen: the DB order until an in-progress reorder exists. */
  private renderedGroups(): FeedGroupEntity[] {
    return this.sortOrder.length === 0 ? this.groupList : this.orderedGroups;
  }

  /**
   * The handle's touch stream. ACTION_DOWN starts the drag (getDragDirs() is UP or DOWN, so only
   * vertical movement counts); each ROW_DRAG_STEP of travel is one onMove.
   */
  private onHandleTouch(index: number, event: TouchEvent): void {
    if (event.touches.length === 0) {
      return;
    }
    const y: number = event.touches[0].displayY;
    if (event.type === TouchType.Down) {
      this.draggingIndex = index;
      this.dragBaselineY = y;
      this.dragOffset = 0;
      return;
    }
    if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
      // The card settles back into the slot it ended up in, rather than snapping.
      animateTo({ duration: REORDER_SWAP_MILLIS, curve: Curve.Friction }, () => {
        this.dragOffset = 0;
      });
      this.draggingIndex = -1;
      return;
    }
    if (this.draggingIndex < 0 || event.type !== TouchType.Move) {
      return;
    }
    // The card FOLLOWS the finger. The port only counted travel and never moved anything, so
    // nothing was visibly being dragged - rows just changed places every 48vp.
    this.dragOffset = y - this.dragBaselineY;
    const rows: number = this.renderedGroups().length;
    if (this.dragOffset >= ROW_PITCH_VP / 2 && this.draggingIndex + 1 < rows) {
      this.dragBaselineY += ROW_PITCH_VP;
      this.dragOffset -= ROW_PITCH_VP;
      this.swapItems(this.draggingIndex, this.draggingIndex + 1);
    } else if (this.dragOffset <= -ROW_PITCH_VP / 2 && this.draggingIndex > 0) {
      this.dragBaselineY -= ROW_PITCH_VP;
      this.dragOffset += ROW_PITCH_VP;
      this.swapItems(this.draggingIndex, this.draggingIndex - 1);
    }
  }

  /** confirm_button -> viewModel.updateOrder(groupOrderedIdList). */
  private async updateOrder(): Promise<void> {
    if (this.isProcessing) {
      return;
    }
    const database: FeedDatabase | null = await this.ensureDatabase();
    if (database === null) {
      return;
    }
    // ProcessingEvent -> disableInput().
    this.isProcessing = true;
    this.debounceSaver.cancel();
    this.pendingOrder = this.sortOrder.slice();
    try {
      await database.updateGroupsOrder(this.pendingOrder);
      // SuccessEvent -> dismiss().
      this.isShown = false;
    } catch (err) {
      this.errorInfo = (err as BusinessError).message;
      hilog.error(0x0000, TAG, 'updateGroupsOrder failed: %{public}s',
        (err as BusinessError).message);
    } finally {
      this.isProcessing = false;
    }
  }

  /**
   * The dialog window's height. base.ui.json puts the empty dialog at [27,1105][957,1210] =
   * 310x35vp: 6dp list padding top and bottom, a 1dp separator and a 22vp button bar. Each row is
   * ?listPreferredItemHeightSmall (48dp) plus the card's 3dp margins.
   */
  private cardHeight(): string {
    return (12 + this.renderedGroups().length * 54 + 23).toString() + 'vp';
  }

  build() {
    // Only the card: FeedGroupReorderDialogHost's CustomDialogController draws the 0.6 dim.
    Stack() {
      Column() {
      List() {
        // handleGroups(): the DB order as-is while groupOrderedIdList is empty, otherwise the
        // list re-sorted by it, so an in-progress reorder survives a DB emission.
        ForEach(this.sortOrder.length === 0 ? this.groupList : this.orderedGroups,
          (item: FeedGroupEntity, index: number) => {
            ListItem() {
              FeedGroupReorderItem({
                groupId: item.uid,
                name: item.name,
                icon: item.icon,
                // The row under the finger is PICKED UP, as ItemTouchHelper raises it: the source
                // lifts the dragged view above the rest instead of leaving the list flat, and
                // carries it with the finger.
                picked: this.draggingIndex === index,
                carryY: this.draggingIndex === index ? this.dragOffset : 0,
                onHandleTouched: (): void => {
                  // dragCallback.startDrag(viewHolder).
                  this.draggingIndex = index;
                  this.dragBaselineY = 0;
                },
                onHandleTouch: (event: TouchEvent): void => {
                  this.onHandleTouch(index, event);
                }
              })
            }
          }, (item: FeedGroupEntity) => item.uid.toString())
      }
      .id('feed_groups_list')
      .width('100%')
      .layoutWeight(1)
      // 6dp list padding plus the row card's own 8dp side margins (feed_group_reorder_item.xml).
      .padding({ left: 14, right: 14, top: 6, bottom: 6 })
      .scrollBar(BarState.Auto)

      Divider()
        .strokeWidth(1)
        .color($r('app.color.separator'))

      Row() {
        Blank()
        Button($r('app.string.ok'))
          .id('confirm_button')
          .type(ButtonType.Normal)
          .height(22)
          .borderRadius(2)
          .backgroundColor(Color.Transparent)
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.on_surface'))
          .padding({ left: 8, right: 8 })
          .enabled(!this.isProcessing)
          .onClick(() => {
            this.updateOrder();
          })
      }
      .width('100%')
      .height(22)
      .alignItems(VerticalAlign.Center)
      }
      // The source's AlertDialog is nearly the screen's width with a small inset, not a narrow
      // centred card - the port's 310vp left wide grey margins the reference does not have.
      .width('94%')
      .height(this.cardHeight())
      .constraintSize({ maxHeight: windowHeightVp(this.getUIContext(), 0.72) })
      .backgroundColor($r('app.color.dialog_background'))
      .borderRadius(2)
      .clip(true)
    }
    .id('FeedGroupReorderDialogPage')
    .width('100%')
  }
}

/** The @CustomDialog a CustomDialogController's builder has to be. */
@CustomDialog
export struct FeedGroupReorderDialogHost {
  @Link isShown: boolean;
  controller?: CustomDialogController;

  build() {
    FeedGroupReorderDialogPage({ isShown: this.isShown })
  }
}

