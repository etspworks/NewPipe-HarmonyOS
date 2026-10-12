/*
 * S3 — port of org.schabi.newpipe.local.feed.item.StreamItem's VIEW half
 * (StreamItem.kt getLayout()/initializeViewBinding()/bind(), over list_stream_item.xml).
 *
 * The data half already lives in model/app/StreamItem.ts (Phase 2). What is here is exactly the
 * part groupie owned: which layout an ItemVersion selects, and the field-by-field bind().
 *
 * groupie's GroupieAdapter maps to LazyForEach + an IDataSource, so the adapter's backing list
 * lives here too (StreamItemDataSource) — FeedFragment is the only screen with a Groupie list,
 * so it does not share InfoListAdapter's InfoItemDataSource.
 *
 * Rule 12 list-row exception: the row root carries the SHARED source id `itemRoot`, never a
 * per-row unique one — the replay resolves tap-card-N by index.
 *
 * S5: styled from fragment_FeedFragment/base.png + list_stream_item.xml + dimens.xml —
 * 12vp row padding, 124x70vp thumbnail, 6vp gutter, 14/11/12fp type, translucent duration badge.
 */
import { StreamItem as StreamItemData, ItemVersion, isLiveStream } from '../model/app/StreamItem';
import { StreamEntity } from '../model/db/entity/StreamEntity';
import { Localization } from '../common/i18n/Localization';
import { shouldLoadImages } from '../common/image/ImageLoader';
import { hilog } from '@kit.PerformanceAnalysisKit';

/** Longer than this and the press was a long press, not a tap. LongPressGesture's own
 * threshold is 500 ms; the margin keeps a slow tap from being swallowed. */
const HELD_CLICK_GUARD_MILLIS: number = 500;

/** Default for a gesture the parent has not bound yet — never silently empty. */
function unwiredGesture(): void {
  hilog.debug(0x0000, 'NewPipe', 'StreamItem: row gesture not bound');
}

/* list_stream_item.xml: @dimen/video_item_search_thumbnail_image_{width,height}. */
const THUMB_W: number = 124;
const THUMB_H: number = 70;
/*
 * list_stream_grid_item.xml is a DIFFERENT layout with a DIFFERENT thumbnail:
 * @dimen/video_item_grid_thumbnail_image_{width,height}. This port had the stacked versions
 * reusing the row layout's 124x70, which is why a Grid or Card list drew cells a third smaller
 * than the reference's - measured on the two handsets at 124.0 x 70.2 vp against 164.0 x 92.0.
 * The resources were already in float.json (308/312) and referenced by nothing but comments.
 */
const GRID_THUMB_W: number = 164;
const GRID_THUMB_H: number = 92;
/* Baseline tokens (state.json generation.styleBaseline). */
const C_ON_SURFACE: Resource = $r('app.color.on_surface');
const C_SECONDARY: Resource = $r('app.color.on_surface_variant');

/**
 * GroupieAdapter's backing list. `updateAsync(loadedState.items, false)` REPLACES the list in
 * one shot (the feed is not paginated), which is why this exposes setItems() rather than the
 * append InfoItemDataSource has.
 */
export class StreamItemDataSource implements IDataSource {
  private items: StreamItemData[] = [];
  private listeners: DataChangeListener[] = [];

  totalCount(): number {
    return this.items.length;
  }

