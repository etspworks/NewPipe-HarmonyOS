/*
 * Port of org.schabi.newpipe.extractor.services.peertube.extractors
 * .PeertubeSepiaStreamInfoItemExtractor (NewPipeExtractor v0.26.5).
 *
 * A StreamInfoItem collected from SepiaSearch.
 */

import { JsonObject } from '../../../json/NanoJson';
import { nonNullString } from '../PeertubeParsingHelper';
import { PeertubeStreamInfoItemExtractor } from './PeertubeStreamInfoItemExtractor';

export class PeertubeSepiaStreamInfoItemExtractor extends PeertubeStreamInfoItemExtractor {
  constructor(item: JsonObject, baseUrl: string) {
    super(item, baseUrl);
    const embedUrl: string = nonNullString(this.item.getString('embedUrl'));
    const embedPath: string = nonNullString(this.item.getString('embedPath'));
    const itemBaseUrl: string = embedUrl.replace(embedPath, '');
    this.setBaseUrl(itemBaseUrl);

    // Usually, all videos, pictures and other content are hosted on the instance,
    // or can be accessed by the same URL path if the instance with baseUrl federates the one
    // where the video is actually uploaded. But it cannot be accessed with Sepiasearch, so we
    // use the item's instance as base URL.
  }
}
