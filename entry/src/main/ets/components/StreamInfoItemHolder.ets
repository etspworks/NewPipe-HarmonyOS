/*
 * S3 - port of org.schabi.newpipe.info_list.holder.StreamInfoItemHolder (list_stream_item.xml).
 *
 * STREAM_HOLDER_TYPE: the mini variant plus itemAdditionalDetails (views and upload date).
 * The row root (@+id/itemRoot) and its click/long-click belong to InfoItemHolder, the base class,
 * so this struct is the BODY that wrapper renders.
 *
 * S5: the four Stream*InfoItemHolder structs were left at the S3 stub geometry - a literal
 * 100x60 thumbnail, no row padding, no gutter, and Text nodes with no size or colour at all, so
 * every kiosk / search / channel / related list drew its titles at the platform default and
 * butted them against the thumbnail. list_stream_item.xml is the same layout StreamItem.ets and
 * LocalStatisticStreamItemHolder.ets already render, so the dimens and the type scale below are
 * theirs, migrated - not numbers chosen here (TC-KIOSK-258/262/267).
 */
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { StreamInfoItem } from '../model/extractor/StreamInfoItem';
import { StreamType } from '../model/enums/StreamType';
import { Localization } from '../common/i18n/Localization';
import { isLiveStream } from '../model/app/StreamItem';
import { choosePreferredImage, shouldLoadImages } from '../common/image/ImageLoader';
import { AppDatabase } from '../common/db/AppDatabase';
import { HistoryRecordManager } from '../common/db/HistoryRecordManager';
import { StreamStateEntity } from '../model/db/entity/StreamStateEntity';
import { Preferences } from '../common/prefs/Preferences';
import { enable_playback_state_lists_key } from '../common/prefs/SettingsKeys';

/**
 * Port of StreamInfoItemHolder.getStreamInfoDetailLine(StreamInfoItem) - the localized view /
 * watching / listening count joined to the relative upload date with DOT_SEPARATOR, and NEITHER
 * half nor the separator emitted when its value is missing. Exported because the source's
 * StreamCard/StreamGrid holders inherit this method from this class.
 */
export function getStreamInfoDetailLine(infoItem: StreamInfoItem | null): string {
  if (infoItem === null) {
    return '';
  }

  let viewsAndDate: string = '';
  const viewCount: number = infoItem.getViewCount();
  if (viewCount >= 0) {
    if (infoItem.getStreamType() === StreamType.AUDIO_LIVE_STREAM) {
      viewsAndDate = Localization.listeningCount(viewCount);
    } else if (infoItem.getStreamType() === StreamType.LIVE_STREAM) {
      viewsAndDate = Localization.shortWatchingCount(viewCount);
    } else {
      viewsAndDate = Localization.shortViewCount(viewCount);
    }
  }

  const uploadDate: string | null = Localization.relativeTimeOrTextual(
    infoItem.getUploadDate(), infoItem.getTextualUploadDate());
  if (uploadDate !== null && uploadDate.length > 0) {
    return viewsAndDate.length === 0
      ? uploadDate
      : Localization.concatenateStrings([viewsAndDate, uploadDate]);
  }
  return viewsAndDate;
}

/**
 * Port of StreamMiniInfoItemHolder.updateFromItem()'s itemDurationView arm, shared by the four
 * row holders that inherit it in the source: `duration > 0` shows the formatted duration, a live
 * stream shows R.string.duration_live, and anything else sets the badge GONE - reproduced here as
 * an empty label, which the holders test for so the badge is ABSENT rather than an empty coloured
 * chip floating over the thumbnail.
 */
export function getStreamDurationText(item: StreamInfoItem | null): string {
  if (item === null) {
    return '';
  }
  if (item.getDuration() > 0) {
    return Localization.getDurationString(item.getDuration());
  }
  return isLiveStream(item.getStreamType()) ? Localization.getString('duration_live') : '';
}

/** The same arm's colour split: a live badge uses live_duration_background_color. */
export function isLiveDurationBadge(item: StreamInfoItem | null): boolean {
  return item !== null && item.getDuration() <= 0 && isLiveStream(item.getStreamType());
}

