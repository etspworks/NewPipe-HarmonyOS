/*
 * Port of org.schabi.newpipe.extractor.linkhandler.{LinkHandlerFactory, ListLinkHandlerFactory,
 * SearchQueryHandlerFactory} (NewPipeExtractor v0.26.5).
 *
 * ArkTS has no overloading and no covariant return types, so:
 *  - `fromUrl(url)` / `fromUrl(url, baseUrl)` collapse into one method with a default baseUrl of
 *    null, meaning "derive it from the url", which is exactly what the one-argument overload did;
 *  - the same for `fromId` and `getUrl`;
 *  - the list factories return the wider handler from their own `*AsList` / `*AsSearch` names,
 *    because a subclass cannot narrow the base method's return type.
 * The per-service factories (wave C) extend these.
 */

import { ParsingException } from '../exceptions/Exceptions';
import { followGoogleRedirectIfNeeded, getBaseUrl, isNullOrEmpty } from '../core/Utils';
import { LinkHandler, ListLinkHandler, SearchQueryHandler } from './LinkHandler';

export abstract class LinkHandlerFactory {
  abstract getId(url: string): string;

  /** `baseUrl` is null when the caller has none, which is the source's one-argument overload. */
  abstract getUrl(id: string, baseUrl: string | null): string;

  abstract onAcceptUrl(url: string): boolean;

  fromUrl(url: string, baseUrl: string | null = null): LinkHandler {
    if (isNullOrEmpty(url)) {
      throw new Error('The url is null or empty');
    }
    const polishedUrl: string = followGoogleRedirectIfNeeded(url);
    const resolvedBaseUrl: string = baseUrl === null ? getBaseUrl(polishedUrl) : baseUrl;
    if (!this.acceptUrl(polishedUrl)) {
      throw new ParsingException('URL not accepted: ' + polishedUrl);
    }
    const id: string = this.getId(polishedUrl);
    return new LinkHandler(polishedUrl, this.getUrl(id, resolvedBaseUrl), id);
  }

  fromId(id: string, baseUrl: string | null = null): LinkHandler {
    const url: string = this.getUrl(id, baseUrl);
    return new LinkHandler(url, url, id);
  }

  acceptUrl(url: string): boolean {
    return this.onAcceptUrl(url);
  }
}

export abstract class ListLinkHandlerFactory extends LinkHandlerFactory {
  /** The list form of getUrl: the source's abstract (id, contentFilter, sortFilter[, baseUrl]). */
  abstract getUrlWithFilters(id: string, contentFilter: string[], sortFilter: string,
    baseUrl: string | null): string;

  getUrl(id: string, baseUrl: string | null = null): string {
    return this.getUrlWithFilters(id, [], '', baseUrl);
  }

  fromUrlAsList(url: string, baseUrl: string | null = null): ListLinkHandler {
    return ListLinkHandler.fromLinkHandler(super.fromUrl(url, baseUrl));
  }

  fromIdAsList(id: string, baseUrl: string | null = null): ListLinkHandler {
    return ListLinkHandler.fromLinkHandler(super.fromId(id, baseUrl));
  }

  fromQuery(id: string, contentFilters: string[], sortFilter: string,
    baseUrl: string | null = null): ListLinkHandler {
    const url: string = this.getUrlWithFilters(id, contentFilters, sortFilter, baseUrl);
    return new ListLinkHandler(url, url, id, contentFilters, sortFilter);
  }

  getAvailableContentFilter(): string[] {
    return [];
  }

  getAvailableSortFilter(): string[] {
    return [];
  }
}

export abstract class SearchQueryHandlerFactory extends ListLinkHandlerFactory {
  getSearchString(url: string): string {
    return '';
  }

  getId(url: string): string {
    return this.getSearchString(url);
  }

  fromSearchQuery(query: string, contentFilter: string[] = [],
    sortFilter: string = ''): SearchQueryHandler {
    return SearchQueryHandler.fromListLinkHandler(
      this.fromQuery(query, contentFilter, sortFilter, null));
  }

  onAcceptUrl(url: string): boolean {
    return false;
  }
}
