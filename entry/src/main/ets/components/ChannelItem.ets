/*
 * S3 — port of org.schabi.newpipe.local.subscription.item.ChannelItem
 * (list_channel_mini_item.xml, and its GRID variant list_channel_grid_item.xml).
 *
 * Unlike the info-list holders, this item layout owns its OWN row root (@+id/itemRoot), so the
 * id and both gestures live here:
 *   root.setOnClickListener { selected(infoItem) }      -> ChannelFragment
 *   root.setOnLongClickListener { held(infoItem) }      -> Share / Open in browser / Unsubscribe
 *
 * `itemRoot` is deliberately ONE shared id across all N rows (Rule 12's list-row exception): the
 * replay resolves `tap-card-N` by index, not by a unique id.
 */
import { hilog } from '@kit.PerformanceAnalysisKit';
import { SubscriptionEntity } from '../model/db/entity/SubscriptionEntity';
import { shouldLoadImages } from '../common/image/ImageLoader';
import { Localization } from '../common/i18n/Localization';

/* S5 — style only. textAppearanceLarge / textAppearanceSmall resolve to AppCompat's
 * textColorPrimary / textColorSecondary, which no migrated resource carries. */
const COLOR_ON_SURFACE: Resource = $r('app.color.on_surface');
const COLOR_SECONDARY_TEXT: Resource = $r('app.color.on_surface_variant');
/** ShapeableImageView + @style/CircularImageView (cornerSize 50%) — half the avatar's side. */
const MINI_AVATAR: number = 42;
const GRID_AVATAR: number = 92;

/** ChannelItem.ItemVersion — MINI is the list mode, GRID the grid one. */
export enum ChannelItemVersion {
  MINI,
  GRID
}

function unwiredGesture(which: string): void {
  hilog.debug(0x0000, 'NewPipe', 'ChannelItem: %{public}s not bound', which);
}

@Component
export struct ChannelItem {
  item: SubscriptionEntity | null = null;
  /** shouldUseGridForSubscription(ctx) picks MINI vs GRID. */
  itemVersion: ChannelItemVersion = ChannelItemVersion.MINI;
  onSelected: () => void = (): void => {
    unwiredGesture('selected');
  };
  onHeld: () => void = (): void => {
    unwiredGesture('held');
  };

  /** CoilHelper.loadAvatar(itemThumbnailView, infoItem.thumbnails). */
  private avatarUrl(): string {
    const url: string | null = this.item === null ? null : this.item.avatarUrl;
    return url === null ? '' : url;
  }

  private title(): string {
    const name: string | null = this.item === null ? null : this.item.name;
    return name === null ? '' : name;
  }

  /**
   * Localization.shortSubscriberCount(ctx, subscriberCount), or
   * @string/subscribers_count_not_available. S4 localizes the number itself.
   */
  private additionalDetails(): string {
    // ChannelItem.kt:53-65 getDetailLine(): shortSubscriberCount when >= 0, else the
    // subscribers_count_not_available string (the empty return picks that branch in build()).
    const count: number | null = this.item === null ? null : this.item.subscriberCount;
    return count === null || count < 0 ? '' : Localization.shortSubscriberCount(count);
  }

  build() {
    // MINI is a horizontal row, GRID stacks the avatar over the name — one root, one branch.
    Flex({
      direction: this.itemVersion === ChannelItemVersion.GRID
        ? FlexDirection.Column : FlexDirection.Row,
      alignItems: ItemAlign.Center
    }) {
      // CoilHelper.loadAvatar(itemThumbnailView, thumbnails) plus
      // itemThumbnailView.visibility = if (ImageStrategy.shouldLoadImages()) VISIBLE else GONE.
      // MINI: 42dp, marginStart 3dp / marginRight 15dp — which puts the title at the
      // capture's 72dp start (12 padding + 3 + 42 + 15). GRID: channel_item_grid_thumbnail_
      // image_size with a 2dp margin, centred over the name.
      Image(this.avatarUrl())
        .id('itemThumbnailView')
        .alt($r('app.media.placeholder_person'))
        .visibility(shouldLoadImages() ? Visibility.Visible : Visibility.None)
        .width(this.itemVersion === ChannelItemVersion.GRID ? GRID_AVATAR : MINI_AVATAR)
        .height(this.itemVersion === ChannelItemVersion.GRID ? GRID_AVATAR : MINI_AVATAR)
        .borderRadius(this.itemVersion === ChannelItemVersion.GRID
          ? GRID_AVATAR / 2 : MINI_AVATAR / 2)
        .margin({
          top: this.itemVersion === ChannelItemVersion.GRID ? 2 : 0,
          bottom: this.itemVersion === ChannelItemVersion.GRID ? 2 : 0,
          left: this.itemVersion === ChannelItemVersion.GRID ? 2 : 3,
          right: this.itemVersion === ChannelItemVersion.GRID ? 2 : 15
        })
        .objectFit(ImageFit.Cover)

      Column() {
        Text(this.title())
          .id('itemTitleView')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .fontSize($r('app.float.video_item_search_title_text_size'))
          .fontColor(COLOR_ON_SURFACE)
          .margin({ top: 3, bottom: 2 })

        if (this.additionalDetails().length > 0) {
          Text(this.additionalDetails())
            .id('itemAdditionalDetails')
            .maxLines(1)
            .fontSize($r('app.float.video_item_search_upload_date_text_size'))
            .fontColor(COLOR_SECONDARY_TEXT)
        } else {
          Text($r('app.string.subscribers_count_not_available'))
            .id('itemAdditionalDetails')
            .maxLines(1)
            .fontSize($r('app.float.video_item_search_upload_date_text_size'))
            .fontColor(COLOR_SECONDARY_TEXT)
        }
      }
      .layoutWeight(1)
      .alignItems(this.itemVersion === ChannelItemVersion.GRID
        ? HorizontalAlign.Center : HorizontalAlign.Start)
    }
    .id('itemRoot')
    .width('100%')
    // video_item_search_padding on the MINI row, channel_item_grid_padding on the grid cell.
    .padding(this.itemVersion === ChannelItemVersion.GRID
      ? $r('app.float.channel_item_grid_padding') : $r('app.float.video_item_search_padding'))
    .onClick(() => {
      this.onSelected();
    })
    .gesture(LongPressGesture().onAction(() => {
      this.onHeld();
    }))
  }
}
