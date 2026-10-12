/*
 * Port of org.schabi.newpipe.extractor.services.youtube.extractors.ItagInfo
 * (NewPipeExtractor v0.26.5).
 *
 * Package-private in Java; exported here since ArkTS has no package visibility.
 */

import { ItagItem } from '../ItagItem';

/** One stream's content (its URL, or its base URL) plus the itag it was built from. */
export class ItagInfo {
  private readonly content: string;
  private readonly itagItem: ItagItem;
  private url: boolean = false;

  constructor(content: string, itagItem: ItagItem) {
    this.content = content;
    this.itagItem = itagItem;
  }

  setIsUrl(isUrl: boolean): void {
    this.url = isUrl;
  }

  /** Either the URL of the content itself or its base URL; see getIsUrl(). */
  getContent(): string {
    return this.content;
  }

  getItagItem(): ItagItem {
    return this.itagItem;
  }

  getIsUrl(): boolean {
    return this.url;
  }
}
