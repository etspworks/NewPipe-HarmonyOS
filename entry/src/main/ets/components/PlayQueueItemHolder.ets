/*
 * S3 - port of org.schabi.newpipe.player.playqueue.PlayQueueItemHolder (play_queue_item.xml).
 *
 * One queue row: thumbnail with a duration badge, title, "uploader" detail line and the drag
 * handle. The source holder owns itemRoot plus its click / long-click; the DRAG and SWIPE that
 * reorder and remove the row belong to PlayQueueItemTouchCallback, which wraps this body.
 *
 * Rule 12's list-row exception: every row carries the source's own @+id/itemRoot, shared, and
 * the replay resolves a row by index.
 */
import { hilog } from '@kit.PerformanceAnalysisKit';
import { PlayQueueItem } from '../model/app/PlayQueueItem';
import { choosePreferredImage, shouldLoadImages } from '../common/image/ImageLoader';
import { Localization } from '../common/i18n/Localization';
import { getNameOfServiceById } from './SelectedTabsAdapter';

/* S5 sizes the thumbnail; S3 only needs the box to exist. */
const THUMB_W: number = 100;
const THUMB_H: number = 60;
/** ViewConfiguration.getLongPressTimeout(): the hold that opens the row menu, in ms. */
const LONG_PRESS_MS: number = 500;
/** The travel that turns a hold into a drag instead, in vp. */
const HOLD_SLOP: number = 12;

@Component
export struct PlayQueueItemHolder {
  item: PlayQueueItem | null = null;
  /**
   * play_queue_item.xml sets no textColor, so the row inherits its HOST's - and the row has two
   * hosts with opposite grounds. Every mount but PlayQueueActivity's list is the player's items
   * panel (#AF000000), where the inherited near-black left the title and the detail line
   * invisible and a queue row looked like a bare thumbnail; the light activity passes false.
   *
   * Both new props carry a default, so the existing call sites keep compiling unchanged.
   */
  @Prop onDarkPanel: boolean = true;
  /** PlayQueue.getIndex() === this row: the playing item is tinted, as the source's is. */
  @Prop selected: boolean = false;
  /** PlayQueueItemBuilder.selected(item) -> player.selectQueueItem(item). */
  onSelected: () => void = (): void => {
    hilog.debug(0x0000, 'NewPipe', 'PlayQueueItemHolder: onSelected not bound');
  };
  /** PlayQueueItemBuilder.held(item) -> the item dialog. */
  onHeld: () => void = (): void => {
    hilog.debug(0x0000, 'NewPipe', 'PlayQueueItemHolder: onHeld not bound');
  };

  /** The pending hold, or -1: cleared by lifting or by moving past HOLD_SLOP. */
  private holdTimer: number = -1;
  private holdX: number = 0;
  private holdY: number = 0;

  /**
   * The hold that opens the row menu is timed off the raw touch stream on purpose. Bound as a
   * LongPressGesture it entered the gesture arena and, being the innermost recognizer, beat the
   * enclosing ListItem's own long-press - the one that starts the List's drag-sort - so a held
   * row could open its menu but never be dragged. onTouch is passive: the ListItem lifts the row
   * at the same moment, and the owner closes the menu again if the finger then travels.
   */
  private onRowTouch(event: TouchEvent): void {
    const touch: TouchObject | undefined = event.touches[0];
    if (event.type === TouchType.Down && touch !== undefined) {
      this.cancelHold();
      this.holdX = touch.x;
      this.holdY = touch.y;
      this.holdTimer = setTimeout((): void => {
        this.holdTimer = -1;
        this.onHeld();
      }, LONG_PRESS_MS);
    } else if (event.type === TouchType.Move && touch !== undefined) {
      if (Math.abs(touch.x - this.holdX) > HOLD_SLOP || Math.abs(touch.y - this.holdY) > HOLD_SLOP) {
        this.cancelHold();
      }
    } else if (event.type === TouchType.Up) {
      // Not on Cancel: the ListItem's own long-press, once it accepts, cancels this row's touch
      // stream while the finger is still down - and that is exactly the hold the menu is for.
      this.cancelHold();
    }
  }

  private cancelHold(): void {
    if (this.holdTimer !== -1) {
      clearTimeout(this.holdTimer);
      this.holdTimer = -1;
    }
  }

