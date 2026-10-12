/*
 * Port of org.schabi.newpipe.extractor.services.bandcamp.linkHandler
 * .BandcampSearchQueryHandlerFactory (NewPipeExtractor v0.26.5).
 * Created by Fynn Godau 2019, GPL v3 or later.
 */

import { SearchQueryHandlerFactory } from '../../../linkhandler/LinkHandlerFactory';
import { encodeUrlUtf8 } from '../../../core/Utils';
import { BASE_URL } from '../extractors/BandcampExtractorHelper';

export class BandcampSearchQueryHandlerFactory extends SearchQueryHandlerFactory {
  private static readonly INSTANCE: BandcampSearchQueryHandlerFactory =
    new BandcampSearchQueryHandlerFactory();

  static getInstance(): BandcampSearchQueryHandlerFactory {
    return BandcampSearchQueryHandlerFactory.INSTANCE;
  }

  getUrlWithFilters(query: string, contentFilter: string[], sortFilter: string,
    baseUrl: string | null = null): string {
    return BASE_URL + '/search?q=' + encodeUrlUtf8(query) + '&page=1';
  }
}
