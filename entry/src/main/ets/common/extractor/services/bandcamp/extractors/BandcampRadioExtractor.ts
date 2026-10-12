/*
 * Port of org.schabi.newpipe.extractor.services.bandcamp.extractors.BandcampRadioExtractor
 * (NewPipeExtractor v0.26.5). Created by Fynn Godau 2019, GPL v3 or later.
 */

import { InfoItemsPage } from '../../../../../model/extractor/ListExtractorInfoItemsPage';
import { Page } from '../../../../../model/extractor/Page';
import { StreamInfoItem } from '../../../../../model/extractor/StreamInfoItem';
import { KioskExtractor } from '../../../info/KioskList';
import { StreamInfoItemsCollector } from '../../../info/StreamInfoItemsCollector';
import { StreamingService } from '../../../core/StreamingService';
import { Downloader } from '../../../downloader/Downloader';
import { ExtractionException, ParsingException } from '../../../exceptions/Exceptions';
import { JsonArray, JsonObject, JsonParser } from '../../../json/NanoJson';
import { ListLinkHandler } from '../../../linkhandler/LinkHandler';
import { BASE_API_URL } from './BandcampExtractorHelper';
import { BandcampRadioInfoItemExtractor } from './BandcampRadioInfoItemExtractor';

export const KIOSK_RADIO: string = 'Radio';
export const RADIO_API_URL: string = BASE_API_URL + '/bcweekly/3/list';

export class BandcampRadioExtractor extends KioskExtractor<StreamInfoItem> {
  private json: JsonObject | null = null;

  constructor(streamingService: StreamingService, linkHandler: ListLinkHandler,
    kioskId: string) {
    super(streamingService, linkHandler, kioskId);
  }

  async onFetchPage(downloader: Downloader): Promise<void> {
    try {
      this.json = JsonParser.object().from(
        (await this.getDownloader().get(RADIO_API_URL)).responseBody());
    } catch (e) {
      throw new ExtractionException('Could not parse Bandcamp Radio API response',
        e instanceof Error ? e as Error : null);
    }
  }

  getName(): string {
    return KIOSK_RADIO;
  }

  async getInitialPage(): Promise<InfoItemsPage<StreamInfoItem>> {
    if (this.json === null) {
      throw new ParsingException('Page is not fetched. Make sure you call fetchPage()');
    }
    const collector: StreamInfoItemsCollector =
      new StreamInfoItemsCollector(this.getServiceId());

    const radioShows: JsonArray = this.json.getArray('results');

    for (let i: number = 0; i < radioShows.size(); i++) {
      collector.commit(new BandcampRadioInfoItemExtractor(radioShows.getObject(i)));
    }

    return InfoItemsPage.fromCollector(collector, null);
  }

  /** The source returns null here; the ported signature is non-nullable, so: an empty page. */
  async getPage(page: Page): Promise<InfoItemsPage<StreamInfoItem>> {
    return InfoItemsPage.emptyPage<StreamInfoItem>();
  }
}
