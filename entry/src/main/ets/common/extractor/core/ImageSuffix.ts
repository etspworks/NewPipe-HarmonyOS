/*
 * Port of org.schabi.newpipe.extractor.utils.ImageSuffix (NewPipeExtractor v0.26.5).
 *
 * The suffix appended to a base image URL, plus the size that suffix is known to return. Used by
 * the YouTube, SoundCloud and Bandcamp image helpers (wave C).
 */

import { ResolutionLevel } from '../../../model/enums/ImageResolutionLevel';

export class ImageSuffix {
  private readonly suffix: string;
  private readonly height: number;
  private readonly width: number;
  private readonly resolutionLevel: ResolutionLevel;

  constructor(suffix: string, height: number, width: number,
    estimatedResolutionLevel: ResolutionLevel) {
    this.suffix = suffix;
    this.height = height;
    this.width = width;
    this.resolutionLevel = estimatedResolutionLevel;
  }

  /** The suffix which needs to be appended to get the full image URL. */
  getSuffix(): string {
    return this.suffix;
  }

  /** The height corresponding to the image suffix, which may be unknown. */
  getHeight(): number {
    return this.height;
  }

  /** The width corresponding to the image suffix, which may be unknown. */
  getWidth(): number {
    return this.width;
  }

  getResolutionLevel(): ResolutionLevel {
    return this.resolutionLevel;
  }

  toString(): string {
    return 'ImageSuffix {' + 'suffix=' + this.suffix + ', height=' + this.height + ', width='
      + this.width + ', resolutionLevel=' + this.resolutionLevel + '}';
  }
}
