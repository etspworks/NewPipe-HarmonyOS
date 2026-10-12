/*
 * Port of org.schabi.newpipe.extractor.{Collector, InfoItemExtractor, InfoItemsCollector}
 * (NewPipeExtractor v0.26.5).
 *
 * A collector turns per-item extractors into info items, keeping the parsing errors instead of
 * throwing them away: one bad row must not lose the whole page.
 */

import { Image } from '../../../model/extractor/Image';
import { FoundAdException, ParsingException } from '../exceptions/Exceptions';
import { InfoItem } from './InfoItem';

export interface Collector<I, E> {
  commit(extractor: E): void;

  extract(extractor: E): I;

  getItems(): I[];

  getErrors(): Error[];

  reset(): void;
}

/**
 * An abstract class rather than the source's interface: ArkTS interfaces cannot carry the
 * default method bodies the four sub-interfaces below it rely on, and every implementation in
 * the source has this as its only supertype.
 */
export abstract class InfoItemExtractor {
  abstract getName(): string;

  abstract getUrl(): string;

  abstract getThumbnails(): Image[];
}

export abstract class InfoItemsCollector<I extends InfoItem, E extends InfoItemExtractor>
implements Collector<I, E> {
  private readonly itemList: I[] = [];
  private readonly errors: Error[] = [];
  private readonly serviceId: number;
  private readonly comparator: ((a: I, b: I) => number) | null;

  constructor(serviceId: number, comparator: ((a: I, b: I) => number) | null = null) {
    this.serviceId = serviceId;
    this.comparator = comparator;
  }

  abstract extract(extractor: E): I;

  getItems(): I[] {
    if (this.comparator !== null) {
      this.itemList.sort(this.comparator);
    }
    return this.itemList;
  }

  getErrors(): Error[] {
    return this.errors;
  }

  reset(): void {
    this.itemList.length = 0;
    this.errors.length = 0;
  }

  protected addError(error: Error): void {
    this.errors.push(error);
  }

  protected addItem(item: I): void {
    this.itemList.push(item);
  }

  getServiceId(): number {
    return this.serviceId;
  }

  commit(extractor: E): void {
    try {
      this.addItem(this.extract(extractor));
    } catch (e) {
      if (e instanceof FoundAdException) {
        // found an ad. Maybe a debug line could be placed here
        return;
      }
      if (e instanceof ParsingException) {
        this.addError(e as ParsingException);
        return;
      }
      throw e;
    }
  }
}
