/*
 * Port of org.schabi.newpipe.extractor.search.SearchInfo (NewPipeExtractor v0.26.5).
 *
 * The related items of a search are polymorphic — streams, channels and playlists in one list —
 * which is why this is a ListInfo<InfoItem> and the search screen branches per item type.
 */

import { ExtractorHelper } from '../../common/extractor/core/ExtractorHelper';
import { InfoItem } from '../../common/extractor/core/InfoItem';
import { ListInfo } from '../../common/extractor/core/ListInfo';
import { toError } from '../../common/extractor/core/Errors';
import { StreamingService } from '../../common/extractor/core/StreamingService';
import { SearchExtractor } from '../../common/extractor/info/SearchExtractor';
import { SearchQueryHandler } from '../../common/extractor/linkhandler/LinkHandler';
import { InfoItemsPage } from './ListExtractorInfoItemsPage';
import { MetaInfo } from './MetaInfo';
import { Page } from './Page';

export class SearchInfo extends ListInfo<InfoItem> {
  readonly searchString: string;
  searchSuggestion: string = '';
  isCorrectedSearch: boolean = false;
  metaInfo: MetaInfo[] = [];

  constructor(serviceId: number, qIHandler: SearchQueryHandler, searchString: string) {
    super(serviceId, qIHandler.getId(), qIHandler.getUrl(), qIHandler.getOriginalUrl(), 'Search',
      qIHandler.getContentFilters(), qIHandler.getSortFilter());
    this.searchString = searchString;
  }

  static async getInfoFromService(service: StreamingService,
    searchQuery: SearchQueryHandler): Promise<SearchInfo> {
    const extractor: SearchExtractor = service.getSearchExtractor(searchQuery);
    await extractor.fetchPage();
    return SearchInfo.getInfo(extractor);
  }

  static async getInfo(extractor: SearchExtractor): Promise<SearchInfo> {
    const info: SearchInfo = new SearchInfo(extractor.getServiceId(), extractor.getLinkHandler(),
      extractor.getSearchString());

    try {
      info.setOriginalUrl(extractor.getOriginalUrl());
    } catch (e) {
      info.addError(toError(e));
    }
    try {
      info.searchSuggestion = extractor.getSearchSuggestion();
    } catch (e) {
      info.addError(toError(e));
    }
    try {
      info.isCorrectedSearch = extractor.isCorrectedSearch();
    } catch (e) {
      info.addError(toError(e));
    }
    try {
      info.metaInfo = extractor.getMetaInfo();
    } catch (e) {
      info.addError(toError(e));
    }

    const page: InfoItemsPage<InfoItem> =
      await ExtractorHelper.getItemsPageOrLogError(info, extractor);
    info.setRelatedItems(page.getItems());
    info.setNextPage(page.getNextPage());

    return info;
  }

  static async getMoreItems(service: StreamingService, query: SearchQueryHandler,
    page: Page): Promise<InfoItemsPage<InfoItem>> {
    return service.getSearchExtractor(query).getPage(page);
  }

  getSearchString(): string {
    return this.searchString;
  }

  getSearchSuggestion(): string {
    return this.searchSuggestion;
  }

  getIsCorrectedSearch(): boolean {
    return this.isCorrectedSearch;
  }

  setIsCorrectedSearch(isCorrectedSearch: boolean): void {
    this.isCorrectedSearch = isCorrectedSearch;
  }

  setSearchSuggestion(searchSuggestion: string): void {
    this.searchSuggestion = searchSuggestion;
  }

  getMetaInfo(): MetaInfo[] {
    return this.metaInfo;
  }

  setMetaInfo(metaInfo: MetaInfo[]): void {
    this.metaInfo = metaInfo;
  }
}
