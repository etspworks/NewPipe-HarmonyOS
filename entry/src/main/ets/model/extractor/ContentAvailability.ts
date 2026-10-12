/*
 * Port of org.schabi.newpipe.extractor.stream.ContentAvailability (NewPipeExtractor v0.26.5).
 * Not declared in the plan's models[]; a real extractor type StreamInfo and StreamInfoItem carry.
 */
export enum ContentAvailability {
  UNKNOWN,
  AVAILABLE,
  MEMBERSHIP,
  PAID,
  UPCOMING
}
