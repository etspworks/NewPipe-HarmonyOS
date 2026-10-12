/**
 * S4 - ReCaptchaActivity (screen_recaptcha_activity). presentation: page. State + wiring only.
 *
 * activity_recaptcha.xml is exactly two views: R.id.toolbar and R.id.reCaptchaWebView. Read
 * verbatim off ReCaptchaActivity.java:49-233 (codegraph):
 *  - The URL is sanitizeRecaptchaUrl(getIntent().getStringExtra(RECAPTCHA_URL_EXTRA)): null/blank
 *    falls back to YT_URL (https://www.youtube.com), and every "pbj=1" form is stripped (it would
 *    make the page JSON). Both branches live in the ported sanitizeRecaptchaUrl() in
 *    common/net/ReCaptchaCookieStore.ts (svc_recaptcha) and are called with the RAW argument, so
 *    a missing extra really takes the null branch instead of being papered over with a literal.
 *    RouterActivityPage / the error panels push that extra as the `recaptcha_url` param, and a
 *    cold deep link delivers the same key through EntryAbility's want parameters.
 *  - JavaScript is ENABLED and the user agent is forced to DownloaderImpl.USER_AGENT.
 *  - Cache, history and ALL cookies are cleared before the load.
 *  - BOTH shouldOverrideUrlLoading and onPageFinished call handleCookiesFromUrl(url) - here
 *    onLoadIntercept (returning false: never block the navigation, exactly as the source returns
 *    false) and onPageEnd. handleCookiesFromUrl reads the cookie manager for that url AND parses
 *    an inline `google_abuse=` parameter out of the URL itself; only cookies containing s_gl= /
 *    goojf= / VISITOR_INFO1_LIVE= / GOOGLE_ABUSE_EXEMPTION= are kept (addYoutubeCookies). All of
 *    that is the ported ReCaptchaCookieStore - this page supplies the url and the cookie string
 *    its own WebCookieManager returned, and stores nothing itself.
 *  - saveCookiesAndFinish() first harvests the cookies of the still-open page, then: non-empty
 *    foundCookies -> persist under recaptcha_cookies_key + DownloaderImpl.setCookie(...) +
 *    RESULT_OK; empty -> the result stays RESULT_CANCELED. Then it loads "about:blank" to stop
 *    background playback and NavUtils.navigateUpTo(MainActivity | FLAG_ACTIVITY_CLEAR_TOP).
 *    That last call is the plan's single navOut edge, kind REPLACE - hence replaceUrl, not
 *    pushUrl: the source clears the stack rather than stacking MainActivity on the captcha.
 *  - BACK IS NOT A CANCEL. onBackPressed() is @SuppressLint("MissingSuperCall") and calls
 *    saveCookiesAndFinish() - it COMMITS whatever cookies were found. onBackPress() below
 *    therefore returns true and really handles the press. It is an override, NOT a view: it
 *    carries no android:id and the capture records no node for it, so this screen renders NO
 *    back control (contract S0011 downgrades that entry for exactly that reason). The same
 *    saveCookiesAndFinish() stays observable through menu_item_done.
 *  - The action bar sets title + subtitle and explicitly DISABLES home-as-up, so there is no
 *    up affordance; menu_recaptcha contributes the single menu_item_done.
 *
 * feat_webview is the Web component of @kit.ArkWeb plus @ohos.web.webview's WebCookieManager;
 * it needs no permission beyond the INTERNET already in module.json5. isLoading / errorInfo are
 * wired to the Web's own load callbacks here and stay UNRENDERED at S4 - their loading and error
 * visuals are S6's half, and the source draws neither.
 */
import { router } from '@kit.ArkUI';
import { webview } from '@kit.ArkWeb';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { ReCaptchaCookieStore, sanitizeRecaptchaUrl, YT_URL }
  from '../common/net/ReCaptchaCookieStore';
import { USER_AGENT } from '../common/net/Downloader';

const TAG: string = 'ReCaptchaActivity';

/** ReCaptchaActivity.RECAPTCHA_URL_EXTRA, as RouterActivityPage and the error panels push it. */
const RECAPTCHA_URL_PARAM: string = 'recaptcha_url';

@Entry
@Component
export struct ReCaptchaActivityPage {
  /**
   * R.id.reCaptchaWebView's url: sanitizeRecaptchaUrl(getIntent().getStringExtra(
   * RECAPTCHA_URL_EXTRA)). The plan names this state var `webView`; it holds what the web view
   * loads, which is the only state the source's WebView carries.
   */
  @State webView: string = YT_URL;
  /** onPageBegin..onPageEnd - the challenge page is remote and takes a visible moment. */
  @State isLoading: boolean = false;
  /** onErrorReceive's getErrorInfo(); empty means the load reported nothing. */
  @State errorInfo: string = '';

