/*
 * Port of org.schabi.newpipe.extractor.Image.ResolutionLevel (NewPipeExtractor v0.26.5).
 */

/** The estimated resolution level of an Image. */
export enum ResolutionLevel {
  /** Height greater than or equal to 720px. */
  HIGH,
  /** Height between 175px inclusive and 720px exclusive. */
  MEDIUM,
  /** Height between 1px inclusive and 175px exclusive. */
  LOW,
  /** The extractor does not know what resolution level the image has. */
  UNKNOWN
}

/** Port of ResolutionLevel.fromHeight(int). */
export function resolutionLevelFromHeight(heightPx: number): ResolutionLevel {
  if (heightPx <= 0) {
    return ResolutionLevel.UNKNOWN;
  }
  if (heightPx < 175) {
    return ResolutionLevel.LOW;
  }
  if (heightPx < 720) {
    return ResolutionLevel.MEDIUM;
  }
  return ResolutionLevel.HIGH;
}