/**
 * Port of StreamMiniInfoItemHolder.updateState(): the holder itself asks HistoryRecordManager for
 * the item's StreamStateEntity and shows itemProgressView over the thumbnail when one exists -
 * the source does exactly this per bind, which is why the query lives here and no caller has to
 * pass anything in. The port stubbed it as `progress() { return 0; }` and drew the bar
 * unconditionally BESIDE the thumbnail at zero, so no list ever showed a watch position
 * (TC-KIOSK-029/056/287).
 *
 * Returns the saved position in SECONDS, or -1 when there is none. updateState()'s own guard
 * skips a live stream and a stream with no duration, and "Positions in lists" turns the markers
 * off for the whole app.
 *
 * ponytail: two indexed reads per visible row, the same pair the source runs (blocking) per bind;
 * batch them in the adapter if a long list ever measures slow.
 */
export async function loadStreamProgressSeconds(item: StreamInfoItem | null,
  context: common.Context): Promise<number> {
  if (item === null || item.getDuration() <= 0 || isLiveStream(item.getStreamType())) {
    return -1;
  }
  const markersEnabled: boolean =
    await Preferences.getBoolean(enable_playback_state_lists_key, true);
  if (!markersEnabled) {
    return -1;
  }
  try {
    const history: HistoryRecordManager =
      new HistoryRecordManager(await AppDatabase.getInstance(context));
    const state: StreamStateEntity | null = await history.loadStreamStateOfInfoItem(item);
    return state === null ? -1 : state.progressMillis / 1000;
  } catch (err) {
    const failure: BusinessError = err as BusinessError;
    hilog.warn(0x0000, 'NewPipe', 'updateState: %{public}s', failure.message);
    return -1;
  }
}

/* list_stream_item.xml's own type scale (the baseline tokens StreamItem.ets already carries). */
export const C_ON_SURFACE: Resource = $r('app.color.on_surface');
export const C_SECONDARY: Resource = $r('app.color.on_surface_variant');

/** The text chain's inset, as a share of video_item_search_thumbnail_image_height (70vp). */
const ROW_TEXT_INSET_TOP: number = 7;    // 10%
const ROW_TEXT_INSET_BOTTOM: number = 7; // 10%

@Component
export struct StreamInfoItemHolder {
  item: StreamInfoItem | null = null;
  /** updateState()'s saved position in seconds; -1 until the query answers, and when none exists. */
  @State progressSeconds: number = -1;

  aboutToAppear(): void {
    loadStreamProgressSeconds(this.item, getContext(this) as common.Context)
      .then((seconds: number): void => {
        this.progressSeconds = seconds;
      });
  }

  /** isShortFormContent(): a short gets a portrait tile instead of the 16:9 one. */
  private isShortForm(): boolean {
    return this.item !== null && this.item.getIsShortFormContent();
  }

  /** CoilHelper.loadThumbnail(itemThumbnailView, item.getThumbnails()). */
  private thumbnailUrl(): string {
    const url: string | null =
      this.item === null ? null : choosePreferredImage(this.item.getThumbnails());
    return url === null ? '' : url;
  }

  private title(): string {
    return this.item === null ? '' : this.item.getName();
  }

  private uploader(): string {
    return this.item === null ? '' : this.item.uploaderName;
  }

  /** StreamMiniInfoItemHolder.updateFromItem(): formatted duration, 'Live', or GONE. */
  private duration(): string {
    return getStreamDurationText(this.item);
  }

  /** A live badge is drawn on live_duration_background_color, not the black one. */
  private isLiveBadge(): boolean {
    return isLiveDurationBadge(this.item);
  }

  /** getStreamInfoDetailLine(item) - inherited by the card and grid holders. */
  private additionalDetails(): string {
    return getStreamInfoDetailLine(this.item);
  }

  /** itemProgressView.setMax((int) item.getDuration()). */
  private durationTotal(): number {
    return this.item === null || this.item.getDuration() <= 0 ? 1 : this.item.getDuration();
  }

