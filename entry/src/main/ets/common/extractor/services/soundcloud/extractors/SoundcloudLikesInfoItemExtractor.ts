/*
 * Port of org.schabi.newpipe.extractor.services.soundcloud.extractors
 * .SoundcloudLikesInfoItemExtractor (NewPipeExtractor v0.26.5).
 *
 * A "like" row wraps the liked track under `track`; everything else is the plain stream row.
 */

import { JsonObject } from '../../../json/NanoJson';
import { SoundcloudStreamInfoItemExtractor } from './SoundcloudStreamInfoItemExtractor';

export class SoundcloudLikesInfoItemExtractor extends SoundcloudStreamInfoItemExtractor {
  constructor(itemObject: JsonObject) {
    super(itemObject.getObject('track'));
  }
}
