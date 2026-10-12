/*
 * Port of org.schabi.newpipe.extractor.services.youtube.ItagItem (NewPipeExtractor v0.26.5).
 *
 * NOMINAL TYPING: this class `implements CoreItagItem` from
 * common/extractor/core/ItagItem.ts (wave B). ArkTS is nominally typed, so AudioStream /
 * VideoStream / SubtitlesStream reject a structurally identical class that does not declare it.
 *
 * ArkTS has no overloading, so the three Java constructors become static factories
 * (ofVideo / ofAudio / copyOf) over one field-wise constructor, and java.util.Locale becomes a
 * BCP-47 string (phase2-logic-contract.md §9).
 *
 * NOT declared in the plan's models[] — a recorded plan defect; ported here, in the YouTube lane.
 */

import { ItagItem as CoreItagItem } from '../../core/ItagItem';
import { ParsingException } from '../../exceptions/Exceptions';
import { MediaFormat } from '../../../../model/enums/MediaFormat';
import { AudioTrackType } from '../../../../model/extractor/AudioTrackType';

export enum ItagType {
  AUDIO,
  VIDEO,
  VIDEO_ONLY
}

export const AVERAGE_BITRATE_UNKNOWN: number = -1;
export const SAMPLE_RATE_UNKNOWN: number = -1;
export const FPS_NOT_APPLICABLE_OR_UNKNOWN: number = -1;
export const TARGET_DURATION_SEC_UNKNOWN: number = -1;
export const AUDIO_CHANNELS_NOT_APPLICABLE_OR_UNKNOWN: number = -1;
export const CONTENT_LENGTH_UNKNOWN: number = -1;
export const APPROX_DURATION_MS_UNKNOWN: number = -1;
export const LAST_MODIFIED_UNKOWN: number = -1;

export class ItagItem implements CoreItagItem {
  private readonly mediaFormat: MediaFormat;

  readonly id: number;
  readonly itagType: ItagType;

  // Audio fields
  /** Deprecated in the source in favour of getAverageBitrate(); kept public as there. */
  avgBitrate: number = AVERAGE_BITRATE_UNKNOWN;
  private sampleRate: number = SAMPLE_RATE_UNKNOWN;
  private audioChannels: number = AUDIO_CHANNELS_NOT_APPLICABLE_OR_UNKNOWN;

  // Video fields
  /** Deprecated in the source in favour of getResolutionString(); kept public as there. */
  resolutionString: string | null = null;
  /** Deprecated in the source in favour of getFps()/setFps(); kept public as there. */
  fps: number = FPS_NOT_APPLICABLE_OR_UNKNOWN;

  // Fields the player response fills in
  private bitrate: number = 0;
  private width: number = 0;
  private height: number = 0;
  private initStart: number = 0;
  private initEnd: number = 0;
  private indexStart: number = 0;
  private indexEnd: number = 0;
  private quality: string = '';
  private codec: string = '';
  private targetDurationSec: number = TARGET_DURATION_SEC_UNKNOWN;
  private approxDurationMs: number = APPROX_DURATION_MS_UNKNOWN;
  private contentLength: number = CONTENT_LENGTH_UNKNOWN;
  private audioTrackId: string | null = null;
  private audioTrackName: string | null = null;
  private audioTrackType: AudioTrackType | null = null;
  /** A BCP-47 language tag, standing in for the source's java.util.Locale. */
  private audioLocale: string | null = null;
  private drc: boolean = false;
  private lastModified: number = LAST_MODIFIED_UNKOWN;
  private xtags: string = '';

  constructor(id: number, type: ItagType, format: MediaFormat) {
    this.id = id;
    this.itagType = type;
    this.mediaFormat = format;
  }

  /** Port of ItagItem(int, ItagType, MediaFormat, String[, int]) — fps defaults to 30. */
  static ofVideo(id: number, type: ItagType, format: MediaFormat, resolution: string,
    fps: number = 30): ItagItem {
    const item: ItagItem = new ItagItem(id, type, format);
    item.resolutionString = resolution;
    item.fps = fps;
    return item;
  }

  /** Port of ItagItem(int, ItagType, MediaFormat, int avgBitrate). */
  static ofAudio(id: number, type: ItagType, format: MediaFormat, avgBitrate: number): ItagItem {
    const item: ItagItem = new ItagItem(id, type, format);
    item.avgBitrate = avgBitrate;
    return item;
  }

