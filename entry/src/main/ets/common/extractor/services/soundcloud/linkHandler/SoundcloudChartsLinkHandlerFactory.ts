/*
 * Port of org.schabi.newpipe.extractor.services.soundcloud.linkHandler
 * .SoundcloudChartsLinkHandlerFactory (NewPipeExtractor v0.26.5).
 *
 * The only SoundCloud factory that needs no network round trip: both directions are constants.
 */

import { ListLinkHandlerFactory } from '../../../linkhandler/LinkHandlerFactory';
import { Parser } from '../../../core/Parser';

const URL_PATTERN: RegExp =
  new RegExp('^https?://(www\\.|m\\.)?soundcloud.com/charts(/top|/new)?/?([#?].*)?$');

export class SoundcloudChartsLinkHandlerFactory extends ListLinkHandlerFactory {
  private static readonly INSTANCE: SoundcloudChartsLinkHandlerFactory =
    new SoundcloudChartsLinkHandlerFactory();

  static getInstance(): SoundcloudChartsLinkHandlerFactory {
    return SoundcloudChartsLinkHandlerFactory.INSTANCE;
  }

  getId(url: string): string {
    return 'New & hot';
  }

  getUrlWithFilters(id: string, contentFilter: string[], sortFilter: string,
    baseUrl: string | null = null): string {
    return 'https://soundcloud.com/charts/new';
  }

  onAcceptUrl(url: string): boolean {
    return Parser.isMatch(URL_PATTERN, url.toLowerCase());
  }
}
