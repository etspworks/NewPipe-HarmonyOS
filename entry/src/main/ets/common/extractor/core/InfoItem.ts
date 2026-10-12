/*
 * Port of org.schabi.newpipe.extractor.InfoItem and its InfoType enum
 * (NewPipeExtractor v0.26.5).
 *
 * The base of every list row the app renders: a stream, a channel, a playlist or a comment.
 */

import { Image } from '../../../model/extractor/Image';

export enum InfoType {
  STREAM,
  PLAYLIST,
  CHANNEL,
  COMMENT
}

export abstract class InfoItem {
  readonly infoType: InfoType;
  readonly serviceId: number;
  readonly url: string;
  readonly name: string;
  /** Public because the player/UI lanes bind it directly; the accessors below mirror the source. */
  thumbnails: Image[] = [];

  constructor(infoType: InfoType, serviceId: number, url: string, name: string) {
    this.infoType = infoType;
    this.serviceId = serviceId;
    this.url = url;
    this.name = name;
  }

  getInfoType(): InfoType {
    return this.infoType;
  }

  getServiceId(): number {
    return this.serviceId;
  }

  getUrl(): string {
    return this.url;
  }

  getName(): string {
    return this.name;
  }

  setThumbnails(thumbnails: Image[]): void {
    this.thumbnails = thumbnails;
  }

  getThumbnails(): Image[] {
    return this.thumbnails;
  }

  toString(): string {
    return `${this.constructor.name}[url="${this.url}", name="${this.name}"]`;
  }
}
