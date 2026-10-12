/*
 * S3 - the VIEW half of org.schabi.newpipe.player.seekbarpreview.SeekbarPreviewThumbnailHolder
 * (player.xml @+id/seekbarPreviewContainer: @+id/currentDisplaySeek over
 * @+id/currentSeekbarPreviewThumbnail).
 *
 * The holder's DATA half - picking the frameset for the quality setting, fetching the storyboard
 * sheet and cropping one frame out of it - already lives in the Phase-2 data layer as
 * common/player/SeekbarPreview.ts. This struct only renders the frame that resolver hands back
 * plus the target timestamp, and stays hidden while nothing is being scrubbed.
 */
import { image } from '@kit.ImageKit';

/** player.xml's currentSeekbarPreviewThumbnail - a 16:9 frame off the storyboard sheet. */
const PREVIEW_WIDTH_VP: number = 160;
const PREVIEW_HEIGHT_VP: number = 90;

/**
 * The frame travels by REFERENCE inside this holder, not as a @Prop.
 *
 * @Prop deep-copies whatever it is given, and a deep copy of a NAPI-backed PixelMap is a plain
 * object with no native handle behind it: the Image kept its measured 160x90 box - it was there
 * in the layout dump, the right size, in the right place - and drew nothing at all, so scrubbing
 * showed the timestamp over the live video frame and no preview. @Observed + @ObjectLink hands
 * over the same object instead of a copy.
 */
@Observed
export class SeekbarPreviewFrame {
  /** SeekbarPreview.previewAt(positionMs); null = this stream exposes no preview frames. */
  frame: image.PixelMap | null = null;
}

@Component
export struct SeekbarPreviewThumbnailHolder {
  /** bottomSeekbarPreviewLayout is only VISIBLE while the seek bar is being dragged. */
  @Prop showing: boolean = false;
  /** currentDisplaySeek: the formatted position the drag would land on. */
  @Prop seekDisplay: string = '';
  /** currentSeekbarPreviewThumbnail - see SeekbarPreviewFrame on why this is not a @Prop. */
  @ObjectLink previewFrame: SeekbarPreviewFrame;

  build() {
    Column() {
      if (this.showing) {
        // currentDisplaySeek is white on the darkened surface; with no colour it drew in the
        // default near-black over the video and the readout could not be made out at all.
        Text(this.seekDisplay)
          .id('currentDisplaySeek')
          .fontSize(14)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.on_primary'))
          .backgroundColor('#64000000')
          .padding({ left: 6, right: 6, top: 2, bottom: 2 })

        if (this.previewFrame.frame !== null) {
          Image(this.previewFrame.frame)
            .id('currentSeekbarPreviewThumbnail')
            // currentSeekbarPreviewThumbnail has a size in player.xml; with none the frame
            // measured to nothing and only the timestamp was ever on screen.
            .width(PREVIEW_WIDTH_VP)
            .height(PREVIEW_HEIGHT_VP)
            .objectFit(ImageFit.Contain)
        }
      }
    }
    .id('seekbarPreviewContainer')
    .alignItems(HorizontalAlign.Center)
    .hitTestBehavior(HitTestMode.Transparent)
  }
}
