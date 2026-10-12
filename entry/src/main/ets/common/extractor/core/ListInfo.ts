/*
 * Port of org.schabi.newpipe.extractor.ListInfo (NewPipeExtractor v0.26.5).
 *
 * ArkTS has no overloading, so the (serviceId, ListLinkHandler, name) constructor is expanded by
 * each subclass into the seven explicit values.
 */

import { Page } from '../../../model/extractor/Page';
import { Info } from './Info';
import { InfoItem } from './InfoItem';

export abstract class ListInfo<T extends InfoItem> extends Info {
  relatedItems: T[] = [];
  nextPage: Page | null = null;
  readonly contentFilters: string[];
  readonly sortFilter: string;

  constructor(serviceId: number, id: string, url: string, originalUrl: string, name: string,
    contentFilter: string[], sortFilter: string) {
    super(serviceId, id, url, originalUrl, name);
    this.contentFilters = contentFilter;
    this.sortFilter = sortFilter;
  }

  getRelatedItems(): T[] {
    return this.relatedItems;
  }

  setRelatedItems(relatedItems: T[]): void {
    this.relatedItems = relatedItems;
  }

  hasNextPage(): boolean {
    return Page.isValid(this.nextPage);
  }

  getNextPage(): Page | null {
    return this.nextPage;
  }

  setNextPage(page: Page | null): void {
    this.nextPage = page;
  }

  getContentFilters(): string[] {
    return this.contentFilters;
  }

  getSortFilter(): string {
    return this.sortFilter;
  }
}