  private controller: webview.WebviewController = new webview.WebviewController();
  /** svc_recaptcha: the cookie accumulation, filtering and persistence (never done here). */
  private cookies: ReCaptchaCookieStore = ReCaptchaCookieStore.getInstance();

  aboutToAppear(): void {
    // A new challenge must not inherit the cookies of the last one (`foundCookies = ""`).
    this.cookies.reset();
    this.webView = sanitizeRecaptchaUrl(this.readUrlArgument());
    // CookieManager.getInstance().removeAllCookies(null), before the load.
    try {
      webview.WebCookieManager.clearAllCookiesSync();
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      hilog.error(0x0000, TAG, 'clearAllCookiesSync failed: %{public}s', error.message);
    }
  }

  /**
   * getIntent().getStringExtra(RECAPTCHA_URL_EXTRA) - null when the extra is absent, which is
   * the input sanitizeRecaptchaUrl's YT_URL branch exists for.
   */
  private readUrlArgument(): string | null {
    const params: Record<string, Object> | undefined =
      router.getParams() as Record<string, Object> | undefined;
    if (params === undefined || params === null) {
      return null;
    }
    const raw: Object | undefined = params[RECAPTCHA_URL_PARAM];
    if (raw === undefined || raw === null) {
      return null;
    }
    return raw.toString();
  }

  /**
   * handleCookiesFromUrl(url): the cookies WebCookieManager holds for this url go to
   * svc_recaptcha, which also digs the inline `google_abuse=` cookie out of the url itself.
   */
  private handleCookiesFromUrl(url: string | null): void {
    if (url === null || url.length === 0) {
      return;
    }
    let cookies: string | null = null;
    try {
      cookies = webview.WebCookieManager.fetchCookieSync(url);
    } catch (err) {
      // No cookie store entry for this url; the source's getCookie() returns null the same way.
      cookies = null;
    }
    this.cookies.handleCookiesFromUrl(url, cookies);
  }

  /** saveCookiesAndFinish(), in the source's order. */
  private saveCookiesAndFinish(): void {
    // try to get cookies of unclosed page
    let current: string = '';
    try {
      current = this.controller.getUrl();
    } catch (err) {
      // The controller is not attached to a loaded page; there is no open url to harvest.
      current = '';
    }
    this.handleCookiesFromUrl(current.length === 0 ? null : current);

    // !foundCookies.isEmpty() -> persist + hand them to the Downloader + setResult(RESULT_OK).
    // An empty harvest stores nothing and leaves the result RESULT_CANCELED.
    if (this.cookies.saveCookies()) {
      hilog.info(0x0000, TAG, '%{public}s', 'saveCookiesAndFinish: cookies stored (RESULT_OK)');
    } else {
      hilog.info(0x0000, TAG, '%{public}s', 'saveCookiesAndFinish: no cookies (RESULT_CANCELED)');
    }

    // Navigate to blank page (unloads youtube to prevent background playback)
    try {
      this.controller.loadUrl('about:blank');
    } catch (err) {
      // Nothing was loaded, so nothing is playing.
    }

    // NavUtils.navigateUpTo(MainActivity | FLAG_ACTIVITY_CLEAR_TOP): replace, never push.
    router.replaceUrl({ url: 'pages/MainActivityPage' })
      .catch((err: BusinessError): void => {
        hilog.error(0x0000, TAG, 'navigateUpTo failed: %{public}s', err.message);
      });
  }

  /** onBackPressed() override: Back commits, it does not cancel. */
  onBackPress(): boolean {
    this.saveCookiesAndFinish();
    return true;
  }

