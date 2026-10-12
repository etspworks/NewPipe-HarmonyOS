/*
 * Port of org.schabi.newpipe.extractor.services.youtube.extractors.YoutubeMusicSearchExtractor
 * (NewPipeExtractor v0.26.5).
 *
 * YouTube Music search runs against a different host (music.youtube.com) with the WEB_REMIX
 * client, and its `params` values are opaque protobuf filters — verbatim from the source.
 */

import {
  JsonArray,
  JsonObject,
  JsonParser,
  JsonStringWriter,
  JsonWriter
} from '../../../json/NanoJson';
import { Downloader, Request } from '../../../downloader/Downloader';
import { StreamingService } from '../../../core/StreamingService';
import { InfoItem } from '../../../core/InfoItem';
import { JsonUtils } from '../../../core/JsonUtils';
import { NewPipe } from '../../../core/NewPipe';
import { SearchExtractor } from '../../../info/SearchExtractor';
import { SearchQueryHandler } from '../../../linkhandler/LinkHandler';
import { ExtractionException, ParsingException } from '../../../exceptions/Exceptions';
import { isNullOrEmpty } from '../../../core/Utils';
import { InfoItemsPage } from '../../../../../model/extractor/ListExtractorInfoItemsPage';
import { MetaInfo } from '../../../../../model/extractor/MetaInfo';
import { Page } from '../../../../../model/extractor/Page';
import { MultiInfoItemsCollector } from '../../../core/MultiInfoItemsCollector';
import {
  DISABLE_PRETTY_PRINT_PARAMETER,
  YOUTUBE_MUSIC_INNERTUBE_URL,
  getTextFromObject,
  getValidJsonResponseBody,
  getYoutubeMusicClientVersion,
  getYoutubeMusicHeaders
} from '../YoutubeParsingHelper';
import {
  MUSIC_ALBUMS,
  MUSIC_ARTISTS,
  MUSIC_PLAYLISTS,
  MUSIC_SONGS,
  MUSIC_VIDEOS
} from '../linkHandler/YoutubeSearchQueryHandlerFactory';
import {
  YoutubeMusicAlbumOrPlaylistInfoItemExtractor,
  YoutubeMusicArtistInfoItemExtractor,
  YoutubeMusicSongOrVideoInfoItemExtractor
} from './YoutubeMusicInfoItemExtractors';

function getDownloader(): Downloader {
  const downloader: Downloader | null = NewPipe.getDownloader();
  if (downloader === null) {
    throw new ExtractionException('Downloader is not initialised');
  }
  return downloader;
}

/** The opaque protobuf `params` filter for one music search type; verbatim from the source. */
function musicSearchParams(contentFilter: string): string | null {
  if (contentFilter === MUSIC_SONGS) {
    return 'Eg-KAQwIARAAGAAgACgAMABqChAEEAUQAxAKEAk%3D';
  }
  if (contentFilter === MUSIC_VIDEOS) {
    return 'Eg-KAQwIABABGAAgACgAMABqChAEEAUQAxAKEAk%3D';
  }
  if (contentFilter === MUSIC_ALBUMS) {
    return 'Eg-KAQwIABAAGAEgACgAMABqChAEEAUQAxAKEAk%3D';
  }
  if (contentFilter === MUSIC_PLAYLISTS) {
    return 'Eg-KAQwIABAAGAAgACgBMABqChAEEAUQAxAKEAk%3D';
  }
  if (contentFilter === MUSIC_ARTISTS) {
    return 'Eg-KAQwIABAAGAAgASgAMABqChAEEAUQAxAKEAk%3D';
  }
  return null;
}

export class YoutubeMusicSearchExtractor extends SearchExtractor {
  private initialData: JsonObject = new JsonObject();
  private cachedItemSectionRendererContents: JsonObject[] | null = null;

  constructor(service: StreamingService, linkHandler: SearchQueryHandler) {
    super(service, linkHandler);
  }

