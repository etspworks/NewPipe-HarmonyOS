/*
 * Port of org.schabi.newpipe.extractor.services.media_ccc.linkHandler
 * .MediaCCCConferenceLinkHandlerFactory (NewPipeExtractor v0.26.5).
 *
 * Since MediaCCC does not really have channel tabs (i.e. it only has one single "tab" with
 * videos), this link handler acts both as the channel link handler and the channel tab link
 * handler. That's why getAvailableContentFilter() has been overridden.
 *
 * The JSON lives on api.media.ccc.de; the bare media.ccc.de host serves the web site
 * (phase2-logic-contract.md §3).
 */

import { ListLinkHandlerFactory } from '../../../linkhandler/LinkHandlerFactory';
import { ChannelTabs } from '../../../info/ChannelTabExtractor';
import { Parser } from '../../../core/Parser';

export const CONFERENCE_API_ENDPOINT: string = 'https://api.media.ccc.de/public/conferences/';
export const CONFERENCE_PATH: string = 'https://media.ccc.de/c/';
const ID_PATTERN: RegExp = new RegExp('(?:(?:(?:api\\.)?media\\.ccc\\.de/public/conferences/)'
  + '|(?:media\\.ccc\\.de/[bc]/))([^/?&#]*)');

export class MediaCCCConferenceLinkHandlerFactory extends ListLinkHandlerFactory {
  private static readonly INSTANCE: MediaCCCConferenceLinkHandlerFactory =
    new MediaCCCConferenceLinkHandlerFactory();

  private constructor() {
    super();
  }

  static getInstance(): MediaCCCConferenceLinkHandlerFactory {
    return MediaCCCConferenceLinkHandlerFactory.INSTANCE;
  }

  getUrlWithFilters(id: string, contentFilter: string[], sortFilter: string,
    baseUrl: string | null): string {
    return CONFERENCE_PATH + id;
  }

  getId(conferenceUrl: string): string {
    return Parser.matchGroup1(ID_PATTERN, conferenceUrl);
  }

  onAcceptUrl(conferenceUrl: string): boolean {
    try {
      this.getId(conferenceUrl);
      return true;
    } catch (e) {
      return false;
    }
  }

  /** MediaCCC's only channel "tab", i.e. ChannelTabs.VIDEOS. */
  getAvailableContentFilter(): string[] {
    return [ChannelTabs.VIDEOS];
  }
}
