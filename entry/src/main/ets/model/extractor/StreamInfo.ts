/*
 * Port of org.schabi.newpipe.extractor.stream.StreamInfo (NewPipeExtractor v0.26.5).
 *
 * THE stream mapper: extractImportantData / extractStreams / extractOptionalData set every field
 * the source sets, in the source's order, each optional one guarded so a single failure becomes
 * an entry in errors[] instead of losing the page. Fields are public camelCase — the player lane
 * binds `videoOnlyStreams`, `hlsUrl` and `startPosition` directly.
 */

import { Info } from '../../common/extractor/core/Info';
import { InfoItem } from '../../common/extractor/core/InfoItem';
import { toError } from '../../common/extractor/core/Errors';
import { ExtractorHelper } from '../../common/extractor/core/ExtractorHelper';
import { ExtractorLogger } from '../../common/extractor/core/ExtractorLogger';
import { NewPipe } from '../../common/extractor/core/NewPipe';
import { StreamingService } from '../../common/extractor/core/StreamingService';
import { isNullOrEmpty } from '../../common/extractor/core/Utils';
import {
  ContentNotAvailableException,
  ContentNotSupportedException,
  ExtractionException
} from '../../common/extractor/exceptions/Exceptions';
import { Privacy, StreamExtractor } from '../../common/extractor/info/StreamExtractor';
import { DateWrapper } from '../../common/extractor/localization/DateWrapper';
import { StreamType } from '../enums/StreamType';
import { AudioStream } from './AudioStream';
import { ContentAvailability } from './ContentAvailability';
import { Description } from './Description';
import { Frameset } from './Frameset';
import { Image } from './Image';
import { MetaInfo } from './MetaInfo';
import { StreamSegment } from './StreamSegment';
import { SubtitlesStream } from './SubtitlesStream';
import { VideoStream } from './VideoStream';

const TAG: string = 'StreamInfo';

export class StreamExtractException extends ExtractionException {
  constructor(message: string) {
    super(message);
    this.name = 'StreamExtractException';
  }
}

export class StreamInfo extends Info {
  streamType: StreamType;
  thumbnails: Image[] = [];
  textualUploadDate: string | null = null;
  /**
   * DEVIATION from the source's DateWrapper: a millisecond epoch, with the wrapper's
   * `isApproximation` flag flattened beside it. DateWrapper has no module in the plan's models[],
   * and the persistence lane stores the two values, not an object.
   */
  uploadDate: number | null = null;
  isUploadDateApproximation: boolean = false;
  duration: number = -1;
  ageLimit: number;
  description: Description = Description.EMPTY_DESCRIPTION;
  viewCount: number = -1;
  likeCount: number = -1;
  dislikeCount: number = -1;
  uploaderName: string = '';
  uploaderUrl: string = '';
  uploaderAvatars: Image[] = [];
  uploaderVerified: boolean = false;
  uploaderSubscriberCount: number = -1;
  subChannelName: string = '';
  subChannelUrl: string = '';
  subChannelAvatars: Image[] = [];
  videoStreams: VideoStream[] = [];
  audioStreams: AudioStream[] = [];
  videoOnlyStreams: VideoStream[] = [];
  dashMpdUrl: string = '';
  hlsUrl: string = '';
  relatedItems: InfoItem[] = [];
  startPosition: number = 0;
  subtitles: SubtitlesStream[] = [];
  host: string = '';
  privacy: Privacy = Privacy.PUBLIC;
  category: string = '';
  licence: string = '';
  supportInfo: string = '';
  /** A BCP-47 language tag; java.util.Locale has no ArkTS equivalent. */
  language: string | null = null;
  tags: string[] = [];
  streamSegments: StreamSegment[] = [];
  metaInfo: MetaInfo[] = [];
  shortFormContent: boolean = false;
  contentAvailability: ContentAvailability = ContentAvailability.AVAILABLE;
  previewFrames: Frameset[] = [];

  constructor(serviceId: number, url: string, originalUrl: string, streamType: StreamType,
    id: string, name: string, ageLimit: number) {
    super(serviceId, id, url, originalUrl, name);
    this.streamType = streamType;
    this.ageLimit = ageLimit;
    ExtractorLogger.d(TAG, 'Created {}', [this]);
  }