  /** Port of the ItagItem(ItagItem) copy constructor. */
  static copyOf(other: ItagItem): ItagItem {
    const item: ItagItem = new ItagItem(other.id, other.itagType, other.mediaFormat);
    item.avgBitrate = other.avgBitrate;
    item.sampleRate = other.sampleRate;
    item.audioChannels = other.audioChannels;
    item.resolutionString = other.resolutionString;
    item.fps = other.fps;
    item.bitrate = other.bitrate;
    item.width = other.width;
    item.height = other.height;
    item.initStart = other.initStart;
    item.initEnd = other.initEnd;
    item.indexStart = other.indexStart;
    item.indexEnd = other.indexEnd;
    item.quality = other.quality;
    item.codec = other.codec;
    item.targetDurationSec = other.targetDurationSec;
    item.approxDurationMs = other.approxDurationMs;
    item.contentLength = other.contentLength;
    item.audioTrackId = other.audioTrackId;
    item.audioTrackName = other.audioTrackName;
    item.audioTrackType = other.audioTrackType;
    item.audioLocale = other.audioLocale;
    return item;
  }

  /**
   * The itag table, from
   * https://github.com/ytdl-org/youtube-dl/blob/e988fa4/youtube_dl/extractor/youtube.py#L1195
   *
   * Built lazily: MediaFormat's own static instances must exist before these are constructed, and
   * a module-level array would run at import time, which ArkTS resolves before MediaFormat's
   * static initialisers on a cyclic import.
   */
  private static itagList: ItagItem[] | null = null;

