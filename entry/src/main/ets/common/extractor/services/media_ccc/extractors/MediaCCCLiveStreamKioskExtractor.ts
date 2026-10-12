/*
 * Port of org.schabi.newpipe.extractor.services.media_ccc.extractors
 * .MediaCCCLiveStreamKioskExtractor (NewPipeExtractor v0.26.5).
 */

import { StreamInfoItemExtractor } from '../../../info/StreamInfoItemExtractor';
import { JsonObject } from '../../../json/NanoJson';
import { DateWrapper } from '../../../localization/DateWrapper';
import { Image } from '../../../../../model/extractor/Image';
import { StreamType } from '../../../../../model/enums/StreamType';
import { getThumbnailsFromLiveStreamItem } from '../MediaCCCParsingHelper';

export class MediaCCCLiveStreamKioskExtractor extends StreamInfoItemExtractor {
  private readonly conferenceInfo: JsonObject;
  private readonly group: string;
  private readonly roomInfo: JsonObject;

  constructor(conferenceInfo: JsonObject, group: string, roomInfo: JsonObject) {
    super();
    this.conferenceInfo = conferenceInfo;
    this.group = group;
    this.roomInfo = roomInfo;
  }

  getName(): string {
    const title: string | null =
      this.roomInfo.getObject('talks').getObject('current').getString('title');
    return title === null ? '' : title;
  }

  getUrl(): string {
    const link: string | null = this.roomInfo.getString('link');
    return link === null ? '' : link;
  }

  getThumbnails(): Image[] {
    return getThumbnailsFromLiveStreamItem(this.roomInfo);
  }

  getStreamType(): StreamType {
    let isVideo: boolean = false;
    for (const stream of this.roomInfo.getArray('streams').streamAsJsonObjects()) {
      if (stream.getString('type') === 'video') {
        isVideo = true;
        break;
      }
    }
    return isVideo ? StreamType.LIVE_STREAM : StreamType.AUDIO_LIVE_STREAM;
  }

  isAd(): boolean {
    return false;
  }

  getDuration(): number {
    return 0;
  }

  getViewCount(): number {
    return -1;
  }

  getUploaderName(): string {
    const conference: string | null = this.conferenceInfo.getString('conference');
    const display: string | null = this.roomInfo.getString('display');
    return (conference === null ? '' : conference) + ' - ' + this.group
      + ' - ' + (display === null ? '' : display);
  }

  getUploaderUrl(): string {
    const slug: string | null = this.conferenceInfo.getString('slug');
    return 'https://media.ccc.de/c/' + (slug === null ? '' : slug);
  }

  isUploaderVerified(): boolean {
    return false;
  }

  getTextualUploadDate(): string | null {
    return null;
  }

  getUploadDate(): DateWrapper | null {
    return null;
  }
}
