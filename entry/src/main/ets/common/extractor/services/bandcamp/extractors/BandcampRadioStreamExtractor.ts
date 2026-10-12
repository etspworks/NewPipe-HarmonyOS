/*
 * Port of org.schabi.newpipe.extractor.services.bandcamp.extractors
 * .BandcampRadioStreamExtractor (NewPipeExtractor v0.26.5).
 */

import { AudioStream, AudioStreamBuilder } from '../../../../../model/extractor/AudioStream';
import { Description, DESCRIPTION_PLAIN_TEXT } from '../../../../../model/extractor/Description';
import { Image } from '../../../../../model/extractor/Image';
import { StreamSegment } from '../../../../../model/extractor/StreamSegment';
import { MediaFormat } from '../../../../../model/enums/MediaFormat';
import { ResolutionLevel } from '../../../../../model/enums/ImageResolutionLevel';
import { InfoItemExtractor, InfoItemsCollector } from '../../../core/Collector';
import { InfoItem } from '../../../core/InfoItem';
import { NewPipe } from '../../../core/NewPipe';
import { StreamingService } from '../../../core/StreamingService';
import { Downloader } from '../../../downloader/Downloader';
import {
  ContentNotSupportedException,
  ExtractionException,
  ParsingException
} from '../../../exceptions/Exceptions';
import { Element, Jsoup } from '../../../html/Jsoup';
import { JsonArray, JsonObject, JsonParser } from '../../../json/NanoJson';
import { LinkHandler } from '../../../linkhandler/LinkHandler';
import { BASE_API_URL, BASE_URL, BandcampExtractorHelper } from './BandcampExtractorHelper';
import { BandcampStreamExtractor } from './BandcampStreamExtractor';

const OPUS_LO: string = 'opus-lo';
const MP3_128: string = 'mp3-128';

export class BandcampRadioStreamExtractor extends BandcampStreamExtractor {
  private showInfo: JsonObject | null = null;

  constructor(service: StreamingService, linkHandler: LinkHandler) {
    super(service, linkHandler);
  }

  private requireShowInfo(): JsonObject {
    if (this.showInfo === null) {
      throw new ParsingException('Page is not fetched. Make sure you call fetchPage()');
    }
    return this.showInfo;
  }

  static async query(id: number): Promise<JsonObject> {
    const dl: Downloader | null = NewPipe.getDownloader();
    if (dl === null) {
      throw new ExtractionException('NewPipe was not initialised with a Downloader');
    }
    try {
      return JsonParser.object().from(
        (await dl.get(BASE_API_URL + '/bcweekly/1/get?id=' + id)).responseBody());
    } catch (e) {
      throw new ParsingException('could not get show data',
        e instanceof Error ? e as Error : null);
    }
  }

  async onFetchPage(downloader: Downloader): Promise<void> {
    this.showInfo = await BandcampRadioStreamExtractor.query(
      Number.parseInt(this.getId(), 10));
  }

  getName(): string {
    /* Select "subtitle" and not "audio_title", as the latter would cause a lot of
     * items to show the same title, e.g. "Bandcamp Weekly".
     */
    const subtitle: string | null = this.requireShowInfo().getString('subtitle');
    return subtitle === null ? '' : subtitle;
  }

  getUploaderUrl(): string {
    throw new ContentNotSupportedException('Fan pages are not supported');
  }

  getUrl(): string {
    return this.getLinkHandler().getUrl();
  }

  getUploaderName(): string {
    const caption: string | null = this.requireShowInfo().getString('image_caption');
    const link: Element | null =
      Jsoup.parse(caption === null ? '' : caption).getElementsByTag('a').first();
    if (link === null) {
      throw new ParsingException('Could not get uploader name');
    }
    return link.text();
  }

  getTextualUploadDate(): string | null {
    return this.requireShowInfo().getString('published_date');
  }

  getThumbnails(): Image[] {
    return BandcampExtractorHelper.getImagesFromImageId(
      this.requireShowInfo().getLong('show_image_id'), false);
  }

  getUploaderAvatars(): Image[] {
    return [new Image(BASE_URL + '/img/buttons/bandcamp-button-circle-whitecolor-512.png',
      512, 512, ResolutionLevel.MEDIUM)];
  }

  getDescription(): Description {
    return new Description(this.requireShowInfo().getString('desc'), DESCRIPTION_PLAIN_TEXT);
  }

  getLength(): number {
    return this.requireShowInfo().getLong('audio_duration');
  }

  async getAudioStreams(): Promise<AudioStream[]> {
    const audioStreams: AudioStream[] = [];
    const streams: JsonObject = this.requireShowInfo().getObject('audio_stream');

    if (streams.has(MP3_128)) {
      const content: string | null = streams.getString(MP3_128);
      audioStreams.push(new AudioStreamBuilder()
        .setId(MP3_128)
        .setContent(content === null ? '' : content, true)
        .setMediaFormat(MediaFormat.MP3)
        .setAverageBitrate(128)
        .build());
    }

    if (streams.has(OPUS_LO)) {
      const content: string | null = streams.getString(OPUS_LO);
      audioStreams.push(new AudioStreamBuilder()
        .setId(OPUS_LO)
        .setContent(content === null ? '' : content, true)
        .setMediaFormat(MediaFormat.OPUS)
        .setAverageBitrate(100)
        .build());
    }

    return audioStreams;
  }

  getStreamSegments(): StreamSegment[] {
    const tracks: JsonArray = this.requireShowInfo().getArray('tracks');
    const segments: StreamSegment[] = [];
    for (const track of tracks.streamAsJsonObjects()) {
      const title: string | null = track.getString('title');
      const segment: StreamSegment =
        new StreamSegment(title === null ? '' : title, track.getInt('timecode'));
      // "track art" is the track's album cover
      segment.setPreviewUrl(BandcampExtractorHelper.getImageUrl(track.getLong('track_art_id'),
        true));
      segment.setChannelName(track.getString('artist'));
      segments.push(segment);
    }
    return segments;
  }

  getLicence(): string {
    // Contrary to other Bandcamp streams, radio streams don't have a license
    return '';
  }

  getCategory(): string {
    // Contrary to other Bandcamp streams, radio streams don't have categories
    return '';
  }

  getTags(): string[] {
    // Contrary to other Bandcamp streams, radio streams don't have tags
    return [];
  }

  async getRelatedItems(): Promise<InfoItemsCollector<InfoItem, InfoItemExtractor> | null> {
    // Contrary to other Bandcamp streams, radio streams don't have related items
    return null;
  }
}