  toString(): string {
    return TAG + '['
      + 'serviceId=' + this.getServiceId()
      + ', url=\'' + this.getUrl() + '\''
      + ', originalUrl=\'' + this.getOriginalUrl() + '\''
      + ', id=\'' + this.getId() + '\''
      + ', name=\'' + this.getName() + '\''
      + ', streamType=' + this.streamType
      + ', ageLimit=' + this.ageLimit
      + ']';
  }

  static async getInfoFromUrl(url: string): Promise<StreamInfo> {
    ExtractorLogger.d(TAG, 'getInfo({url})', [url]);
    return StreamInfo.getInfoFromService(NewPipe.getServiceByUrl(url), url);
  }

  static async getInfoFromService(service: StreamingService, url: string): Promise<StreamInfo> {
    ExtractorLogger.d(TAG, 'getInfo({service},{url})', [service, url]);
    return StreamInfo.getInfo(service.getStreamExtractorFromUrl(url));
  }

  static async getInfo(extractor: StreamExtractor): Promise<StreamInfo> {
    ExtractorLogger.d(TAG, 'getInfo({extractor})', [extractor]);
    await extractor.fetchPage();
    try {
      const streamInfo: StreamInfo = StreamInfo.extractImportantData(extractor);
      await StreamInfo.extractStreams(streamInfo, extractor);
      await StreamInfo.extractOptionalData(streamInfo, extractor);
      return streamInfo;
    } catch (e) {
      if (!(e instanceof ExtractionException)) {
        throw e;
      }
      // Fill in the service's own explanation when it has one; it is what the UI shows.
      const errorMessage: string | null = extractor.getErrorMessage();
      if (isNullOrEmpty(errorMessage)) {
        throw e;
      }
      throw new ContentNotAvailableException(errorMessage as string, e as ExtractionException);
    }
  }

  private static extractImportantData(extractor: StreamExtractor): StreamInfo {
    // Important data, without it the content can't be displayed: if one is not available, the
    // frontend can not show the stream at all, so an exception is thrown.
    const url: string = extractor.getUrl();
    const streamType: StreamType = extractor.getStreamType();
    const id: string = extractor.getId();
    const name: string = extractor.getName();
    const ageLimit: number = extractor.getAgeLimit();

    if (streamType === StreamType.NONE || isNullOrEmpty(url) || isNullOrEmpty(id)
      || name === null || ageLimit === -1) {
      throw new ExtractionException('Some important stream information was not given.');
    }

    return new StreamInfo(extractor.getServiceId(), url, extractor.getOriginalUrl(), streamType,
      id, name, ageLimit);
  }

  private static async extractStreams(streamInfo: StreamInfo,
    extractor: StreamExtractor): Promise<void> {
    // Load and extract the streams; if none is available the stream cannot be played at all.
    try {
      streamInfo.dashMpdUrl = extractor.getDashMpdUrl();
    } catch (e) {
      streamInfo.addError(new ExtractionException('Couldn\'t get DASH manifest', toError(e)));
    }
    try {
      streamInfo.hlsUrl = extractor.getHlsUrl();
    } catch (e) {
      streamInfo.addError(new ExtractionException('Couldn\'t get HLS manifest', toError(e)));
    }
    try {
      streamInfo.audioStreams = await extractor.getAudioStreams();
    } catch (e) {
      if (e instanceof ContentNotSupportedException) {
        throw e;
      }
      streamInfo.addError(new ExtractionException('Couldn\'t get audio streams', toError(e)));
    }
    try {
      streamInfo.videoStreams = await extractor.getVideoStreams();
    } catch (e) {
      streamInfo.addError(new ExtractionException('Couldn\'t get video streams', toError(e)));
    }
    try {
      streamInfo.videoOnlyStreams = await extractor.getVideoOnlyStreams();
    } catch (e) {
      streamInfo.addError(new ExtractionException('Couldn\'t get video only streams', toError(e)));
    }

    // Either audio or video has to be available, otherwise the stream cannot be played.
    if (streamInfo.videoStreams.length === 0 && streamInfo.audioStreams.length === 0
      && isNullOrEmpty(streamInfo.dashMpdUrl) && isNullOrEmpty(streamInfo.hlsUrl)) {
      throw new StreamExtractException(
        'Could not get any stream. See error variable to get further details.');
    }
  }

