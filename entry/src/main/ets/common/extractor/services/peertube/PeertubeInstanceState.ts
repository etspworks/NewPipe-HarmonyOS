/*
 * DEVIATION, forced by phase2-logic-contract.md §9: the source's PeerTube link-handler factories
 * are singletons that read the instance base url from `ServiceList.PeerTube.getBaseUrl()`, i.e.
 * from the one live PeertubeService. Importing ServiceList here would recreate the init-time
 * module cycle registerServices() exists to avoid, so the single mutable value those factories
 * actually need lives in this leaf module instead.
 *
 * PeertubeService writes it from its constructor and from setInstance(), which is exactly when
 * `ServiceList.PeerTube.getBaseUrl()` would have started returning something else.
 */

import { PeertubeInstance } from '../../../../model/extractor/PeertubeInstance';

/** The content instance; DEFAULT_INSTANCE is https://framatube.org (see PeertubeInstance). */
let currentBaseUrl: string = PeertubeInstance.DEFAULT_INSTANCE.getUrl();

export function getPeertubeBaseUrl(): string {
  return currentBaseUrl;
}

export function setPeertubeBaseUrl(baseUrl: string): void {
  currentBaseUrl = baseUrl;
}
