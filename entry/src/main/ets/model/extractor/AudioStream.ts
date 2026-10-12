/*
 * Port of org.schabi.newpipe.extractor.stream.AudioStream and its Builder
 * (NewPipeExtractor v0.26.5).
 *
 * The Builder is kept: every service constructs audio streams through it, and it is where the
 * itag's fields are copied onto the stream. Fields are public camelCase for the player lane.
 */

import { DeliveryMethod } from '../enums/DeliveryMethod';
import { MediaFormat } from '../enums/MediaFormat';
import { ItagItem } from '../../common/extractor/core/ItagItem';
import { AudioTrackType } from './AudioTrackType';
import { ITAG_NOT_AVAILABLE_OR_NOT_APPLICABLE, Stream } from './Stream';

export const UNKNOWN_BITRATE: number = -1;

export class AudioStream extends Stream {
  readonly averageBitrate: number;
  itag: number = ITAG_NOT_AVAILABLE_OR_NOT_APPLICABLE;
  bitrate: number = 0;
  initStart: number = 0;
  initEnd: number = 0;
  indexStart: number = 0;
  indexEnd: number = 0;
  quality: string = '';
  codec: string = '';
  readonly audioTrackId: string | null;
  readonly audioTrackName: string | null;
  /** A BCP-47 language tag; java.util.Locale has no ArkTS equivalent. */
  readonly audioLocale: string | null;
  readonly audioTrackType: AudioTrackType | null;
  itagItem: ItagItem | null = null;

  constructor(builder: AudioStreamBuilder) {
    super(builder.id as string, builder.content as string, builder.isUrl, builder.mediaFormat,
      builder.deliveryMethod, builder.manifestUrl);
    const itag: ItagItem | null = builder.itagItem;
    if (itag !== null) {
      this.itagItem = itag;
      this.itag = itag.id;
      this.quality = itag.getQuality();
      this.bitrate = itag.getBitrate();
      this.initStart = itag.getInitStart();
      this.initEnd = itag.getInitEnd();
      this.indexStart = itag.getIndexStart();
      this.indexEnd = itag.getIndexEnd();
      this.codec = itag.getCodec();
    }
    this.averageBitrate = builder.averageBitrate;
    this.audioTrackId = builder.audioTrackId;
    this.audioTrackName = builder.audioTrackName;
    this.audioLocale = builder.audioLocale;
    this.audioTrackType = builder.audioTrackType;
  }

  equalStats(cmp: Stream | null): boolean {
    if (!super.equalStats(cmp) || !(cmp instanceof AudioStream)) {
      return false;
    }
    const other: AudioStream = cmp as AudioStream;
    return this.averageBitrate === other.averageBitrate
      && this.audioTrackId === other.audioTrackId
      && this.audioTrackType === other.audioTrackType
      && this.audioLocale === other.audioLocale;
  }

  getAverageBitrate(): number {
    return this.averageBitrate;
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

  getQuality(): string {
    return this.quality;
  }

  getCodec(): string {
    return this.codec;
  }

  getAudioTrackId(): string | null {
    return this.audioTrackId;
  }

  getAudioTrackName(): string | null {
    return this.audioTrackName;
  }

  getAudioLocale(): string | null {
    return this.audioLocale;
  }

  getAudioTrackType(): AudioTrackType | null {
    return this.audioTrackType;
  }

  getItagItem(): ItagItem | null {
    return this.itagItem;
  }
}

export class AudioStreamBuilder {
  id: string | null = null;
  content: string | null = null;
  isUrl: boolean = false;
  deliveryMethod: DeliveryMethod = DeliveryMethod.PROGRESSIVE_HTTP;
  mediaFormat: MediaFormat | null = null;
  manifestUrl: string | null = null;
  averageBitrate: number = UNKNOWN_BITRATE;
  audioTrackId: string | null = null;
  audioTrackName: string | null = null;
  audioLocale: string | null = null;
  audioTrackType: AudioTrackType | null = null;
  itagItem: ItagItem | null = null;

  setId(id: string): AudioStreamBuilder {
    this.id = id;
    return this;
  }

  setContent(content: string, isUrl: boolean): AudioStreamBuilder {
    this.content = content;
    this.isUrl = isUrl;
    return this;
  }

  setMediaFormat(mediaFormat: MediaFormat | null): AudioStreamBuilder {
    this.mediaFormat = mediaFormat;
    return this;
  }

  setDeliveryMethod(deliveryMethod: DeliveryMethod): AudioStreamBuilder {
    this.deliveryMethod = deliveryMethod;
    return this;
  }

  setManifestUrl(manifestUrl: string | null): AudioStreamBuilder {
    this.manifestUrl = manifestUrl;
    return this;
  }

  setAverageBitrate(averageBitrate: number): AudioStreamBuilder {
    this.averageBitrate = averageBitrate;
    return this;
  }

  setAudioTrackId(audioTrackId: string | null): AudioStreamBuilder {
    this.audioTrackId = audioTrackId;
    return this;
  }

  setAudioTrackName(audioTrackName: string | null): AudioStreamBuilder {
    this.audioTrackName = audioTrackName;
    return this;
  }

  setAudioTrackType(audioTrackType: AudioTrackType | null): AudioStreamBuilder {
    this.audioTrackType = audioTrackType;
    return this;
  }

  /** A BCP-47 language tag, standing in for the source's java.util.Locale. */
  setAudioLocale(audioLocale: string | null): AudioStreamBuilder {
    this.audioLocale = audioLocale;
    return this;
  }

  setItagItem(itagItem: ItagItem | null): AudioStreamBuilder {
    this.itagItem = itagItem;
    return this;
  }

  build(): AudioStream {
    this.validateBuild();
    return new AudioStream(this);
  }

  validateBuild(): void {
    if (this.id === null) {
      throw new Error('The identifier of the audio stream has been not set or is null. If you '
        + 'are not able to get an identifier, use the static constant ID_UNKNOWN of the Stream '
        + 'class.');
    }
    if (this.content === null) {
      throw new Error('The content of the audio stream has been not set or is null. Please '
        + 'specify a non-null one with setContent.');
    }
  }
}
