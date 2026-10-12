/*
 * Port of org.schabi.newpipe.extractor.services.peertube.linkHandler
 * .PeertubeTrendingLinkHandlerFactory (NewPipeExtractor v0.26.5).
 */

import { url as ohosUrl } from '@kit.ArkTS';
import { ListLinkHandlerFactory } from '../../../linkhandler/LinkHandlerFactory';
import { ParsingException } from '../../../exceptions/Exceptions';
import { getPeertubeBaseUrl } from '../PeertubeInstanceState';

export const KIOSK_TRENDING: string = 'Trending';
export const KIOSK_MOST_LIKED: string = 'Most liked';
export const KIOSK_RECENT: string = 'Recently added';
export const KIOSK_LOCAL: string = 'Local';

/** `%s` is the instance base url; the paths are instance-relative. */
export const KIOSK_MAP: Map<string, string> = new Map<string, string>([
  [KIOSK_TRENDING, '%s/api/v1/videos?sort=-trending'],
  [KIOSK_MOST_LIKED, '%s/api/v1/videos?sort=-likes'],
  [KIOSK_RECENT, '%s/api/v1/videos?sort=-publishedAt'],
  [KIOSK_LOCAL, '%s/api/v1/videos?sort=-publishedAt&isLocal=true']
]);

export class PeertubeTrendingLinkHandlerFactory extends ListLinkHandlerFactory {
  private static readonly INSTANCE: PeertubeTrendingLinkHandlerFactory =
    new PeertubeTrendingLinkHandlerFactory();

  private constructor() {
    super();
  }

  static getInstance(): PeertubeTrendingLinkHandlerFactory {
    return PeertubeTrendingLinkHandlerFactory.INSTANCE;
  }

  getUrlWithFilters(id: string, contentFilters: string[], sortFilter: string,
    baseUrl: string | null): string {
    const template: string | undefined = KIOSK_MAP.get(id);
    if (template === undefined) {
      throw new ParsingException('no kiosk found with the id: ' + id);
    }
    return template.replace('%s', baseUrl === null ? getPeertubeBaseUrl() : baseUrl);
  }

  getId(kioskUrl: string): string {
    // Java's String.replace() replaces every occurrence, which split/join reproduces.
    const cleanUrl: string = kioskUrl.split(getPeertubeBaseUrl()).join('%s');
    if (cleanUrl.includes('/videos/trending')) {
      return KIOSK_TRENDING;
    } else if (cleanUrl.includes('/videos/most-liked')) {
      return KIOSK_MOST_LIKED;
    } else if (cleanUrl.includes('/videos/recently-added')) {
      return KIOSK_RECENT;
    } else if (cleanUrl.includes('/videos/local')) {
      return KIOSK_LOCAL;
    }
    for (const entry of KIOSK_MAP.entries()) {
      if (cleanUrl === entry[1]) {
        return entry[0];
      }
    }
    throw new ParsingException('no id found for this url');
  }

  onAcceptUrl(kioskUrl: string): boolean {
    try {
      const parsed: ohosUrl.URL = new ohosUrl.URL(kioskUrl);
      if (parsed.protocol.length === 0) {
        return false;
      }
      return kioskUrl.includes('/videos?') || kioskUrl.includes('/videos/trending')
        || kioskUrl.includes('/videos/most-liked') || kioskUrl.includes('/videos/recently-added')
        || kioskUrl.includes('/videos/local');
    } catch (e) {
      return false;
    }
  }
}
