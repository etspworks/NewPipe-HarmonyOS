/*
 * Port of org.schabi.newpipe.extractor.stream.StreamExtractor (NewPipeExtractor v0.26.5).
 *
 * The getters that do I/O in the source (the three stream lists, the subtitles and the related
 * items) are Promises here, per phase2-logic-contract.md §1; the rest stay synchronous.
 * ArkTS has no overloading, so getSubtitles(MediaFormat) keeps that name and the no-argument
 * default keeps the source's own getSubtitlesDefault().
 */

import { Extractor } from '../core/Extractor';
import { InfoItemExtractor, InfoItemsCollector } from '../core/Collector';
import { InfoItem } from '../core/InfoItem';
import { StreamingService } from '../core/StreamingService';
import { Parser, RegexException } from '../core/Parser';
import { LinkHandler } from '../linkhandler/LinkHandler';
import { DateWrapper } from '../localization/DateWrapper';
import { ParsingException } from '../exceptions/Exceptions';
import { MediaFormat } from '../../../model/enums/MediaFormat';
import { StreamType } from '../../../model/enums/StreamType';
import { AudioStream } from '../../../model/extractor/AudioStream';
import { ContentAvailability } from '../../../model/extractor/ContentAvailability';
import { Description } from '../../../model/extractor/Description';
import { Frameset } from '../../../model/extractor/Frameset';
import { Image } from '../../../model/extractor/Image';
import { MetaInfo } from '../../../model/extractor/MetaInfo';
import { StreamSegment } from '../../../model/extractor/StreamSegment';
import { SubtitlesStream } from '../../../model/extractor/SubtitlesStream';
import { VideoStream } from '../../../model/extractor/VideoStream';

export const NO_AGE_LIMIT: number = 0;
export const UNKNOWN_SUBSCRIBER_COUNT: number = -1;

export enum Privacy {
  PUBLIC,
  UNLISTED,
  PRIVATE,
  INTERNAL,
  OTHER
}

export abstract class StreamExtractor extends Extractor {
  constructor(service: StreamingService, linkHandler: LinkHandler) {
    super(service, linkHandler);
  }

  getTextualUploadDate(): string | null {
    return null;
  }

  getUploadDate(): DateWrapper | null {
    return null;
  }

  abstract getThumbnails(): Image[];

  getDescription(): Description {
    return Description.EMPTY_DESCRIPTION;
  }

  getAgeLimit(): number {
    return NO_AGE_LIMIT;
  }

  /** The length in seconds. */
  getLength(): number {
    return 0;
  }

  /** The position the url points at (`&t=`), in seconds. */
  getTimeStamp(): number {
    return 0;
  }

  getViewCount(): number {
    return -1;
  }

  getLikeCount(): number {
    return -1;
  }

  getDislikeCount(): number {
    return -1;
  }

  abstract getUploaderUrl(): string;

  abstract getUploaderName(): string;

  isUploaderVerified(): boolean {
    return false;
  }

  getUploaderSubscriberCount(): number {
    return UNKNOWN_SUBSCRIBER_COUNT;
  }

  getUploaderAvatars(): Image[] {
    return [];
  }

  getSubChannelUrl(): string {
    return '';
  }

  getSubChannelName(): string {
    return '';
  }

  getSubChannelAvatars(): Image[] {
    return [];
  }

  getDashMpdUrl(): string {
    return '';
  }

  getHlsUrl(): string {
    return '';
  }

  abstract getAudioStreams(): Promise<AudioStream[]>;

  abstract getVideoStreams(): Promise<VideoStream[]>;

  abstract getVideoOnlyStreams(): Promise<VideoStream[]>;

  async getSubtitlesDefault(): Promise<SubtitlesStream[]> {
    return [];
  }

  async getSubtitles(format: MediaFormat): Promise<SubtitlesStream[]> {
    return [];
  }

  abstract getStreamType(): StreamType;

  async getRelatedItems(): Promise<InfoItemsCollector<InfoItem, InfoItemExtractor> | null> {
    return null;
  }

  getFrames(): Frameset[] {
    return [];
  }

  /** The service's own "why this cannot be played" message, or null. */
  getErrorMessage(): string | null {
    return null;
  }

  /**
   * The `t`/`start` timestamp of the original url in seconds; `-2` when the url carries none and
   * `0` when it carries an empty one, exactly as in the source.
   */
  protected getTimestampSeconds(regexPattern: string): number {
    let timestamp: string;
    try {
      timestamp = Parser.matchGroup1OfString(regexPattern, this.getOriginalUrl());
    } catch (e) {
      if (e instanceof RegexException) {
        // catch this instead of adding it to the errors: the url simply has no timestamp
        return -2;
      }
      throw e;
    }
    if (timestamp.length === 0) {
      return 0;
    }
    try {
      let secondsString: string = '';
      let minutesString: string = '';
      let hoursString: string = '';
      try {
        secondsString = Parser.matchGroup1OfString('(\\d+)s', timestamp);
        minutesString = Parser.matchGroup1OfString('(\\d+)m', timestamp);
        hoursString = Parser.matchGroup1OfString('(\\d+)h', timestamp);
      } catch (e) {
        if (secondsString.length === 0 && minutesString.length === 0) {
          // the timestamp is just a number of seconds, e.g. `t=120`
          secondsString = Parser.matchGroup1OfString('t=(\\d+)', timestamp);
        }
      }
      const seconds: number = secondsString.length === 0 ? 0 : Number.parseInt(secondsString, 10);
      const minutes: number = minutesString.length === 0 ? 0 : Number.parseInt(minutesString, 10);
      const hours: number = hoursString.length === 0 ? 0 : Number.parseInt(hoursString, 10);
      return seconds + 60 * minutes + 3600 * hours;
    } catch (e) {
      throw new ParsingException('Could not get timestamp.',
        e instanceof Error ? e as Error : null);
    }
  }

  getHost(): string {
    return '';
  }

  getPrivacy(): Privacy {
    return Privacy.PUBLIC;
  }

  getCategory(): string {
    return '';
  }

  getLicence(): string {
    return '';
  }

  /** A BCP-47 language tag; java.util.Locale has no ArkTS equivalent. */
  getLanguageInfo(): string | null {
    return null;
  }

  getTags(): string[] {
    return [];
  }

  getSupportInfo(): string {
    return '';
  }

  getStreamSegments(): StreamSegment[] {
    return [];
  }

  getMetaInfo(): MetaInfo[] {
    return [];
  }

  isShortFormContent(): boolean {
    return false;
  }

  getContentAvailability(): ContentAvailability {
    return ContentAvailability.UNKNOWN;
  }
}