  build() {
    Row() {
      if (shouldLoadImages()) {
        // list_stream_item.xml: itemDurationView is layout_gravity="bottom|end" over
        // the thumbnail, with the duration paddings and a 2dp inset. StreamItem.ets
        // already places it that way; these holders centred it instead.
        Stack({ alignContent: Alignment.BottomEnd }) {
          // An empty src draws nothing; CoilHelper renders the placeholder for a missing
          // thumbnail, so it is the src there and the `alt` for the load in flight.
          Image(this.thumbnailUrl() === ''
            ? $r('app.media.placeholder_thumbnail_video') : this.thumbnailUrl())
            .alt($r('app.media.placeholder_thumbnail_video'))
            .id('itemThumbnailView')
            .width('100%')
            .height('100%')
            // A short's still is PORTRAIT. The reference does NOT narrow the row's thumbnail
            // column for it: it keeps the same 124x70 box and letterboxes the portrait still
            // inside it, centred, so the text column stays where every other row in the app
            // puts it. Contain reproduces that. Cover would crop the short to 16:9, which is
            // the defect this card reported.
            .objectFit(this.isShortForm() ? ImageFit.Contain : ImageFit.Cover)
          // setVisibility(GONE) when there is neither a duration nor a live badge.
          if (this.duration().length > 0) {
            Text(this.duration())
              .id('itemDurationView')
              .fontSize($r('app.float.video_item_search_duration_text_size'))
              .fontColor($r('app.color.duration_text_color'))
              .backgroundColor(this.isLiveBadge()
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
          if (this.progressSeconds > 0) {
            Progress({
              value: this.progressSeconds,
              total: this.durationTotal(),
              type: ProgressType.Linear
            })
              .id('itemProgressView')
              .width('100%')
              .height(4)
              .color($r('app.color.primary'))
          }
        }
        // One box for every row, short or not - the objectFit above is what fits a short into it.
        .width($r('app.float.video_item_search_thumbnail_image_width'))
        .height($r('app.float.video_item_search_thumbnail_image_height'))
        .margin({ right: $r('app.float.video_item_search_image_right_margin') })
      }
      Column() {
        Text(this.title())
          .id('itemVideoTitleView')
          .fontSize($r('app.float.video_item_search_title_text_size'))
          .fontColor(C_ON_SURFACE)
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
          .textAlign(TextAlign.Start)
        Text(this.uploader())
          .id('itemUploaderView')
          .fontSize($r('app.float.video_item_search_uploader_text_size'))
          .fontColor(C_SECONDARY)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
          .textAlign(TextAlign.Start)
        Text(this.additionalDetails())
          .id('itemAdditionalDetails')
          .fontSize($r('app.float.video_item_search_upload_date_text_size'))
          .fontColor(C_SECONDARY)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
          .textAlign(TextAlign.Start)
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      // list_stream_item.xml constrains the three texts as a vertical CHAIN - the title to the
      // parent's top, the details line to its bottom, the uploader between them - and a chain
      // spreads by default. So on the reference the three lines are distributed across the
      // thumbnail's height, with the last one ending level with its bottom edge. The port stacked
      // them tight under one another and left the rest of the row empty: measured on the same
      // kiosk row, texts 484-634 against a thumbnail running 484-712, ~78 px of air.
      //
      // A minimum height of the thumbnail plus SpaceBetween IS that chain: shorter text spans the
      // thumbnail and spreads, and a two-line title leaves no slack to spread, which is what the
      // chain does too.
      .constraintSize({ minHeight: $r('app.float.video_item_search_thumbnail_image_height') })
      // ...and the chain is inset from both ends rather than touching them: the reference's first
      // line starts below the thumbnail's top edge and its last ends above the bottom one: 10% of
      // the thumbnail height at each end - 7vp of 70vp.
      .padding({ top: ROW_TEXT_INSET_TOP, bottom: ROW_TEXT_INSET_BOTTOM })
      .justifyContent(FlexAlign.SpaceBetween)
    }
    .width('100%')
    .padding($r('app.float.video_item_search_padding'))
    // StreamItem.ets:252, the S5 reference for this same list_stream_item.xml, aligns the row to
    // the TOP. Centred, a row whose title wraps to two lines pushed its thumbnail down and broke
    // the unbroken strip of thumbnails the list draws down the left edge.
    .alignItems(VerticalAlign.Top)
  }
}
