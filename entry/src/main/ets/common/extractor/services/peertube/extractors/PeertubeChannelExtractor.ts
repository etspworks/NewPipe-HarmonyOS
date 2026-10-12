/*
 * Port of org.schabi.newpipe.extractor.services.peertube.extractors.PeertubeChannelExtractor
 * (NewPipeExtractor v0.26.5).
 */

import { ChannelExtractor } from '../../../info/ChannelExtractor';
import { ChannelTabs } from '../../../info/ChannelTabExtractor';
import { StreamingService } from '../../../core/StreamingService';
import { ListLinkHandler } from '../../../linkhandler/LinkHandler';
import { Downloader, Response } from '../../../downloader/Downloader';
import { JsonObject, JsonParser } from '../../../json/NanoJson';
import { JsonUtils } from '../../../core/JsonUtils';
import { toError } from '../../../core/Errors';
import { ExtractionException } from '../../../exceptions/Exceptions';
import { Image } from '../../../../../model/extractor/Image';
import {
  getAvatarsFromOwnerAccountOrVideoChannelObject,
  getBannersFromAccountOrVideoChannelObject,
  nonNullString
} from '../PeertubeParsingHelper';
import { API_ENDPOINT } from '../linkHandler/PeertubeChannelLinkHandlerFactory';
import {
  PeertubeChannelTabLinkHandlerFactory
} from '../linkHandler/PeertubeChannelTabLinkHandlerFactory';

export class PeertubeChannelExtractor extends ChannelExtractor {
  private json: JsonObject = new JsonObject();
  private readonly baseUrl: string;

  constructor(service: StreamingService, linkHandler: ListLinkHandler) {
    super(service, linkHandler);
    this.baseUrl = this.getBaseUrl();
  }

  getAvatars(): Image[] {
    return getAvatarsFromOwnerAccountOrVideoChannelObject(this.baseUrl, this.json);
  }

  getBanners(): Image[] {
    return getBannersFromAccountOrVideoChannelObject(this.baseUrl, this.json);
  }

  /** The source concatenates the raw `id` value; PeerTube channel ids are numeric. */
  getFeedUrl(): string | null {
    return this.getBaseUrl() + '/feeds/videos.xml?videoChannelId=' + this.json.getLong('id');
  }

  getSubscriberCount(): number {
    return this.json.getLong('followersCount');
  }

  getDescription(): string {
    return nonNullString(this.json.getString('description'));
  }

  getParentChannelName(): string {
    return JsonUtils.getString(this.json, 'ownerAccount.name');
  }

  getParentChannelUrl(): string {
    return JsonUtils.getString(this.json, 'ownerAccount.url');
  }

  getParentChannelAvatars(): Image[] {
    return getAvatarsFromOwnerAccountOrVideoChannelObject(this.baseUrl,
      this.json.getObject('ownerAccount'));
  }

  isVerified(): boolean {
    return false;
  }

  getTabs(): ListLinkHandler[] {
    return [
      PeertubeChannelTabLinkHandlerFactory.getInstance().fromQuery(this.getId(),
        [ChannelTabs.VIDEOS], '', this.getBaseUrl()),
      PeertubeChannelTabLinkHandlerFactory.getInstance().fromQuery(this.getId(),
        [ChannelTabs.PLAYLISTS], '', this.getBaseUrl())
    ];
  }

  async onFetchPage(downloader: Downloader): Promise<void> {
    const response: Response = await downloader.get(this.baseUrl + API_ENDPOINT + this.getId());
    this.setInitialData(response.responseBody());
  }

  private setInitialData(responseBody: string): void {
    try {
      this.json = JsonParser.object().from(responseBody);
    } catch (e) {
      throw new ExtractionException('Unable to extract PeerTube channel data', toError(e));
    }
  }

  getName(): string {
    return JsonUtils.getString(this.json, 'displayName');
  }
}
