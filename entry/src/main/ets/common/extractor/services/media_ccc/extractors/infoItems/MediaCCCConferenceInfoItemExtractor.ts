/*
 * Port of org.schabi.newpipe.extractor.services.media_ccc.extractors.infoItems
 * .MediaCCCConferenceInfoItemExtractor (NewPipeExtractor v0.26.5).
 */

import { ChannelInfoItemExtractor } from '../../../../info/ChannelExtractor';
import { ITEM_COUNT_UNKNOWN } from '../../../../core/ListExtractor';
import { JsonObject } from '../../../../json/NanoJson';
import { Image } from '../../../../../../model/extractor/Image';
import { getImageListFromLogoImageUrl } from '../../MediaCCCParsingHelper';

export class MediaCCCConferenceInfoItemExtractor extends ChannelInfoItemExtractor {
  private readonly conference: JsonObject;

  constructor(conference: JsonObject) {
    super();
    this.conference = conference;
  }

  getDescription(): string {
    return '';
  }

  getSubscriberCount(): number {
    return -1;
  }

  getStreamCount(): number {
    return ITEM_COUNT_UNKNOWN;
  }

  isVerified(): boolean {
    return false;
  }

  getName(): string {
    const title: string | null = this.conference.getString('title');
    return title === null ? '' : title;
  }

  getUrl(): string {
    const conferenceUrl: string | null = this.conference.getString('url');
    return conferenceUrl === null ? '' : conferenceUrl;
  }

  getThumbnails(): Image[] {
    return getImageListFromLogoImageUrl(this.conference.getString('logo_url'));
  }
}
