/*
 * Port of org.schabi.newpipe.extractor.services.peertube.linkHandler
 * .PeertubeChannelLinkHandlerFactory (NewPipeExtractor v0.26.5).
 */

import { url as ohosUrl } from '@kit.ArkTS';
import { ListLinkHandlerFactory } from '../../../linkhandler/LinkHandlerFactory';
import { Parser } from '../../../core/Parser';
import { getPeertubeBaseUrl } from '../PeertubeInstanceState';

/** Java's `id.matches(ID_PATTERN)` is a FULL match, so the ArkTS RegExp is anchored. */
const ID_PATTERN: RegExp = new RegExp('^((accounts|a)|(video-channels|c))/([^/?&#]*)$');
const ID_URL_PATTERN: RegExp = new RegExp('/((accounts|a)|(video-channels|c))/([^/?&#]*)');

/** Instance-relative API root; the base url is whichever instance the user picked. */
export const API_ENDPOINT: string = '/api/v1/';

/** Fix duplicates of `/a/` and `/c/`, the short forms of accounts and video-channels. */
function fixId(id: string): string {
  const cleanedId: string = id.startsWith('/') ? id.substring(1) : id;
  if (cleanedId.startsWith('a/')) {
    return 'accounts' + cleanedId.substring(1);
  } else if (cleanedId.startsWith('c/')) {
    return 'video-channels' + cleanedId.substring(1);
  }
  return cleanedId;
}

export class PeertubeChannelLinkHandlerFactory extends ListLinkHandlerFactory {
  private static readonly INSTANCE: PeertubeChannelLinkHandlerFactory =
    new PeertubeChannelLinkHandlerFactory();

  private constructor() {
    super();
  }

  static getInstance(): PeertubeChannelLinkHandlerFactory {
    return PeertubeChannelLinkHandlerFactory.INSTANCE;
  }

  getId(channelUrl: string): string {
    return fixId(Parser.matchGroup(ID_URL_PATTERN, channelUrl, 0));
  }

  getUrlWithFilters(id: string, contentFilter: string[], sortFilter: string,
    baseUrl: string | null): string {
    const resolvedBaseUrl: string = baseUrl === null ? getPeertubeBaseUrl() : baseUrl;
    if (Parser.isMatch(ID_PATTERN, id)) {
      return resolvedBaseUrl + '/' + fixId(id);
    }
    // This is needed for compatibility with older versions where we didn't support
    // video channels yet
    return resolvedBaseUrl + '/accounts/' + id;
  }

  onAcceptUrl(channelUrl: string): boolean {
    try {
      const parsed: ohosUrl.URL = new ohosUrl.URL(channelUrl);
      if (parsed.protocol.length === 0) {
        return false;
      }
      return channelUrl.includes('/accounts/') || channelUrl.includes('/a/')
        || channelUrl.includes('/video-channels/') || channelUrl.includes('/c/');
    } catch (e) {
      return false;
    }
  }
}
