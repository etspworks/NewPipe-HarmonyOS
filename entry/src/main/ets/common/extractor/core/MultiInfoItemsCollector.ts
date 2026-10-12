/*
 * Port of org.schabi.newpipe.extractor.MultiInfoItemsCollector (NewPipeExtractor v0.26.5).
 *
 * The collector for a heterogeneous list (a search page, a channel tab): it dispatches each item
 * extractor to the per-type collector that knows how to map it, and inherits those collectors'
 * errors so one bad row never loses the page.
 *
 * Wave B did not port it and the five concurrent service lanes each kept a local copy rather than
 * two lanes creating one shared path; the C-close pass hoisted this one copy here and deleted the
 * five. The Java `else` arm throws IllegalArgumentException, which has no analogue here — the
 * method's declared `throws ParsingException` is used instead, and every caller already treats an
 * item failure as an extraction error.
 */

import { InfoItemExtractor, InfoItemsCollector } from './Collector';
import { InfoItem } from './InfoItem';
import { ChannelInfoItemExtractor, ChannelInfoItemsCollector } from '../info/ChannelExtractor';
import {
  PlaylistInfoItemExtractor,
  PlaylistInfoItemsCollector
} from '../info/PlaylistExtractor';
import { StreamInfoItemExtractor } from '../info/StreamInfoItemExtractor';
import { StreamInfoItemsCollector } from '../info/StreamInfoItemsCollector';
import { ParsingException } from '../exceptions/Exceptions';

export class MultiInfoItemsCollector extends InfoItemsCollector<InfoItem, InfoItemExtractor> {
  private readonly streamCollector: StreamInfoItemsCollector;
  private readonly userCollector: ChannelInfoItemsCollector;
  private readonly playlistCollector: PlaylistInfoItemsCollector;

  constructor(serviceId: number) {
    super(serviceId);
    this.streamCollector = new StreamInfoItemsCollector(serviceId);
    this.userCollector = new ChannelInfoItemsCollector(serviceId);
    this.playlistCollector = new PlaylistInfoItemsCollector(serviceId);
  }

  getErrors(): Error[] {
    const errors: Error[] = super.getErrors().slice();
    for (const error of this.streamCollector.getErrors()) {
      errors.push(error);
    }
    for (const error of this.userCollector.getErrors()) {
      errors.push(error);
    }
    for (const error of this.playlistCollector.getErrors()) {
      errors.push(error);
    }
    return errors;
  }

  reset(): void {
    super.reset();
    this.streamCollector.reset();
    this.userCollector.reset();
    this.playlistCollector.reset();
  }

  // Use the corresponding collector for each item extractor type
  extract(extractor: InfoItemExtractor): InfoItem {
    if (extractor instanceof StreamInfoItemExtractor) {
      return this.streamCollector.extract(extractor as StreamInfoItemExtractor);
    } else if (extractor instanceof ChannelInfoItemExtractor) {
      return this.userCollector.extract(extractor as ChannelInfoItemExtractor);
    } else if (extractor instanceof PlaylistInfoItemExtractor) {
      return this.playlistCollector.extract(extractor as PlaylistInfoItemExtractor);
    }
    throw new ParsingException('Invalid extractor type: ' + extractor);
  }
}
