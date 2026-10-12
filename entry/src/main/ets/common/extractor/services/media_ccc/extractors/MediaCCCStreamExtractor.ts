/*
 * Port of org.schabi.newpipe.extractor.services.media_ccc.extractors.MediaCCCStreamExtractor
 * (NewPipeExtractor v0.26.5).
 */

import { intl } from '@kit.LocalizationKit';
import { StreamExtractor } from '../../../info/StreamExtractor';
import { StreamingService } from '../../../core/StreamingService';
import { LinkHandler } from '../../../linkhandler/LinkHandler';
import { Downloader } from '../../../downloader/Downloader';
import { JsonArray, JsonObject, JsonParser } from '../../../json/NanoJson';
import { JsonUtils } from '../../../core/JsonUtils';
import { toError } from '../../../core/Errors';
import { DateWrapper } from '../../../localization/DateWrapper';
import { ExtractionException } from '../../../exceptions/Exceptions';
import { MediaFormat } from '../../../../../model/enums/MediaFormat';
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
import { getImageListFromLogoImageUrl, getThumbnailsFromStreamItem } from '../MediaCCCParsingHelper';
import {
  CONFERENCE_PATH
} from '../linkHandler/MediaCCCConferenceLinkHandlerFactory';
import { VIDEO_API_ENDPOINT } from '../linkHandler/MediaCCCStreamLinkHandlerFactory';

const CONFERENCE_URL_PREFIX: RegExp =
  new RegExp('https://(api\\.)?media\\.ccc\\.de/public/conferences/');

export class MediaCCCStreamExtractor extends StreamExtractor {
  private data: JsonObject = new JsonObject();
  private conferenceData: JsonObject = new JsonObject();

  constructor(service: StreamingService, linkHandler: LinkHandler) {
    super(service, linkHandler);
  }

  getTextualUploadDate(): string | null {
    return this.data.getString('release_date');
  }

  getUploadDate(): DateWrapper | null {
    return DateWrapper.fromOffsetDateTime(this.getTextualUploadDate());
  }

  getThumbnails(): Image[] {
    return getThumbnailsFromStreamItem(this.data);
  }

  getDescription(): Description {
    return new Description(this.data.getString('description'), DESCRIPTION_PLAIN_TEXT);
  }

  getLength(): number {
    return this.data.getInt('length');
  }

  getViewCount(): number {
    return this.data.getInt('view_count');
  }

  getUploaderUrl(): string {
    return CONFERENCE_PATH + this.getUploaderName();
  }

  getUploaderName(): string {
    const conferenceUrl: string | null = this.data.getString('conference_url');
    if (conferenceUrl === null) {
      return '';
    }
    CONFERENCE_URL_PREFIX.lastIndex = 0;
    return conferenceUrl.replace(CONFERENCE_URL_PREFIX, '');
  }

  getUploaderAvatars(): Image[] {
    return getImageListFromLogoImageUrl(this.conferenceData.getString('logo_url'));
  }

  async getAudioStreams(): Promise<AudioStream[]> {
    const recordings: JsonArray = this.data.getArray('recordings');
    const audioStreams: AudioStream[] = [];
    for (const recording of recordings.streamAsJsonObjects()) {
      const mimeType: string | null = recording.getString('mime_type');
      if (mimeType !== null && mimeType.startsWith('audio')) {
        // First we need to resolve the actual video data from the CDN
        let mediaFormat: MediaFormat | null;
        if (mimeType.endsWith('opus')) {
          mediaFormat = MediaFormat.OPUS;
        } else if (mimeType.endsWith('mpeg')) {
          mediaFormat = MediaFormat.MP3;
        } else if (mimeType.endsWith('ogg')) {
          mediaFormat = MediaFormat.OGG;
        } else {
          mediaFormat = null;
        }

        const recordingUrl: string | null = recording.getString('recording_url');
        const builder: AudioStreamBuilder = new AudioStreamBuilder()
          .setId(recording.getString('filename', ID_UNKNOWN) as string)
          .setContent(recordingUrl === null ? '' : recordingUrl, true)
          .setMediaFormat(mediaFormat)
          .setAverageBitrate(UNKNOWN_BITRATE);

        const language: string | null = recording.getString('language');
        // If the language contains a - symbol, this means that the stream has an audio
        // track with multiple languages, so there is no specific language for this stream
        // Don't set the audio language in this case
        if (language !== null && !language.includes('-')) {
          // §9 made the locale a BCP-47 string; the source's LocaleCompat.forLanguageTag() is
          // `new Locale(language)` for a tag with no separator, whose tag is the string itself.
          builder.setAudioLocale(language);
        }

        // Not checking containsSimilarStream here, since MediaCCC does not provide enough
        // information to decide whether two streams are similar. Hence that method would
        // always return false, e.g. even for different language variations.
        audioStreams.push(builder.build());
      }
    }
    return audioStreams;
  }

