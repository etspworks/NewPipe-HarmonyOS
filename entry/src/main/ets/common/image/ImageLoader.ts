/*
 * svc_image_loader (endpoint `thumbnail_image_load`) - port of
 * app/src/main/java/org/schabi/newpipe/util/image/{ImageStrategy.kt, PreferredImageQuality.kt,
 * CoilHelper.kt}.
 *
 * Coil maps to ArkUI's own `Image` component (dependency-decisions.json: coil -> Image +
 * svc_image_loader), which fetches and caches a network URL itself. So the half of CoilHelper
 * that built ImageRequests disappears; what does NOT disappear, and is the whole point of this
 * module, is ImageStrategy: choosing WHICH of the several image URLs a service returns to show,
 * given the user's image-quality preference. That ranking is ported line for line.
 *
 * loadPixelMap() is the port of CoilHelper.loadBitmapBlocking(): the notification path needs the
 * decoded pixels, not a URL. It goes through @ohos.net.http + @kit.ImageKit and destroys the
 * request in `finally` (Rule 8).
 */

import { http } from '@kit.NetworkKit';
import { image } from '@kit.ImageKit';
import { Image } from '../../model/extractor/Image';
import { ResolutionLevel } from '../../model/enums/ImageResolutionLevel';
import { AppPreferences } from '../prefs/Preferences';
import {
  image_quality_key,
  image_quality_none_key,
  image_quality_low_key,
  image_quality_high_key
} from '../prefs/SettingsKeys';
import { USER_AGENT } from '../net/Downloader';

/** Port of PreferredImageQuality. */
export enum PreferredImageQuality {
  NONE,
  LOW,
  MEDIUM,
  HIGH
}

/** Port of PreferredImageQuality.toResolutionLevel(). */
export function toResolutionLevel(quality: PreferredImageQuality): ResolutionLevel {
  switch (quality) {
    case PreferredImageQuality.LOW:
      return ResolutionLevel.LOW;
    case PreferredImageQuality.MEDIUM:
      return ResolutionLevel.MEDIUM;
    case PreferredImageQuality.HIGH:
      return ResolutionLevel.HIGH;
    default:
      return ResolutionLevel.UNKNOWN;
  }
}

/** ImageStrategy.BEST_LOW_H / BEST_MEDIUM_H, verbatim. */
const BEST_LOW_H: number = 75;
const BEST_MEDIUM_H: number = 250;

/** Image.HEIGHT_UNKNOWN / WIDTH_UNKNOWN, verbatim. */
const HEIGHT_UNKNOWN: number = -1;
const WIDTH_UNKNOWN: number = -1;

let preferredImageQuality: PreferredImageQuality = PreferredImageQuality.MEDIUM;

/** Port of ImageStrategy.setPreferredImageQuality(). */
export function setPreferredImageQuality(quality: PreferredImageQuality): void {
  preferredImageQuality = quality;
}

export function getPreferredImageQuality(): PreferredImageQuality {
  return preferredImageQuality;
}

/** Port of ImageStrategy.shouldLoadImages(). */
export function shouldLoadImages(): boolean {
  return preferredImageQuality !== PreferredImageQuality.NONE;
}

/** Port of PreferredImageQuality.fromPreferenceKey(context, key). */
export function readPreferredImageQuality(prefs: AppPreferences): PreferredImageQuality {
  const key: string = prefs.getStringResolvedSync(image_quality_key, image_quality_key);
  if (key === image_quality_none_key) {
    return PreferredImageQuality.NONE;
  }
  if (key === image_quality_low_key) {
    return PreferredImageQuality.LOW;
  }
  if (key === image_quality_high_key) {
    return PreferredImageQuality.HIGH;
  }
  return PreferredImageQuality.MEDIUM; // default to medium
}

/** Port of ImageStrategy.estimatePixelCount(image, widthOverHeight). */
export function estimatePixelCount(img: Image, widthOverHeight: number): number {
  if (img.getHeight() === HEIGHT_UNKNOWN) {
    if (img.getWidth() === WIDTH_UNKNOWN) {
      // images of completely unknown size are in their own subgroup, so any one will do
      return 0;
    }
    return img.getWidth() * img.getWidth() / widthOverHeight;
  }
  if (img.getWidth() === WIDTH_UNKNOWN) {
    return img.getHeight() * img.getHeight() * widthOverHeight;
  }
  return img.getHeight() * img.getWidth();
}

/**
 * Port of the first comparison step: images are grouped by how far their resolution level is
 * from the preferred one, avoiding UNKNOWN as much as possible.
 */
function levelRank(level: ResolutionLevel, preferredLevel: ResolutionLevel): number {
  if (level === ResolutionLevel.UNKNOWN) {
    return 3;
  }
  if (level === preferredLevel) {
    return 0;
  }
  if (level === ResolutionLevel.MEDIUM) {
    return 1;
  }
  return 2;
}