  private static async extractOptionalData(streamInfo: StreamInfo,
    extractor: StreamExtractor): Promise<void> {
    // Extract the optional data one by one: a failure here is recorded, never fatal.
    try {
      streamInfo.thumbnails = extractor.getThumbnails();
    } catch (e) {
      streamInfo.addError(toError(e));
    }
    try {
      streamInfo.duration = extractor.getLength();
    } catch (e) {
      streamInfo.addError(toError(e));
    }
    try {
      streamInfo.uploaderName = extractor.getUploaderName();
    } catch (e) {
      streamInfo.addError(toError(e));
    }
    try {
      streamInfo.uploaderUrl = extractor.getUploaderUrl();
    } catch (e) {
      streamInfo.addError(toError(e));
    }
    try {
      streamInfo.uploaderAvatars = extractor.getUploaderAvatars();
    } catch (e) {
      streamInfo.addError(toError(e));
    }
    try {
      streamInfo.uploaderVerified = extractor.isUploaderVerified();
    } catch (e) {
      streamInfo.addError(toError(e));
    }
    try {
      streamInfo.uploaderSubscriberCount = extractor.getUploaderSubscriberCount();
    } catch (e) {
      streamInfo.addError(toError(e));
    }
    try {
      streamInfo.subChannelName = extractor.getSubChannelName();
    } catch (e) {
      streamInfo.addError(toError(e));
    }
    try {
      streamInfo.subChannelUrl = extractor.getSubChannelUrl();
    } catch (e) {
      streamInfo.addError(toError(e));
    }
    try {
      streamInfo.subChannelAvatars = extractor.getSubChannelAvatars();
    } catch (e) {
      streamInfo.addError(toError(e));
    }
    try {
      streamInfo.description = extractor.getDescription();
    } catch (e) {
      streamInfo.addError(toError(e));
    }
    try {
      streamInfo.viewCount = extractor.getViewCount();
    } catch (e) {
      streamInfo.addError(toError(e));
    }
    try {
      streamInfo.textualUploadDate = extractor.getTextualUploadDate();
    } catch (e) {
      streamInfo.addError(toError(e));
    }
    try {
      streamInfo.setUploadDate(extractor.getUploadDate());
    } catch (e) {
      streamInfo.addError(toError(e));
    }
    try {
      streamInfo.startPosition = extractor.getTimeStamp();
    } catch (e) {
      streamInfo.addError(toError(e));
    }
    try {
      streamInfo.likeCount = extractor.getLikeCount();
    } catch (e) {
      streamInfo.addError(toError(e));
    }
    try {
      streamInfo.dislikeCount = extractor.getDislikeCount();
    } catch (e) {
      streamInfo.addError(toError(e));
    }
    try {
      streamInfo.subtitles = await extractor.getSubtitlesDefault();
    } catch (e) {
      streamInfo.addError(toError(e));
    }
    try {
      streamInfo.host = extractor.getHost();
    } catch (e) {
      streamInfo.addError(toError(e));
    }
    try {
      streamInfo.privacy = extractor.getPrivacy();
    } catch (e) {
      streamInfo.addError(toError(e));
    }
    try {
      streamInfo.category = extractor.getCategory();
    } catch (e) {
      streamInfo.addError(toError(e));
    }
    try {
      streamInfo.licence = extractor.getLicence();
    } catch (e) {
      streamInfo.addError(toError(e));
    }
    try {
      streamInfo.language = extractor.getLanguageInfo();
    } catch (e) {
      streamInfo.addError(toError(e));
    }
    try {
      streamInfo.tags = extractor.getTags();
    } catch (e) {
      streamInfo.addError(toError(e));
    }
    try {
      streamInfo.supportInfo = extractor.getSupportInfo();
    } catch (e) {
      streamInfo.addError(toError(e));
    }
    try {
      streamInfo.streamSegments = extractor.getStreamSegments();
    } catch (e) {
      streamInfo.addError(toError(e));
    }
    try {
      streamInfo.metaInfo = extractor.getMetaInfo();
    } catch (e) {
      streamInfo.addError(toError(e));
    }
    try {
      streamInfo.previewFrames = extractor.getFrames();
    } catch (e) {
      streamInfo.addError(toError(e));
    }
    try {
      streamInfo.shortFormContent = extractor.isShortFormContent();
    } catch (e) {
      streamInfo.addError(toError(e));
    }
    try {
      streamInfo.contentAvailability = extractor.getContentAvailability();
    } catch (e) {
      streamInfo.addError(toError(e));
    }

    streamInfo.relatedItems =
      await ExtractorHelper.getRelatedItemsOrLogError(streamInfo, extractor);
  }