  async getVideoStreams(): Promise<VideoStream[]> {
    const recordings: JsonArray = this.data.getArray('recordings');
    const videoStreams: VideoStream[] = [];
    for (const recording of recordings.streamAsJsonObjects()) {
      const mimeType: string | null = recording.getString('mime_type');
      if (mimeType !== null && mimeType.startsWith('video')) {
        // First we need to resolve the actual video data from the CDN
        let mediaFormat: MediaFormat | null;
        if (mimeType.endsWith('webm')) {
          mediaFormat = MediaFormat.WEBM;
        } else if (mimeType.endsWith('mp4')) {
          mediaFormat = MediaFormat.MPEG_4;
        } else {
          mediaFormat = null;
        }

        // Not checking containsSimilarStream here, since MediaCCC does not provide enough
        // information to decide whether two streams are similar. Hence that method would
        // always return false, e.g. even for different language variations.
        const recordingUrl: string | null = recording.getString('recording_url');
        videoStreams.push(new VideoStreamBuilder()
          .setId(recording.getString('filename', ID_UNKNOWN) as string)
          .setContent(recordingUrl === null ? '' : recordingUrl, true)
          .setIsVideoOnly(false)
          .setMediaFormat(mediaFormat)
          .setResolution(recording.getInt('height') + 'p')
          .build());
      }
    }

    return videoStreams;
  }

  async getVideoOnlyStreams(): Promise<VideoStream[]> {
    return [];
  }

  getStreamType(): StreamType {
    return StreamType.VIDEO_STREAM;
  }

  async onFetchPage(downloader: Downloader): Promise<void> {
    const videoUrl: string = VIDEO_API_ENDPOINT + this.getId();
    const videoBody: string = (await downloader.get(videoUrl)).responseBody();
    try {
      this.data = JsonParser.object().from(videoBody);
    } catch (e) {
      throw new ExtractionException('Could not parse json returned by URL: ' + videoUrl,
        toError(e));
    }
    const conferenceUrl: string | null = this.data.getString('conference_url');
    const conferenceBody: string =
      (await downloader.get(conferenceUrl === null ? '' : conferenceUrl)).responseBody();
    try {
      this.conferenceData = JsonParser.object().from(conferenceBody);
    } catch (e) {
      throw new ExtractionException('Could not parse json returned by URL: ' + videoUrl,
        toError(e));
    }
  }

  getName(): string {
    const title: string | null = this.data.getString('title');
    return title === null ? '' : title;
  }

  getOriginalUrl(): string {
    const frontendLink: string | null = this.data.getString('frontend_link');
    return frontendLink === null ? '' : frontendLink;
  }

  /**
   * ponytail: the source resolves the three-letter ISO-639-2 code through
   * Locale.getISOLanguages(); ArkTS exposes no ISO-language table, so the code is handed to ICU
   * as-is — it canonicalises the codes it knows and rejects junk. A surviving three-letter tag is
   * cosmetic (§9 made this a BCP-47 string). Add an explicit 639-2/T map only if the UI shows one.
   */
  getLanguageInfo(): string | null {
    const code: string | null = this.data.getString('original_language');
    if (code === null || code.length === 0) {
      return null;
    }
    try {
      return new intl.Locale(code).language;
    } catch (e) {
      return null;
    }
  }

  getTags(): string[] {
    return JsonUtils.getStringListFromJsonArray(this.data.getArray('tags'));
  }
}
