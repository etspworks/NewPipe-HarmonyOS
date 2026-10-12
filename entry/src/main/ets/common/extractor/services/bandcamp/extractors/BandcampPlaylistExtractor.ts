/*
 * Port of org.schabi.newpipe.extractor.services.bandcamp.extractors.BandcampPlaylistExtractor
 * (NewPipeExtractor v0.26.5).
 */

import {
  Description,
  DESCRIPTION_HTML
} from '../../../../../model/extractor/Description';
import { Image } from '../../../../../model/extractor/Image';
import { InfoItemsPage } from '../../../../../model/extractor/ListExtractorInfoItemsPage';
import { Page } from '../../../../../model/extractor/Page';
import { StreamInfoItem } from '../../../../../model/extractor/StreamInfoItem';
import { JsonUtils } from '../../../core/JsonUtils';
import { StreamingService } from '../../../core/StreamingService';
import { HTTPS } from '../../../core/Utils';
import { Downloader } from '../../../downloader/Downloader';
import { PaidContentException, ParsingException } from '../../../exceptions/Exceptions';
import { Document, Element, Elements, Jsoup } from '../../../html/Jsoup';
import { JsonArray, JsonObject } from '../../../json/NanoJson';
import { ListLinkHandler } from '../../../linkhandler/LinkHandler';
import { PlaylistExtractor } from '../../../info/PlaylistExtractor';
import { StreamInfoItemsCollector } from '../../../info/StreamInfoItemsCollector';
import { BandcampExtractorHelper } from './BandcampExtractorHelper';
import { BandcampStreamExtractor } from './BandcampStreamExtractor';
import { BandcampPlaylistStreamInfoItemExtractor } from './streaminfoitem/BandcampPlaylistStreamInfoItemExtractor';

/**
 * An arbitrarily chosen number above which cover arts won't be fetched individually for each
 * track; instead, it will be assumed that every track has the same cover art as the album,
 * which is not always the case.
 */
const MAXIMUM_INDIVIDUAL_COVER_ARTS: number = 10;

export class BandcampPlaylistExtractor extends PlaylistExtractor {
  private document: Document | null = null;
  private albumJson: JsonObject | null = null;
  private trackInfo: JsonArray | null = null;
  private name: string = '';

  constructor(service: StreamingService, linkHandler: ListLinkHandler) {
    super(service, linkHandler);
  }

  private requireDocument(): Document {
    if (this.document === null) {
      throw new ParsingException('Page is not fetched. Make sure you call fetchPage()');
    }
    return this.document;
  }

  private requireAlbumJson(): JsonObject {
    if (this.albumJson === null) {
      throw new ParsingException('Page is not fetched. Make sure you call fetchPage()');
    }
    return this.albumJson;
  }

  private requireTrackInfo(): JsonArray {
    if (this.trackInfo === null) {
      throw new ParsingException('Page is not fetched. Make sure you call fetchPage()');
    }
    return this.trackInfo;
  }

  async onFetchPage(downloader: Downloader): Promise<void> {
    const html: string = (await downloader.get(this.getLinkHandler().getUrl())).responseBody();
    this.document = Jsoup.parse(html);
    this.albumJson = BandcampStreamExtractor.getAlbumInfoJson(html);
    this.trackInfo = this.albumJson.getArray('trackinfo');

    try {
      const albumTitle: string | null =
        JsonUtils.getJsonData(html, 'data-embed').getString('album_title');
      this.name = albumTitle === null ? '' : albumTitle;
    } catch (e) {
      throw new ParsingException('Faulty JSON; page likely does not contain album data',
        e instanceof Error ? e as Error : null);
    }

    if (this.trackInfo.size() === 0) {
      // Albums without trackInfo need to be purchased before they can be played
      throw new PaidContentException('Album needs to be purchased');
    }
  }

  getThumbnails(): Image[] {
    if (this.requireAlbumJson().isNull('art_id')) {
      return [];
    }
    return BandcampExtractorHelper.getImagesFromImageId(
      this.requireAlbumJson().getLong('art_id'), true);
  }

  getUploaderUrl(): string {
    const parts: string[] = this.getUrl().split('/');
    // https: (/) (/) * .bandcamp.com (/) and leave out the rest - INCLUDING the trailing slash.
    // The track extractor builds each item's url as `getUploaderUrl() + title_link`, and
    // title_link already starts with one, so the extra slash here produced
    // "https://x.bandcamp.com//track/voyage". PlayQueueItem.isSameItem() compares urls verbatim,
    // so the stream the detail page loaded never matched the queue it had just been handed: a
    // ten-item queue collapsed to one, and with it went shuffle, repeat and previous/next.
    return HTTPS + parts[2];
  }

  getUploaderName(): string {
    const artist: string | null = this.requireAlbumJson().getString('artist');
    return artist === null ? '' : artist;
  }

  getUploaderAvatars(): Image[] {
    const photo: Element | null = this.requireDocument().getElementsByClass('band-photo').first();
    return BandcampExtractorHelper.getImagesFromImageUrl(
      photo === null ? '' : photo.attr('src'));
  }

  isUploaderVerified(): boolean {
    return false;
  }

  getStreamCount(): number {
    return this.requireTrackInfo().size();
  }

  getDescription(): Description {
    const tInfo: Element | null = this.requireDocument().getElementById('trackInfo');
    if (tInfo === null) {
      throw new ParsingException('Could not find trackInfo in document');
    }
    const about: Elements = tInfo.getElementsByClass('tralbum-about');
    const credits: Elements = tInfo.getElementsByClass('tralbum-credits');
    const license: Element | null = this.requireDocument().getElementById('license');
    if (about.isEmpty() && credits.isEmpty() && license === null) {
      return Description.EMPTY_DESCRIPTION;
    }
    let sb: string = '';
    const aboutFirst: Element | null = about.first();
    if (aboutFirst !== null) {
      sb += aboutFirst.html();
    }
    const creditsFirst: Element | null = credits.first();
    if (creditsFirst !== null) {
      sb += creditsFirst.html();
    }
    if (license !== null) {
      sb += license.html();
    }
    return new Description(sb, DESCRIPTION_HTML);
  }

  async getInitialPage(): Promise<InfoItemsPage<StreamInfoItem>> {
    const collector: StreamInfoItemsCollector =
      new StreamInfoItemsCollector(this.getServiceId());
    const trackInfo: JsonArray = this.requireTrackInfo();

    for (let i: number = 0; i < trackInfo.size(); i++) {
      const track: JsonObject = trackInfo.getObject(i);

      if (trackInfo.size() < MAXIMUM_INDIVIDUAL_COVER_ARTS) {
        // Load cover art of every track individually
        const extractor: BandcampPlaylistStreamInfoItemExtractor =
          BandcampPlaylistStreamInfoItemExtractor.withService(track, this.getUploaderUrl(),
            this.getService());
        await extractor.resolveThumbnails();
        collector.commit(extractor);
      } else {
        // Pretend every track has the same cover art as the album
        collector.commit(BandcampPlaylistStreamInfoItemExtractor.withSubstituteCovers(track,
          this.getUploaderUrl(), this.getThumbnails()));
      }
    }

    return InfoItemsPage.fromCollector(collector, null);
  }

  /** The source returns null here; the ported signature is non-nullable, so: an empty page. */
  async getPage(page: Page): Promise<InfoItemsPage<StreamInfoItem>> {
    return InfoItemsPage.emptyPage<StreamInfoItem>();
  }

  getName(): string {
    return this.name;
  }
}
