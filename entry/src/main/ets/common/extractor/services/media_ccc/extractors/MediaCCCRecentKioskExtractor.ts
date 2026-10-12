/*
 * Port of org.schabi.newpipe.extractor.services.media_ccc.extractors.MediaCCCRecentKioskExtractor
 * (NewPipeExtractor v0.26.5).
 *
 * ponytail: the source parses `date` with the strict Java pattern
 * "yyyy-MM-dd'T'HH:mm:ss.SSSzzzz"; ArkTS has no DateTimeFormatter, so this uses Date's own
 * ISO-8601 parse, which accepts a slightly wider set of inputs and rejects the same junk. Swap in
 * an explicit parser only if an instance is found emitting a date Date() misreads.
 */

import { StreamInfoItemExtractor } from '../../../info/StreamInfoItemExtractor';
import { JsonObject } from '../../../json/NanoJson';
import { DateWrapper } from '../../../localization/DateWrapper';
import { ParsingException } from '../../../exceptions/Exceptions';
import { Image } from '../../../../../model/extractor/Image';
import { StreamType } from '../../../../../model/enums/StreamType';
import { getImageListFromLogoImageUrl } from '../MediaCCCParsingHelper';
import {
  MediaCCCConferenceLinkHandlerFactory
} from '../linkHandler/MediaCCCConferenceLinkHandlerFactory';

export class MediaCCCRecentKioskExtractor extends StreamInfoItemExtractor {
  private readonly event: JsonObject;

  constructor(event: JsonObject) {
    super();
    this.event = event;
  }

  getName(): string {
    const title: string | null = this.event.getString('title');
    return title === null ? '' : title;
  }

  getUrl(): string {
    const frontendLink: string | null = this.event.getString('frontend_link');
    return frontendLink === null ? '' : frontendLink;
  }

  getThumbnails(): Image[] {
    return getImageListFromLogoImageUrl(this.event.getString('poster_url'));
  }

  getStreamType(): StreamType {
    return StreamType.VIDEO_STREAM;
  }

  isAd(): boolean {
    return false;
  }

  getDuration(): number {
    // duration and length have the same value, see
    // https://github.com/voc/voctoweb/blob/master/app/views/public/shared/_event.json.jbuilder
    return this.event.getInt('duration');
  }

  getViewCount(): number {
    return this.event.getInt('view_count');
  }

  getUploaderName(): string {
    const conferenceTitle: string | null = this.event.getString('conference_title');
    return conferenceTitle === null ? '' : conferenceTitle;
  }

  getUploaderUrl(): string {
    const conferenceUrl: string | null = this.event.getString('conference_url');
    // API URL in, web URL out
    return MediaCCCConferenceLinkHandlerFactory.getInstance()
      .fromUrl(conferenceUrl === null ? '' : conferenceUrl).getUrl();
  }

  isUploaderVerified(): boolean {
    return false;
  }

  getTextualUploadDate(): string | null {
    return this.event.getString('date');
  }

  getUploadDate(): DateWrapper | null {
    const date: string | null = this.event.getString('date');
    const parsed: Date = new Date(date === null ? '' : date);
    if (Number.isNaN(parsed.getTime())) {
      throw new ParsingException('Could not parse date: "' + date + '"');
    }
    return new DateWrapper(parsed);
  }
}