  private static getItagList(): ItagItem[] {
    let list: ItagItem[] | null = ItagItem.itagList;
    if (list !== null) {
      return list;
    }
    list = [
      // VIDEO     ID  Type   Format  Resolution  FPS
      ItagItem.ofVideo(17, ItagType.VIDEO, MediaFormat.v3GPP, '144p'),
      ItagItem.ofVideo(36, ItagType.VIDEO, MediaFormat.v3GPP, '240p'),

      ItagItem.ofVideo(18, ItagType.VIDEO, MediaFormat.MPEG_4, '360p'),
      ItagItem.ofVideo(34, ItagType.VIDEO, MediaFormat.MPEG_4, '360p'),
      ItagItem.ofVideo(35, ItagType.VIDEO, MediaFormat.MPEG_4, '480p'),
      ItagItem.ofVideo(59, ItagType.VIDEO, MediaFormat.MPEG_4, '480p'),
      ItagItem.ofVideo(78, ItagType.VIDEO, MediaFormat.MPEG_4, '480p'),
      ItagItem.ofVideo(22, ItagType.VIDEO, MediaFormat.MPEG_4, '720p'),
      ItagItem.ofVideo(37, ItagType.VIDEO, MediaFormat.MPEG_4, '1080p'),
      ItagItem.ofVideo(38, ItagType.VIDEO, MediaFormat.MPEG_4, '1080p'),

      ItagItem.ofVideo(43, ItagType.VIDEO, MediaFormat.WEBM, '360p'),
      ItagItem.ofVideo(44, ItagType.VIDEO, MediaFormat.WEBM, '480p'),
      ItagItem.ofVideo(45, ItagType.VIDEO, MediaFormat.WEBM, '720p'),
      ItagItem.ofVideo(46, ItagType.VIDEO, MediaFormat.WEBM, '1080p'),

      // AUDIO     ID      ItagType          Format        Bitrate
      ItagItem.ofAudio(171, ItagType.AUDIO, MediaFormat.WEBMA, 128),
      ItagItem.ofAudio(172, ItagType.AUDIO, MediaFormat.WEBMA, 256),
      ItagItem.ofAudio(599, ItagType.AUDIO, MediaFormat.M4A, 32),
      ItagItem.ofAudio(139, ItagType.AUDIO, MediaFormat.M4A, 48),
      ItagItem.ofAudio(140, ItagType.AUDIO, MediaFormat.M4A, 128),
      ItagItem.ofAudio(141, ItagType.AUDIO, MediaFormat.M4A, 256),
      ItagItem.ofAudio(600, ItagType.AUDIO, MediaFormat.WEBMA_OPUS, 35),
      ItagItem.ofAudio(249, ItagType.AUDIO, MediaFormat.WEBMA_OPUS, 50),
      ItagItem.ofAudio(250, ItagType.AUDIO, MediaFormat.WEBMA_OPUS, 70),
      ItagItem.ofAudio(251, ItagType.AUDIO, MediaFormat.WEBMA_OPUS, 160),

      // VIDEO ONLY  ID      Type     Format  Resolution  FPS
      ItagItem.ofVideo(160, ItagType.VIDEO_ONLY, MediaFormat.MPEG_4, '144p'),
      ItagItem.ofVideo(394, ItagType.VIDEO_ONLY, MediaFormat.MPEG_4, '144p'),
      ItagItem.ofVideo(133, ItagType.VIDEO_ONLY, MediaFormat.MPEG_4, '240p'),
      ItagItem.ofVideo(395, ItagType.VIDEO_ONLY, MediaFormat.MPEG_4, '240p'),
      ItagItem.ofVideo(134, ItagType.VIDEO_ONLY, MediaFormat.MPEG_4, '360p'),
      ItagItem.ofVideo(396, ItagType.VIDEO_ONLY, MediaFormat.MPEG_4, '360p'),
      ItagItem.ofVideo(135, ItagType.VIDEO_ONLY, MediaFormat.MPEG_4, '480p'),
      ItagItem.ofVideo(212, ItagType.VIDEO_ONLY, MediaFormat.MPEG_4, '480p'),
      ItagItem.ofVideo(397, ItagType.VIDEO_ONLY, MediaFormat.MPEG_4, '480p'),
      ItagItem.ofVideo(136, ItagType.VIDEO_ONLY, MediaFormat.MPEG_4, '720p'),
      ItagItem.ofVideo(398, ItagType.VIDEO_ONLY, MediaFormat.MPEG_4, '720p'),
      ItagItem.ofVideo(298, ItagType.VIDEO_ONLY, MediaFormat.MPEG_4, '720p60', 60),
      ItagItem.ofVideo(137, ItagType.VIDEO_ONLY, MediaFormat.MPEG_4, '1080p'),
      ItagItem.ofVideo(399, ItagType.VIDEO_ONLY, MediaFormat.MPEG_4, '1080p'),
      ItagItem.ofVideo(299, ItagType.VIDEO_ONLY, MediaFormat.MPEG_4, '1080p60', 60),
      ItagItem.ofVideo(400, ItagType.VIDEO_ONLY, MediaFormat.MPEG_4, '1440p'),
      ItagItem.ofVideo(266, ItagType.VIDEO_ONLY, MediaFormat.MPEG_4, '2160p'),
      ItagItem.ofVideo(401, ItagType.VIDEO_ONLY, MediaFormat.MPEG_4, '2160p'),

      ItagItem.ofVideo(278, ItagType.VIDEO_ONLY, MediaFormat.WEBM, '144p'),
      ItagItem.ofVideo(242, ItagType.VIDEO_ONLY, MediaFormat.WEBM, '240p'),
      ItagItem.ofVideo(243, ItagType.VIDEO_ONLY, MediaFormat.WEBM, '360p'),
      ItagItem.ofVideo(244, ItagType.VIDEO_ONLY, MediaFormat.WEBM, '480p'),
      ItagItem.ofVideo(245, ItagType.VIDEO_ONLY, MediaFormat.WEBM, '480p'),
      ItagItem.ofVideo(246, ItagType.VIDEO_ONLY, MediaFormat.WEBM, '480p'),
      ItagItem.ofVideo(247, ItagType.VIDEO_ONLY, MediaFormat.WEBM, '720p'),
      ItagItem.ofVideo(248, ItagType.VIDEO_ONLY, MediaFormat.WEBM, '1080p'),
      ItagItem.ofVideo(271, ItagType.VIDEO_ONLY, MediaFormat.WEBM, '1440p'),
      // #272 is either 3840x2160 (e.g. RtoitU2A-3E) or 7680x4320 (sLprVF6d7Ug)
      ItagItem.ofVideo(272, ItagType.VIDEO_ONLY, MediaFormat.WEBM, '2160p'),
      ItagItem.ofVideo(302, ItagType.VIDEO_ONLY, MediaFormat.WEBM, '720p60', 60),
      ItagItem.ofVideo(303, ItagType.VIDEO_ONLY, MediaFormat.WEBM, '1080p60', 60),
      ItagItem.ofVideo(308, ItagType.VIDEO_ONLY, MediaFormat.WEBM, '1440p60', 60),
      ItagItem.ofVideo(313, ItagType.VIDEO_ONLY, MediaFormat.WEBM, '2160p'),
      ItagItem.ofVideo(315, ItagType.VIDEO_ONLY, MediaFormat.WEBM, '2160p60', 60)
    ];
    ItagItem.itagList = list;
    return list;
  }

  static isSupported(itag: number): boolean {
    for (const item of ItagItem.getItagList()) {
      if (itag === item.id) {
        return true;
      }
    }
    return false;
  }

  static getItag(itagId: number): ItagItem {
    for (const item of ItagItem.getItagList()) {
      if (itagId === item.id) {
        return ItagItem.copyOf(item);
      }
    }
    throw new ParsingException('itag ' + itagId + ' is not supported');
  }

  getMediaFormat(): MediaFormat {
    return this.mediaFormat;
  }

  getBitrate(): number {
    return this.bitrate;
  }

