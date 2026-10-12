/*
 * Port of org.schabi.newpipe.extractor.services.bandcamp.extractors.streaminfoitem
 * .BandcampPlaylistStreamInfoItemExtractor (NewPipeExtractor v0.26.5).
 *
 * ArkTS deviation: the source resolves a track's own cover art INSIDE getThumbnails() by
 * running a whole StreamExtractor, which is I/O and cannot happen in the synchronous
 * getThumbnails() the ported core declares. resolveThumbnails() does that fetch and the
 * playlist extractor awaits it before committing the item; getThumbnails() then serves it.
 * The two Java constructors (with a service, with substitute covers) become two factories.
 */

import { Image } from '../../../../../../model/extractor/Image';
import { StreamingService } from '../../../../core/StreamingService';
import { ParsingException } from '../../../../exceptions/Exceptions';
import { StreamExtractor } from '../../../../info/StreamExtractor';
import { JsonObject } from '../../../../json/NanoJson';
import { BandcampStreamInfoItemExtractor } from './BandcampStreamInfoItemExtractor';

export class BandcampPlaylistStreamInfoItemExtractor extends BandcampStreamInfoItemExtractor {
  private readonly track: JsonObject;
  private substituteCovers: Image[];
  private readonly service: StreamingService | null;

  private constructor(track: JsonObject, uploaderUrl: string, service: StreamingService | null,
    substituteCovers: Image[]) {
    super(uploaderUrl);
    this.track = track;
    this.service = service;
    this.substituteCovers = substituteCovers;
  }

  /** Port of the (track, uploaderUrl, service) constructor: cover art per track. */
  static withService(track: JsonObject, uploaderUrl: string,
    service: StreamingService): BandcampPlaylistStreamInfoItemExtractor {
    return new BandcampPlaylistStreamInfoItemExtractor(track, uploaderUrl, service, []);
  }

  /** Port of the (track, uploaderUrl, substituteCovers) constructor: the album's cover art. */
  static withSubstituteCovers(track: JsonObject, uploaderUrl: string,
    substituteCovers: Image[]): BandcampPlaylistStreamInfoItemExtractor {
    return new BandcampPlaylistStreamInfoItemExtractor(track, uploaderUrl, null,
      substituteCovers);
  }

  getName(): string {
    const name: string | null = this.track.getString('title');
    return name === null ? '' : name;
  }

  getUrl(): string {
    const relativeUrl: string | null = this.track.getString('title_link');
    if (relativeUrl !== null) {
      return this.getUploaderUrl() + relativeUrl;
    }
    return '';
  }

  getDuration(): number {
    return this.track.getLong('duration');
  }

  getUploaderName(): string {
    // Tracks can have an individual artist name, but it is not included in the given JSON.
    return '';
  }

  /**
   * Each track can have its own cover art. Unless a substitute was provided, the thumbnail is
   * extracted by running a stream extractor over the track's page - which is what makes this
   * step asynchronous.
   */
  async resolveThumbnails(): Promise<void> {
    const url: string = this.getUrl();
    if (this.substituteCovers.length === 0 && url.length > 0 && this.service !== null) {
      try {
        const extractor: StreamExtractor = this.service.getStreamExtractorFromUrl(url);
        await extractor.fetchPage();
        this.substituteCovers = extractor.getThumbnails();
      } catch (e) {
        throw new ParsingException('Could not download cover art location',
          e instanceof Error ? e as Error : null);
      }
    }
  }

  getThumbnails(): Image[] {
    return this.substituteCovers;
  }
}
