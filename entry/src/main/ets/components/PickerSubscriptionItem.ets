/*
 * S3 — port of org.schabi.newpipe.local.subscription.item.PickerSubscriptionItem
 * (picker_subscription_item.xml). One cell of the 4-column subscriptions_selector_list grid.
 *
 * bind():
 *   CoilHelper.loadAvatar(thumbnailView, subscriptionEntity.avatarUrl)
 *   titleView.text = subscriptionEntity.name
 *   selectedHighlight.isVisible = isSelected
 * updateSelected(view, isSelected) only animates that same highlight, so `isSelected` is the one
 * piece of state the cell renders — the tick overlay is EXCLUSIVE with nothing; it sits ON TOP of
 * the avatar in a FrameLayout, which is a Stack here.
 *
 * Rule 12: repeated cell, so ONE shared id — `picker_subscription_itemroot`, the instrumenter's
 * injected slug, which is what the capture recorded and what the replay resolves by index.
 *
 * S5 owns the visual finish (circular avatar shape, 10sp title, colorControlHighlight scrim).
 */
import { hilog } from '@kit.PerformanceAnalysisKit';
import { SubscriptionEntity } from '../model/db/entity/SubscriptionEntity';

/**
 * picker_subscription_item.xml's own height: 4dp padding + the 48dp avatar + 2dp margin + one
 * 10sp title line. It is pinned rather than left to wrap because the highlight has to match it
 * exactly, and a '100%' height inside .overlay() resolves against the available space, not the
 * host - which drew the tick as a band down the whole grid.
 */
const CELL_HEIGHT: number = 72;

@Component
export struct PickerSubscriptionItem {
  item: SubscriptionEntity | null = null;
  /** PickerSubscriptionItem.isSelected — membership in FeedGroupDialog.selectedSubscriptions. */
  @Prop isSelected: boolean = false;
  onSelected: () => void = (): void => {
    hilog.debug(0x0000, 'NewPipe', 'PickerSubscriptionItem: onSelected not bound');
  };

  private avatarUrl(): string {
    const url: string | null = this.item === null ? null : this.item.avatarUrl;
    return url === null ? '' : url;
  }

  private title(): string {
    const name: string | null = this.item === null ? null : this.item.name;
    return name === null ? '' : name;
  }

  /**
   * selected_highlight: GONE unless the cell is in selectedSubscriptions.
   *
   * It is an .overlay() rather than a Stack child. The source's overlay is match_parent inside a
   * wrap_content FrameLayout, which Android resolves against the MEASURED parent; ArkTS resolves
   * '100%' against the AVAILABLE space, so as a Stack child it made the cell claim the whole grid
   * height the moment it was selected. .overlay() does not participate in layout at all, so the
   * cell keeps the body's size and the tick still covers it.
   */
  @Builder
  selectedHighlight() {
    Column() {
      Image($r('app.media.ic_done'))
        .width(48)
        .height(48)
        .margin({ top: 4 })
        .fillColor(Color.White)
        .objectFit(ImageFit.Contain)
    }
    .id('selected_highlight')
    .width('100%')
    .height(CELL_HEIGHT)
    .backgroundColor($r('app.color.selected'))
    .alignItems(HorizontalAlign.Center)
  }

  build() {
    // The root FrameLayout: the cell body, with selected_highlight laid over it.
    Stack() {
      Column() {
        Image(this.avatarUrl())
          .id('thumbnail_view')
          .width(48)
          .height(48)
          .borderRadius(24)
          .objectFit(ImageFit.Cover)
          .backgroundColor('#D6D7D7')

        Text(this.title())
          .id('title_view')
          .width('100%')
          .fontSize(10)
          .fontColor($r('app.color.on_surface'))
          .margin({ top: 2 })
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .textAlign(TextAlign.Center)
      }
      .width('100%')
      .height(CELL_HEIGHT)
      .constraintSize({ minWidth: 72 })
      .padding(4)
      .justifyContent(FlexAlign.Center)
      .alignItems(HorizontalAlign.Center)
      .overlay(this.isSelected ? this.selectedHighlight() : undefined,
        { align: Alignment.Center })
    }
    .id('picker_subscription_itemroot')
    .width('100%')
    .margin(2)
    .onClick(() => {
      this.onSelected();
    })
  }
}