  setBitrate(bitrate: number): void {
    this.bitrate = bitrate;
  }

  getWidth(): number {
    return this.width;
  }

  setWidth(width: number): void {
    this.width = width;
  }

  getHeight(): number {
    return this.height;
  }

  setHeight(height: number): void {
    this.height = height;
  }

  /** The frame rate, or FPS_NOT_APPLICABLE_OR_UNKNOWN for non-video itags. */
  getFps(): number {
    return this.fps;
  }

  setFps(fps: number): void {
    this.fps = fps > 0 ? fps : FPS_NOT_APPLICABLE_OR_UNKNOWN;
  }

  getInitStart(): number {
    return this.initStart;
  }

  setInitStart(initStart: number): void {
    this.initStart = initStart;
  }

  getInitEnd(): number {
    return this.initEnd;
  }

  setInitEnd(initEnd: number): void {
    this.initEnd = initEnd;
  }

  getIndexStart(): number {
    return this.indexStart;
  }

  setIndexStart(indexStart: number): void {
    this.indexStart = indexStart;
  }

  getIndexEnd(): number {
    return this.indexEnd;
  }

  setIndexEnd(indexEnd: number): void {
    this.indexEnd = indexEnd;
  }

  getQuality(): string {
    return this.quality;
  }

  setQuality(quality: string): void {
    this.quality = quality;
  }

  /** Only known for video itags; null otherwise. */
  getResolutionString(): string | null {
    return this.resolutionString;
  }

  getCodec(): string {
    return this.codec;
  }

  setCodec(codec: string): void {
    this.codec = codec;
  }

  /** Only known for audio itags; AVERAGE_BITRATE_UNKNOWN otherwise. See getBitrate(). */
  getAverageBitrate(): number {
    return this.avgBitrate;
  }

  getSampleRate(): number {
    return this.sampleRate;
  }

  setSampleRate(sampleRate: number): void {
    this.sampleRate = sampleRate > 0 ? sampleRate : SAMPLE_RATE_UNKNOWN;
  }

  getAudioChannels(): number {
    return this.audioChannels;
  }

  setAudioChannels(audioChannels: number): void {
    this.audioChannels = audioChannels > 0
      ? audioChannels : AUDIO_CHANNELS_NOT_APPLICABLE_OR_UNKNOWN;
  }

  /** Average sequence duration of (ended) livestreams; TARGET_DURATION_SEC_UNKNOWN for videos. */
  getTargetDurationSec(): number {
    return this.targetDurationSec;
  }

  setTargetDurationSec(targetDurationSec: number): void {
    this.targetDurationSec = targetDurationSec > 0
      ? targetDurationSec : TARGET_DURATION_SEC_UNKNOWN;
  }

  getApproxDurationMs(): number {
    return this.approxDurationMs;
  }

  setApproxDurationMs(approxDurationMs: number): void {
    this.approxDurationMs = approxDurationMs > 0
      ? approxDurationMs : APPROX_DURATION_MS_UNKNOWN;
  }

  getContentLength(): number {
    return this.contentLength;
  }

  setContentLength(contentLength: number): void {
    this.contentLength = contentLength > 0 ? contentLength : CONTENT_LENGTH_UNKNOWN;
  }

  getAudioTrackId(): string | null {
    return this.audioTrackId;
  }

  setAudioTrackId(audioTrackId: string | null): void {
    this.audioTrackId = audioTrackId;
  }

  getAudioTrackName(): string | null {
    return this.audioTrackName;
  }

  setAudioTrackName(audioTrackName: string | null): void {
    this.audioTrackName = audioTrackName;
  }

  getAudioTrackType(): AudioTrackType | null {
    return this.audioTrackType;
  }

  setAudioTrackType(audioTrackType: AudioTrackType | null): void {
    this.audioTrackType = audioTrackType;
  }

  /** A BCP-47 language tag, or null when unknown. */
  getAudioLocale(): string | null {
    return this.audioLocale;
  }

  setAudioLocale(audioLocale: string | null): void {
    this.audioLocale = audioLocale;
  }

  /** Whether the audio track has dynamic range compression applied. */
  isDrc(): boolean {
    return this.drc;
  }

  setIsDrc(isDrc: boolean): void {
    this.drc = isDrc;
  }

  /** Unix timestamp, or LAST_MODIFIED_UNKOWN. */
  getLastModified(): number {
    return this.lastModified;
  }

  setLastModified(lastModified: number): void {
    this.lastModified = lastModified;
  }

  /** Base64-encoded protobuf key-value list of extra stream tags (DRC among them). */
  getXtags(): string {
    return this.xtags;
  }

  setXtags(xtags: string): void {
    this.xtags = xtags;
  }
}
