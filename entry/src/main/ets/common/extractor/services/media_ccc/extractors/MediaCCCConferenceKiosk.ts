/*
 * Port of org.schabi.newpipe.extractor.services.media_ccc.extractors.MediaCCCConferenceKiosk
 * (NewPipeExtractor v0.26.5).
 */

import { KioskExtractor } from '../../../info/KioskList';
import { StreamingService } from '../../../core/StreamingService';
import { ListLinkHandler } from '../../../linkhandler/LinkHandler';
import { ChannelInfoItemsCollector } from '../../../info/ChannelExtractor';
import { Downloader } from '../../../downloader/Downloader';
import { JsonArray, JsonObject, JsonParser } from '../../../json/NanoJson';
import { toError } from '../../../core/Errors';
import { ExtractionException } from '../../../exceptions/Exceptions';
import { ChannelInfoItem } from '../../../../../model/extractor/ChannelInfoItem';
import { InfoItemsPage } from '../../../../../model/extractor/ListExtractorInfoItemsPage';
import { Page } from '../../../../../model/extractor/Page';
import {
  MediaCCCConferenceInfoItemExtractor
} from './infoItems/MediaCCCConferenceInfoItemExtractor';

export const KIOSK_ID: string = 'conferences';

export class MediaCCCConferenceKiosk extends KioskExtractor<ChannelInfoItem> {
  private doc: JsonObject = new JsonObject();

  constructor(streamingService: StreamingService, linkHandler: ListLinkHandler,
    kioskId: string) {
    super(streamingService, linkHandler, kioskId);
  }

  async getInitialPage(): Promise<InfoItemsPage<ChannelInfoItem>> {
    const conferences: JsonArray = this.doc.getArray('conferences');
    const collector: ChannelInfoItemsCollector =
      new ChannelInfoItemsCollector(this.getServiceId());
    for (let i = 0; i < conferences.size(); i++) {
      collector.commit(new MediaCCCConferenceInfoItemExtractor(conferences.getObject(i)));
    }

    return InfoItemsPage.fromCollector(collector, null);
  }

  async getPage(page: Page): Promise<InfoItemsPage<ChannelInfoItem>> {
    return InfoItemsPage.emptyPage();
  }

  async onFetchPage(downloader: Downloader): Promise<void> {
    const site: string = (await downloader.get(this.getLinkHandler().getUrl(), null,
      this.getExtractorLocalization())).responseBody();
    try {
      this.doc = JsonParser.object().from(site);
    } catch (e) {
      throw new ExtractionException('Could not parse json.', toError(e));
    }
  }

  getName(): string {
    const name: string | null = this.doc.getString('Conferences');
    return name === null ? '' : name;
  }
}
