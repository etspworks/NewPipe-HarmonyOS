/*
 * Port of org.schabi.newpipe.extractor.kiosk.{KioskExtractor, KioskList}
 * (NewPipeExtractor v0.26.5).
 *
 * A kiosk is a service's own ready-made list (YouTube Trending, SoundCloud Charts). Building one
 * can do I/O in the factory, so every getExtractor* is a Promise.
 */

import { InfoItem } from '../core/InfoItem';
import { ListExtractor } from '../core/ListExtractor';
import { NewPipe } from '../core/NewPipe';
import { StreamingService } from '../core/StreamingService';
import { isNullOrEmpty } from '../core/Utils';
import { ExtractionException } from '../exceptions/Exceptions';
import { ListLinkHandler } from '../linkhandler/LinkHandler';
import { ListLinkHandlerFactory } from '../linkhandler/LinkHandlerFactory';
import { ContentCountry } from '../localization/ContentCountry';
import { Localization } from '../downloader/Localization';
import { Page } from '../../../model/extractor/Page';

export abstract class KioskExtractor<T extends InfoItem> extends ListExtractor<T> {
  private readonly kioskId: string;

  constructor(streamingService: StreamingService, linkHandler: ListLinkHandler, kioskId: string) {
    super(streamingService, linkHandler);
    this.kioskId = kioskId;
  }

  getId(): string {
    return this.kioskId;
  }

  abstract getName(): string;
}

/** Builds one kiosk extractor; the factory itself may fetch, hence the Promise. */
export interface KioskExtractorFactory {
  createNewKiosk(streamingService: StreamingService, url: string,
    kioskId: string): Promise<KioskExtractor<InfoItem>>;
}

/**
 * The order Java's `HashMap.keySet()` walks string keys in - which is the order the source's
 * `KioskList` (a HashMap) hands its kiosks out, and so the order every NewPipe drawer lists them.
 * A JS Map keeps INSERTION order instead, so the port's drawer listed the kiosks as the service
 * registered them: YouTube read Live, Trending podcasts, Gaming trends... where the reference reads
 * Gaming trends, Trending music, Trending movies and shows, Trending podcasts, Trending, Live.
 *
 * HashMap: hash = String.hashCode() ^ (h >>> 16); bucket = hash & (capacity - 1); capacity starts
 * at 16 and doubles once size exceeds 0.75 of it; a bucket keeps its keys in insertion order, and
 * a resize split keeps that relative order. Pure, so it is checked without a device.
 */
export function javaHashMapKeyOrder(keys: string[]): string[] {
  let capacity: number = 16;
  while (keys.length > capacity * 0.75) {
    capacity *= 2;
  }
  const buckets: string[][] = [];
  for (let i = 0; i < capacity; i++) {
    buckets.push([]);
  }
  for (const key of keys) {
    let h: number = 0;
    for (let i = 0; i < key.length; i++) {
      h = (Math.imul(31, h) + key.charCodeAt(i)) | 0;
    }
    h = h ^ (h >>> 16);
    buckets[h & (capacity - 1)].push(key);
  }
  const ordered: string[] = [];
  for (const bucket of buckets) {
    ordered.push(...bucket);
  }
  return ordered;
}

class KioskEntry {
  readonly extractorFactory: KioskExtractorFactory;
  readonly handlerFactory: ListLinkHandlerFactory;

  constructor(ef: KioskExtractorFactory, h: ListLinkHandlerFactory) {
    this.extractorFactory = ef;
    this.handlerFactory = h;
  }
}

export class KioskList {
  private readonly service: StreamingService;
  private readonly kioskList: Map<string, KioskEntry> = new Map<string, KioskEntry>();
  private defaultKiosk: string | null = null;
  private forcedLocalization: Localization | null = null;
  private forcedContentCountry: ContentCountry | null = null;

  constructor(service: StreamingService) {
    this.service = service;
  }

  addKioskEntry(extractorFactory: KioskExtractorFactory, handlerFactory: ListLinkHandlerFactory,
    id: string): void {
    if (this.kioskList.get(id) !== undefined) {
      throw new Error('Kiosk with type ' + id + ' already exists.');
    }
    this.kioskList.set(id, new KioskEntry(extractorFactory, handlerFactory));
  }

  setDefaultKiosk(kioskType: string): void {
    this.defaultKiosk = kioskType;
  }

  async getDefaultKioskExtractor(nextPage: Page | null = null,
    localization: Localization = NewPipe.getPreferredLocalization()):
    Promise<KioskExtractor<InfoItem> | null> {
    if (!isNullOrEmpty(this.defaultKiosk)) {
      return this.getExtractorById(this.defaultKiosk as string, nextPage, localization);
    }
    const keys: string[] = this.getAvailableKiosks();
    if (keys.length > 0) {
      // if not set get any entry
      return this.getExtractorById(keys[0], nextPage, localization);
    }
    return null;
  }

  getDefaultKioskId(): string | null {
    return this.defaultKiosk;
  }

  async getExtractorById(kioskId: string, nextPage: Page | null,
    localization: Localization = NewPipe.getPreferredLocalization()):
    Promise<KioskExtractor<InfoItem>> {
    const ke: KioskEntry | undefined = this.kioskList.get(kioskId);
    if (ke === undefined) {
      throw new ExtractionException('No kiosk found with the type: ' + kioskId);
    }
    const kioskExtractor: KioskExtractor<InfoItem> = await ke.extractorFactory.createNewKiosk(
      this.service, ke.handlerFactory.fromIdAsList(kioskId).getUrl(), kioskId);
    if (this.forcedLocalization !== null) {
      kioskExtractor.forceLocalization(this.forcedLocalization);
    }
    if (this.forcedContentCountry !== null) {
      kioskExtractor.forceContentCountry(this.forcedContentCountry);
    }
    return kioskExtractor;
  }

  /** kioskList.keySet(): in HashMap order, not registration order - see javaHashMapKeyOrder(). */
  getAvailableKiosks(): string[] {
    return javaHashMapKeyOrder(Array.from(this.kioskList.keys()));
  }

  async getExtractorByUrl(url: string, nextPage: Page | null,
    localization: Localization = NewPipe.getPreferredLocalization()):
    Promise<KioskExtractor<InfoItem>> {
    for (const ke of this.kioskList.values()) {
      if (ke.handlerFactory.acceptUrl(url)) {
        return this.getExtractorById(ke.handlerFactory.getId(url), nextPage, localization);
      }
    }
    throw new ExtractionException('Could not find a kiosk that fits to the url: ' + url);
  }

  getListLinkHandlerFactoryByType(type: string): ListLinkHandlerFactory {
    const entry: KioskEntry | undefined = this.kioskList.get(type);
    if (entry === undefined) {
      throw new ExtractionException('No kiosk found with the type: ' + type);
    }
    return entry.handlerFactory;
  }

  forceLocalization(localization: Localization | null): void {
    this.forcedLocalization = localization;
  }

  forceContentCountry(contentCountry: ContentCountry | null): void {
    this.forcedContentCountry = contentCountry;
  }
}
