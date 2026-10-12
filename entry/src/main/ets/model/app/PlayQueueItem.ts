/*
 * Port of app/src/main/java/org/schabi/newpipe/player/playqueue/PlayQueueItem.java - one entry
 * of the play queue.
 *
 * `getStream()` returned `Single<StreamInfo>` built on ExtractorHelper. Per
 * phase2-logic-contract.md section 1 a one-shot load is a Promise; the extractor entry point
 * itself is generated in the extractor wave, so it is injected once at startup
 * (setStreamInfoLoader) rather than imported from a module this file would have to guess the
 * location of. `doOnError { error = it }` is preserved: a failed load records the error on the
 * item, which is what the queue UI reads to grey the row out.
 */

import { Image } from '../extractor/Image';
import { StreamType } from '../enums/StreamType';
import { StreamInfo } from '../extractor/StreamInfo';
import { StreamInfoItem } from '../extractor/StreamInfoItem';

/** PlayQueueItem.RECOVERY_UNSET (Long.MIN_VALUE), verbatim. */
export const RECOVERY_UNSET: number = Number.MIN_SAFE_INTEGER;
/** PlayQueueItem.EMPTY_STRING, verbatim. */
const EMPTY_STRING: string = '';

/** The signature of ExtractorHelper.getStreamInfo(serviceId, url, forceLoad). */
export type StreamInfoLoader =
  (serviceId: number, url: string, forceLoad: boolean) => Promise<StreamInfo>;

let streamInfoLoader: StreamInfoLoader | null = null;

/** Called once at startup by ServiceLocator, with the extractor wave's ExtractorHelper. */
export function setStreamInfoLoader(loader: StreamInfoLoader): void {
  streamInfoLoader = loader;
}

/**
 * TC-PLAYER-399/400: a stable identity per item, for the queue list's drag-sort key. The url is
 * not one - a queue may legitimately hold the same stream twice - and the INDEX is the thing the
 * key must not depend on, since that is what a reorder changes.
 */
let nextPlayQueueItemUid: number = 0;

export class PlayQueueItem {
  /** Assigned once, never reused, and stable for the life of this item. See nextPlayQueueItemUid. */
  readonly uid: number = nextPlayQueueItemUid++;
  readonly title: string;
  readonly url: string;
  readonly serviceId: number;
  readonly duration: number;
  readonly thumbnails: Image[];
  readonly uploader: string;
  readonly uploaderUrl: string | null;
  readonly streamType: StreamType;

  private autoQueued: boolean = false;
  private recoveryPosition: number = RECOVERY_UNSET;
  private error: Error | null = null;

  /** Port of the private all-args constructor, including its null-to-empty-string coalescing. */
  constructor(name: string | null, url: string | null, serviceId: number, duration: number,
    thumbnails: Image[], uploader: string | null, uploaderUrl: string | null,
    streamType: StreamType) {
    this.title = name !== null ? name : EMPTY_STRING;
    this.url = url !== null ? url : EMPTY_STRING;
    this.serviceId = serviceId;
    this.duration = duration;
    this.thumbnails = thumbnails;
    this.uploader = uploader !== null ? uploader : EMPTY_STRING;
    this.uploaderUrl = uploaderUrl;
    this.streamType = streamType;
    this.recoveryPosition = RECOVERY_UNSET;
  }

  /** Port of PlayQueueItem(StreamInfo), start position included. */
  static fromStreamInfo(info: StreamInfo): PlayQueueItem {
    const item: PlayQueueItem = new PlayQueueItem(info.getName(), info.getUrl(), info.getServiceId(),
      info.getDuration(), info.getThumbnails(), info.getUploaderName(), info.getUploaderUrl(),
      info.getStreamType());
    if (info.getStartPosition() > 0) {
      item.setRecoveryPosition(info.getStartPosition() * 1000);
    }
    return item;
  }

  /** Port of PlayQueueItem(StreamInfoItem). */
  static fromStreamInfoItem(item: StreamInfoItem): PlayQueueItem {
    return new PlayQueueItem(item.getName(), item.getUrl(), item.getServiceId(),
      item.getDuration(), item.getThumbnails(), item.getUploaderName(), item.getUploaderUrl(),
      item.getStreamType());
  }

  /**
   * Port of isSameItem(): whether these two items should be treated as the same stream, so the
   * player can keep running when e.g. jumping between timestamps.
   */
  isSameItem(other: PlayQueueItem | null): boolean {
    if (other === null) {
      return false;
    }
    // the same service and URL uniquely determine that the same stream can keep running
    return this.serviceId === other.serviceId && this.url === other.url;
  }

  getTitle(): string {
    return this.title;
  }

  getUrl(): string {
    return this.url;
  }

  getServiceId(): number {
    return this.serviceId;
  }

  getDuration(): number {
    return this.duration;
  }

  getThumbnails(): Image[] {
    return this.thumbnails;
  }

  getUploader(): string {
    return this.uploader;
  }

  getUploaderUrl(): string | null {
    return this.uploaderUrl;
  }

  getStreamType(): StreamType {
    return this.streamType;
  }

  getRecoveryPosition(): number {
    return this.recoveryPosition;
  }

  /** Package-private in the source: only PlayQueue.setRecovery() calls it. */
  setRecoveryPosition(recoveryPosition: number): void {
    this.recoveryPosition = recoveryPosition;
  }

  getError(): Error | null {
    return this.error;
  }

  /** Port of getStream(): loads this item's StreamInfo, recording a failure on the item. */
  async getStream(): Promise<StreamInfo> {
    const loader: StreamInfoLoader | null = streamInfoLoader;
    if (loader === null) {
      const err: Error = new Error('PlayQueueItem.getStream() before setStreamInfoLoader()');
      this.error = err;
      throw err;
    }
    try {
      return await loader(this.serviceId, this.url, false);
    } catch (e) {
      this.error = e as Error;
      throw e;
    }
  }

  isAutoQueued(): boolean {
    return this.autoQueued;
  }

  setAutoQueued(autoQueued: boolean): void {
    this.autoQueued = autoQueued;
  }
}
