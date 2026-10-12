/*
 * Port of org.schabi.newpipe.extractor.services.peertube.linkHandler
 * .PeertubeCommentsLinkHandlerFactory (NewPipeExtractor v0.26.5).
 */

import { url as ohosUrl } from '@kit.ArkTS';
import { ListLinkHandlerFactory } from '../../../linkhandler/LinkHandlerFactory';
import { getPeertubeBaseUrl } from '../PeertubeInstanceState';
import { PeertubeStreamLinkHandlerFactory } from './PeertubeStreamLinkHandlerFactory';

/** Instance-relative; `%s` is the video id, exactly as in the source's String.format. */
const COMMENTS_ENDPOINT: string = '/api/v1/videos/%s/comment-threads';

export class PeertubeCommentsLinkHandlerFactory extends ListLinkHandlerFactory {
  private static readonly INSTANCE: PeertubeCommentsLinkHandlerFactory =
    new PeertubeCommentsLinkHandlerFactory();

  private constructor() {
    super();
  }

  static getInstance(): PeertubeCommentsLinkHandlerFactory {
    return PeertubeCommentsLinkHandlerFactory.INSTANCE;
  }

  getId(commentsUrl: string): string {
    // the same id is needed
    return PeertubeStreamLinkHandlerFactory.getInstance().getId(commentsUrl);
  }

  onAcceptUrl(commentsUrl: string): boolean {
    try {
      const parsed: ohosUrl.URL = new ohosUrl.URL(commentsUrl);
      if (parsed.protocol.length === 0) {
        return false;
      }
      return commentsUrl.includes('/videos/') || commentsUrl.includes('/w/');
    } catch (e) {
      return false;
    }
  }

  getUrlWithFilters(id: string, contentFilter: string[], sortFilter: string,
    baseUrl: string | null): string {
    return (baseUrl === null ? getPeertubeBaseUrl() : baseUrl)
      + COMMENTS_ENDPOINT.replace('%s', id);
  }
}
