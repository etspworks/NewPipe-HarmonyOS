/*
 * Port of the NON-UI half of org.schabi.newpipe.error.ReCaptchaActivity (the plan's svc_recaptcha),
 * plus App.setCookiesToDownloader() and HistorySettingsFragment's "clear reCaptcha cookies".
 *
 * When YouTube answers HTTP 429 the Downloader raises ReCaptchaException carrying the url; the app
 * opens that url in a WebView (endpoint `recaptcha_challenge_webview`), the user solves the
 * challenge, and the cookies the page hands back are stored and sent on every later request. This
 * module owns the cookie half — accumulating, persisting, and handing them to DownloaderImpl.
 *
 * The WebView PAGE is Phase 3. It calls handleCookiesFromUrl() with the url it is on and the
 * cookie string it read from its own WebviewController, so nothing here depends on ArkWeb.
 */

import { AppPreferences } from '../prefs/Preferences';
import { recaptcha_cookies_key } from '../prefs/SettingsKeys';
import { decodeUrlUtf8 } from '../extractor/core/Utils';
import { DownloaderImpl, RECAPTCHA_COOKIES_KEY } from './Downloader';

/** YouTube is the most likely service to have thrown a recaptcha. */
export const YT_URL: string = 'https://www.youtube.com';

/** Port of ReCaptchaActivity.sanitizeRecaptchaUrl(). */
export function sanitizeRecaptchaUrl(url: string | null): string {
  if (url === null || url.trim().length === 0) {
    return YT_URL;
  }
  // remove "pbj=1" parameter from YouTube urls, as it makes the page JSON and not HTML
  return url.replace('&pbj=1', '').replace('pbj=1&', '').replace('?pbj=1', '');
}

export class ReCaptchaCookieStore {
  private static readonly INSTANCE: ReCaptchaCookieStore = new ReCaptchaCookieStore();

  private foundCookies: string = '';

  private constructor() {
    // no instance
  }

  static getInstance(): ReCaptchaCookieStore {
    return ReCaptchaCookieStore.INSTANCE;
  }

  /** What has been collected so far in this challenge. */
  getFoundCookies(): string {
    return this.foundCookies;
  }

  /** Called when the challenge screen opens, so a new run does not inherit the last one. */
  reset(): void {
    this.foundCookies = '';
  }

  /**
   * Port of handleCookiesFromUrl(): the cookies the WebView holds for this url, plus the ones
   * YouTube sometimes puts INSIDE the url as `google_abuse=`.
   *
   * @param cookies what the WebView's own cookie manager returned for `url`, or null.
   */
  handleCookiesFromUrl(url: string | null, cookies: string | null): void {
    if (url === null) {
      return;
    }
    this.handleCookies(cookies);

    // sometimes cookies are inside the url
    const abuseStart: number = url.indexOf('google_abuse=');
    if (abuseStart !== -1) {
      const abuseEnd: number = url.indexOf('+path');
      if (abuseEnd > abuseStart + 13) {
        try {
          this.handleCookies(decodeUrlUtf8(url.substring(abuseStart + 13, abuseEnd)));
        } catch (e) {
          // invalid google abuse segment; the source logs and moves on
        }
      }
    }
  }

  /** Port of handleCookies(); add here methods to extract cookies for other services. */
  handleCookies(cookies: string | null): void {
    if (cookies === null) {
      return;
    }
    this.addYoutubeCookies(cookies);
  }

  private addYoutubeCookies(cookies: string): void {
    if (cookies.includes('s_gl=') || cookies.includes('goojf=')
      || cookies.includes('VISITOR_INFO1_LIVE=')
      || cookies.includes('GOOGLE_ABUSE_EXEMPTION=')) {
      // youtube seems to also need the other cookies:
      this.addCookie(cookies);
    }
  }

  private addCookie(cookie: string): void {
    if (this.foundCookies.includes(cookie)) {
      return;
    }
    if (this.foundCookies.length === 0 || this.foundCookies.endsWith('; ')) {
      this.foundCookies += cookie;
    } else if (this.foundCookies.endsWith(';')) {
      this.foundCookies += ' ' + cookie;
    } else {
      this.foundCookies += '; ' + cookie;
    }
  }

  /**
   * Port of saveCookiesAndFinish()'s persistence half: store what was collected and hand it to the
   * Downloader so the retried request carries it. Returns false when nothing was collected, which
   * is the source's RESULT_CANCELED.
   */
  saveCookies(): boolean {
    if (this.foundCookies.length === 0) {
      return false;
    }
    AppPreferences.instance().putString(recaptcha_cookies_key, this.foundCookies);
    DownloaderImpl.getInstance().setCookie(RECAPTCHA_COOKIES_KEY, this.foundCookies);
    return true;
  }

  /** Port of App.setCookiesToDownloader(): re-arm the Downloader at startup. */
  restoreToDownloader(): void {
    const stored: string = AppPreferences.instance().getStringSync(recaptcha_cookies_key, '');
    DownloaderImpl.getInstance().setCookie(RECAPTCHA_COOKIES_KEY, stored);
  }

  /** Port of HistorySettingsFragment's "clear reCaptcha cookies" action. */
  clearCookies(): void {
    this.foundCookies = '';
    AppPreferences.instance().putString(recaptcha_cookies_key, '');
    DownloaderImpl.getInstance().setCookie(RECAPTCHA_COOKIES_KEY, '');
  }

  /** Port of HistorySettingsFragment's enabled-state check for that action. */
  hasStoredCookies(): boolean {
    return AppPreferences.instance().getStringSync(recaptcha_cookies_key, '').length !== 0;
  }
}
