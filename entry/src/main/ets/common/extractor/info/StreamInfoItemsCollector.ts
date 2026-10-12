/*
 * Port of org.schabi.newpipe.extractor.stream.StreamInfoItemsCollector
 * (NewPipeExtractor v0.26.5).
 *
 * THE stream-row mapper: every field the source's extract() sets is set here too. A field
 * dropped here renders as a permanently blank thumbnail or a 0 count on every stream list.
 */

import { InfoItemsCollector } from '../core/Collector';
import { toError } from '../core/Errors';
import { FoundAdException } from '../exceptions/Exceptions';
import { StreamInfoItem } from '../../../model/extractor/StreamInfoItem';
import { StreamInfoItemExtractor } from './StreamInfoItemExtractor';

export class StreamInfoItemsCollector
  extends InfoItemsCollector<StreamInfoItem, StreamInfoItemExtractor> {
  constructor(serviceId: number,
    comparator: ((a: StreamInfoItem, b: StreamInfoItem) => number) | null = null) {
    super(serviceId, comparator);
  }

  extract(extractor: StreamInfoItemExtractor): StreamInfoItem {
    if (extractor.isAd()) {
      throw new FoundAdException('Found ad');
    }

    const resultItem: StreamInfoItem = new StreamInfoItem(
      this.getServiceId(), extractor.getUrl(), extractor.getName(), extractor.getStreamType());

    try {
      resultItem.duration = extractor.getDuration();
    } catch (e) {
      this.addError(toError(e));
    }
    try {
      resultItem.uploaderName = extractor.getUploaderName();
    } catch (e) {
      this.addError(toError(e));
    }
    try {
      resultItem.textualUploadDate = extractor.getTextualUploadDate();
    } catch (e) {
      this.addError(toError(e));
    }
    try {
      resultItem.setUploadDate(extractor.getUploadDate());
    } catch (e) {
      this.addError(toError(e));
    }
    try {
      resultItem.viewCount = extractor.getViewCount();
    } catch (e) {
      this.addError(toError(e));
    }
    try {
      resultItem.thumbnails = extractor.getThumbnails();
    } catch (e) {
      this.addError(toError(e));
    }
    try {
      resultItem.uploaderUrl = extractor.getUploaderUrl();
    } catch (e) {
      this.addError(toError(e));
    }
    try {
      resultItem.uploaderAvatars = extractor.getUploaderAvatars();
    } catch (e) {
      this.addError(toError(e));
    }
    try {
      resultItem.uploaderVerified = extractor.isUploaderVerified();
    } catch (e) {
      this.addError(toError(e));
    }
    try {
      resultItem.shortDescription = extractor.getShortDescription();
    } catch (e) {
      this.addError(toError(e));
    }
    try {
      resultItem.shortFormContent = extractor.isShortFormContent();
    } catch (e) {
      this.addError(toError(e));
    }
    try {
      resultItem.contentAvailability = extractor.getContentAvailability();
    } catch (e) {
      this.addError(toError(e));
    }

    return resultItem;
  }

  commit(extractor: StreamInfoItemExtractor): void {
    try {
      this.addItem(this.extract(extractor));
    } catch (e) {
      if (e instanceof FoundAdException) {
        return;
      }
      this.addError(toError(e));
    }
  }
}
