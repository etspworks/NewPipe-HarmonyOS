/*
 * Port of org.schabi.newpipe.extractor.services.bandcamp.extractors
 * .BandcampRadioInfoItemExtractor (NewPipeExtractor v0.26.5).
 */

import { Image } from '../../../../../model/extractor/Image';
import { StreamType } from '../../../../../model/enums/StreamType';
import { StreamInfoItemExtractor } from '../../../info/StreamInfoItemExtractor';
import { DateWrapper } from '../../../localization/DateWrapper';
import { JsonObject } from '../../../json/NanoJson';
import { BASE_URL, BandcampExtractorHelper } from './BandcampExtractorHelper';

export class BandcampRadioInfoItemExtractor extends StreamInfoItemExtractor {
  private readonly show: JsonObject;

  constructor(radioShow: JsonObject) {
    super();
    this.show = radioShow;
  }

  getDuration(): number {
    /* Duration is only present in the more detailed information that has to be queried
    separately. Therefore, over 300 queries would be needed every time the kiosk is opened if we
    were to display the real value. */
    return 0;
  }

  getShortDescription(): string | null {
    return this.show.getString('desc');
  }

  getTextualUploadDate(): string | null {
    return this.show.getString('date');
  }

  getUploadDate(): DateWrapper | null {
    return BandcampExtractorHelper.parseDate(this.getTextualUploadDate());
  }

  getName(): string {
    const name: string | null = this.show.getString('subtitle');
    return name === null ? '' : name;
  }

  getUrl(): string {
    return BASE_URL + '/?show=' + this.show.getInt('id');
  }

  getThumbnails(): Image[] {
    return BandcampExtractorHelper.getImagesFromImageId(this.show.getLong('image_id'), false);
  }

  getStreamType(): StreamType {
    return StreamType.AUDIO_STREAM;
  }

  getViewCount(): number {
    return -1;
  }

  getUploaderName(): string {
    // The "title" field contains the title of the series, e.g. "Bandcamp Weekly".
    const title: string | null = this.show.getString('title');
    return title === null ? '' : title;
  }

  getUploaderUrl(): string {
    return '';
  }

  isUploaderVerified(): boolean {
    return false;
  }

  isAd(): boolean {
    return false;
  }
}
