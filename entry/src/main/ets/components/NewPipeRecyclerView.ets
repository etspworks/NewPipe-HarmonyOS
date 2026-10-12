/*
 * S3 — port of org.schabi.newpipe.views.NewPipeRecyclerView, the RecyclerView subclass
 * fragment_comments.xml uses for @+id/items_list.
 *
 * The subclass adds NOTHING to scrolling, layout or item rendering — every override in it exists
 * for one purpose: to fix D-pad FOCUS movement on TV, because RecyclerView's own focusSearch()
 * "fails to produce correct results in many cases":
 *   init()                    setFocusable(true) + FOCUS_AFTER_DESCENDANTS
 *   focusSearch()             always returns null, so every move falls through to
 *                             dispatchUnhandledMove()
 *   dispatchUnhandledMove()   arrow-scrolls by a fixed 100px when the adapter yields no view, and
 *                             SWALLOWS a downward move entirely while allowDpadScroll is false
 *                             ("Consuming downward scroll: content load in progress")
 *   setFocusScrollAllowed()   what the fragment calls to set that flag around a page load
 *   removeDetachedView()      requestFocus() on itself when the focused child is being recycled
 *
 * So this port carries the FOCUS behaviour and nothing else: the scrolling, recycling and item
 * binding are the ArkUI `List` inside InfoListAdapter's job, and that List is what keeps the
 * `items_list` slug (Rule 12 — one id per page, and it belongs on the real scroller).
 *
 * `focusScrollAllowed` is setFocusScrollAllowed(): while a page load is in progress a DOWN key is
 * consumed here instead of moving focus off the end of the list.
 */
import { hilog } from '@kit.PerformanceAnalysisKit';
import { KeyCode } from '@kit.InputKit';

@Component
export struct NewPipeRecyclerView {
  /** setFocusScrollAllowed(allowed) — false while loadMoreItems() is in flight. */
  @Prop focusScrollAllowed: boolean = true;
  @BuilderParam content: () => void = this.emptyContent;

  @Builder
  emptyContent() {
    Row()
  }

  build() {
    Column() {
      this.content()
    }
    .width('100%')
    .height('100%')
    // init(): setFocusable(true), FOCUS_AFTER_DESCENDANTS — the rows take focus first, and the
    // container itself is focusable so removeDetachedView() has somewhere to park focus.
    .focusable(true)
    .onKeyEvent((event: KeyEvent) => {
      // dispatchUnhandledMove(): "Consuming downward scroll: content load in progress".
      if (!this.focusScrollAllowed && event.type === KeyType.Down
        && event.keyCode === (KeyCode.KEYCODE_DPAD_DOWN as number)) {
        event.stopPropagation();
        hilog.info(0x0000, 'NewPipe', 'Consuming downward scroll: content load in progress');
      }
    })
  }
}
