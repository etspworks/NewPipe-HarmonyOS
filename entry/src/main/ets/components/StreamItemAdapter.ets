/*
 * S3 — port of org.schabi.newpipe.util.StreamItemAdapter (a BaseAdapter over
 * stream_quality_item.xml), the rows behind the download dialog's quality_spinner and
 * audio_stream_spinner.
 *
 * The Java adapter is generic over <T extends Stream, U extends Stream> and derives each row's
 * four fields in getView() (StreamItemAdapter.java:124-200):
 *   wo_sound_icon      GONE by default; VISIBLE for a video-only stream with NO secondary audio;
 *                      INVISIBLE (a space reserved, so the labels stay aligned) when the stream
 *                      HAS a secondary stream in the dropdown, and for the audio/subtitle kinds
 *                      when at least one sibling row needs the icon
 *   stream_format_name a SubtitlesStream's language tag; otherwise the MediaFormat name, with
 *                      "opus" spelled out and unknown_format when there is none
 *   stream_quality     the quality string (resolution, bitrate or subtitle name)
 *   stream_size        the fetched byte size; GONE until a size is known
 * ArkTS has no generics over ArkUI structs, so the DERIVATION stays with the caller (the download
 * dialog knows which stream kind it is showing) and this struct renders the derived row - the same
 * split AudioTrackAdapter already uses for the track rows.
 *
 * Rule 12's list-row exception: N identical rows, so ONE shared id resolved by index.
 *
 * S5 owns the row's 48dp height, the two-line typography and the icon tint.
 */
import { hilog } from '@kit.PerformanceAnalysisKit';

/** wo_sound_icon's three states, verbatim from getView()'s woSoundIconVisibility. */
export enum WoSoundIconState {
  GONE,
  INVISIBLE,
  VISIBLE
}

/** One getView() row, with every field already derived by the owning screen. */
export class StreamItemEntry {
  /** stream_format_name. */
  readonly formatName: string;
  /** stream_quality. */
  readonly quality: string;
  /** stream_size; empty means the size is not known yet and the view is GONE. */
  readonly size: string;
  /** woSoundIconVisibility. */
  readonly woSoundIcon: WoSoundIconState;

  constructor(formatName: string, quality: string, size: string,
    woSoundIcon: WoSoundIconState = WoSoundIconState.GONE) {
    this.formatName = formatName;
    this.quality = quality;
    this.size = size;
    this.woSoundIcon = woSoundIcon;
  }
}

@Component
export struct StreamItemAdapter {
  /** streamsWrapper.getStreamsList(), already mapped to rows. */
  entries: StreamItemEntry[] = [];
  /** The spinner's current selection. */
  @Prop selectedIndex: number = 0;
  /** onItemSelected(position). */
  onItemSelected: (index: number) => void = (index: number): void => {
    hilog.debug(0x0000, 'NewPipe', 'StreamItemAdapter: select %{public}d unbound', index);
  };

  build() {
    Column() {
      ForEach(this.entries, (entry: StreamItemEntry, index: number) => {
        Row() {
          // GONE removes the icon; INVISIBLE keeps its 20dp box so the labels stay aligned.
          if (entry.woSoundIcon !== WoSoundIconState.GONE) {
            Image($r('app.media.ic_volume_off'))
              .id('wo_sound_icon')
              .width(20)
              .height(48)
              .margin({ left: 6 })
              .fillColor($r('app.color.on_surface_variant'))
              .objectFit(ImageFit.Contain)
              .visibility(entry.woSoundIcon === WoSoundIconState.VISIBLE
                ? Visibility.Visible : Visibility.Hidden)
          }

          Column() {
            // TextAppearance.AppCompat.Caption at 12sp in a 22dp band; base.png samples it at
            // #6D6D6D = the theme's secondary text over the #EEEEEE dialog surface.
            Text(entry.formatName)
              .id('stream_format_name')
              .height(22)
              .maxLines(1)
              .fontSize(12)
              .fontColor($r('app.color.on_surface_variant'))
              .textAlign(TextAlign.Start)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
            // TextAppearance.AppCompat.Body1 at 14sp in a 26dp band, primary text (#1F1F1F).
            Text(entry.quality)
              .id('stream_quality')
              .height(26)
              .maxLines(1)
              .fontSize(14)
              .fontColor($r('app.color.on_surface'))
              .textAlign(TextAlign.Start)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }
          .layoutWeight(1)
          .padding({ left: 12, right: 18 })
          .alignItems(HorizontalAlign.Start)

          // sizeView is GONE until the size fetch lands.
          if (entry.size.length > 0) {
            Text(entry.size)
              .id('stream_size')
              .maxLines(1)
              .height(48)
              .padding({ left: 8, right: 8 })
              .fontSize(12)
              .fontColor($r('app.color.on_surface_variant'))
              .textAlign(TextAlign.End)
          }
        }
        .id('stream_quality_itemroot')
        .width('100%')
        // stream_quality_item.xml: android:layout_height="48dp".
        .height(48)
        .alignItems(VerticalAlign.Center)
        .onClick(() => {
          this.onItemSelected(index);
        })
      }, (entry: StreamItemEntry, index: number) => `${index}-${entry.quality}`)
    }
    .width('100%')
  }
}
