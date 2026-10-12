/*
 * Port of org.schabi.newpipe.extractor.search.SearchExtractor (NewPipeExtractor v0.26.5).
 */

import { InfoItem } from '../core/InfoItem';
import { ListExtractor } from '../core/ListExtractor';
import { StreamingService } from '../core/StreamingService';
import { ExtractionException } from '../exceptions/Exceptions';
import { SearchQueryHandler } from '../linkhandler/LinkHandler';
import { MetaInfo } from '../../../model/extractor/MetaInfo';

export class NothingFoundException extends ExtractionException {
  constructor(message: string) {
    super(message);
    this.name = 'NothingFoundException';
  }
}

export abstract class SearchExtractor extends ListExtractor<InfoItem> {
  constructor(service: StreamingService, linkHandler: SearchQueryHandler) {
    super(service, linkHandler);
  }

  getSearchString(): string {
    return this.getLinkHandler().getSearchString();
  }

  /** The service's "did you mean ..." suggestion, or an empty string. */
  abstract getSearchSuggestion(): string;

  getLinkHandler(): SearchQueryHandler {
    return super.getLinkHandler() as SearchQueryHandler;
  }

  getName(): string {
    return this.getLinkHandler().getSearchString();
  }

  /** Whether the service already corrected the query and searched for something else. */
  abstract isCorrectedSearch(): boolean;

  abstract getMetaInfo(): MetaInfo[];
}
