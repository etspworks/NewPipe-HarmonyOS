/*
 * Port of org.schabi.newpipe.extractor.services.bandcamp.extractors.BandcampStreamExtractor
 * (NewPipeExtractor v0.26.5). Created by Fynn Godau 2019, GPL v3 or later.
 */

import { AudioStream, AudioStreamBuilder } from '../../../../../model/extractor/AudioStream';
import { Description, DESCRIPTION_PLAIN_TEXT } from '../../../../../model/extractor/Description';
import { Image } from '../../../../../model/extractor/Image';
import { VideoStream } from '../../../../../model/extractor/VideoStream';
import { MediaFormat } from '../../../../../model/enums/MediaFormat';
import { StreamType } from '../../../../../model/enums/StreamType';
import { InfoItemExtractor, InfoItemsCollector } from '../../../core/Collector';
import { InfoItem } from '../../../core/InfoItem';
import { JsonUtils } from '../../../core/JsonUtils';
import { StreamingService } from '../../../core/StreamingService';
import { HTTPS, nonEmptyAndNullJoin, replaceHttpWithHttps } from '../../../core/Utils';
import { Downloader } from '../../../downloader/Downloader';
import {
  PaidContentException,
  ParsingException,
  ExtractionException
} from '../../../exceptions/Exceptions';
import { Document, Element, Jsoup } from '../../../html/Jsoup';
import { JsonObject } from '../../../json/NanoJson';
import { LinkHandler } from '../../../linkhandler/LinkHandler';
import { DateWrapper } from '../../../localization/DateWrapper';
import { PlaylistInfoItemsCollector } from '../../../info/PlaylistExtractor';
import { StreamExtractor } from '../../../info/StreamExtractor';
import { BandcampExtractorHelper } from './BandcampExtractorHelper';
import { BandcampRelatedPlaylistInfoItemExtractor } from './BandcampRelatedPlaylistInfoItemExtractor';

export class BandcampStreamExtractor extends StreamExtractor {
  protected albumJson: JsonObject | null = null;
  protected current: JsonObject | null = null;
  protected document: Document | null = null;

  constructor(service: StreamingService, linkHandler: LinkHandler) {
    super(service, linkHandler);
  }

  protected requireAlbumJson(): JsonObject {
    if (this.albumJson === null) {
      throw new ParsingException('Page is not fetched. Make sure you call fetchPage()');
    }
    return this.albumJson;
  }

  protected requireCurrent(): JsonObject {
    if (this.current === null) {
      throw new ParsingException('Page is not fetched. Make sure you call fetchPage()');
    }
    return this.current;
  }

  protected requireDocument(): Document {
    if (this.document === null) {
      throw new ParsingException('Page is not fetched. Make sure you call fetchPage()');
    }
    return this.document;
  }

  async onFetchPage(downloader: Downloader): Promise<void> {
    const html: string = (await downloader.get(this.getLinkHandler().getUrl())).responseBody();
    this.document = Jsoup.parse(html);
    this.albumJson = BandcampStreamExtractor.getAlbumInfoJson(html);
    this.current = this.albumJson.getObject('current');

    if (this.albumJson.getArray('trackinfo').size() > 1) {
      // In this case, we are actually viewing an album page!
      throw new ExtractionException('Page is actually an album, not a track');
    }

    if (this.albumJson.getArray('trackinfo').getObject(0).isNull('file')) {
      throw new PaidContentException('This track is not available without being purchased');
    }
  }

  /** The JSON that contains the album's metadata, embedded in the page. */
  static getAlbumInfoJson(html: string): JsonObject {
    try {
      return JsonUtils.getJsonData(html, 'data-tralbum');
    } catch (e) {
      throw new ParsingException('Faulty JSON; page likely does not contain album data',
        e instanceof Error ? e as Error : null);
    }
  }

  getName(): string {
    const title: string | null = this.requireCurrent().getString('title');
    return title === null ? '' : title;
  }

  getUploaderUrl(): string {
    const parts: string[] = this.getUrl().split('/');
    // https: (/) (/) * .bandcamp.com (/) and leave out the rest
    return HTTPS + parts[2] + '/';
  }