/**
 * Port of ImageStrategy.choosePreferredImage(images, nonNoneQuality).
 *
 * The three ranking steps of the source's Comparator chain, in order:
 *   1. distance of the resolution level from the preferred one,
 *   2. known image size preferred over unknown,
 *   3. within a subgroup of known sizes, closeness to BEST_LOW_H / BEST_MEDIUM_H, or the
 *      largest image for HIGH.
 */
export function choosePreferredImageWithQuality(images: Image[],
  nonNoneQuality: PreferredImageQuality): string | null {
  if (images.length === 0) {
    return null;
  }

  // used to estimate the pixel count where only one of height/width is known
  let widthOverHeight: number = 1.0;
  for (const img of images) {
    if (img.getHeight() !== HEIGHT_UNKNOWN && img.getWidth() !== WIDTH_UNKNOWN) {
      widthOverHeight = img.getWidth() / img.getHeight();
      break;
    }
  }

  const preferredLevel: ResolutionLevel = toResolutionLevel(nonNoneQuality);

  let best: Image | null = null;
  let bestRank: number = 0;
  let bestUnknownSize: boolean = false;
  let bestScore: number = 0;

  for (const img of images) {
    const rank: number = levelRank(img.getEstimatedResolutionLevel(), preferredLevel);
    const unknownSize: boolean = img.getHeight() === HEIGHT_UNKNOWN && img.getWidth() === WIDTH_UNKNOWN;

    let score: number = 0;
    if (nonNoneQuality === PreferredImageQuality.LOW) {
      score = Math.abs(estimatePixelCount(img, widthOverHeight)
        - BEST_LOW_H * BEST_LOW_H * widthOverHeight);
    } else if (nonNoneQuality === PreferredImageQuality.MEDIUM) {
      score = Math.abs(estimatePixelCount(img, widthOverHeight)
        - BEST_MEDIUM_H * BEST_MEDIUM_H * widthOverHeight);
    } else if (nonNoneQuality === PreferredImageQuality.HIGH) {
      // reversed so the highest resolution wins
      score = -estimatePixelCount(img, widthOverHeight);
    }

    if (best === null) {
      best = img;
      bestRank = rank;
      bestUnknownSize = unknownSize;
      bestScore = score;
      continue;
    }
    if (rank !== bestRank) {
      if (rank < bestRank) {
        best = img;
        bestRank = rank;
        bestUnknownSize = unknownSize;
        bestScore = score;
      }
      continue;
    }
    if (unknownSize !== bestUnknownSize) {
      if (!unknownSize) {
        best = img;
        bestUnknownSize = unknownSize;
        bestScore = score;
      }
      continue;
    }
    if (score < bestScore) {
      best = img;
      bestScore = score;
    }
  }

  return best === null ? null : best.getUrl();
}

/** Port of ImageStrategy.choosePreferredImage(images). */
export function choosePreferredImage(images: Image[]): string | null {
  if (preferredImageQuality === PreferredImageQuality.NONE) {
    return null; // do not load images
  }
  return choosePreferredImageWithQuality(images, preferredImageQuality);
}

/**
 * Port of ImageStrategy.imageListToDbUrl(images): like choosePreferredImage, but an image is
 * chosen even when the user disabled images, so nothing is saved empty to the database.
 */
export function imageListToDbUrl(images: Image[]): string | null {
  const quality: PreferredImageQuality = preferredImageQuality === PreferredImageQuality.NONE
    ? PreferredImageQuality.MEDIUM
    : preferredImageQuality;
  return choosePreferredImageWithQuality(images, quality);
}

/** Port of ImageStrategy.dbUrlToImageList(url). */
export function dbUrlToImageList(url: string | null): Image[] {
  if (url === null) {
    return [];
  }
  return [new Image(url, HEIGHT_UNKNOWN, WIDTH_UNKNOWN, ResolutionLevel.UNKNOWN)];
}

/**
 * Port of CoilHelper.loadBitmapBlocking(context, url): fetches and decodes one image.
 * Used where ArkUI's own `Image` cannot be: the new-stream notification's large icon.
 * Returns null on any failure, as the source returns null.
 */
export async function loadPixelMap(url: string | null): Promise<image.PixelMap | null> {
  if (url === null || url.length === 0 || !shouldLoadImages()) {
    return null;
  }
  const request: http.HttpRequest = http.createHttp();
  try {
    const options: http.HttpRequestOptions = {
      method: http.RequestMethod.GET,
      header: { 'User-Agent': USER_AGENT } as Record<string, string>,
      expectDataType: http.HttpDataType.ARRAY_BUFFER,
      connectTimeout: 30000,
      readTimeout: 30000
    };
    const response: http.HttpResponse = await request.request(url, options);
    if (response.responseCode !== 200 || !(response.result instanceof ArrayBuffer)) {
      return null;
    }
    const source: image.ImageSource = image.createImageSource(response.result as ArrayBuffer);
    try {
      return await source.createPixelMap();
    } finally {
      await source.release();
    }
  } catch (err) {
    return null;
  } finally {
    request.destroy();
  }
}
