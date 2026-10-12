/*
 * Port of org.schabi.newpipe.extractor.MetaInfo (NewPipeExtractor v0.26.5).
 *
 * The service's own banner above a stream or a search ("this topic is covered by ..."), with the
 * links it points at. Java holds java.net.URL objects; here a url is the string the UI opens,
 * which is what every consumer of getUrls() needs.
 */

import { Description } from './Description';

export class MetaInfo {
  title: string = '';
  content: Description = Description.EMPTY_DESCRIPTION;
  urls: string[] = [];
  urlTexts: string[] = [];

  constructor(title: string = '', content: Description = Description.EMPTY_DESCRIPTION,
    urls: string[] = [], urlTexts: string[] = []) {
    this.title = title;
    this.content = content;
    this.urls = urls;
    this.urlTexts = urlTexts;
  }

  getTitle(): string {
    return this.title;
  }

  setTitle(title: string): void {
    this.title = title;
  }

  getContent(): Description {
    return this.content;
  }

  setContent(content: Description): void {
    this.content = content;
  }

  getUrls(): string[] {
    return this.urls;
  }

  setUrls(urls: string[]): void {
    this.urls = urls;
  }

  addUrl(url: string): void {
    this.urls.push(url);
  }

  getUrlTexts(): string[] {
    return this.urlTexts;
  }

  setUrlTexts(urlTexts: string[]): void {
    this.urlTexts = urlTexts;
  }

  addUrlText(urlText: string): void {
    this.urlTexts.push(urlText);
  }
}
