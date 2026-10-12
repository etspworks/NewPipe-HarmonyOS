/*
 * Port of org.schabi.newpipe.extractor.services.peertube.linkHandler
 * .PeertubeStreamLinkHandlerFactory (NewPipeExtractor v0.26.5).
 */

import { url as ohosUrl } from '@kit.ArkTS';
import { LinkHandlerFactory } from '../../../linkhandler/LinkHandlerFactory';
import { Parser } from '../../../core/Parser';
import { getPeertubeBaseUrl } from '../PeertubeInstanceState';

// we exclude p/ because /w/p/ is a playlist, not a video
const ID_PATTERN: RegExp = new RegExp('(/w/|(/videos/(watch/|embed/)?))(?!p/)([^/?&#]*)');

/** Instance-relative: the PeerTube API is always `<instance>/api/v1/...`. */
export const VIDEO_API_ENDPOINT: string = '/api/v1/videos/';

// From PeerTube 3.3.0, the default path is /w/.
// We still use /videos/watch/ for compatibility reasons:
// /videos/watch/ is still accepted by >=3.3.0 but /w/ isn't by <3.3.0
const VIDEO_PATH: string = '/videos/watch/';

export class PeertubeStreamLinkHandlerFactory extends LinkHandlerFactory {
  private static readonly INSTANCE: PeertubeStreamLinkHandlerFactory =
    new PeertubeStreamLinkHandlerFactory();

  private constructor() {
    super();
  }

  static getInstance(): PeertubeStreamLinkHandlerFactory {
    return PeertubeStreamLinkHandlerFactory.INSTANCE;
  }

  getUrl(id: string, baseUrl: string | null = null): string {
    return (baseUrl === null ? getPeertubeBaseUrl() : baseUrl) + VIDEO_PATH + id;
  }

  getId(streamUrl: string): string {
    return Parser.matchGroup(ID_PATTERN, streamUrl, 4);
  }

  onAcceptUrl(streamUrl: string): boolean {
    if (streamUrl.includes('/playlist/')) {
      return false;
    }
    try {
      const parsed: ohosUrl.URL = new ohosUrl.URL(streamUrl);
      if (parsed.protocol.length === 0) {
        return false;
      }
      this.getId(streamUrl);
      return true;
    } catch (e) {
      return false;
    }
  }
}