  getUrl(): string {
    const url: string | null = replaceHttpWithHttps(this.requireAlbumJson().getString('url'));
    return url === null ? '' : url;
  }

  getUploaderName(): string {
    const artist: string | null = this.requireAlbumJson().getString('artist');
    return artist === null ? '' : artist;
  }

  getTextualUploadDate(): string | null {
    return this.requireCurrent().getString('publish_date');
  }

  getUploadDate(): DateWrapper | null {
    return BandcampExtractorHelper.parseDate(this.getTextualUploadDate());
  }

  getThumbnails(): Image[] {
    if (this.requireAlbumJson().isNull('art_id')) {
      return [];
    }

    return BandcampExtractorHelper.getImagesFromImageId(
      this.requireAlbumJson().getLong('art_id'), true);
  }

  getUploaderAvatars(): Image[] {
    const photo: Element | null = this.requireDocument().getElementsByClass('band-photo').first();
    return BandcampExtractorHelper.getImagesFromImageUrl(
      photo === null ? '' : photo.attr('src'));
  }

  getDescription(): Description {
    const current: JsonObject = this.requireCurrent();
    const s: string = nonEmptyAndNullJoin('\n\n', [current.getString('about'),
      current.getString('lyrics'), current.getString('credits')]);
    return new Description(s, DESCRIPTION_PLAIN_TEXT);
  }

  async getAudioStreams(): Promise<AudioStream[]> {
    const content: string | null = this.requireAlbumJson().getArray('trackinfo').getObject(0)
      .getObject('file').getString('mp3-128');
    return [new AudioStreamBuilder()
      .setId('mp3-128')
      .setContent(content === null ? '' : content, true)
      .setMediaFormat(MediaFormat.MP3)
      .setAverageBitrate(128)
      .build()];
  }

  getLength(): number {
    return Math.trunc(this.requireAlbumJson().getArray('trackinfo').getObject(0)
      .getDouble('duration'));
  }

  async getVideoStreams(): Promise<VideoStream[]> {
    return [];
  }

  async getVideoOnlyStreams(): Promise<VideoStream[]> {
    return [];
  }

  getStreamType(): StreamType {
    return StreamType.AUDIO_STREAM;
  }

  async getRelatedItems(): Promise<InfoItemsCollector<InfoItem, InfoItemExtractor> | null> {
    const collector: PlaylistInfoItemsCollector =
      new PlaylistInfoItemsCollector(this.getServiceId());
    for (const album of this.requireDocument().getElementsByClass('recommended-album').toArray()) {
      collector.commit(new BandcampRelatedPlaylistInfoItemExtractor(album));
    }

    return collector as InfoItemsCollector<InfoItem, InfoItemExtractor>;
  }

  getCategory(): string {
    // Get first tag from html, which is the artist's Genre
    for (const tags of this.requireDocument().getElementsByClass('tralbum-tags').toArray()) {
      const tag: Element | null = tags.getElementsByClass('tag').first();
      if (tag !== null) {
        return tag.text();
      }
    }
    return '';
  }

  getLicence(): string {
    /*
    Tests resulted in this mapping of ints to licence:
    https://cloud.disroot.org/s/ZTWBxbQ9fKRmRWJ/preview (screenshot from a Bandcamp artist's
    account)
    */
    const licenseType: number = this.requireCurrent().getInt('license_type');
    if (licenseType === 1) {
      return 'All rights reserved ©';
    }
    if (licenseType === 2) {
      return 'CC BY-NC-ND 3.0';
    }
    if (licenseType === 3) {
      return 'CC BY-NC-SA 3.0';
    }
    if (licenseType === 4) {
      return 'CC BY-NC 3.0';
    }
    if (licenseType === 5) {
      return 'CC BY-ND 3.0';
    }
    if (licenseType === 6) {
      return 'CC BY 3.0';
    }
    if (licenseType === 8) {
      return 'CC BY-SA 3.0';
    }
    return 'Unknown';
  }

  getTags(): string[] {
    const tags: string[] = [];
    for (const keyword of this.requireDocument()
      .getElementsByAttributeValue('itemprop', 'keywords').toArray()) {
      tags.push(keyword.text());
    }
    return tags;
  }
}
