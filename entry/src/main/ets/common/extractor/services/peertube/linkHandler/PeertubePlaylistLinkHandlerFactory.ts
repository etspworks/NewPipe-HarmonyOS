/*
 * Port of org.schabi.newpipe.extractor.services.peertube.linkHandler
 * .PeertubePlaylistLinkHandlerFactory (NewPipeExtractor v0.26.5).
 */

import { url as ohosUrl } from '@kit.ArkTS';
import { ListLinkHandlerFactory } from '../../../linkhandler/LinkHandlerFactory';
import { Parser } from '../../../core/Parser';
import { ParsingException } from '../../../exceptions/Exceptions';
import { getPeertubeBaseUrl } from '../PeertubeInstanceState';

const ID_PATTERN: RegExp = new RegExp('(/videos/watch/playlist/|/w/p/)([^/?&#]*)');
const API_ID_PATTERN: RegExp = new RegExp('/video-playlists/([^/?&#]*)');

export class PeertubePlaylistLinkHandlerFactory extends ListLinkHandlerFactory {
  private static readonly INSTANCE: PeertubePlaylistLinkHandlerFactory =
    new PeertubePlaylistLinkHandlerFactory();

  private constructor() {
    super();
  }

  static getInstance(): PeertubePlaylistLinkHandlerFactory {
    return PeertubePlaylistLinkHandlerFactory.INSTANCE;
  }

  getUrlWithFilters(id: string, contentFilters: string[], sortFilter: string,
    baseUrl: string | null): string {
    return (baseUrl === null ? getPeertubeBaseUrl() : baseUrl) + '/api/v1/video-playlists/' + id;
  }

  getId(playlistUrl: string): string {
    try {
      return Parser.matchGroup(ID_PATTERN, playlistUrl, 2);
    } catch (e) {
      if (!(e instanceof ParsingException)) {
        throw e;
      }
      // might also be an API url, no reason to throw an exception here
    }
    return Parser.matchGroup1(API_ID_PATTERN, playlistUrl);
  }

  onAcceptUrl(playlistUrl: string): boolean {
    try {
      const parsed: ohosUrl.URL = new ohosUrl.URL(playlistUrl);
      if (parsed.protocol.length === 0) {
        return false;
      }
      this.getId(playlistUrl);
      return true;
    } catch (e) {
      return false;
    }
  }
}
