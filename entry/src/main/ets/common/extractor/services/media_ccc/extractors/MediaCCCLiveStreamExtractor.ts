/*
 * Port of org.schabi.newpipe.extractor.services.media_ccc.extractors.MediaCCCLiveStreamExtractor
 * (NewPipeExtractor v0.26.5).
 *
 * The live streams come from a third host, https://streaming.media.ccc.de (§3); the room is
 * matched out of the shared streams/v2.json document in onFetchPage.
 */

import { StreamExtractor } from '../../../info/StreamExtractor';
import { StreamingService } from '../../../core/StreamingService';
import { LinkHandler } from '../../../linkhandler/LinkHandler';
import { Downloader } from '../../../downloader/Downloader';
import { JsonArray, JsonObject, JsonValue } from '../../../json/NanoJson';
import { ExtractionException } from '../../../exceptions/Exceptions';
import { MediaFormat } from '../../../../../model/enums/MediaFormat';
import { DeliveryMethod } from '../../../../../model/enums/DeliveryMethod';
import { StreamType } from '../../../../../model/enums/StreamType';
import {
  AudioStream,
  AudioStreamBuilder,
  UNKNOWN_BITRATE
} from '../../../../../model/extractor/AudioStream';
import { Description, DESCRIPTION_PLAIN_TEXT } from '../../../../../model/extractor/Description';
import { Image } from '../../../../../model/extractor/Image';
import { ID_UNKNOWN } from '../../../../../model/extractor/Stream';
import { VideoStream, VideoStreamBuilder } from '../../../../../model/extractor/VideoStream';
import { getLiveStreams, getThumbnailsFromLiveStreamItem } from '../MediaCCCParsingHelper';

const STREAMS: string = 'streams';
const URLS: string = 'urls';
const URL: string = 'url';

/**
 * Ties together one stream JSON object, its URL key and its URL value — the source's private
 * MediaCCCLiveStreamMapperDTO.
 */
class MediaCCCLiveStreamMapperDTO {
  readonly streamJsonObj: JsonObject;
  readonly urlKey: string;
  readonly urlValue: JsonObject;

  constructor(streamJsonObj: JsonObject, urlKey: string, urlValue: JsonObject) {
    this.streamJsonObj = streamJsonObj;
    this.urlKey = urlKey;
    this.urlValue = urlValue;
  }
}

export class MediaCCCLiveStreamExtractor extends StreamExtractor {
  private conference: JsonObject = new JsonObject();
  private group: string = '';
  private room: JsonObject = new JsonObject();

  constructor(service: StreamingService, linkHandler: LinkHandler) {
    super(service, linkHandler);
  }

  async onFetchPage(downloader: Downloader): Promise<void> {
    const doc: JsonArray = await getLiveStreams(downloader, this.getExtractorLocalization());
    // Find the correct room
    for (let c = 0; c < doc.size(); c++) {
      const conferenceObject: JsonObject = doc.getObject(c);
      const groups: JsonArray = conferenceObject.getArray('groups');
      for (let g = 0; g < groups.size(); g++) {
        const groupObject: string | null = groups.getObject(g).getString('group');
        const rooms: JsonArray = groups.getObject(g).getArray('rooms');
        for (let r = 0; r < rooms.size(); r++) {
          const roomObject: JsonObject = rooms.getObject(r);
          const mandator: string | null = conferenceObject.getString('mandator');
          const slug: string | null = roomObject.getString('slug');
          if (this.getId() === (mandator === null ? '' : mandator) + '/'
            + (slug === null ? '' : slug)) {
            this.conference = conferenceObject;
            this.group = groupObject === null ? '' : groupObject;
            this.room = roomObject;
            return;
          }
        }
      }
    }
    throw new ExtractionException("Could not find room matching id: '" + this.getId() + "'");
  }

  getName(): string {
    const display: string | null = this.room.getString('display');
    return display === null ? '' : display;
  }

  getThumbnails(): Image[] {
    return getThumbnailsFromLiveStreamItem(this.room);
  }

  getDescription(): Description {
    const description: string | null = this.conference.getString('description');
    return new Description((description === null ? '' : description) + ' - ' + this.group,
      DESCRIPTION_PLAIN_TEXT);
  }

  getViewCount(): number {
    return -1;
  }

  getUploaderUrl(): string {
    const slug: string | null = this.conference.getString('slug');
    return 'https://streaming.media.ccc.de/' + (slug === null ? '' : slug);
  }

