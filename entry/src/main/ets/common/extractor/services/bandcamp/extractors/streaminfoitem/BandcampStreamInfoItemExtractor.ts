/*
 * Port of org.schabi.newpipe.extractor.services.bandcamp.extractors.streaminfoitem
 * .BandcampStreamInfoItemExtractor (NewPipeExtractor v0.26.5).
 *
 * Implements methods that return a constant value in subclasses for better readability.
 */

import { StreamType } from '../../../../../../model/enums/StreamType';
import { StreamInfoItemExtractor } from '../../../../info/StreamInfoItemExtractor';
import { DateWrapper } from '../../../../localization/DateWrapper';

export abstract class BandcampStreamInfoItemExtractor extends StreamInfoItemExtractor {
  private readonly uploaderUrl: string;

  constructor(uploaderUrl: string) {
    super();
    this.uploaderUrl = uploaderUrl;
  }

  getStreamType(): StreamType {
    return StreamType.AUDIO_STREAM;
  }

  getViewCount(): number {
    return -1;
  }

  getUploaderUrl(): string {
    return this.uploaderUrl;
  }

  getTextualUploadDate(): string | null {
    return null;
  }

  getUploadDate(): DateWrapper | null {
    return null;
  }

  isUploaderVerified(): boolean {
    return false;
  }

  isAd(): boolean {
    return false;
  }
}
