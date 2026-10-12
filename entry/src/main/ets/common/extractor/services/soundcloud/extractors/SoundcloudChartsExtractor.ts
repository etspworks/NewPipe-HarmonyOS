/*
 * Port of org.schabi.newpipe.extractor.services.soundcloud.extractors.SoundcloudChartsExtractor
 * (NewPipeExtractor v0.26.5).
 */

import { InfoItemsPage } from '../../../../../model/extractor/ListExtractorInfoItemsPage';
import { Page } from '../../../../../model/extractor/Page';
import { StreamInfoItem } from '../../../../../model/extractor/StreamInfoItem';
import { KioskExtractor } from '../../../info/KioskList';
import { StreamInfoItemsCollector } from '../../../info/StreamInfoItemsCollector';
import { StreamingService } from '../../../core/StreamingService';
import { isNullOrEmpty } from '../../../core/Utils';
import { Downloader } from '../../../downloader/Downloader';
import { ListLinkHandler } from '../../../linkhandler/LinkHandler';
import { ContentCountry } from '../../../localization/ContentCountry';
import { SOUNDCLOUD_API_V2_URL, SoundcloudParsingHelper } from '../SoundcloudParsingHelper';

export class SoundcloudChartsExtractor extends KioskExtractor<StreamInfoItem> {
  private initialFetchNextPageUrl: string | null = null;
  private initialFetchCollector: StreamInfoItemsCollector | null = null;

  constructor(service: StreamingService, linkHandler: ListLinkHandler, kioskId: string) {
    super(service, linkHandler, kioskId);
  }

  async onFetchPage(downloader: Downloader): Promise<void> {
    // Check if already run
    if (this.initialFetchNextPageUrl !== null) {
      return;
    }

    const collector: StreamInfoItemsCollector =
      new StreamInfoItemsCollector(this.getServiceId());
    this.initialFetchCollector = collector;

    const apiUrl: string = SOUNDCLOUD_API_V2_URL + 'charts'
      + '?genre=soundcloud:genres:all-music'
      + '&client_id=' + await SoundcloudParsingHelper.clientId()
      + '&kind=trending';

    const contentCountry: ContentCountry = this.getService().getContentCountry();
    let apiUrlWithRegion: string | null = null;
    for (const supported of this.getService().getSupportedCountries()) {
      if (supported.equals(contentCountry)) {
        apiUrlWithRegion = apiUrl + '&region=soundcloud:regions:'
          + contentCountry.getCountryCode();
        break;
      }
    }

    try {
      this.initialFetchNextPageUrl = await SoundcloudParsingHelper.getStreamsFromApi(collector,
        apiUrlWithRegion === null ? apiUrl : apiUrlWithRegion, true);
    } catch (e) {
      // Request to other region may be geo-restricted.
      // See https://github.com/TeamNewPipe/NewPipeExtractor/issues/537.
      // We retry without the specified region.
      this.initialFetchNextPageUrl =
        await SoundcloudParsingHelper.getStreamsFromApi(collector, apiUrl, true);
    }
  }

  getName(): string {
    return this.getId();
  }

  async getPage(page: Page): Promise<InfoItemsPage<StreamInfoItem>> {
    if (page === null || isNullOrEmpty(page.getUrl())) {
      throw new Error('Page doesn\'t contain an URL');
    }

    const collector: StreamInfoItemsCollector =
      new StreamInfoItemsCollector(this.getServiceId());
    const nextPageUrl: string = await SoundcloudParsingHelper.getStreamsFromApi(collector,
      page.getUrl() as string, true);

    return InfoItemsPage.fromCollector(collector, new Page(nextPageUrl));
  }

  async getInitialPage(): Promise<InfoItemsPage<StreamInfoItem>> {
    const collector: StreamInfoItemsCollector | null = this.initialFetchCollector;
    if (collector === null) {
      throw new Error('Page is not fetched. Make sure you call fetchPage()');
    }
    return InfoItemsPage.fromCollector(collector, new Page(this.initialFetchNextPageUrl));
  }
}