  build() {
    Column() {
      // toolbar: title_activity_recaptcha / subtitle_activity_recaptcha, home-as-up disabled.
      //
      // S5, measured off S0011 (1080px / 360vp, density 3.0). The bar is [0,72][1080,240] = 56vp,
      // ?attr/actionBarSize, on ?attr/colorPrimary sampled #E53935 = light_youtube_primary_color.
      // Its title inset is 48px = 16vp, which is the no-navigation-icon inset - the source
      // disables home-as-up, so nothing sits left of the text.
      //
      // The CONTENT colour here is dark, not the white the style baseline carries: this Toolbar
      // gets no android:theme in activity_recaptcha.xml, so it keeps the activity's default text
      // appearance instead of NewPipe's ToolbarTheme (actionColor=@color/white). The pixels
      // agree - title #1E0707 is textColorPrimary #DE000000 composited over #E53935, subtitle
      // #691A18 is textColorSecondary #8A000000 over the same red, and the action glyph is pure
      // #000000. Using color.onPrimary here would have been the baseline's value on the wrong bar.
      Row() {
        // actionBar title + subtitle. home-as-up is explicitly DISABLED in the source, so the
        // toolbar carries no up affordance - the only control on it is the Done menu item.
        // The pair measures 84..228px = 48vp, centred in the 56vp bar: title line 27vp (20sp),
        // subtitle line 21vp (14sp).
        Column() {
          Text($r('app.string.title_activity_recaptcha'))
            .fontSize(20)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.on_surface'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Text($r('app.string.subtitle_activity_recaptcha'))
            .fontSize(14)
            .fontColor($r('app.color.on_surface_variant'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
        .justifyContent(FlexAlign.Center)

        // menu_recaptcha -> R.id.menu_item_done -> saveCookiesAndFinish(). onOptionsItemSelected
        // returns false for everything else, so this is the toolbar's only action.
        // [936,84][1080,228] = a 48vp square action item flush with the bar's end.
        // The source renders this as an ICON, never a label: menu_recaptcha.xml declares
        // android:icon="@drawable/ic_done" with showAsAction="always", and S0011 shows a black
        // checkmark with content-desc "Done" and no text at all. The .id() is what the replay
        // and the correctness gate address it by (Rule 12), so an icon-only item stays findable.
        // S6: the action item is a 48vp SQUARE, not a bare 24vp glyph - [936,84][1080,228] in
        // S0011 is exactly 48x48vp flush with the bar's end, and the 24vp ic_done draws centred
        // inside it. Carrying the glyph alone left an item whose bounds (and tap target) were
        // half the source's; 12vp of padding inside a 48vp box renders the same pixels at the
        // same centre (x 1008px) and restores the source's own hit area.
        Image($r('app.media.ic_done'))
          .id('menu_item_done')
          .accessibilityText($r('app.string.done'))
          .width(48)
          .height(48)
          .padding(12)
          .objectFit(ImageFit.Contain)
          .fillColor($r('app.color.accent'))
          .onClick(() => {
            this.saveCookiesAndFinish();
          })
      }
      .id('toolbar')
      .width('100%')
      .height(56)
      .alignItems(VerticalAlign.Center)
      .padding({ left: 16 })
      .backgroundColor($r('app.color.primary'))

      Web({ src: this.webView, controller: this.controller })
        .id('reCaptchaWebView')
        // webSettings.setJavaScriptEnabled(true)
        .javaScriptAccess(true)
        .onControllerAttached(() => {
          // webSettings.setUserAgentString(DownloaderImpl.USER_AGENT), and the cache/history
          // wipe: both need the attached controller, and both run before the first load.
          try {
            this.controller.setCustomUserAgent(USER_AGENT);
            this.controller.removeCache(true);
            this.controller.clearHistory();
          } catch (err) {
            const error: BusinessError = err as BusinessError;
            hilog.error(0x0000, TAG, 'web setup failed: %{public}s', error.message);
          }
        })
        .onPageBegin((event: OnPageBeginEvent) => {
          this.isLoading = true;
          this.errorInfo = '';
          hilog.debug(0x0000, TAG, 'loading %{public}s', event.url);
        })
        // WebViewClient.shouldOverrideUrlLoading: harvest, then return false (never intercept).
        .onLoadIntercept((event: OnLoadInterceptEvent): boolean => {
          this.handleCookiesFromUrl(event.data.getRequestUrl());
          return false;
        })
        // WebViewClient.onPageFinished(view, url)
        .onPageEnd((event: OnPageEndEvent) => {
          this.isLoading = false;
          this.handleCookiesFromUrl(event.url);
        })
        .onErrorReceive((event: OnErrorReceiveEvent) => {
          this.isLoading = false;
          this.errorInfo = event.error.getErrorInfo();
        })
        .width('100%')
        .layoutWeight(1)
    }
    .id('ReCaptchaActivityPage')
    .width('100%')
    .height('100%')
    // The whole area below the bar is the WebView's own page, sampled #FFFFFF in S0011.
    .backgroundColor($r('app.color.surface'))
  }
}