  /** The WEB_REMIX request context; identical in onFetchPage and getPage but for the query. */
  private async musicContextBody(withQuery: boolean, params: string | null):
    Promise<ArrayBuffer> {
    const writer: JsonStringWriter = JsonWriter.string()
      .object()
      .object('context')
      .object('client')
      .value('clientName', 'WEB_REMIX')
      .value('clientVersion', await getYoutubeMusicClientVersion())
      .value('hl', 'en-GB')
      .value('gl', this.getExtractorContentCountry().getCountryCode())
      .value('platform', 'DESKTOP')
      .value('utcOffsetMinutes', 0)
      .end()
      .object('request')
      .array('internalExperimentFlags')
      .end()
      .value('useSsl', true)
      .end()
      .object('user')
      // TODO (as in the source): expose restricted mode with .value('enableSafetyMode', boolean)
      .value('lockedSafetyMode', false)
      .end()
      .end();

    if (withQuery) {
      writer.value('query', this.getSearchString());
      writer.value('params', params);
    }

    return Request.utf8Body(writer.end().done());
  }

  async onFetchPage(downloader: Downloader): Promise<void> {
    const url: string = YOUTUBE_MUSIC_INNERTUBE_URL + 'search?' + DISABLE_PRETTY_PRINT_PARAMETER;
    const params: string | null =
      musicSearchParams(this.getLinkHandler().getContentFilters()[0]);

    const json: ArrayBuffer = await this.musicContextBody(true, params);

    const responseBody: string = getValidJsonResponseBody(
      await getDownloader().postWithContentTypeJson(url, getYoutubeMusicHeaders(), json));

    try {
      this.initialData = JsonParser.object().from(responseBody);
    } catch (e) {
      throw new ParsingException('Could not parse JSON', e instanceof Error ? e as Error : null);
    }
  }

  private getItemSectionRendererContents(): JsonObject[] {
    let cached: JsonObject[] | null = this.cachedItemSectionRendererContents;
    if (cached !== null) {
      return cached;
    }
    cached = [];
    const contents: JsonArray = this.initialData
      .getObject('contents')
      .getObject('tabbedSearchResultsRenderer')
      .getArray('tabs')
      .getObject(0)
      .getObject('tabRenderer')
      .getObject('content')
      .getObject('sectionListRenderer')
      .getArray('contents');
    for (const c of contents.streamAsJsonObjects()) {
      const isr: JsonObject = c.getObject('itemSectionRenderer');
      if (isr.size() > 0) {
        cached.push(isr.getArray('contents').getObject(0));
      }
    }
    this.cachedItemSectionRendererContents = cached;
    return cached;
  }

  getSearchSuggestion(): string {
    for (const obj of this.getItemSectionRendererContents()) {
      const didYouMeanRenderer: JsonObject = obj.getObject('didYouMeanRenderer');
      if (didYouMeanRenderer.size() > 0) {
        const corrected: string | null =
          getTextFromObject(didYouMeanRenderer.getObject('correctedQuery'));
        return corrected === null ? '' : corrected;
      }
      // As of 2025-07 the backend no longer returns "showing results for ...", but the JS
      // frontend still carries the code, so the source still reads it
      const showingResultsForRenderer: JsonObject = obj.getObject('showingResultsForRenderer');
      if (showingResultsForRenderer.size() > 0) {
        return JsonUtils.getString(showingResultsForRenderer,
          'correctedQueryEndpoint.searchEndpoint.query');
      }
    }
    return '';
  }

  isCorrectedSearch(): boolean {
    for (const obj of this.getItemSectionRendererContents()) {
      if (obj.has('showingResultsForRenderer')) {
        return true;
      }
    }
    return false;
  }

  getMetaInfo(): MetaInfo[] {
    return [];
  }