  aboutToDisappear(): void {
    this.cancelHold();
  }

  /** CoilHelper.loadThumbnail(itemThumbnailView, item.getThumbnails()). */
  private thumbnailUrl(): string {
    const url: string | null =
      this.item === null ? null : choosePreferredImage(this.item.getThumbnails());
    return url === null ? '' : url;
  }

  private title(): string {
    return this.item === null ? '' : this.item.getTitle();
  }

  /**
   * itemAdditionalDetails, verbatim from PlayQueueItemBuilder.buildItem():
   * concatenateStrings(item.getUploader(), getNameOfServiceById(item.getServiceId())) - the
   * uploader AND the service, joined by the dot separator. The port printed the uploader alone,
   * so the reference's "Lofi Girl - YouTube" read "Lofi Girl" here.
   */
  private additionalDetails(): string {
    const item: PlayQueueItem | null = this.item;
    if (item === null) {
      return '';
    }
    return Localization.concatenateStrings([
      item.getUploader(), getNameOfServiceById(item.getServiceId())
    ]);
  }

  /**
   * Localization.getDurationString(item.getDuration()) - the badge is mm:ss, not raw seconds.
   * `if (item.getDuration() > 0)` in the source: a live stream carries 0 and shows no badge at
   * all, where `< 0` printed a "00:00" over the live thumbnail.
   */
  private duration(): string {
    return this.item === null || this.item.getDuration() <= 0
      ? '' : Localization.getDurationString(this.item.getDuration());
  }

  /** itemVideoTitleView: ?android:textColorPrimary, resolved against the host's ground. */
  private titleColor(): ResourceColor {
    return this.onDarkPanel ? '#FFFFFFFF' : $r('app.color.on_surface');
  }

  /** itemAdditionalDetails: the dimmer ?android:textColorSecondary of the same ground. */
  private detailColor(): ResourceColor {
    return this.onDarkPanel ? '#B3FFFFFF' : $r('app.color.on_surface_variant');
  }

  /** The playing row is tinted rather than recoloured, so it reads on either ground. */
  private rowBackground(): ResourceColor {
    if (!this.selected) {
      return Color.Transparent;
    }
    return this.onDarkPanel ? '#33FFFFFF' : $r('app.color.selected');
  }

  build() {
    Row() {
      if (shouldLoadImages()) {
        Stack({ alignContent: Alignment.BottomEnd }) {
          Image(this.thumbnailUrl())
            .id('itemThumbnailView')
            .width('100%')
            .height('100%')
            .objectFit(ImageFit.Cover)
            // An Image is draggable by default, and that SYSTEM drag-and-drop (a floating copy
            // of the picture) takes the long-press before the List's own drag-sort can, so a
            // row held on its thumbnail or handle lifted a pixelmap and never reordered.
            .draggable(false)
          // The badge sits ON the thumbnail, so it carries its own scrim - unlike the two text
          // lines it never inherits a usable colour from either host.
          Text(this.duration())
            .id('itemDurationView')
            .fontSize(12)
            .fontColor('#FFFFFFFF')
            .backgroundColor('#A0000000')
            .padding({ left: 4, right: 4 })
        }
        .width(THUMB_W)
        .height(THUMB_H)
      }

      Column() {
        Text(this.title())
          .id('itemVideoTitleView')
          .width('100%')
          .maxLines(1)
          .fontSize(14)
          .fontColor(this.titleColor())
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(this.additionalDetails())
          .id('itemAdditionalDetails')
          .width('100%')
          .maxLines(1)
          .fontSize(12)
          .fontColor(this.detailColor())
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      .padding({ left: 8, right: 8 })

      Image($r('app.media.ic_drag_handle'))
        .id('itemHandle')
        .width(24)
        .height(24)
        .fillColor(this.detailColor())
        .draggable(false)
    }
    .id('itemRoot')
    .width('100%')
    .padding({ left: 8, right: 8, top: 4, bottom: 4 })
    .backgroundColor(this.rowBackground())
    .alignItems(VerticalAlign.Center)
    .onClick(() => {
      this.onSelected();
    })
    .onTouch((event: TouchEvent) => {
      this.onRowTouch(event);
    })
  }
}
