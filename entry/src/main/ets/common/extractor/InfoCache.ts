/*
 * Port of org.schabi.newpipe.util.InfoCache (the plan's svc_info_cache).
 *
 * The app-side LRU of already-extracted Info objects, keyed by "<serviceId>:<type>:<url>" and
 * expiring per service. It is what makes going back to a page instant, and what
 * ExtractorHelper.checkCache() consults before every network load.
 *
 * DEVIATIONS, both forced and both narrow:
 *  - androidx.collection.LruCache -> `@ohos.util` LRUCache, the platform's own LruCache analogue.
 *    It has no snapshot()/trimToSize(), so removeStaleCache() walks keys() and trimCache() uses
 *    the resize-trim idiom (shrink the capacity, then restore it), which is exactly what
 *    Android's LruCache.resize(int) does internally.
 *  - Java synchronizes every access on the cache. ArkTS runs this on one thread and has no
 *    monitor, so the synchronized blocks are dropped rather than faked.
 *  - ServiceHelper.getCacheExpirationMillis() has no module of its own in the plan; it is one
 *    branch and lives here, next to its only caller.
 */

import { util } from '@kit.ArkTS';
import { Info } from './core/Info';
import { SoundCloud } from './ServiceRegistry';
import { DownloaderImpl } from '../net/Downloader';

const MAX_ITEMS_ON_CACHE: number = 60;
/** Trim the cache to this size. */
const TRIM_CACHE_TO: number = 30;

const MILLIS_PER_MINUTE: number = 60 * 1000;
const MILLIS_PER_HOUR: number = 60 * MILLIS_PER_MINUTE;

/** Identifies the type of {@link Info} to put into the cache. */
export enum InfoCacheType {
  STREAM,
  CHANNEL,
  CHANNEL_TAB,
  COMMENTS,
  PLAYLIST,
  KIOSK
}

/** Port of ServiceHelper.getCacheExpirationMillis(int). */
export function getCacheExpirationMillis(serviceId: number): number {
  return serviceId === SoundCloud.getServiceId() ? 5 * MILLIS_PER_MINUTE : MILLIS_PER_HOUR;
}

class CacheData {
  readonly expireTimestamp: number;
  readonly info: Info;

  constructor(info: Info, timeoutMillis: number) {
    this.expireTimestamp = Date.now() + timeoutMillis;
    this.info = info;
  }

  isExpired(): boolean {
    return Date.now() > this.expireTimestamp;
  }
}

export class InfoCache {
  private static readonly INSTANCE: InfoCache = new InfoCache();

  private readonly lruCache: util.LRUCache<string, CacheData> =
    new util.LRUCache<string, CacheData>(MAX_ITEMS_ON_CACHE);

  private constructor() {
    // no instance
  }

  static getInstance(): InfoCache {
    return InfoCache.INSTANCE;
  }

  private static keyOf(serviceId: number, url: string, cacheType: InfoCacheType): string {
    const ordinal: number = cacheType;
    return `${serviceId}:${ordinal}:${url}`;
  }

  private getValid(key: string): Info | null {
    const data: CacheData | undefined = this.lruCache.get(key);
    if (data === undefined) {
      return null;
    }
    if (data.isExpired()) {
      this.lruCache.remove(key);
      return null;
    }
    return data.info;
  }

  getFromKey(serviceId: number, url: string, cacheType: InfoCacheType): Info | null {
    return this.getValid(InfoCache.keyOf(serviceId, url, cacheType));
  }

  putInfo(serviceId: number, url: string, info: Info, cacheType: InfoCacheType): void {
    const expirationMillis: number = getCacheExpirationMillis(info.getServiceId());
    this.lruCache.put(InfoCache.keyOf(serviceId, url, cacheType),
      new CacheData(info, expirationMillis));
  }

  removeInfo(serviceId: number, url: string, cacheType: InfoCacheType): void {
    this.lruCache.remove(InfoCache.keyOf(serviceId, url, cacheType));
  }

  clearCache(): void {
    this.lruCache.clear();
  }

  /** Port of trimCache(): drop what has expired, then shrink back to TRIM_CACHE_TO. */
  trimCache(): void {
    this.removeStaleCache();
    if (this.lruCache.length > TRIM_CACHE_TO) {
      this.lruCache.updateCapacity(TRIM_CACHE_TO);
      this.lruCache.updateCapacity(MAX_ITEMS_ON_CACHE);
    }
  }

  private removeStaleCache(): void {
    for (const key of this.lruCache.keys()) {
      const data: CacheData | undefined = this.lruCache.get(key);
      if (data !== undefined && data.isExpired()) {
        this.lruCache.remove(key);
      }
    }
  }

  getSize(): number {
    return this.lruCache.length;
  }
}

/*
 * Contract §8: DownloaderImpl calls its cache invalidator when the YouTube restricted-mode
 * cookie changes, and the source's DownloaderImpl calls InfoCache.getInstance().clearCache()
 * there directly. Registering on import (the same idiom ServiceRegistry uses) keeps the
 * invalidation wired without a startup step that could be forgotten — anything that can toggle
 * restricted mode has already imported ExtractorHelper, which imports this module.
 */
DownloaderImpl.getInstance().setCacheInvalidator(() => {
  InfoCache.getInstance().clearCache();
});
