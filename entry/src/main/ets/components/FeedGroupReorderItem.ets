/*
 * S3 — port of org.schabi.newpipe.local.subscription.item.FeedGroupReorderItem
 * (feed_group_reorder_item.xml): a CardView holding group_icon, group_name and handle.
 *
 * bind(): groupName.text = name; groupIcon.setImageResource(icon.getDrawableRes()).
 *
 * The ROW HAS NO CLICK LISTENER. The only interactive child is `handle`, whose OnTouchListener
 * starts the drag on ACTION_DOWN (dragCallback.startDrag(viewHolder)); getDragDirs() is UP or
 * DOWN. FeedGroupReorderDialog's TouchCallback additionally returns false from both
 * isLongPressDragEnabled() and isItemViewSwipeEnabled(), so the handle is the ONLY way to
 * reorder — making the row tappable here would ship an invented control.
 *
 * Rule 12: repeated row, so ONE shared id — `feed_group_reorder_itemroot`; `handle` is the
 * contract's own control id (S0135) and is likewise shared across the rows.
 *
 * S5 owns the visual finish (card background/corner/elevation, listPreferredItemHeightSmall).
 */
import { hilog } from '@kit.PerformanceAnalysisKit';
import { FeedGroupIcon, feedGroupIconDrawable } from '../model/enums/FeedGroupIcon';
import { mediaByName } from './SelectedTabsAdapter';

@Component
export struct FeedGroupReorderItem {
  groupId: number = 0;
  name: string = '';
  icon: FeedGroupIcon = FeedGroupIcon.ALL;
  /** True while this row is the one being dragged, so it reads as lifted off the list. */
  @Prop picked: boolean = false;
  /** How far the finger has carried this row from its slot, in vp. Zero unless it is the one held. */
  @Prop carryY: number = 0;
  /** handle ACTION_DOWN -> dragCallback.startDrag(viewHolder). */
  onHandleTouched: () => void = (): void => {
    hilog.debug(0x0000, 'NewPipe', 'FeedGroupReorderItem: onHandleTouched not bound');
  };
  /** The rest of the handle's OnTouchListener stream: TouchCallback.onMove drives the swap. */
  onHandleTouch: (event: TouchEvent) => void = (event: TouchEvent): void => {
    hilog.debug(0x0000, 'NewPipe', 'FeedGroupReorderItem: onHandleTouch not bound (%{public}d)',
      event.type as number);
  };

  build() {
    Row() {
      Image(mediaByName(feedGroupIconDrawable(this.icon)))
        .id('group_icon')
        .width(24)
        .height(24)
        .margin({ left: 16 })
        .objectFit(ImageFit.Contain)

      Text(this.name)
        .id('group_name')
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)
        .fontSize(16)
        .fontColor($r('app.color.on_surface'))
        .margin({ left: 16, top: 6, bottom: 6 })

      Image($r('app.media.ic_drag_handle'))
        .id('handle')
        .width(56)
        .height(48)
        .padding({ left: 16, right: 16, top: 12, bottom: 12 })
        .fillColor($r('app.color.on_surface_variant'))
        .objectFit(ImageFit.Contain)
        // ONE touch stream, as in the source: ACTION_DOWN is the drag start. A separate onClick
        // fired onHandleTouched a second time, after onTouch's Up had already ended the drag.
        .onTouch((event: TouchEvent) => {
          if (event.type === TouchType.Down) {
            this.onHandleTouched();
          }
          this.onHandleTouch(event);
        })
    }
    .id('feed_group_reorder_itemroot')
    .width('100%')
    .constraintSize({ minHeight: 48 })
    .margin({ top: 3, bottom: 3 })
    .backgroundColor($r('app.color.surface'))
    .borderRadius(5)
    .shadow(this.picked
      ? { radius: 12, color: '#40000000', offsetX: 0, offsetY: 4 }
      : { radius: 4, color: '#1A000000', offsetX: 0, offsetY: 1 })
    .scale(this.picked ? { x: 1.02, y: 1.02 } : { x: 1, y: 1 })
    .animation({ duration: 120, curve: Curve.Friction })
    // Above its neighbours and under the finger, which is what makes the drag visible at all.
    .zIndex(this.picked ? 1 : 0)
    .translate({ y: this.carryY })
    .alignItems(VerticalAlign.Center)
  }
}
