/*
 * Port of org.schabi.newpipe.extractor.linkhandler.LinkHandler, ListLinkHandler and
 * SearchQueryHandler (NewPipeExtractor v0.26.5).
 *
 * The url <-> id mapping every deep link, share url and getChannelTab() call goes through. The
 * three classes live in one module because ListLinkHandler and SearchQueryHandler are copy
 * constructors over LinkHandler's own fields, which ArkTS cannot express across files without
 * making those fields public.
 */

import { getBaseUrl } from '../core/Utils';

export class LinkHandler {
  protected readonly originalUrl: string;
  protected readonly url: string;
  protected readonly id: string;

  constructor(originalUrl: string, url: string, id: string) {
    this.originalUrl = originalUrl;
    this.url = url;
    this.id = id;
  }

  getOriginalUrl(): string {
    return this.originalUrl;
  }

  getUrl(): string {
    return this.url;
  }

  getId(): string {
    return this.id;
  }

  getBaseUrl(): string {
    return getBaseUrl(this.url);
  }
}

export class ListLinkHandler extends LinkHandler {
  protected readonly contentFilters: string[];
  protected readonly sortFilter: string;

  constructor(originalUrl: string, url: string, id: string, contentFilters: string[],
    sortFilter: string) {
    super(originalUrl, url, id);
    this.contentFilters = contentFilters;
    this.sortFilter = sortFilter;
  }

  /** Port of the ListLinkHandler(LinkHandler) constructor: no filters, empty sort filter. */
  static fromLinkHandler(handler: LinkHandler): ListLinkHandler {
    return new ListLinkHandler(handler.getOriginalUrl(), handler.getUrl(), handler.getId(),
      [], '');
  }

  /** Port of the ListLinkHandler(ListLinkHandler) copy constructor. */
  static copyOf(handler: ListLinkHandler): ListLinkHandler {
    return new ListLinkHandler(handler.getOriginalUrl(), handler.getUrl(), handler.getId(),
      handler.getContentFilters(), handler.getSortFilter());
  }

  getContentFilters(): string[] {
    return this.contentFilters;
  }

  getSortFilter(): string {
    return this.sortFilter;
  }
}

export class SearchQueryHandler extends ListLinkHandler {
  constructor(originalUrl: string, url: string, searchString: string, contentFilters: string[],
    sortFilter: string) {
    super(originalUrl, url, searchString, contentFilters, sortFilter);
  }

  /** Port of the SearchQueryHandler(ListLinkHandler) constructor. */
  static fromListLinkHandler(handler: ListLinkHandler): SearchQueryHandler {
    return new SearchQueryHandler(handler.getOriginalUrl(), handler.getUrl(), handler.getId(),
      handler.getContentFilters(), handler.getSortFilter());
  }

  getSearchString(): string {
    return this.getId();
  }
}