  getStreamType(): StreamType {
    return this.streamType;
  }

  getThumbnails(): Image[] {
    return this.thumbnails;
  }

  getTextualUploadDate(): string | null {
    return this.textualUploadDate;
  }

  /** The millisecond epoch of the upload, or null; see the field's note. */
  getUploadDate(): number | null {
    return this.uploadDate;
  }

  /** Takes the extractor's DateWrapper and flattens it onto the two fields. */
  setUploadDate(uploadDate: DateWrapper | null): void {
    this.uploadDate = uploadDate === null ? null : uploadDate.getInstant().getTime();
    this.isUploadDateApproximation = uploadDate !== null && uploadDate.isApproximation();
  }

  getDuration(): number {
    return this.duration;
  }

  getAgeLimit(): number {
    return this.ageLimit;
  }

  getDescription(): Description {
    return this.description;
  }

  getViewCount(): number {
    return this.viewCount;
  }

  getLikeCount(): number {
    return this.likeCount;
  }

  getDislikeCount(): number {
    return this.dislikeCount;
  }

  getUploaderName(): string {
    return this.uploaderName;
  }

  getUploaderUrl(): string {
    return this.uploaderUrl;
  }

  getUploaderAvatars(): Image[] {
    return this.uploaderAvatars;
  }

  getIsUploaderVerified(): boolean {
    return this.uploaderVerified;
  }

  getUploaderSubscriberCount(): number {
    return this.uploaderSubscriberCount;
  }

  getSubChannelName(): string {
    return this.subChannelName;
  }

  getSubChannelUrl(): string {
    return this.subChannelUrl;
  }

  getSubChannelAvatars(): Image[] {
    return this.subChannelAvatars;
  }

  getVideoStreams(): VideoStream[] {
    return this.videoStreams;
  }

  getAudioStreams(): AudioStream[] {
    return this.audioStreams;
  }

  getVideoOnlyStreams(): VideoStream[] {
    return this.videoOnlyStreams;
  }

  getDashMpdUrl(): string {
    return this.dashMpdUrl;
  }

  getHlsUrl(): string {
    return this.hlsUrl;
  }

  getRelatedItems(): InfoItem[] {
    return this.relatedItems;
  }

  getStartPosition(): number {
    return this.startPosition;
  }

  getSubtitles(): SubtitlesStream[] {
    return this.subtitles;
  }

  getHost(): string {
    return this.host;
  }

  getPrivacy(): Privacy {
    return this.privacy;
  }

  getCategory(): string {
    return this.category;
  }

  getLicence(): string {
    return this.licence;
  }

  getLanguageInfo(): string | null {
    return this.language;
  }

  getTags(): string[] {
    return this.tags;
  }

  getSupportInfo(): string {
    return this.supportInfo;
  }

  getStreamSegments(): StreamSegment[] {
    return this.streamSegments;
  }

  getMetaInfo(): MetaInfo[] {
    return this.metaInfo;
  }

  getPreviewFrames(): Frameset[] {
    return this.previewFrames;
  }

  getIsShortFormContent(): boolean {
    return this.shortFormContent;
  }

  getContentAvailability(): ContentAvailability {
    return this.contentAvailability;
  }
}
