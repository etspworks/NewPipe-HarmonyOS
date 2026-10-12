/*
 * Port of org.schabi.newpipe.extractor.services.bandcamp.extractors.BandcampChannelExtractor
 * (NewPipeExtractor v0.26.5). Created by Fynn Godau 2019, GPL v3 or later.
 *
 * ArkTS deviation: the source's getBanners() downloads the artist page inside a synchronous
 * getter. The ported ChannelExtractor.getBanners() is synchronous too, so that page is fetched
 * once in onFetchPage() and the banners are built from it here.
 */

import { Image } from '../../../../../model/extractor/Image';
import { ResolutionLevel } from '../../../../../model/enums/ImageResolutionLevel';
import { ChannelExtractor } from '../../../info/ChannelExtractor';
import { ChannelTabExtractor, ChannelTabs } from '../../../info/ChannelTabExtractor';
import { StreamingService } from '../../../core/StreamingService';
import { replaceHttpWithHttps } from '../../../core/Utils';
import { Downloader } from '../../../downloader/Downloader';
import { ParsingException } from '../../../exceptions/Exceptions';
import { Element, Jsoup } from '../../../html/Jsoup';
import { ListLinkHandler } from '../../../linkhandler/LinkHandler';
import {
  ChannelTabExtractorBuilder,
  ReadyChannelTabListLinkHandler
} from '../../../linkhandler/ReadyChannelTabListLinkHandler';
import { JsonArray, JsonObject } from '../../../json/NanoJson';
import { BandcampExtractorHelper } from './BandcampExtractorHelper';
import { BandcampChannelTabExtractor } from './BandcampChannelTabExtractor';
import { BandcampChannelTabLinkHandlerFactory } from '../linkHandler/BandcampChannelTabLinkHandlerFactory';

class TabExtractorBuilder implements ChannelTabExtractorBuilder {
  private readonly discography: JsonArray;

  constructor(discography: JsonArray) {
    this.discography = discography;
  }

  build(service: StreamingService, linkHandler: ListLinkHandler): ChannelTabExtractor {
    return BandcampChannelTabExtractor.fromDiscography(service, linkHandler, this.discography);
  }
}

export class BandcampChannelExtractor extends ChannelExtractor {
  private channelInfo: JsonObject | null = null;
  private banners: Image[] = [];

  constructor(service: StreamingService, linkHandler: ListLinkHandler) {
    super(service, linkHandler);
  }

  private requireChannelInfo(): JsonObject {
    if (this.channelInfo === null) {
      throw new ParsingException('Page is not fetched. Make sure you call fetchPage()');
    }
    return this.channelInfo;
  }

  async onFetchPage(downloader: Downloader): Promise<void> {
    this.channelInfo = await BandcampExtractorHelper.resolveArtistDetails(this.getId());

    /*
     * Mobile API does not return the header or not the correct header.
     * Therefore, we need to query the website.
     */
    try {
      const bandcampUrl: string | null =
        replaceHttpWithHttps(this.channelInfo.getString('bandcamp_url'));
      const html: string =
        (await downloader.get(bandcampUrl === null ? '' : bandcampUrl)).responseBody();

      const banners: Image[] = [];
      const customHeader: Element | null = Jsoup.parse(html).getElementById('customHeader');
      if (customHeader !== null) {
        for (const img of customHeader.getElementsByTag('img').toArray()) {
          const src: string = img.attr('src');
          if (src.length > 0) {
            const https: string | null = replaceHttpWithHttps(src);
            banners.push(new Image(https === null ? src : https, Image.HEIGHT_UNKNOWN,
              Image.WIDTH_UNKNOWN, ResolutionLevel.UNKNOWN));
          }
        }
      }
      this.banners = banners;
    } catch (e) {
      throw new ParsingException('Could not download artist web site',
        e instanceof Error ? e as Error : null);
    }
  }

  getAvatars(): Image[] {
    return BandcampExtractorHelper.getImagesFromImageId(
      this.requireChannelInfo().getLong('bio_image_id'), false);
  }

  getBanners(): Image[] {
    return this.banners;
  }

  /** Bandcamp discontinued their RSS feeds because it hadn't been used enough. */
  getFeedUrl(): string | null {
    return null;
  }

  getSubscriberCount(): number {
    return -1;
  }

  getDescription(): string {
    const bio: string | null = this.requireChannelInfo().getString('bio');
    return bio === null ? '' : bio;
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
    return false;
  }

  getTabs(): ListLinkHandler[] {
    const discography: JsonArray = this.requireChannelInfo().getArray('discography');
    const builder: TabExtractorBuilder = new TabExtractorBuilder(discography);

    const tabs: ListLinkHandler[] = [];

    let foundTrackItem: boolean = false;
    let foundAlbumItem: boolean = false;

    for (const discographyJsonItem of discography.streamAsJsonObjects()) {
      if (foundTrackItem && foundAlbumItem) {
        break;
      }

      const itemType: string | null = discographyJsonItem.getString('item_type');

      if (!foundTrackItem && itemType === 'track') {
        foundTrackItem = true;
        tabs.push(new ReadyChannelTabListLinkHandler(this.getUrl()
          + BandcampChannelTabLinkHandlerFactory.getUrlSuffix(ChannelTabs.TRACKS),
          this.getId(), ChannelTabs.TRACKS, builder));
      }

      if (!foundAlbumItem && itemType === 'album') {
        foundAlbumItem = true;
        tabs.push(new ReadyChannelTabListLinkHandler(this.getUrl()
          + BandcampChannelTabLinkHandlerFactory.getUrlSuffix(ChannelTabs.ALBUMS),
          this.getId(), ChannelTabs.ALBUMS, builder));
      }
    }

    return tabs;
  }

  getName(): string {
    const name: string | null = this.requireChannelInfo().getString('name');
    return name === null ? '' : name;
  }
}
