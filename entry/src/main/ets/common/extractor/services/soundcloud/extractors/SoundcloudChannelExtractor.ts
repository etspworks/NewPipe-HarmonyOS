/*
 * Port of org.schabi.newpipe.extractor.services.soundcloud.extractors.SoundcloudChannelExtractor
 * (NewPipeExtractor v0.26.5).
 */

import { Image } from '../../../../../model/extractor/Image';
import { ChannelExtractor } from '../../../info/ChannelExtractor';
import { ChannelTabs } from '../../../info/ChannelTabExtractor';
import { StreamingService } from '../../../core/StreamingService';
import { ParsingException } from '../../../exceptions/Exceptions';
import { ListLinkHandler } from '../../../linkhandler/LinkHandler';
import { Downloader } from '../../../downloader/Downloader';
import { JsonObject, JsonParser } from '../../../json/NanoJson';
import { SOUNDCLOUD_API_V2_URL, SoundcloudParsingHelper } from '../SoundcloudParsingHelper';
import { SoundcloudChannelTabLinkHandlerFactory } from '../linkHandler/SoundcloudChannelTabLinkHandlerFactory';

const USERS_ENDPOINT: string = SOUNDCLOUD_API_V2_URL + 'users/';

export class SoundcloudChannelExtractor extends ChannelExtractor {
  private userId: string = '';
  private user: JsonObject | null = null;

  constructor(service: StreamingService, linkHandler: ListLinkHandler) {
    super(service, linkHandler);
  }

  private requireUser(): JsonObject {
    if (this.user === null) {
      throw new ParsingException('Page is not fetched. Make sure you call fetchPage()');
    }
    return this.user;
  }

  async onFetchPage(downloader: Downloader): Promise<void> {
    this.userId = this.getLinkHandler().getId();
    const apiUrl: string = USERS_ENDPOINT + this.userId + '?client_id='
      + await SoundcloudParsingHelper.clientId();

    const response: string = (await downloader.get(apiUrl, null,
      this.getExtractorLocalization())).responseBody();
    try {
      this.user = JsonParser.object().from(response);
    } catch (e) {
      throw new ParsingException('Could not parse json response',
        e instanceof Error ? e as Error : null);
    }
  }

  getId(): string {
    return this.userId;
  }

  getName(): string {
    const name: string | null = this.requireUser().getString('username');
    return name === null ? '' : name;
  }

  getAvatars(): Image[] {
    return SoundcloudParsingHelper.getAllImagesFromArtworkOrAvatarUrl(
      this.requireUser().getString('avatar_url'));
  }

  getBanners(): Image[] {
    return SoundcloudParsingHelper.getAllImagesFromVisualUrl(
      this.requireUser().getObject('visuals').getArray('visuals').getObject(0)
        .getString('visual_url'));
  }

  getFeedUrl(): string | null {
    return null;
  }

  getSubscriberCount(): number {
    return this.requireUser().getLong('followers_count', 0);
  }

  getDescription(): string {
    const description: string | null = this.requireUser().getString('description', '');
    return description === null ? '' : description;
  }

  getParentChannelName(): string {
    return '';
  }

  getParentChannelUrl(): string {
    return '';
  }

  getParentChannelAvatars(): Image[] {
    return [];
  }

  isVerified(): boolean {
    return this.requireUser().getBoolean('verified');
  }

  getTabs(): ListLinkHandler[] {
    const url: string = this.getUrl();
    const urlTracks: string = url
      + SoundcloudChannelTabLinkHandlerFactory.getUrlSuffix(ChannelTabs.TRACKS);
    const urlPlaylists: string = url
      + SoundcloudChannelTabLinkHandlerFactory.getUrlSuffix(ChannelTabs.PLAYLISTS);
    const urlAlbums: string = url
      + SoundcloudChannelTabLinkHandlerFactory.getUrlSuffix(ChannelTabs.ALBUMS);
    const urlLikes: string = url
      + SoundcloudChannelTabLinkHandlerFactory.getUrlSuffix(ChannelTabs.LIKES);
    const id: string = this.getId();

    return [
      new ListLinkHandler(urlTracks, urlTracks, id, [ChannelTabs.TRACKS], ''),
      new ListLinkHandler(urlPlaylists, urlPlaylists, id, [ChannelTabs.PLAYLISTS], ''),
      new ListLinkHandler(urlAlbums, urlAlbums, id, [ChannelTabs.ALBUMS], ''),
      new ListLinkHandler(urlLikes, urlLikes, id, [ChannelTabs.LIKES], '')
    ];
  }
}