  async getInitialPage(): Promise<InfoItemsPage<InfoItem>> {
    const collector: MultiInfoItemsCollector =
      new MultiInfoItemsCollector(this.getServiceId());

    const contents: JsonArray = JsonUtils.getArray(
      JsonUtils.getArray(this.initialData, 'contents.tabbedSearchResultsRenderer.tabs')
        .getObject(0),
      'tabRenderer.content.sectionListRenderer.contents');

    let nextPage: Page | null = null;
    for (const content of contents.streamAsJsonObjects()) {
      if (content.has('musicShelfRenderer')) {
        const musicShelfRenderer: JsonObject = content.getObject('musicShelfRenderer');
        this.collectMusicStreamsFrom(collector, musicShelfRenderer.getArray('contents'));
        nextPage = YoutubeMusicSearchExtractor.getNextPageFrom(
          musicShelfRenderer.getArray('continuations'));
      }
    }

    return InfoItemsPage.fromCollector(collector, nextPage);
  }

  async getPage(page: Page): Promise<InfoItemsPage<InfoItem>> {
    if (page === null || isNullOrEmpty(page.getUrl())) {
      throw new ParsingException('Page doesn\'t contain an URL');
    }

    const collector: MultiInfoItemsCollector =
      new MultiInfoItemsCollector(this.getServiceId());

    const json: ArrayBuffer = await this.musicContextBody(false, null);

    const responseBody: string = getValidJsonResponseBody(
      await getDownloader().postWithContentTypeJson(page.getUrl() as string,
        getYoutubeMusicHeaders(), json));

    let ajaxJson: JsonObject;
    try {
      ajaxJson = JsonParser.object().from(responseBody);
    } catch (e) {
      throw new ParsingException('Could not parse JSON', e instanceof Error ? e as Error : null);
    }

    const musicShelfContinuation: JsonObject = ajaxJson.getObject('continuationContents')
      .getObject('musicShelfContinuation');
    this.collectMusicStreamsFrom(collector, musicShelfContinuation.getArray('contents'));

    return InfoItemsPage.fromCollector(collector, YoutubeMusicSearchExtractor.getNextPageFrom(
      musicShelfContinuation.getArray('continuations')));
  }

  private collectMusicStreamsFrom(collector: MultiInfoItemsCollector, videos: JsonArray): void {
    const searchType: string = this.getLinkHandler().getContentFilters()[0];

    for (const item of videos.streamAsJsonObjects()) {
      if (!item.has('musicResponsiveListItemRenderer')) {
        continue;
      }
      const infoItem: JsonObject = item.getObject('musicResponsiveListItemRenderer');

      const displayPolicy: string =
        infoItem.getString('musicItemRendererDisplayPolicy', '') as string;
      if (displayPolicy === 'MUSIC_ITEM_RENDERER_DISPLAY_POLICY_GREY_OUT') {
        // No URL information is available for a greyed-out item
        continue;
      }

      const descriptionElements: JsonArray = infoItem.getArray('flexColumns')
        .getObject(1)
        .getObject('musicResponsiveListItemFlexColumnRenderer')
        .getObject('text')
        .getArray('runs');

      if (searchType === MUSIC_SONGS || searchType === MUSIC_VIDEOS) {
        collector.commit(new YoutubeMusicSongOrVideoInfoItemExtractor(infoItem,
          descriptionElements, searchType));
      } else if (searchType === MUSIC_ARTISTS) {
        collector.commit(new YoutubeMusicArtistInfoItemExtractor(infoItem));
      } else if (searchType === MUSIC_ALBUMS || searchType === MUSIC_PLAYLISTS) {
        collector.commit(new YoutubeMusicAlbumOrPlaylistInfoItemExtractor(infoItem,
          descriptionElements, searchType));
      }
    }
  }

  private static getNextPageFrom(continuations: JsonArray): Page | null {
    if (continuations.size() === 0) {
      return null;
    }
    const continuation: string | null = continuations.getObject(0)
      .getObject('nextContinuationData')
      .getString('continuation');
    return new Page('https://music.youtube.com/youtubei/v1/search?ctoken=' + continuation
      + '&continuation=' + continuation + '&' + DISABLE_PRETTY_PRINT_PARAMETER);
  }
}
