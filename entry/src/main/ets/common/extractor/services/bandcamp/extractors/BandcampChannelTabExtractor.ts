/*
 * Port of org.schabi.newpipe.extractor.services.bandcamp.extractors.BandcampChannelTabExtractor
 * (NewPipeExtractor v0.26.5).
 *
 * The two item extractors resolve their URL through the mobile API, which is I/O the ported
 * synchronous InfoItemExtractor.getUrl() cannot do, so each item's URL is primed here (this
 * method is already async) before it is committed.
 */

import { InfoItemsPage } from '../../../../../model/extractor/ListExtractorInfoItemsPage';
import { Page } from '../../../../../model/extractor/Page';
import { InfoItem } from '../../../core/InfoItem';
import { StreamingService } from '../../../core/StreamingService';
import { ChannelTabExtractor, ChannelTabs } from '../../../info/ChannelTabExtractor';
import { Downloader } from '../../../downloader/Downloader';
import { ListLinkHandler } from '../../../linkhandler/LinkHandler';
import { JsonArray } from '../../../json/NanoJson';
import { MultiInfoItemsCollector } from '../../../core/MultiInfoItemsCollector';
import { BandcampExtractorHelper } from './BandcampExtractorHelper';
import { BandcampAlbumInfoItemExtractor } from './BandcampAlbumInfoItemExtractor';
import { BandcampDiscographStreamInfoItemExtractor } from './streaminfoitem/BandcampDiscographStreamInfoItemExtractor';

export class BandcampChannelTabExtractor extends ChannelTabExtractor {
  private discography: JsonArray | null = null;
  private readonly filter: string;

  constructor(service: StreamingService, linkHandler: ListLinkHandler) {
    super(service, linkHandler);

    const tab: string = linkHandler.getContentFilters()[0];
    if (tab === ChannelTabs.TRACKS) {
      this.filter = 'track';
    } else if (tab === ChannelTabs.ALBUMS) {
      this.filter = 'album';
    } else {
      throw new Error('Unsupported channel tab: ' + tab);
    }
  }

  static fromDiscography(service: StreamingService, linkHandler: ListLinkHandler,
    discography: JsonArray): BandcampChannelTabExtractor {
    const tabExtractor: BandcampChannelTabExtractor =
      new BandcampChannelTabExtractor(service, linkHandler);
    tabExtractor.discography = discography;
    return tabExtractor;
  }

  async onFetchPage(downloader: Downloader): Promise<void> {
    if (this.discography === null) {
      this.discography = (await BandcampExtractorHelper.resolveArtistDetails(this.getId()))
        .getArray('discography');
    }
  }

  async getInitialPage(): Promise<InfoItemsPage<InfoItem>> {
    const collector: MultiInfoItemsCollector =
      new MultiInfoItemsCollector(this.getServiceId());
    const discography: JsonArray | null = this.discography;
    if (discography === null) {
      return InfoItemsPage.fromCollector(collector, null);
    }

    for (const discographJsonObject of discography.streamAsJsonObjects()) {
      // A discograph is as an item appears in a discography
      const itemType: string | null = discographJsonObject.getString('item_type', '');

      if (itemType !== this.filter) {
        continue;
      }

      if (itemType === 'track') {
        const extractor: BandcampDiscographStreamInfoItemExtractor =
          new BandcampDiscographStreamInfoItemExtractor(discographJsonObject, this.getUrl());
        await extractor.resolveUrl();
        collector.commit(extractor);
      } else if (itemType === 'album') {
        const extractor: BandcampAlbumInfoItemExtractor =
          new BandcampAlbumInfoItemExtractor(discographJsonObject, this.getUrl());
        await extractor.resolveUrl();
        collector.commit(extractor);
      }
    }

    return InfoItemsPage.fromCollector(collector, null);
  }

  /** The source returns null here; the ported signature is non-nullable, so: an empty page. */
  async getPage(page: Page): Promise<InfoItemsPage<InfoItem>> {
    return InfoItemsPage.emptyPage<InfoItem>();
  }
}
