/*
 * Port of org.schabi.newpipe.extractor.services.media_ccc.extractors.MediaCCCChannelTabExtractor
 * (NewPipeExtractor v0.26.5).
 *
 * MediaCCC does not really have channel tabs, but rather a list of videos for each conference,
 * so this class just acts as a videos channel tab extractor.
 */

import { ChannelTabExtractor } from '../../../info/ChannelTabExtractor';
import { StreamingService } from '../../../core/StreamingService';
import { ListLinkHandler } from '../../../linkhandler/LinkHandler';
import { InfoItem } from '../../../core/InfoItem';
import { Downloader } from '../../../downloader/Downloader';
import { JsonObject } from '../../../json/NanoJson';
import { InfoItemsPage } from '../../../../../model/extractor/ListExtractorInfoItemsPage';
import { Page } from '../../../../../model/extractor/Page';
import { MultiInfoItemsCollector } from '../../../core/MultiInfoItemsCollector';
import { fetchConferenceData } from '../MediaCCCParsingHelper';
import { MediaCCCStreamInfoItemExtractor } from './infoItems/MediaCCCStreamInfoItemExtractor';

export class MediaCCCChannelTabExtractor extends ChannelTabExtractor {
  private conferenceData: JsonObject | null;

  /**
   * @param conferenceData not null when it has already been fetched by
   *                       MediaCCCConferenceExtractor; null means fetch it anew.
   */
  constructor(service: StreamingService, linkHandler: ListLinkHandler,
    conferenceData: JsonObject | null) {
    super(service, linkHandler);
    this.conferenceData = conferenceData;
  }

  async onFetchPage(downloader: Downloader): Promise<void> {
    if (this.conferenceData === null) {
      // only fetch conference data if we don't have it already
      this.conferenceData = await fetchConferenceData(downloader, this.getId());
    }
  }

  async getInitialPage(): Promise<InfoItemsPage<InfoItem>> {
    const collector: MultiInfoItemsCollector = new MultiInfoItemsCollector(this.getServiceId());
    if (this.conferenceData === null) {
      // will surely be != null after onFetchPage
      throw new Error('Conference data is missing; call fetchPage() first');
    }
    for (const event of this.conferenceData.getArray('events').streamAsJsonObjects()) {
      collector.commit(new MediaCCCStreamInfoItemExtractor(event));
    }
    return InfoItemsPage.fromCollector(collector, null);
  }

  async getPage(page: Page): Promise<InfoItemsPage<InfoItem>> {
    return InfoItemsPage.emptyPage();
  }
}