  getData(index: number): StreamItemData {
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

  getItemsList(): StreamItemData[] {
    return this.items;
  }

  isEmpty(): boolean {
    return this.items.length === 0;
  }

  /** groupAdapter.updateAsync(loadedState.items, false). */
  setItems(items: StreamItemData[]): void {
    this.items = items;
    this.notifyReloaded();
  }

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
export struct StreamItem {
  item: StreamItemData | null = null;
  /** getLayout(): NORMAL/MINI/GRID/CARD pick a different row layout. */
  @Prop itemVersion: ItemVersion = ItemVersion.NORMAL;
  /**
   * execBindEnd — highlightNewItemsAfter() sets it on rows whose uploadDate is newer than the
   * previous oldestSubscriptionUpdate: bold title plus a dashed border (the border is S5).
   */
  @Prop highlighted: boolean = false;
  /** onItemClick -> openVideoDetailFragment; ignored while isRefreshing (the page decides). */
  onSelected: () => void = unwiredGesture;
  /** onItemLongClick -> showInfoItemDialog(stream.toStreamInfoItem()). */
  onHeld: () => void = unwiredGesture;
  /**
   * When the long press last fired. A parallel gesture is not arbitrated against the row's own
   * click, so without this the press that opens the menu ALSO navigates, and the menu comes up
   * over the detail page it just pushed.
   */
  private pressedAt: number = 0;

  private stream(): StreamEntity | null {
    return this.item === null ? null : this.item.getStream();
  }

  private title(): string {
    const s: StreamEntity | null = this.stream();
    return s === null ? '' : s.title;
  }

  private uploader(): string {
    const s: StreamEntity | null = this.stream();
    return s === null ? '' : s.uploader;
  }

  private thumbnailUrl(): string {
    const s: StreamEntity | null = this.stream();
    return s === null || s.thumbnailUrl === null ? '' : s.thumbnailUrl;
  }

  /** bind(): duration > 0 -> getDurationString; live -> @string/duration_live; else GONE. */
  private hasDuration(): boolean {
    const s: StreamEntity | null = this.stream();
    return s !== null && (s.duration > 0 || isLiveStream(s.streamType));
  }

  /** bind(): a live stream gets @color/live_duration_background_color, not the black one. */
  private isLive(): boolean {
    const s: StreamEntity | null = this.stream();
    return s !== null && s.duration <= 0 && isLiveStream(s.streamType);
  }

  private durationText(): string {
    const s: StreamEntity | null = this.stream();
    if (s === null) {
      return '';
    }
    return s.duration > 0 ? Localization.getDurationString(s.duration) : 'LIVE';
  }

  /** itemProgressView is VISIBLE only for a finite stream that carries a saved position. */
  private hasProgress(): boolean {
    return this.item !== null && this.item.getProgressSeconds() !== null;
  }

  private progressSeconds(): number {
    const p: number | null = this.item === null ? null : this.item.getProgressSeconds();
    return p === null ? 0 : p;
  }

  private durationSeconds(): number {
    const s: StreamEntity | null = this.stream();
    return s === null || s.duration <= 0 ? 1 : s.duration;
  }

  /** bind(): itemAdditionalDetails is written for every version EXCEPT MINI. */
  private additionalDetails(): string {
    return this.item === null ? '' : this.item.getStreamInfoDetailLine();
  }

  /** getLayout(): GRID and CARD stack the same pieces vertically; NORMAL and MINI lay them out
   * as a row. The two grid layouts are one branch here because their two holders -
   * StreamGridInfoItemHolder and StreamCardInfoItemHolder, which this mirrors - are themselves
   * identical in this port. */
  private isStacked(): boolean {
    return this.itemVersion === ItemVersion.GRID || this.itemVersion === ItemVersion.CARD;
  }

  /** The thumbnail with its duration badge and resume bar - identical in all four versions. */
  @Builder
  thumbnailBlock() {
    Stack({ alignContent: Alignment.BottomEnd }) {
      Image(this.thumbnailUrl())
        .id('itemThumbnailView')
        .width('100%')
        .height('100%')
        .objectFit(ImageFit.Cover)
        .backgroundColor($r('app.color.placeholder_background'))

      if (this.hasDuration()) {
        Text(this.durationText())
          .id('itemDurationView')
          .fontSize($r('app.float.video_item_search_duration_text_size'))
          .fontColor($r('app.color.duration_text_color'))
          .backgroundColor(this.isLive()
            ? $r('app.color.live_duration_background_color')
            : $r('app.color.duration_background_color'))
          .padding({
            left: $r('app.float.video_item_search_duration_horizontal_padding'),
            right: $r('app.float.video_item_search_duration_horizontal_padding'),
            top: $r('app.float.video_item_search_duration_vertical_padding'),
            bottom: $r('app.float.video_item_search_duration_vertical_padding')
          })
          .margin($r('app.float.video_item_search_duration_margin'))
      }

      if (this.hasProgress()) {
        Progress({
          value: this.progressSeconds(),
          total: this.durationSeconds(),
          type: ProgressType.Linear
        })
          .id('itemProgressView')
          .width('100%')
          .height(4)
          .color($r('app.color.primary'))
      }
    }
    // The stacked versions are the grid layout, and it has its own thumbnail size.
    .width(this.isStacked() ? GRID_THUMB_W : THUMB_W)
    .height(this.isStacked() ? GRID_THUMB_H : THUMB_H)
  }

  /** The three text lines. MINI is the one version bind() does not write the details line for. */
  @Builder
  detailsBlock() {
    Text(this.title())
      .id('itemVideoTitleView')
      .maxLines(2)
      .textOverflow({ overflow: TextOverflow.Ellipsis })
      .fontSize($r('app.float.video_item_search_title_text_size'))
      .fontColor(C_ON_SURFACE)
      .width('100%')
      // execBindEnd's highlight: setTypeface(BOLD) on the title.
      .fontWeight(this.highlighted ? FontWeight.Bold : FontWeight.Normal)

    Text(this.uploader())
      .id('itemUploaderView')
      .maxLines(1)
      .textOverflow({ overflow: TextOverflow.Ellipsis })
      .fontSize($r('app.float.video_item_search_uploader_text_size'))
      .fontColor(C_SECONDARY)
      .width('100%')

    if (this.itemVersion !== ItemVersion.MINI) {
      Text(this.additionalDetails())
        .id('itemAdditionalDetails')
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .fontSize($r('app.float.video_item_search_upload_date_text_size'))
        .fontColor(C_SECONDARY)
        .width('100%')
    }
  }

  build() {
    // list_stream_item.xml / list_stream_mini_item.xml / list_stream_grid_item.xml /
    // list_stream_card_item.xml share the same view ids; only the arrangement and the presence
    // of itemAdditionalDetails differ.
    if (this.isStacked()) {
      // The grid cell stacks the same pieces, so the thumbnail's gutter is a BOTTOM margin
      // rather than a right one - the shape StreamGridInfoItemHolder was verified in.
      Column() {
        if (shouldLoadImages()) {
          this.thumbnailBlock()
        }

        Column() {
          this.detailsBlock()
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
        .margin({ top: $r('app.float.video_item_search_image_right_margin') })
      }
      // Rule 12 list-row exception: the SHARED source slug, resolved by index at replay.
      .id('itemRoot')
      .width('100%')
      .alignItems(HorizontalAlign.Start)
      .padding($r('app.float.video_item_search_padding'))
      .border(this.highlighted
        ? { width: 1, color: $r('app.color.border'), style: BorderStyle.Dashed }
        : { width: 0 })
      // onTouch, not onClick: ArkUI delivers the click on finger-up BEFORE the parallel long
      // press reports, so a time guard inside onClick never sees the press that is already in
      // flight - the menu opened over the detail page the same press had just pushed. Measuring
      // the press here decides it in one place: a short press selects, a long one does not.
      .onTouch((event: TouchEvent) => {
        if (event.type === TouchType.Down) {
          this.pressedAt = Date.now();
        } else if (event.type === TouchType.Up) {
          if (Date.now() - this.pressedAt < HELD_CLICK_GUARD_MILLIS) {
            this.onSelected();
          }
        }
      })
      // parallelGesture, not gesture: the row lives inside a List that is itself inside a
      // Refresh, and the enclosing scroll container wins the gesture arena for a press that
      // lasts long enough to be a long press - the menu never opened on the feed, while the
      // Downloads row, which uses bindContextMenu's own LongPress response, always did.
      // A parallel gesture is not arbitrated against the parent's, so the row sees the press.
      .parallelGesture(
        LongPressGesture()
          .onAction(() => {
            this.onHeld();
          })
      )
    } else {
      Row() {
        if (shouldLoadImages()) {
          this.thumbnailBlock()
        }

        Column() {
          this.detailsBlock()
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
        .margin({ left: $r('app.float.video_item_search_image_right_margin') })
      }
      // Rule 12 list-row exception: the SHARED source slug, resolved by index at replay.
      .id('itemRoot')
      .width('100%')
      .alignItems(VerticalAlign.Top)
      .padding($r('app.float.video_item_search_padding'))
      // execBindEnd's highlight: @drawable/dashed_border_light layered over the row background.
      .border(this.highlighted
        ? { width: 1, color: $r('app.color.border'), style: BorderStyle.Dashed }
        : { width: 0 })
      // onTouch, not onClick: ArkUI delivers the click on finger-up BEFORE the parallel long
      // press reports, so a time guard inside onClick never sees the press that is already in
      // flight - the menu opened over the detail page the same press had just pushed. Measuring
      // the press here decides it in one place: a short press selects, a long one does not.
      .onTouch((event: TouchEvent) => {
        if (event.type === TouchType.Down) {
          this.pressedAt = Date.now();
        } else if (event.type === TouchType.Up) {
          if (Date.now() - this.pressedAt < HELD_CLICK_GUARD_MILLIS) {
            this.onSelected();
          }
        }
      })
      // parallelGesture, not gesture: the row lives inside a List that is itself inside a
      // Refresh, and the enclosing scroll container wins the gesture arena for a press that
      // lasts long enough to be a long press - the menu never opened on the feed, while the
      // Downloads row, which uses bindContextMenu's own LongPress response, always did.
      // A parallel gesture is not arbitrated against the parent's, so the row sees the press.
      .parallelGesture(
        LongPressGesture()
          .onAction(() => {
            this.onHeld();
          })
      )
    }
  }
}
