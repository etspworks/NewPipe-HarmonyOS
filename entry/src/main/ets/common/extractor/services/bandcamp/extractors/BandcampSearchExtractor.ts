/*
 * Port of org.schabi.newpipe.extractor.services.bandcamp.extractors.BandcampSearchExtractor
 * (NewPipeExtractor v0.26.5). Created by Fynn Godau 2019, GPL v3 or later.
 *
 * Bandcamp search is HTML scraping of https://bandcamp.com/search - there is no JSON API for it.
 */

import { InfoItemsPage } from '../../../../../model/extractor/ListExtractorInfoItemsPage';
import { MetaInfo } from '../../../../../model/extractor/MetaInfo';
import { Page } from '../../../../../model/extractor/Page';
import { InfoItem } from '../../../core/InfoItem';
import { StreamingService } from '../../../core/StreamingService';
import { Downloader, HeaderMap } from '../../../downloader/Downloader';
import { Document, Element, Elements, Jsoup } from '../../../html/Jsoup';
import { SearchQueryHandler } from '../../../linkhandler/LinkHandler';
import { SearchExtractor } from '../../../info/SearchExtractor';
import { MultiInfoItemsCollector } from '../../../core/MultiInfoItemsCollector';
import { BandcampChannelInfoItemExtractor } from './BandcampChannelInfoItemExtractor';
import { BandcampPlaylistInfoItemExtractor } from './BandcampPlaylistInfoItemExtractor';
import { BandcampSearchStreamInfoItemExtractor } from './streaminfoitem/BandcampSearchStreamInfoItemExtractor';

export class BandcampSearchExtractor extends SearchExtractor {
  constructor(service: StreamingService, linkHandler: SearchQueryHandler) {
    super(service, linkHandler);
  }

  getSearchSuggestion(): string {
    return '';
  }

  isCorrectedSearch(): boolean {
    return false;
  }

  getMetaInfo(): MetaInfo[] {
    return [];
  }

  async getPage(page: Page): Promise<InfoItemsPage<InfoItem>> {
    const collector: MultiInfoItemsCollector =
      new MultiInfoItemsCollector(this.getServiceId());

    // TODO: idk why this cookie works. See https://github.com/TeamNewPipe/NewPipe/issues/13476
    // Replace with something more reliable
    const headers: HeaderMap = new Map<string, string[]>();
    headers.set('Cookie', ['identity']);
    const pageUrl: string | null = page.getUrl();
    const url: string = pageUrl === null ? '' : pageUrl;
    const response: string = (await this.getDownloader().get(url, headers)).responseBody();
    const d: Document = Jsoup.parse(response);

    for (const searchResult of d.getElementsByClass('searchresult').toArray()) {
      let type: string = '';
      const resultInfo: Element | null =
        searchResult.getElementsByClass('result-info').first();
      if (resultInfo !== null) {
        const itemType: Element | null = resultInfo.getElementsByClass('itemtype').first();
        if (itemType !== null) {
          type = itemType.text();
        }
      }

      if (type === 'ARTIST') {
        collector.commit(new BandcampChannelInfoItemExtractor(searchResult));
      } else if (type === 'ALBUM') {
        collector.commit(new BandcampPlaylistInfoItemExtractor(searchResult));
      } else if (type === 'TRACK') {
        collector.commit(new BandcampSearchStreamInfoItemExtractor(searchResult, ''));
      }
      // don't display fan results ("FAN") or other things
    }

    // Count pages
    const pageLists: Elements = d.getElementsByClass('pagelist');
    if (pageLists.isEmpty()) {
      return InfoItemsPage.fromCollector(collector, null);
    }

    const firstPageList: Element | null = pageLists.first();
    const pages: Element[] =
      firstPageList === null ? [] : firstPageList.getElementsByTag('li').toArray();

    // Find current page
    let currentPage: number = -1;
    for (let i: number = 0; i < pages.length; i++) {
      if (!pages[i].getElementsByTag('span').isEmpty()) {
        currentPage = i + 1;
        break;
      }
    }

    let nextUrl: string | null = null;
    if (currentPage < pages.length) {
      nextUrl = url.substring(0, url.length - 1) + (currentPage + 1);
    }

    return InfoItemsPage.fromCollector(collector, new Page(nextUrl));
  }

  async getInitialPage(): Promise<InfoItemsPage<InfoItem>> {
    return this.getPage(new Page(this.getUrl()));
  }

  async onFetchPage(downloader: Downloader): Promise<void> {
  }
}
