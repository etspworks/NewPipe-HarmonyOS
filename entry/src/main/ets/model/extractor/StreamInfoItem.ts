/*
 * Port of org.schabi.newpipe.extractor.stream.StreamInfoItem (NewPipeExtractor v0.26.5).
 *
 * The row every stream list renders. Fields are public camelCase (the UI and player lanes bind
 * them directly) and the source's getters/setters are kept beside them.
 */

import { InfoItem, InfoType } from '../../common/extractor/core/InfoItem';
import { DateWrapper } from '../../common/extractor/localization/DateWrapper';
import { StreamType } from '../enums/StreamType';
import { ContentAvailability } from './ContentAvailability';
import { Image } from './Image';

export class StreamInfoItem extends InfoItem {
  readonly streamType: StreamType;
  uploaderName: string = '';
  shortDescription: string | null = null;
  textualUploadDate: string | null = null;
  /**
   * DEVIATION from the source's DateWrapper: a millisecond epoch, with the wrapper's
   * `isApproximation` flag flattened beside it. DateWrapper has no module in the plan's models[],
   * and the persistence lane stores the two values, not an object.
   */
  uploadDate: number | null = null;
  isUploadDateApproximation: boolean = false;
  viewCount: number = -1;
  duration: number = -1;
  uploaderUrl: string | null = null;
  uploaderAvatars: Image[] = [];
  uploaderVerified: boolean = false;
  shortFormContent: boolean = false;
  contentAvailability: ContentAvailability = ContentAvailability.AVAILABLE;

  constructor(serviceId: number, url: string, name: string, streamType: StreamType) {
    super(InfoType.STREAM, serviceId, url, name);
    this.streamType = streamType;
  }

  getStreamType(): StreamType {
    return this.streamType;
  }

  getUploaderName(): string {
    return this.uploaderName;
  }

  setUploaderName(uploaderName: string): void {
    this.uploaderName = uploaderName;
  }

  getViewCount(): number {
    return this.viewCount;
  }

  setViewCount(viewCount: number): void {
    this.viewCount = viewCount;
  }

  getDuration(): number {
    return this.duration;
  }

  setDuration(duration: number): void {
    this.duration = duration;
  }

  getUploaderUrl(): string | null {
    return this.uploaderUrl;
  }

  setUploaderUrl(uploaderUrl: string | null): void {
    this.uploaderUrl = uploaderUrl;
  }

  getUploaderAvatars(): Image[] {
    return this.uploaderAvatars;
  }

  setUploaderAvatars(uploaderAvatars: Image[]): void {
    this.uploaderAvatars = uploaderAvatars;
  }

  getShortDescription(): string | null {
    return this.shortDescription;
  }

  setShortDescription(shortDescription: string | null): void {
    this.shortDescription = shortDescription;
  }

  getTextualUploadDate(): string | null {
    return this.textualUploadDate;
  }

  setTextualUploadDate(textualUploadDate: string | null): void {
    this.textualUploadDate = textualUploadDate;
  }

  /** The millisecond epoch of the upload, or null; see the field's note. */
  getUploadDate(): number | null {
    return this.uploadDate;
  }

  /** Takes the extractor's DateWrapper and flattens it onto the two fields. */
  setUploadDate(uploadDate: DateWrapper | null): void {
    this.uploadDate = uploadDate === null ? null : uploadDate.getInstant().getTime();
    this.isUploadDateApproximation = uploadDate !== null && uploadDate.isApproximation();
  }

  getIsUploaderVerified(): boolean {
    return this.uploaderVerified;
  }

  setUploaderVerified(uploaderVerified: boolean): void {
    this.uploaderVerified = uploaderVerified;
  }

  getIsShortFormContent(): boolean {
    return this.shortFormContent;
  }

  setShortFormContent(shortFormContent: boolean): void {
    this.shortFormContent = shortFormContent;
  }

  getContentAvailability(): ContentAvailability {
    return this.contentAvailability;
  }

  setContentAvailability(availability: ContentAvailability): void {
    this.contentAvailability = availability;
  }

  toString(): string {
    return 'StreamInfoItem{streamType=' + this.streamType
      + ', uploaderName=\'' + this.uploaderName + '\''
      + ', textualUploadDate=\'' + this.textualUploadDate + '\''
      + ', viewCount=' + this.viewCount
      + ', duration=' + this.duration
      + ', uploaderUrl=\'' + this.uploaderUrl + '\''
      + ', infoType=' + this.getInfoType()
      + ', serviceId=' + this.getServiceId()
      + ', url=\'' + this.getUrl() + '\''
      + ', name=\'' + this.getName() + '\''
      + ', thumbnails=\'' + this.thumbnails + '\''
      + ', uploaderVerified=\'' + this.uploaderVerified + '\''
      + '}';
  }
}
