/*
 * Port of org.schabi.newpipe.extractor.services.media_ccc.linkHandler
 * .MediaCCCLiveListLinkHandlerFactory (NewPipeExtractor v0.26.5).
 */

import { ListLinkHandlerFactory } from '../../../linkhandler/LinkHandlerFactory';

const STREAM_PATTERN: RegExp = new RegExp('^(?:https?://)?media\\.ccc\\.de/live$');

export class MediaCCCLiveListLinkHandlerFactory extends ListLinkHandlerFactory {
  private static readonly INSTANCE: MediaCCCLiveListLinkHandlerFactory =
    new MediaCCCLiveListLinkHandlerFactory();

  private constructor() {
    super();
  }

  static getInstance(): MediaCCCLiveListLinkHandlerFactory {
    return MediaCCCLiveListLinkHandlerFactory.INSTANCE;
  }

  getId(liveUrl: string): string {
    return 'live';
  }

  onAcceptUrl(liveUrl: string): boolean {
    STREAM_PATTERN.lastIndex = 0;
    return STREAM_PATTERN.test(liveUrl);
  }

  getUrlWithFilters(id: string, contentFilter: string[], sortFilter: string,
    baseUrl: string | null): string {
    // FIXME: wrong URL; should be https://streaming.media.ccc.de/{conference_slug}/{room_slug}
    // (verbatim from the source — the kiosk works because the live-stream list is fetched from
    // https://streaming.media.ccc.de/streams/v2.json, not from this url)
    return 'https://media.ccc.de/live';
  }
}
