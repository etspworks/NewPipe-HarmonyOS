/*
 * Port of org.schabi.newpipe.extractor.services.soundcloud.extractors.SoundcloudStreamExtractor
 * (NewPipeExtractor v0.26.5).
 */

import { AudioStream, AudioStreamBuilder } from '../../../../../model/extractor/AudioStream';
import { Description, DESCRIPTION_PLAIN_TEXT } from '../../../../../model/extractor/Description';
import { Image } from '../../../../../model/extractor/Image';
import { ID_UNKNOWN, Stream } from '../../../../../model/extractor/Stream';
import { VideoStream } from '../../../../../model/extractor/VideoStream';
import { DeliveryMethod } from '../../../../../model/enums/DeliveryMethod';
import { MediaFormat } from '../../../../../model/enums/MediaFormat';
import { StreamType } from '../../../../../model/enums/StreamType';
import { InfoItemExtractor, InfoItemsCollector } from '../../../core/Collector';
import { InfoItem } from '../../../core/InfoItem';
import { NewPipe } from '../../../core/NewPipe';
import { StreamingService } from '../../../core/StreamingService';
import { encodeUrlUtf8, isNullOrEmpty } from '../../../core/Utils';
import { Downloader } from '../../../downloader/Downloader';
import {
  ContentNotAvailableException,
  ExtractionException,
  GeographicRestrictionException,
  ParsingException,
  SoundCloudGoPlusContentException
} from '../../../exceptions/Exceptions';
import { LinkHandler } from '../../../linkhandler/LinkHandler';
import { DateWrapper } from '../../../localization/DateWrapper';
import { JsonArray, JsonObject, JsonParser } from '../../../json/NanoJson';
import { Privacy, StreamExtractor } from '../../../info/StreamExtractor';
import { StreamInfoItemsCollector } from '../../../info/StreamInfoItemsCollector';
import { SOUNDCLOUD_API_V2_URL, SoundcloudParsingHelper } from '../SoundcloudParsingHelper';

export class SoundcloudStreamExtractor extends StreamExtractor {
  private track: JsonObject | null = null;
  private isAvailable: boolean = true;

  constructor(service: StreamingService, linkHandler: LinkHandler) {
    super(service, linkHandler);
  }

  private requireTrack(): JsonObject {
    if (this.track === null) {
      throw new ParsingException('Page is not fetched. Make sure you call fetchPage()');
    }
    return this.track;
  }

  async onFetchPage(downloader: Downloader): Promise<void> {
    this.track = await SoundcloudParsingHelper.resolveFor(downloader, this.getUrl());

    const policy: string | null = this.track.getString('policy', '');
    if (policy !== 'ALLOW' && policy !== 'MONETIZE') {
      this.isAvailable = false;

      if (policy === 'SNIP') {
        throw new SoundCloudGoPlusContentException();
      }

      if (policy === 'BLOCK') {
        throw new GeographicRestrictionException(
          'This track is not available in user\'s country');
      }

      throw new ContentNotAvailableException('Content not available: policy ' + policy);
    }
  }

  getId(): string {
    return `${this.requireTrack().getLong('id')}`;
  }

  getName(): string {
    const name: string | null = this.requireTrack().getString('title');
    return name === null ? '' : name;
  }

  getTextualUploadDate(): string | null {
    return this.requireTrack().getString('created_at');
  }

  getUploadDate(): DateWrapper | null {
    return SoundcloudParsingHelper.parseDate(this.getTextualUploadDate());
  }

  getThumbnails(): Image[] {
    return SoundcloudParsingHelper.getAllImagesFromTrackObject(this.requireTrack());
  }

  getDescription(): Description {
    return new Description(this.requireTrack().getString('description'), DESCRIPTION_PLAIN_TEXT);
  }

  getLength(): number {
    return Math.floor(this.requireTrack().getLong('duration') / 1000);
  }

  getTimeStamp(): number {
    const timestamp: number = this.getTimestampSeconds('(#t=\\d{0,3}h?\\d{0,3}m?\\d{1,3}s?)');
    return timestamp === -2 ? 0 : timestamp;
  }

  getViewCount(): number {
    return this.requireTrack().getLong('playback_count');
  }

  getLikeCount(): number {
    return this.requireTrack().getLong('likes_count', -1);
  }

  getUploaderUrl(): string {
    return SoundcloudParsingHelper.getUploaderUrl(this.requireTrack());
  }

  getUploaderName(): string {
    return SoundcloudParsingHelper.getUploaderName(this.requireTrack());
  }

  isUploaderVerified(): boolean {
    return this.requireTrack().getObject('user').getBoolean('verified');
  }

  getUploaderAvatars(): Image[] {
    return SoundcloudParsingHelper.getAllImagesFromArtworkOrAvatarUrl(
      SoundcloudParsingHelper.getAvatarUrl(this.requireTrack()));
  }

