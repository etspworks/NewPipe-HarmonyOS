/*
 * Port of app/src/main/java/org/schabi/newpipe/local/feed/item/StreamItem.kt - one stream row
 * of the feed / history / bookmark lists.
 *
 * The source class is a groupie `BindableItem<ListStreamItemBinding>`: half data, half view
 * binding. groupie maps to `LazyForEach` + an IDataSource (dependency-decisions.json), so the
 * binding half - getLayout(), initializeViewBinding(), bind(), getSpanSize(), execBindEnd - is
 * the ArkUI row component's job in Phase 3. What lives here is the data half plus the two
 * derived strings the row shows, which are real logic and are ported verbatim:
 * getStreamInfoDetailLine() and getFormattedRelativeUploadDate().
 */

import { StreamWithState } from '../db/view/StreamWithState';
import { StreamEntity } from '../db/entity/StreamEntity';
import { StreamType } from '../enums/StreamType';
import { Localization } from '../../common/i18n/Localization';

/** StreamItem.ItemVersion, verbatim - which row layout the list uses. */
export enum ItemVersion {
  NORMAL,
  MINI,
  GRID,
  CARD
}

/** StreamItem.UPDATE_RELATIVE_TIME, the groupie payload that refreshes only the time-ago line. */
export const UPDATE_RELATIVE_TIME: number = 1;

/** Port of StreamTypeUtil.isLiveStream(StreamType). */
export function isLiveStream(streamType: StreamType): boolean {
  return streamType === StreamType.LIVE_STREAM
    || streamType === StreamType.AUDIO_LIVE_STREAM
    || streamType === StreamType.POST_LIVE_STREAM
    || streamType === StreamType.POST_LIVE_AUDIO_STREAM;
}

/** Port of StreamTypeUtil.isAudio(StreamType): the service serves no video for this item. */
export function isAudioStream(streamType: StreamType): boolean {
  return streamType === StreamType.AUDIO_STREAM
    || streamType === StreamType.AUDIO_LIVE_STREAM
    || streamType === StreamType.POST_LIVE_AUDIO_STREAM;
}

export class StreamItem {
  streamWithState: StreamWithState;
  itemVersion: ItemVersion;

  private readonly stream: StreamEntity;
  private readonly stateProgressTime: number | null;

  constructor(streamWithState: StreamWithState, itemVersion: ItemVersion = ItemVersion.NORMAL) {
    this.streamWithState = streamWithState;
    this.itemVersion = itemVersion;
    this.stream = streamWithState.stream;
    this.stateProgressTime = streamWithState.stateProgressMillis;
  }

  /** Port of getId(). */
  getId(): number {
    return this.stream.uid;
  }

  getStream(): StreamEntity {
    return this.stream;
  }

  /** Port of the `stateProgressTime` field, in milliseconds, or null when never watched. */
  getStateProgressMillis(): number | null {
    return this.stateProgressTime;
  }

  /**
   * The progress bar the row shows: seconds watched out of the stream duration, or null when
   * there is no progress to show. Port of the bind() branch that sets itemProgressView.
   */
  getProgressSeconds(): number | null {
    const progress: number | null = this.stateProgressTime;
    if (progress === null || this.stream.duration <= 0) {
      return null;
    }
    return Math.trunc(progress / 1000);
  }

  /** Port of isLongClickable(): only real playable stream types support the long-press menu. */
  isLongClickable(): boolean {
    const type: StreamType = this.stream.streamType;
    return type === StreamType.AUDIO_STREAM
      || type === StreamType.VIDEO_STREAM
      || type === StreamType.LIVE_STREAM
      || type === StreamType.AUDIO_LIVE_STREAM
      || type === StreamType.POST_LIVE_STREAM
      || type === StreamType.POST_LIVE_AUDIO_STREAM;
  }

  /**
   * Port of getStreamInfoDetailLine(context): "<views> • <time ago>", either half omitted when
   * it is unknown, with the live variants of the count.
   */
  getStreamInfoDetailLine(): string {
    let viewsAndDate: string = '';
    const viewCount: number | null = this.stream.viewCount;
    if (viewCount !== null && viewCount >= 0) {
      if (this.stream.streamType === StreamType.AUDIO_LIVE_STREAM) {
        viewsAndDate = Localization.listeningCount(viewCount);
      } else if (this.stream.streamType === StreamType.LIVE_STREAM) {
        viewsAndDate = Localization.shortWatchingCount(viewCount);
      } else {
        viewsAndDate = Localization.shortViewCount(viewCount);
      }
    }

    const uploadDate: string | null = this.getFormattedRelativeUploadDate();
    if (uploadDate !== null && uploadDate.length > 0) {
      return viewsAndDate.length === 0
        ? uploadDate
        : Localization.concatenateStrings([viewsAndDate, uploadDate]);
    }
    return viewsAndDate;
  }

  /**
   * Port of getFormattedRelativeUploadDate(context): the parsed date rendered relatively, else
   * the service's own textual date. The DEBUG "show original time ago" append is inside
   * Localization.relativeTimeOrTextual here, which is where the same preference is read.
   */
  getFormattedRelativeUploadDate(): string | null {
    const uploadDate: number | null = this.stream.uploadDate;
    if (uploadDate === null) {
      return this.stream.textualUploadDate;
    }
    return Localization.relativeTimeOrTextual(uploadDate, this.stream.textualUploadDate);
  }
}
