/*
 * Port of org.schabi.newpipe.extractor.ListExtractor.InfoItemsPage (NewPipeExtractor v0.26.5).
 *
 * One page of gathered items, the errors raised while gathering them, and the pointer to the next
 * page. Nested inside ListExtractor in Java; a top-level module here, because ArkTS has no nested
 * classes and the plan gives it its own model file.
 */

import { InfoItem } from '../../common/extractor/core/InfoItem';
import { InfoItemExtractor, InfoItemsCollector } from '../../common/extractor/core/Collector';
import { Page } from './Page';

export class InfoItemsPage<T extends InfoItem> {
  /** The current list of items of this page. */
  private readonly itemsList: T[];
  /** Url pointing to the next page relative to this one. */
  private readonly nextPage: Page | null;
  /** Errors that happened during the extraction. */
  private readonly errors: Error[];

  constructor(itemsList: T[], nextPage: Page | null, errors: Error[]) {
    this.itemsList = itemsList;
    this.nextPage = nextPage;
    this.errors = errors;
  }

  /** Port of the InfoItemsPage(InfoItemsCollector, Page) constructor. */
  static fromCollector<T extends InfoItem, E extends InfoItemExtractor>(
    collector: InfoItemsCollector<T, E>, nextPage: Page | null): InfoItemsPage<T> {
    return new InfoItemsPage<T>(collector.getItems(), nextPage, collector.getErrors());
  }

  /** An empty page: no items, no errors, no next page. */
  static emptyPage<T extends InfoItem>(): InfoItemsPage<T> {
    return new InfoItemsPage<T>([], null, []);
  }

  hasNextPage(): boolean {
    return Page.isValid(this.nextPage);
  }

  getItems(): T[] {
    return this.itemsList;
  }

  /** The next page if available, or null otherwise. */
  getNextPage(): Page | null {
    return this.nextPage;
  }

  getErrors(): Error[] {
    return this.errors;
  }
}
