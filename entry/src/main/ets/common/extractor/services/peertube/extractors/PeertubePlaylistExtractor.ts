/*
 * Port of org.schabi.newpipe.extractor.services.peertube.extractors.PeertubePlaylistExtractor
 * (NewPipeExtractor v0.26.5).
 */

import { PlaylistExtractor } from '../../../info/PlaylistExtractor';
import { StreamingService } from '../../../core/StreamingService';
import { ListLinkHandler } from '../../../linkhandler/LinkHandler';
import { Downloader, Response } from '../../../downloader/Downloader';
import { JsonObject, JsonParser } from '../../../json/NanoJson';
import { isBlank, isNullOrEmpty } from '../../../core/Utils';
import { toError } from '../../../core/Errors';
import { ExtractionException, ParsingException } from '../../../exceptions/Exceptions';
import { StreamInfoItemsCollector } from '../../../info/StreamInfoItemsCollector';
import { Image } from '../../../../../model/extractor/Image';
import { Description, DESCRIPTION_PLAIN_TEXT } from '../../../../../model/extractor/Description';
import { InfoItemsPage } from '../../../../../model/extractor/ListExtractorInfoItemsPage';
import { Page } from '../../../../../model/extractor/Page';
import { StreamInfoItem } from '../../../../../model/extractor/StreamInfoItem';
import {
  COUNT_KEY,
  getAvatarsFromOwnerAccountOrVideoChannelObject,
  getNextPage,
  getThumbnailsFromPlaylistOrVideoItem,
  ITEMS_PER_PAGE,
  nonNullString,
  START_KEY,
  validate
} from '../PeertubeParsingHelper';
import { collectStreamItemsFrom } from '../PeertubeItemCollector';

export class PeertubePlaylistExtractor extends PlaylistExtractor {
  private playlistInfo: JsonObject = new JsonObject();

  constructor(service: StreamingService, linkHandler: ListLinkHandler) {
    super(service, linkHandler);
  }

  getThumbnails(): Image[] {
    return getThumbnailsFromPlaylistOrVideoItem(this.getBaseUrl(), this.playlistInfo);
  }

  getUploaderUrl(): string {
    return nonNullString(this.playlistInfo.getObject('ownerAccount').getString('url'));
  }

  getUploaderName(): string {
    return nonNullString(this.playlistInfo.getObject('ownerAccount').getString('displayName'));
  }

  getUploaderAvatars(): Image[] {
    return getAvatarsFromOwnerAccountOrVideoChannelObject(this.getBaseUrl(),
      this.playlistInfo.getObject('ownerAccount'));
  }

  isUploaderVerified(): boolean {
    return false;
  }

  getStreamCount(): number {
    return this.playlistInfo.getLong('videosLength');
  }

  getDescription(): Description {
    const description: string | null = this.playlistInfo.getString('description');
    if (isNullOrEmpty(description)) {
      return Description.EMPTY_DESCRIPTION;
    }
    return new Description(description, DESCRIPTION_PLAIN_TEXT);
  }

  getSubChannelName(): string {
    return nonNullString(this.playlistInfo.getObject('videoChannel').getString('displayName'));
  }

  getSubChannelUrl(): string {
    return nonNullString(this.playlistInfo.getObject('videoChannel').getString('url'));
  }

  getSubChannelAvatars(): Image[] {
    return getAvatarsFromOwnerAccountOrVideoChannelObject(this.getBaseUrl(),
      this.playlistInfo.getObject('videoChannel'));
  }

  async getInitialPage(): Promise<InfoItemsPage<StreamInfoItem>> {
    return this.getPage(new Page(this.getUrl() + '/videos?' + START_KEY + '=0&'
      + COUNT_KEY + '=' + ITEMS_PER_PAGE));
  }

  async getPage(page: Page): Promise<InfoItemsPage<StreamInfoItem>> {
    const pageUrl: string | null = page === null ? null : page.getUrl();
    if (isNullOrEmpty(pageUrl)) {
      throw new Error("Page doesn't contain an URL");
    }

    const response: Response = await this.getDownloader().get(pageUrl as string);

    let json: JsonObject | null = null;
    if (!isBlank(response.responseBody())) {
      try {
        json = JsonParser.object().from(response.responseBody());
      } catch (e) {
        throw new ParsingException('Could not parse json data for playlist info', toError(e));
      }
    }

    if (json !== null) {
      validate(json);
      const total: number = json.getLong('total');

      const collector: StreamInfoItemsCollector =
        new StreamInfoItemsCollector(this.getServiceId());
      collectStreamItemsFrom(collector, json, this.getBaseUrl());

      return InfoItemsPage.fromCollector(collector, getNextPage(pageUrl as string, total));
    }
    throw new ExtractionException('Unable to get PeerTube playlist info');
  }

  async onFetchPage(downloader: Downloader): Promise<void> {
    const response: Response = await downloader.get(this.getUrl());
    try {
      this.playlistInfo = JsonParser.object().from(response.responseBody());
    } catch (e) {
      throw new ExtractionException('Could not parse json', toError(e));
    }
    validate(this.playlistInfo);
  }

  getName(): string {
    return nonNullString(this.playlistInfo.getString('displayName'));
  }
}