  async getAudioStreams(): Promise<AudioStream[]> {
    const audioStreams: AudioStream[] = [];
    const track: JsonObject = this.requireTrack();

    // Streams can be streamable and downloadable - or explicitly not.
    // For playing the track, it is only necessary to have a streamable track.
    // If this is not the case, this track might not be published yet.
    if (!track.getBoolean('streamable') || !this.isAvailable) {
      return audioStreams;
    }

    const transcodings: JsonArray = track.getObject('media').getArray('transcodings');
    if (transcodings.size() > 0) {
      // Get information about what stream formats are available
      await this.extractAudioStreams(transcodings, audioStreams);
    }

    return audioStreams;
  }

  private async getTranscodingUrl(endpointUrl: string): Promise<string> {
    let apiStreamUrl: string = endpointUrl + '?client_id='
      + await SoundcloudParsingHelper.clientId();

    const trackAuthorization: string | null =
      this.requireTrack().getString('track_authorization');
    if (!isNullOrEmpty(trackAuthorization)) {
      apiStreamUrl += '&track_authorization=' + trackAuthorization;
    }

    const downloader: Downloader | null = NewPipe.getDownloader();
    if (downloader === null) {
      throw new ExtractionException('NewPipe was not initialised with a Downloader');
    }
    const response: string = (await downloader.get(apiStreamUrl)).responseBody();
    let urlObject: JsonObject;
    try {
      urlObject = JsonParser.object().from(response);
    } catch (e) {
      throw new ParsingException('Could not parse streamable URL',
        e instanceof Error ? e as Error : null);
    }

    const url: string | null = urlObject.getString('url');
    return url === null ? '' : url;
  }

  private async extractAudioStreams(transcodings: JsonArray,
    audioStreams: AudioStream[]): Promise<void> {
    for (const transcoding of transcodings.streamAsJsonObjects()) {
      const url: string | null = transcoding.getString('url');
      if (isNullOrEmpty(url)) {
        continue;
      }

      try {
        const preset: string | null = transcoding.getString('preset', ID_UNKNOWN);
        const protocol: string | null = transcoding.getObject('format').getString('protocol');

        if (protocol !== null && protocol.includes('encrypted')) {
          // Skip DRM-protected streams, which have encrypted in their protocol name
          continue;
        }

        const presetId: string = preset === null ? ID_UNKNOWN : preset;
        const builder: AudioStreamBuilder = new AudioStreamBuilder().setId(presetId);

        if (protocol === 'hls') {
          builder.setDeliveryMethod(DeliveryMethod.HLS);
        }

        builder.setContent(await this.getTranscodingUrl(url as string), true);

        if (presetId.includes('mp3')) {
          builder.setMediaFormat(MediaFormat.MP3);
          builder.setAverageBitrate(128);
        } else if (presetId.includes('opus')) {
          builder.setMediaFormat(MediaFormat.OPUS);
          builder.setAverageBitrate(64);
        } else if (presetId.includes('aac_160k')) {
          builder.setMediaFormat(MediaFormat.M4A);
          builder.setAverageBitrate(160);
        } else {
          // Unknown format, skip to the next audio stream
          continue;
        }

        const audioStream: AudioStream = builder.build();
        if (!Stream.containSimilarStream(audioStream, audioStreams)) {
          audioStreams.push(audioStream);
        }
      } catch (e) {
        // Something went wrong when trying to get and add this audio stream, skip to the next one
      }
    }
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
    const collector: StreamInfoItemsCollector =
      new StreamInfoItemsCollector(this.getServiceId());
    const apiUrl: string = SOUNDCLOUD_API_V2_URL + 'tracks/' + encodeUrlUtf8(this.getId())
      + '/related?client_id=' + encodeUrlUtf8(await SoundcloudParsingHelper.clientId());

    await SoundcloudParsingHelper.getStreamsFromApi(collector, apiUrl);
    return collector as InfoItemsCollector<InfoItem, InfoItemExtractor>;
  }

  getPrivacy(): Privacy {
    return this.requireTrack().getString('sharing') === 'public'
      ? Privacy.PUBLIC : Privacy.PRIVATE;
  }

  getCategory(): string {
    const genre: string | null = this.requireTrack().getString('genre');
    return genre === null ? '' : genre;
  }

  getLicence(): string {
    const licence: string | null = this.requireTrack().getString('license');
    return licence === null ? '' : licence;
  }

  getTags(): string[] {
    // Tags are separated by spaces, but they can be multiple words escaped by quotes "
    const rawTagList: string | null = this.requireTrack().getString('tag_list');
    if (rawTagList === null) {
      return [];
    }
    const tagList: string[] = rawTagList.split(' ');
    const tags: string[] = [];
    let escapedTag: string = '';
    let isEscaped: boolean = false;
    for (const tag of tagList) {
      if (tag.startsWith('"')) {
        escapedTag += tag.split('"').join('');
        isEscaped = true;
      } else if (isEscaped) {
        if (tag.endsWith('"')) {
          escapedTag += ' ' + tag.split('"').join('');
          isEscaped = false;
          // Faithful to the source: the Java StringBuilder is NOT reset here either.
          tags.push(escapedTag);
        } else {
          escapedTag += ' ' + tag;
        }
      } else if (tag.length > 0) {
        tags.push(tag);
      }
    }
    return tags;
  }
}
