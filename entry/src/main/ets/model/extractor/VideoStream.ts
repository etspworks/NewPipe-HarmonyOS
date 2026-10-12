/*
 * Port of org.schabi.newpipe.extractor.stream.VideoStream and its Builder
 * (NewPipeExtractor v0.26.5).
 */

import { DeliveryMethod } from '../enums/DeliveryMethod';
import { MediaFormat } from '../enums/MediaFormat';
import { ItagItem } from '../../common/extractor/core/ItagItem';
import { ITAG_NOT_AVAILABLE_OR_NOT_APPLICABLE, Stream } from './Stream';

export const RESOLUTION_UNKNOWN: string = '';

export class VideoStream extends Stream {
  readonly resolution: string;
  readonly isVideoOnly: boolean;
  itag: number = ITAG_NOT_AVAILABLE_OR_NOT_APPLICABLE;
  bitrate: number = 0;
  initStart: number = 0;
  initEnd: number = 0;
  indexStart: number = 0;
  indexEnd: number = 0;
  width: number = 0;
  height: number = 0;
  fps: number = 0;
  quality: string = '';
  codec: string = '';
  itagItem: ItagItem | null = null;

  constructor(id: string, content: string, isUrl: boolean, format: MediaFormat | null,
    deliveryMethod: DeliveryMethod, resolution: string, isVideoOnly: boolean,
    manifestUrl: string | null, itagItem: ItagItem | null) {
    super(id, content, isUrl, format, deliveryMethod, manifestUrl);
    if (itagItem !== null) {
      this.itagItem = itagItem;
      this.itag = itagItem.id;
      this.bitrate = itagItem.getBitrate();
      this.initStart = itagItem.getInitStart();
      this.initEnd = itagItem.getInitEnd();
      this.indexStart = itagItem.getIndexStart();
      this.indexEnd = itagItem.getIndexEnd();
      this.codec = itagItem.getCodec();
      this.height = itagItem.getHeight();
      this.width = itagItem.getWidth();
      this.quality = itagItem.getQuality();
      this.fps = itagItem.getFps();
    }
    this.resolution = resolution;
    this.isVideoOnly = isVideoOnly;
  }

  equalStats(cmp: Stream | null): boolean {
    if (!super.equalStats(cmp) || !(cmp instanceof VideoStream)) {
      return false;
    }
    const other: VideoStream = cmp as VideoStream;
    return this.resolution === other.resolution && this.isVideoOnly === other.isVideoOnly;
  }

  getResolution(): string {
    return this.resolution;
  }

  getIsVideoOnly(): boolean {
    return this.isVideoOnly;
  }

  getItag(): number {
    return this.itag;
  }

  getBitrate(): number {
    return this.bitrate;
  }

  getInitStart(): number {
    return this.initStart;
  }

  getInitEnd(): number {
    return this.initEnd;
  }

  getIndexStart(): number {
    return this.indexStart;
  }

  getIndexEnd(): number {
    return this.indexEnd;
  }

  getWidth(): number {
    return this.width;
  }

  getHeight(): number {
    return this.height;
  }

  getFps(): number {
    return this.fps;
  }

  getQuality(): string {
    return this.quality;
  }

  getCodec(): string {
    return this.codec;
  }

  getItagItem(): ItagItem | null {
    return this.itagItem;
  }
}

export class VideoStreamBuilder {
  id: string | null = null;
  content: string | null = null;
  isUrl: boolean = false;
  deliveryMethod: DeliveryMethod = DeliveryMethod.PROGRESSIVE_HTTP;
  mediaFormat: MediaFormat | null = null;
  manifestUrl: string | null = null;
  isVideoOnly: boolean | null = null;
  resolution: string | null = null;
  itagItem: ItagItem | null = null;

  setId(id: string): VideoStreamBuilder {
    this.id = id;
    return this;
  }

  setContent(content: string, isUrl: boolean): VideoStreamBuilder {
    this.content = content;
    this.isUrl = isUrl;
    return this;
  }

  setMediaFormat(mediaFormat: MediaFormat | null): VideoStreamBuilder {
    this.mediaFormat = mediaFormat;
    return this;
  }

  setDeliveryMethod(deliveryMethod: DeliveryMethod): VideoStreamBuilder {
    this.deliveryMethod = deliveryMethod;
    return this;
  }

  setManifestUrl(manifestUrl: string | null): VideoStreamBuilder {
    this.manifestUrl = manifestUrl;
    return this;
  }

  setIsVideoOnly(isVideoOnly: boolean): VideoStreamBuilder {
    this.isVideoOnly = isVideoOnly;
    return this;
  }

  setResolution(resolution: string): VideoStreamBuilder {
    this.resolution = resolution;
    return this;
  }

  setItagItem(itagItem: ItagItem | null): VideoStreamBuilder {
    this.itagItem = itagItem;
    return this;
  }

  build(): VideoStream {
    if (this.id === null) {
      throw new Error('The identifier of the video stream has been not set or is null. If you '
        + 'are not able to get an identifier, use the static constant ID_UNKNOWN of the Stream '
        + 'class.');
    }
    if (this.content === null) {
      throw new Error('The content of the video stream has been not set or is null. Please '
        + 'specify a non-null one with setContent.');
    }
    if (this.isVideoOnly === null) {
      throw new Error('The video stream has been not set as a video-only stream or as a video '
        + 'stream with embedded audio. Please specify this information with setIsVideoOnly.');
    }
    if (this.resolution === null) {
      throw new Error('The resolution of the video stream has been not set. Please specify it '
        + 'with setResolution (use an empty string if you are not able to get it).');
    }
    return new VideoStream(this.id, this.content, this.isUrl, this.mediaFormat,
      this.deliveryMethod, this.resolution, this.isVideoOnly, this.manifestUrl, this.itagItem);
  }
}
