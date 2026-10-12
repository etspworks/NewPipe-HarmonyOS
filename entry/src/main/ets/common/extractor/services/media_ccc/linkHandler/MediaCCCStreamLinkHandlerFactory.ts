/*
 * Port of org.schabi.newpipe.extractor.services.media_ccc.linkHandler
 * .MediaCCCStreamLinkHandlerFactory (NewPipeExtractor v0.26.5).
 *
 * Three hosts, and they are not interchangeable (phase2-logic-contract.md §3):
 * api.media.ccc.de serves the JSON, media.ccc.de the web pages, streaming.media.ccc.de the live
 * streams.
 */

import { LinkHandlerFactory } from '../../../linkhandler/LinkHandlerFactory';
import { Parser, RegexException } from '../../../core/Parser';
import { isLiveStreamId } from '../MediaCCCParsingHelper';

export const VIDEO_API_ENDPOINT: string = 'https://api.media.ccc.de/public/events/';
const VIDEO_PATH: string = 'https://media.ccc.de/v/';
const RECORDING_ID_PATTERN: RegExp =
  new RegExp('(?:(?:(?:api\\.)?media\\.ccc\\.de/public/events/)|(?:media\\.ccc\\.de/v/))([^/?&#]*)');
const LIVE_STREAM_PATH: string = 'https://streaming.media.ccc.de/';
const LIVE_STREAM_ID_PATTERN: RegExp = new RegExp('streaming\\.media\\.ccc\\.de\\/(\\w+\\/\\w+)');

export class MediaCCCStreamLinkHandlerFactory extends LinkHandlerFactory {
  private static readonly INSTANCE: MediaCCCStreamLinkHandlerFactory =
    new MediaCCCStreamLinkHandlerFactory();

  private constructor() {
    super();
  }

  static getInstance(): MediaCCCStreamLinkHandlerFactory {
    return MediaCCCStreamLinkHandlerFactory.INSTANCE;
  }

  getId(streamUrl: string): string {
    let streamId: string | null = null;
    try {
      streamId = Parser.matchGroup1(LIVE_STREAM_ID_PATTERN, streamUrl);
    } catch (e) {
      if (!(e instanceof RegexException)) {
        throw e;
      }
    }

    if (streamId === null) {
      return Parser.matchGroup1(RECORDING_ID_PATTERN, streamUrl);
    }
    return streamId;
  }

  getUrl(id: string, baseUrl: string | null = null): string {
    if (isLiveStreamId(id)) {
      return LIVE_STREAM_PATH + id;
    }
    return VIDEO_PATH + id;
  }

  onAcceptUrl(streamUrl: string): boolean {
    try {
      this.getId(streamUrl);
      return true;
    } catch (e) {
      return false;
    }
  }
}
