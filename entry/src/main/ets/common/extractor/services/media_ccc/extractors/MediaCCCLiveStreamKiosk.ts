/*
 * Port of org.schabi.newpipe.extractor.services.media_ccc.extractors.MediaCCCLiveStreamKiosk
 * (NewPipeExtractor v0.26.5).
 */

import { KioskExtractor } from '../../../info/KioskList';
import { StreamingService } from '../../../core/StreamingService';
import { ListLinkHandler } from '../../../linkhandler/LinkHandler';
import { StreamInfoItemsCollector } from '../../../info/StreamInfoItemsCollector';
import { Downloader } from '../../../downloader/Downloader';
import { JsonArray, JsonObject } from '../../../json/NanoJson';
import { InfoItemsPage } from '../../../../../model/extractor/ListExtractorInfoItemsPage';
import { Page } from '../../../../../model/extractor/Page';
import { StreamInfoItem } from '../../../../../model/extractor/StreamInfoItem';
import { getLiveStreams } from '../MediaCCCParsingHelper';
import { MediaCCCLiveStreamKioskExtractor } from './MediaCCCLiveStreamKioskExtractor';

export const KIOSK_ID: string = 'live';

export class MediaCCCLiveStreamKiosk extends KioskExtractor<StreamInfoItem> {
  private doc: JsonArray = new JsonArray();

  constructor(streamingService: StreamingService, linkHandler: ListLinkHandler,
    kioskId: string) {
    super(streamingService, linkHandler, kioskId);
  }

  async onFetchPage(downloader: Downloader): Promise<void> {
    this.doc = await getLiveStreams(downloader, this.getExtractorLocalization());
  }

  async getInitialPage(): Promise<InfoItemsPage<StreamInfoItem>> {
    const collector: StreamInfoItemsCollector =
      new StreamInfoItemsCollector(this.getServiceId());
    for (let c = 0; c < this.doc.size(); c++) {
      const conference: JsonObject = this.doc.getObject(c);
      if (conference.getBoolean('isCurrentlyStreaming')) {
        const groups: JsonArray = conference.getArray('groups');
        for (let g = 0; g < groups.size(); g++) {
          const groupName: string | null = groups.getObject(g).getString('group');
          const rooms: JsonArray = groups.getObject(g).getArray('rooms');
          for (let r = 0; r < rooms.size(); r++) {
            const room: JsonObject = rooms.getObject(r);
            collector.commit(new MediaCCCLiveStreamKioskExtractor(conference,
              groupName === null ? '' : groupName, room));
          }
        }
      }
    }
    return InfoItemsPage.fromCollector(collector, null);
  }

  async getPage(page: Page): Promise<InfoItemsPage<StreamInfoItem>> {
    return InfoItemsPage.emptyPage();
  }

  getName(): string {
    return KIOSK_ID;
  }
}
