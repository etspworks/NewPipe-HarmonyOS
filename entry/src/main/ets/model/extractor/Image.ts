/*
 * Port of org.schabi.newpipe.extractor.Image (NewPipeExtractor v0.26.5).
 *
 * Depending on the service the height, the width or both may be unknown; implementations must use
 * HEIGHT_UNKNOWN / WIDTH_UNKNOWN in that case so clients can tell.
 */

import { ResolutionLevel } from '../enums/ImageResolutionLevel';

export class Image {
  /** The height of an Image is unknown. */
  static readonly HEIGHT_UNKNOWN: number = -1;
  /** The width of an Image is unknown. */
  static readonly WIDTH_UNKNOWN: number = -1;

  private readonly url: string;
  private readonly height: number;
  private readonly width: number;
  private readonly estimatedResolutionLevel: ResolutionLevel;

  constructor(url: string, height: number, width: number,
    estimatedResolutionLevel: ResolutionLevel) {
    this.url = url;
    this.height = height;
    this.width = width;
    this.estimatedResolutionLevel = estimatedResolutionLevel;
  }

  getUrl(): string {
    return this.url;
  }

  /** The height, or HEIGHT_UNKNOWN. */
  getHeight(): number {
    return this.height;
  }

  /** The width, or WIDTH_UNKNOWN. */
  getWidth(): number {
    return this.width;
  }

  getEstimatedResolutionLevel(): ResolutionLevel {
    return this.estimatedResolutionLevel;
  }

  toString(): string {
    return 'Image {' + 'url=' + this.url + ', height=' + this.height + ', width=' + this.width
      + ', estimatedResolutionLevel=' + this.estimatedResolutionLevel + '}';
  }
}
