/*
 * Port of org.schabi.newpipe.extractor.services.media_ccc.extractors.MediaCCCConferenceExtractor
 * (NewPipeExtractor v0.26.5).
 *
 * The source's static fetchConferenceData() lives in MediaCCCParsingHelper here; see its header.
 */

import { ChannelExtractor } from '../../../info/ChannelExtractor';
import { ChannelTabExtractor, ChannelTabs } from '../../../info/ChannelTabExtractor';
import { StreamingService } from '../../../core/StreamingService';
import { ListLinkHandler } from '../../../linkhandler/LinkHandler';
import {
  ChannelTabExtractorBuilder,
  ReadyChannelTabListLinkHandler
} from '../../../linkhandler/ReadyChannelTabListLinkHandler';
import { Downloader } from '../../../downloader/Downloader';
import { JsonObject } from '../../../json/NanoJson';
import { Image } from '../../../../../model/extractor/Image';
import { fetchConferenceData, getImageListFromLogoImageUrl } from '../MediaCCCParsingHelper';
import { MediaCCCChannelTabExtractor } from './MediaCCCChannelTabExtractor';

/** Port of the lambda the source passes to ReadyChannelTabListLinkHandler. */
class MediaCCCChannelTabExtractorBuilder implements ChannelTabExtractorBuilder {
  private readonly conferenceData: JsonObject;

  constructor(conferenceData: JsonObject) {
    this.conferenceData = conferenceData;
  }

  build(service: StreamingService, linkHandler: ListLinkHandler): ChannelTabExtractor {
    return new MediaCCCChannelTabExtractor(service, linkHandler, this.conferenceData);
  }
}

export class MediaCCCConferenceExtractor extends ChannelExtractor {
  private conferenceData: JsonObject = new JsonObject();

  constructor(service: StreamingService, linkHandler: ListLinkHandler) {
    super(service, linkHandler);
  }

  getAvatars(): Image[] {
    return getImageListFromLogoImageUrl(this.conferenceData.getString('logo_url'));
  }

  getBanners(): Image[] {
    return [];
  }

  getFeedUrl(): string | null {
    return null;
  }

  getSubscriberCount(): number {
    return -1;
  }

  getDescription(): string {
    return '';
  }

  getParentChannelName(): string {
    return '';
  }

  getParentChannelUrl(): string {
    return '';
  }

  getParentChannelAvatars(): Image[] {
    return [];
  }

  isVerified(): boolean {
    return false;
  }

  getTabs(): ListLinkHandler[] {
    // avoid keeping a reference to MediaCCCConferenceExtractor inside the builder
    const theConferenceData: JsonObject = this.conferenceData;
    return [new ReadyChannelTabListLinkHandler(this.getUrl(), this.getId(), ChannelTabs.VIDEOS,
      new MediaCCCChannelTabExtractorBuilder(theConferenceData))];
  }

  async onFetchPage(downloader: Downloader): Promise<void> {
    this.conferenceData = await fetchConferenceData(downloader, this.getId());
  }

  getName(): string {
    const title: string | null = this.conferenceData.getString('title');
    return title === null ? '' : title;
  }
}
