/*
 * Port of org.schabi.newpipe.extractor.stream.Stream (NewPipeExtractor v0.26.5).
 *
 * Fields are public camelCase: the player lane binds `content`, `isUrl` and `deliveryMethod`
 * directly. The source's getters are kept beside them.
 */

import { MediaFormat } from '../enums/MediaFormat';
import { DeliveryMethod } from '../enums/DeliveryMethod';
import { ItagItem } from '../../common/extractor/core/ItagItem';

export const FORMAT_ID_UNKNOWN: number = -1;
export const ID_UNKNOWN: string = ' ';
export const ITAG_NOT_AVAILABLE_OR_NOT_APPLICABLE: number = -1;

export abstract class Stream {
  readonly id: string;
  readonly mediaFormat: MediaFormat | null;
  readonly content: string;
  readonly isUrl: boolean;
  readonly deliveryMethod: DeliveryMethod;
  readonly manifestUrl: string | null;

  constructor(id: string, content: string, isUrl: boolean, format: MediaFormat | null,
    deliveryMethod: DeliveryMethod, manifestUrl: string | null) {
    this.id = id;
    this.content = content;
    this.isUrl = isUrl;
    this.mediaFormat = format;
    this.deliveryMethod = deliveryMethod;
    this.manifestUrl = manifestUrl;
  }

  /** Whether a stream with the same stats is already in the list. */
  static containSimilarStream(stream: Stream, streamList: Stream[] | null): boolean {
    if (streamList === null || streamList.length === 0) {
      return false;
    }
    for (const cmpStream of streamList) {
      if (stream.equalStats(cmpStream)) {
        return true;
      }
    }
    return false;
  }

  equalStats(other: Stream | null): boolean {
    return other !== null && this.mediaFormat !== null && other.mediaFormat !== null
      && this.mediaFormat.id === other.mediaFormat.id
      && this.deliveryMethod === other.deliveryMethod
      && this.isUrl === other.isUrl;
  }

  getId(): string {
    return this.id;
  }

  /** Deprecated in the source: null unless the content IS a url. */
  getUrl(): string | null {
    return this.isUrl ? this.content : null;
  }

  getContent(): string {
    return this.content;
  }

  getIsUrl(): boolean {
    return this.isUrl;
  }

  getFormat(): MediaFormat | null {
    return this.mediaFormat;
  }

  getFormatId(): number {
    return this.mediaFormat !== null ? this.mediaFormat.id : FORMAT_ID_UNKNOWN;
  }

  getDeliveryMethod(): DeliveryMethod {
    return this.deliveryMethod;
  }

  getManifestUrl(): string | null {
    return this.manifestUrl;
  }

  abstract getItagItem(): ItagItem | null;
}
