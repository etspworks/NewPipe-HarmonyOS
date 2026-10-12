/*
 * Port of org.schabi.newpipe.extractor.services.media_ccc.extractors.infoItems
 * .MediaCCCStreamInfoItemExtractor (NewPipeExtractor v0.26.5).
 */

import { StreamInfoItemExtractor } from '../../../../info/StreamInfoItemExtractor';
import { JsonObject } from '../../../../json/NanoJson';
import { DateWrapper } from '../../../../localization/DateWrapper';
import { Image } from '../../../../../../model/extractor/Image';
import { StreamType } from '../../../../../../model/enums/StreamType';
import { getThumbnailsFromStreamItem } from '../../MediaCCCParsingHelper';

export class MediaCCCStreamInfoItemExtractor extends StreamInfoItemExtractor {
  private readonly event: JsonObject;

  constructor(event: JsonObject) {
    super();
    this.event = event;
  }

  getStreamType(): StreamType {
    return StreamType.VIDEO_STREAM;
  }

  isAd(): boolean {
    return false;
  }

  getDuration(): number {
    return this.event.getInt('length');
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
    return conferenceUrl === null ? '' : conferenceUrl;
  }

  isUploaderVerified(): boolean {
    return false;
  }

  getTextualUploadDate(): string | null {
    return this.event.getString('release_date');
  }

  getUploadDate(): DateWrapper | null {
    // if null, event is in the future...
    return DateWrapper.fromOffsetDateTime(this.getTextualUploadDate());
  }

  getName(): string {
    const title: string | null = this.event.getString('title');
    return title === null ? '' : title;
  }

  getUrl(): string {
    const guid: string | null = this.event.getString('guid');
    return 'https://media.ccc.de/public/events/' + (guid === null ? '' : guid);
  }

  getThumbnails(): Image[] {
    return getThumbnailsFromStreamItem(this.event);
  }
}
