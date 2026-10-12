/*
 * Port of org.schabi.newpipe.extractor.services.bandcamp.extractors.BandcampFeaturedExtractor
 * (NewPipeExtractor v0.26.5). Created by Fynn Godau 2019, GPL v3 or later.
 */

import { InfoItemsPage } from '../../../../../model/extractor/ListExtractorInfoItemsPage';
import { Page } from '../../../../../model/extractor/Page';
import { PlaylistInfoItem } from '../../../../../model/extractor/PlaylistInfoItem';
import { KioskExtractor } from '../../../info/KioskList';
import { PlaylistInfoItemsCollector } from '../../../info/PlaylistExtractor';
import { StreamingService } from '../../../core/StreamingService';
import { Downloader, Request } from '../../../downloader/Downloader';
import { ParsingException } from '../../../exceptions/Exceptions';
import { JsonArray, JsonObject, JsonParser } from '../../../json/NanoJson';
import { ListLinkHandler } from '../../../linkhandler/LinkHandler';
import { BASE_API_URL } from './BandcampExtractorHelper';
import { BandcampPlaylistInfoItemFeaturedExtractor } from './BandcampPlaylistInfoItemFeaturedExtractor';

export const KIOSK_FEATURED: string = 'Featured';
/** Bandcamp's mobile bootstrap feed - a path suffix onto the one API base, not its own host. */
export const FEATURED_API_URL: string = BASE_API_URL + '/mobile/24/bootstrap_data';
export const MORE_FEATURED_API_URL: string = BASE_API_URL + '/mobile/24/feed_older_logged_out';

export class BandcampFeaturedExtractor extends KioskExtractor<PlaylistInfoItem> {
  private json: JsonObject | null = null;

  constructor(streamingService: StreamingService, listLinkHandler: ListLinkHandler,
    kioskId: string) {
    super(streamingService, listLinkHandler, kioskId);
  }

  async onFetchPage(downloader: Downloader): Promise<void> {
    try {
      this.json = JsonParser.object().from(
        (await this.getDownloader().postWithContentTypeJson(FEATURED_API_URL,
          new Map<string, string[]>(),
          Request.utf8Body('{"platform":"","version":0}'))).responseBody());
    } catch (e) {
      throw new ParsingException('Could not parse Bandcamp featured API response',
        e instanceof Error ? e as Error : null);
    }
  }

  getName(): string {
    return KIOSK_FEATURED;
  }

  async getInitialPage(): Promise<InfoItemsPage<PlaylistInfoItem>> {
    if (this.json === null) {
      throw new ParsingException('Page is not fetched. Make sure you call fetchPage()');
    }
    const featuredStories: JsonArray = this.json.getObject('feed_content')
      .getObject('stories')
      .getArray('featured');

    return this.extractItems(featuredStories);
  }

  private extractItems(featuredStories: JsonArray): InfoItemsPage<PlaylistInfoItem> {
    const c: PlaylistInfoItemsCollector =
      new PlaylistInfoItemsCollector(this.getServiceId());

    for (let i: number = 0; i < featuredStories.size(); i++) {
      const featuredStory: JsonObject = featuredStories.getObject(i);

      if (featuredStory.isNull('album_title')) {
        // Is not an album, ignore
        continue;
      }

      c.commit(new BandcampPlaylistInfoItemFeaturedExtractor(featuredStory));
    }

    const lastFeaturedStory: JsonObject =
      featuredStories.getObject(featuredStories.size() - 1);
    return InfoItemsPage.fromCollector(c,
      BandcampFeaturedExtractor.getNextPageFrom(lastFeaturedStory));
  }

  /** The next page is generated from the metadata of the last featured story. */
  private static getNextPageFrom(lastFeaturedStory: JsonObject): Page {
    const lastStoryDate: number = lastFeaturedStory.getLong('story_date');
    const lastStoryId: number = lastFeaturedStory.getLong('ntid');
    const lastStoryType: string | null = lastFeaturedStory.getString('story_type');
    return new Page(MORE_FEATURED_API_URL + '?story_groups=featured'
      + ':' + lastStoryDate + ':' + lastStoryType + ':' + lastStoryId);
  }

  async getPage(page: Page): Promise<InfoItemsPage<PlaylistInfoItem>> {
    let response: JsonObject;
    try {
      const url: string | null = page.getUrl();
      response = JsonParser.object().from(
        (await this.getDownloader().get(url === null ? '' : url)).responseBody());
    } catch (e) {
      throw new ParsingException('Could not parse Bandcamp featured API response',
        e instanceof Error ? e as Error : null);
    }

    return this.extractItems(response.getObject('stories').getArray('featured'));
  }
}
