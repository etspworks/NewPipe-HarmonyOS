/*
 * Port of org.schabi.newpipe.extractor.services.soundcloud.extractors
 * .SoundcloudPlaylistInfoItemExtractor (NewPipeExtractor v0.26.5).
 */

import { Image } from '../../../../../model/extractor/Image';
import { PlaylistInfoItemExtractor } from '../../../info/PlaylistExtractor';
import { isNullOrEmpty, replaceHttpWithHttps } from '../../../core/Utils';
import { ParsingException } from '../../../exceptions/Exceptions';
import { JsonObject } from '../../../json/NanoJson';
import { SoundcloudParsingHelper } from '../SoundcloudParsingHelper';

const USER_KEY: string = 'user';
const AVATAR_URL_KEY: string = 'avatar_url';
const ARTWORK_URL_KEY: string = 'artwork_url';

export class SoundcloudPlaylistInfoItemExtractor extends PlaylistInfoItemExtractor {
  private readonly itemObject: JsonObject;

  constructor(itemObject: JsonObject) {
    super();
    this.itemObject = itemObject;
  }

  getName(): string {
    const name: string | null = this.itemObject.getString('title');
    return name === null ? '' : name;
  }

  getUrl(): string {
    const url: string | null = replaceHttpWithHttps(this.itemObject.getString('permalink_url'));
    return url === null ? '' : url;
  }

  getThumbnails(): Image[] {
    // Over-engineering at its finest
    if (this.itemObject.isString(ARTWORK_URL_KEY)) {
      const artworkUrl: string | null = this.itemObject.getString(ARTWORK_URL_KEY);
      if (!isNullOrEmpty(artworkUrl)) {
        return SoundcloudParsingHelper.getAllImagesFromArtworkOrAvatarUrl(artworkUrl);
      }
    }

    try {
      // Look for artwork URL inside the track list
      for (const trackObject of this.itemObject.getArray('tracks').streamAsJsonObjects()) {
        // First look for track artwork URL
        if (trackObject.isString(ARTWORK_URL_KEY)) {
          const artworkUrl: string | null = trackObject.getString(ARTWORK_URL_KEY);
          if (!isNullOrEmpty(artworkUrl)) {
            return SoundcloudParsingHelper.getAllImagesFromArtworkOrAvatarUrl(artworkUrl);
          }
        }

        // Then look for track creator avatar URL
        const creatorAvatar: string | null =
          trackObject.getObject(USER_KEY).getString(AVATAR_URL_KEY);
        if (!isNullOrEmpty(creatorAvatar)) {
          return SoundcloudParsingHelper.getAllImagesFromArtworkOrAvatarUrl(creatorAvatar);
        }
      }
    } catch (e) {
      // Try other method
    }

    try {
      // Last resort, use user avatar URL. If still not found, then throw an exception.
      return SoundcloudParsingHelper.getAllImagesFromArtworkOrAvatarUrl(
        this.itemObject.getObject(USER_KEY).getString(AVATAR_URL_KEY));
    } catch (e) {
      throw new ParsingException('Failed to extract playlist thumbnails',
        e instanceof Error ? e as Error : null);
    }
  }

  getUploaderName(): string {
    try {
      const name: string | null = this.itemObject.getObject(USER_KEY).getString('username');
      return name === null ? '' : name;
    } catch (e) {
      throw new ParsingException('Failed to extract playlist uploader',
        e instanceof Error ? e as Error : null);
    }
  }

  getUploaderUrl(): string {
    const url: string | null = this.itemObject.getObject(USER_KEY).getString('permalink_url');
    return url === null ? '' : url;
  }

  isUploaderVerified(): boolean {
    return this.itemObject.getObject(USER_KEY).getBoolean('verified');
  }

  getStreamCount(): number {
    return this.itemObject.getLong('track_count');
  }
}
