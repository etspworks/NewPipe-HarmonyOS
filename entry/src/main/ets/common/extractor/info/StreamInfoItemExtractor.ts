/*
 * Port of org.schabi.newpipe.extractor.stream.StreamInfoItemExtractor
 * (NewPipeExtractor v0.26.5).
 *
 * An abstract class, not an interface: ArkTS interfaces cannot carry the source's `default`
 * method bodies, and those defaults are what most service extractors rely on.
 */

import { InfoItemExtractor } from '../core/Collector';
import { DateWrapper } from '../localization/DateWrapper';
import { ContentAvailability } from '../../../model/extractor/ContentAvailability';
import { Image } from '../../../model/extractor/Image';
import { StreamType } from '../../../model/enums/StreamType';

export abstract class StreamInfoItemExtractor extends InfoItemExtractor {
  abstract getStreamType(): StreamType;

  abstract isAd(): boolean;

  /** The duration in seconds. */
  abstract getDuration(): number;

  abstract getViewCount(): number;

  abstract getUploaderName(): string;

  abstract getUploaderUrl(): string;

  getUploaderAvatars(): Image[] {
    return [];
  }

  abstract isUploaderVerified(): boolean;

  abstract getTextualUploadDate(): string | null;

  abstract getUploadDate(): DateWrapper | null;

  getShortDescription(): string | null {
    return null;
  }

  isShortFormContent(): boolean {
    return false;
  }

  getContentAvailability(): ContentAvailability {
    return ContentAvailability.UNKNOWN;
  }
}
