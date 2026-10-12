/*
 * Port of org.schabi.newpipe.extractor.services.youtube.linkHandler
 * .YoutubeCommentsLinkHandlerFactory (NewPipeExtractor v0.26.5).
 */

import { ListLinkHandlerFactory } from '../../../linkhandler/LinkHandlerFactory';
import { FoundAdException, ParsingException } from '../../../exceptions/Exceptions';
import { YoutubeStreamLinkHandlerFactory } from './YoutubeStreamLinkHandlerFactory';

export class YoutubeCommentsLinkHandlerFactory extends ListLinkHandlerFactory {
  private static instance: YoutubeCommentsLinkHandlerFactory | null = null;

  static getInstance(): YoutubeCommentsLinkHandlerFactory {
    let current: YoutubeCommentsLinkHandlerFactory | null =
      YoutubeCommentsLinkHandlerFactory.instance;
    if (current === null) {
      current = new YoutubeCommentsLinkHandlerFactory();
      YoutubeCommentsLinkHandlerFactory.instance = current;
    }
    return current;
  }

  getUrlWithFilters(id: string, contentFilter: string[], sortFilter: string,
    baseUrl: string | null): string {
    return 'https://www.youtube.com/watch?v=' + id;
  }

  /** The same id as the stream factory produces: comments belong to a video. */
  getId(urlString: string): string {
    return YoutubeStreamLinkHandlerFactory.getInstance().getId(urlString);
  }

  onAcceptUrl(url: string): boolean {
    try {
      this.getId(url);
      return true;
    } catch (e) {
      if (e instanceof FoundAdException) {
        throw e;
      }
      if (e instanceof ParsingException) {
        return false;
      }
      throw e;
    }
  }
}
