/*
 * Port of org.schabi.newpipe.extractor.subscription.{SubscriptionExtractor, SubscriptionItem}
 * (NewPipeExtractor v0.26.5).
 *
 * Importing subscriptions from a channel url does I/O, so that one is a Promise; the
 * InputStream overloads become one method taking the file's text plus its content type, since
 * ArkTS has no InputStream and the importer reads the picked file itself.
 */

import { util } from '@kit.ArkTS';
import { StreamingService } from '../core/StreamingService';
import { ParsingException } from '../exceptions/Exceptions';

export class InvalidSourceException extends ParsingException {
  constructor(detailMessage: string | null = null, cause: Error | null = null) {
    super('Not a valid source' + (detailMessage === null ? '' : ' (' + detailMessage + ')'),
      cause);
    this.name = 'InvalidSourceException';
  }
}

export enum ContentSource {
  CHANNEL_URL,
  INPUT_STREAM
}

export class SubscriptionItem {
  readonly serviceId: number;
  readonly url: string;
  readonly name: string;

  constructor(serviceId: number, url: string, name: string) {
    this.serviceId = serviceId;
    this.url = url;
    this.name = name;
  }

  getServiceId(): number {
    return this.serviceId;
  }

  getUrl(): string {
    return this.url;
  }

  getName(): string {
    return this.name;
  }

  toString(): string {
    return 'SubscriptionItem[name=' + this.name + ' > ' + this.serviceId + ':' + this.url + ']';
  }
}

export abstract class SubscriptionExtractor {
  private readonly supportedSources: ContentSource[];
  protected readonly service: StreamingService;

  constructor(service: StreamingService, supportedSources: ContentSource[]) {
    this.service = service;
    this.supportedSources = supportedSources;
  }

  getSupportedSources(): ContentSource[] {
    return this.supportedSources;
  }

  /** Where the user gets the subscription list from, shown in the import screen. */
  abstract getRelatedUrl(): string | null;

  async fromChannelUrl(channelUrl: string): Promise<SubscriptionItem[]> {
    throw new Error('Service ' + this.service.getServiceInfo().getName()
      + ' doesn\'t support extracting from a channel url');
  }

  /**
   * The source's two fromInputStream overloads, collapsed: the picked file's CONTENT plus its
   * content type. ArkTS has no InputStream, so the importer reads the file itself and passes
   * either its text or — for a binary export such as a Google Takeout ZIP — its raw bytes.
   *
   * @param tempDir a sandbox directory an implementation may use for scratch files (unzipping);
   *                empty when the caller has none, in which case a binary format is refused
   *                rather than mishandled.
   */
  async fromFileContent(content: string | ArrayBuffer, contentType: string = '',
    tempDir: string = ''): Promise<SubscriptionItem[]> {
    throw new Error('Service ' + this.service.getServiceInfo().getName()
      + ' doesn\'t support extracting from an InputStream');
  }
}

/** Decodes a picked file's bytes as UTF-8; a string passes straight through. */
export function subscriptionContentAsText(content: string | ArrayBuffer): string {
  if (typeof content === 'string') {
    return content as string;
  }
  return util.TextDecoder.create('utf-8').decodeToString(new Uint8Array(content as ArrayBuffer));
}