  getUploaderName(): string {
    const conferenceName: string | null = this.conference.getString('conference');
    return conferenceName === null ? '' : conferenceName;
  }

  /**
   * The URL of the first DASH stream found. There can be several; the others are in
   * getVideoStreams().
   */
  getDashMpdUrl(): string {
    return this.getManifestOfDeliveryMethodWanted('dash');
  }

  /**
   * The URL of the first HLS stream found. There can be several; the others are in
   * getVideoStreams().
   */
  getHlsUrl(): string {
    return this.getManifestOfDeliveryMethodWanted('hls');
  }

  private getManifestOfDeliveryMethodWanted(deliveryMethod: string): string {
    for (const streamObject of this.room.getArray(STREAMS).streamAsJsonObjects()) {
      const urls: JsonObject = streamObject.getObject(URLS);
      if (urls.has(deliveryMethod)) {
        const manifestUrl: string | null = urls.getObject(deliveryMethod).getString(URL, '');
        return manifestUrl === null ? '' : manifestUrl;
      }
    }
    return '';
  }

  async getAudioStreams(): Promise<AudioStream[]> {
    const audioStreams: AudioStream[] = [];
    for (const dto of this.getStreamDtos('audio')) {
      const urlValue: string | null = dto.urlValue.getString(URL);
      const builder: AudioStreamBuilder = new AudioStreamBuilder()
        .setId(dto.urlValue.getString('tech', ID_UNKNOWN) as string)
        .setContent(urlValue === null ? '' : urlValue, true)
        .setAverageBitrate(UNKNOWN_BITRATE);

      if (dto.urlKey === 'hls') {
        // We don't know with the type string what media format will have HLS streams.
        // However, the tech string may contain some information about the media format used.
        audioStreams.push(builder.setDeliveryMethod(DeliveryMethod.HLS).build());
      } else {
        audioStreams.push(builder.setMediaFormat(MediaFormat.getFromSuffix(dto.urlKey)).build());
      }
    }
    return audioStreams;
  }

  async getVideoStreams(): Promise<VideoStream[]> {
    const videoStreams: VideoStream[] = [];
    for (const dto of this.getStreamDtos('video')) {
      const videoSize: JsonArray = dto.streamJsonObj.getArray('videoSize');
      const urlValue: string | null = dto.urlValue.getString(URL);

      const builder: VideoStreamBuilder = new VideoStreamBuilder()
        .setId(dto.urlValue.getString('tech', ID_UNKNOWN) as string)
        .setContent(urlValue === null ? '' : urlValue, true)
        .setIsVideoOnly(false)
        .setResolution(videoSize.getInt(0) + 'x' + videoSize.getInt(1));

      if (dto.urlKey === 'hls') {
        // We don't know with the type string what media format will have HLS streams.
        // However, the tech string may contain some information about the media format used.
        videoStreams.push(builder.setDeliveryMethod(DeliveryMethod.HLS).build());
      } else {
        videoStreams.push(builder.setMediaFormat(MediaFormat.getFromSuffix(dto.urlKey)).build());
      }
    }
    return videoStreams;
  }

  /** Port of the source's getStreams(String, Function) stream pipeline, minus the converter. */
  private getStreamDtos(streamType: string): MediaCCCLiveStreamMapperDTO[] {
    const dtos: MediaCCCLiveStreamMapperDTO[] = [];
    for (const streamJsonObj of this.room.getArray(STREAMS).streamAsJsonObjects()) {
      // Only process streams of requested type
      if (streamJsonObj.getString('type') !== streamType) {
        continue;
      }
      const urls: JsonObject = streamJsonObj.getObject(URLS);
      for (const urlKey of urls.keys()) {
        // Ensure that we only process JsonObjects
        const urlValue: JsonValue | null = urls.get(urlKey);
        if (!(urlValue instanceof JsonObject)) {
          continue;
        }
        // The DASH manifest will be extracted with getDashMpdUrl
        if (urlKey === 'dash') {
          continue;
        }
        dtos.push(new MediaCCCLiveStreamMapperDTO(streamJsonObj, urlKey,
          urlValue as JsonObject));
      }
    }
    return dtos;
  }

  async getVideoOnlyStreams(): Promise<VideoStream[]> {
    return [];
  }

  getStreamType(): StreamType {
    return StreamType.LIVE_STREAM;
  }

  getCategory(): string {
    return this.group;
  }
}
