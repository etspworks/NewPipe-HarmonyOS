/*
 * Port of org.schabi.newpipe.extractor.Info (NewPipeExtractor v0.26.5).
 *
 * ArkTS has no overloading, so the Info(serviceId, LinkHandler, name) convenience constructor is
 * gone: a subclass expands it into the five explicit values, as the source's own constructor did.
 */

import { ExtractionException } from '../exceptions/Exceptions';
import { ExtractorLogger } from './ExtractorLogger';
import { NewPipe } from './NewPipe';
import { StreamingService } from './StreamingService';

const TAG: string = 'Info';

export abstract class Info {
  private readonly serviceId: number;
  /** e.g. Youtube: `https://www.youtube.com/watch?v=RER5qCTzZ7` -> `RER5qCTzZ7`. */
  private readonly id: string;
  /** May be a cleaned url, unlike originalUrl. */
  private readonly url: string;
  /** The url the extraction of this Info was started with. */
  private originalUrl: string;
  private readonly name: string;

  private readonly errors: Error[] = [];

  constructor(serviceId: number, id: string, url: string, originalUrl: string, name: string) {
    this.serviceId = serviceId;
    this.id = id;
    this.url = url;
    this.originalUrl = originalUrl;
    this.name = name;
    ExtractorLogger.d(TAG, 'Base Created {}', [this]);
  }

  addError(throwable: Error): void {
    this.errors.push(throwable);
  }

  addAllErrors(throwables: Error[]): void {
    for (const throwable of throwables) {
      this.errors.push(throwable);
    }
  }

  toString(): string {
    const ifDifferentString: string = this.url === this.originalUrl
      ? '' : ` (originalUrl="${this.originalUrl}")`;
    return `${this.constructor.name}[url="${this.url}"${ifDifferentString}, `
      + `name="${this.name}"]`;
  }

  /** If you use an api and want to handle the website url, overriding the original url matters. */
  setOriginalUrl(originalUrl: string): void {
    this.originalUrl = originalUrl;
  }

  getServiceId(): number {
    return this.serviceId;
  }

  getService(): StreamingService {
    try {
      return NewPipe.getService(this.serviceId);
    } catch (e) {
      // this should be unreachable, as serviceId certainly refers to a valid service
      throw new ExtractionException('Info object has invalid service id',
        e instanceof Error ? e as Error : null);
    }
  }

  getId(): string {
    return this.id;
  }

  getUrl(): string {
    return this.url;
  }

  getOriginalUrl(): string {
    return this.originalUrl;
  }

  getName(): string {
    return this.name;
  }

  getErrors(): Error[] {
    return this.errors;
  }
}
