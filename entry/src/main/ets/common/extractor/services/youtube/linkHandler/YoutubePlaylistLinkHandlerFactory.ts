/*
 * Port of org.schabi.newpipe.extractor.services.youtube.linkHandler
 * .YoutubePlaylistLinkHandlerFactory (NewPipeExtractor v0.26.5).
 *
 * The source overrides `fromUrl(String)`; here that list-returning form is `fromUrlAsList`
 * (the wave-B rename, since ArkTS cannot narrow a base method's return type).
 */

import { ListLinkHandlerFactory } from '../../../linkhandler/LinkHandlerFactory';
import { LinkHandler, ListLinkHandler } from '../../../linkhandler/LinkHandler';
import { ParsingException } from '../../../exceptions/Exceptions';
import { getQueryValue, isHTTP, stringToURL } from '../../../core/Utils';
import {
  extractVideoIdFromMixId,
  isInvidiousURL,
  isYoutubeMixId,
  isYoutubeURL
} from '../YoutubeParsingHelper';
import { url as ohosUrl } from '@kit.ArkTS';

export class YoutubePlaylistLinkHandlerFactory extends ListLinkHandlerFactory {
  private static instance: YoutubePlaylistLinkHandlerFactory | null = null;

  static getInstance(): YoutubePlaylistLinkHandlerFactory {
    let current: YoutubePlaylistLinkHandlerFactory | null =
      YoutubePlaylistLinkHandlerFactory.instance;
    if (current === null) {
      current = new YoutubePlaylistLinkHandlerFactory();
      YoutubePlaylistLinkHandlerFactory.instance = current;
    }
    return current;
  }

  getUrlWithFilters(id: string, contentFilters: string[], sortFilter: string,
    baseUrl: string | null): string {
    return 'https://www.youtube.com/playlist?list=' + id;
  }

  getId(url: string): string {
    try {
      const urlObj: ohosUrl.URL = stringToURL(url);

      if (!isHTTP(urlObj) || !(isYoutubeURL(urlObj) || isInvidiousURL(urlObj))) {
        throw new ParsingException('the url given is not a YouTube-URL');
      }

      const path: string = urlObj.pathname;
      if (path !== '/watch' && path !== '/playlist') {
        throw new ParsingException('the url given is neither a video nor a playlist URL');
      }

      const listID: string | null = getQueryValue(urlObj, 'list');
      if (listID === null) {
        throw new ParsingException('the URL given does not include a playlist');
      }
      if (!new RegExp('^[a-zA-Z0-9_-]{10,}$').test(listID)) {
        throw new ParsingException(
          'the list-ID given in the URL does not match the list pattern');
      }
      return listID;
    } catch (exception) {
      const message: string =
        exception instanceof Error ? (exception as Error).message : `${exception}`;
      throw new ParsingException('Error could not parse URL: ' + message,
        exception instanceof Error ? exception as Error : null);
    }
  }

  onAcceptUrl(url: string): boolean {
    try {
      this.getId(url);
    } catch (e) {
      return false;
    }
    return true;
  }

  /**
   * For a mix (auto-generated playlist) url, return a handler whose url is
   * `https://youtube.com/watch?v=videoId&list=playlistId`; otherwise defer to the base.
   */
  fromUrlAsList(url: string, baseUrl: string | null = null): ListLinkHandler {
    try {
      const urlObj: ohosUrl.URL = stringToURL(url);
      const listID: string | null = getQueryValue(urlObj, 'list');
      if (listID !== null && isYoutubeMixId(listID)) {
        let videoID: string | null = getQueryValue(urlObj, 'v');
        if (videoID === null) {
          videoID = extractVideoIdFromMixId(listID);
        }
        const newUrl: string = 'https://www.youtube.com/watch?v=' + videoID + '&list=' + listID;
        return ListLinkHandler.fromLinkHandler(new LinkHandler(url, newUrl, listID));
      }
    } catch (exception) {
      if (exception instanceof ParsingException) {
        throw exception;
      }
      const message: string =
        exception instanceof Error ? (exception as Error).message : `${exception}`;
      throw new ParsingException('Error could not parse URL: ' + message,
        exception instanceof Error ? exception as Error : null);
    }
    return super.fromUrlAsList(url, baseUrl);
  }
}
