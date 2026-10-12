/**
 * comp_potoken_webview - port of org.schabi.newpipe.util.potoken.PoTokenWebView.
 *
 * SOURCE STRUCTURE (PoTokenWebView.kt): an OFF-SCREEN WebView owned by the Activity, never added
 * to the view hierarchy the user sees. It loads `assets/po_token.html` with base URL
 * https://www.youtube.com, runs BotGuard in it, and talks to Kotlin over a JavaScript interface
 * named `PoTokenWebView`. Its settings are exactly three: JavaScript ON, a desktop User-Agent,
 * and `blockNetworkLoads = true` ("the WebView does not need internet access" - every network hop
 * is done by DownloaderImpl, not by the page).
 *
 * The ArkTS half already exists in the data layer: `common/net/PoTokenProvider.ts` owns the
 * NETWORK side (the two BotGuard calls, the challenge/integrity parsing, the u8/base64
 * conversions) and declares `PoTokenWebViewDriver`. S4 supplies the JS side: the driver below
 * evaluates the same three snippets the source evaluates, and `javaScriptProxy` registers the
 * `PoTokenWebView` JS interface those snippets call back into
 * (`webView.addJavascriptInterface(this, JS_INTERFACE)`, line 45).
 *
 * `po_token.html` is bundled at entry/src/main/resources/rawfile/po_token.html.
 *
 * Per phase2-logic-contract.md 2.3 this whole path is BEST-EFFORT and never fatal: a rejected
 * promise here resolves PoTokenProviderImpl.prepare() to false and the extractor loads through
 * the nsig-free client profiles (ANDROID / IOS / TVHTML5), which need no poToken.
 *
 * ponytail: the page is loaded straight from rawfile rather than through the source's
 * `loadDataWithBaseURL("https://www.youtube.com", ...)`, so the document origin is the local
 * resource one rather than youtube.com. Upgrade path if BotGuard is ever measured to reject that
 * origin: read the rawfile with resourceManager and hand it to
 * `WebviewController.loadData(html, 'text/html', 'utf-8', 'https://www.youtube.com')` instead.
 *
 * The component renders no controls and must never take a touch - it is 1x1 and
 * hit-test-transparent so it cannot sit on top of whatever the host page draws at that corner.
 */
import { webview } from '@kit.ArkWeb';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { PoTokenProviderImpl, PoTokenWebViewDriver } from '../common/net/PoTokenProvider';

const TAG: string = 'PoTokenWebView';

/**
 * AppStorage key the host page's `@StorageLink` watches. While it is false no `Web` exists in
 * the tree at all, which is what the source does: MainActivity never creates a PoTokenWebView -
 * PoTokenProviderImpl.getWebClientPoToken() creates one lazily, and only when it needs a token
 * (`shouldRecreate` -> `PoTokenWebView.newPoTokenGenerator(App.instance)`,
 * PoTokenProviderImpl.kt:80).
 */
export const PO_TOKEN_WEBVIEW_NEEDED: string = 'poTokenWebViewNeeded';

/**
 * Port of the companion object's `newPoTokenGenerator(context)`: the ONE entry point that brings
 * the WebView into existence. Call it before awaiting PoTokenProviderImpl.prepare(videoId) - the
 * component mounts in response, loads po_token.html and calls setDriver() from onPageEnd, exactly
 * as before. Until something asks, no driver is registered and the extractor stays on the
 * nsig-free clients, which is the documented fallback (phase2-logic-contract.md 2.3) and not a
 * failure.
 */
export function requestPoTokenWebView(): void {
  AppStorage.setOrCreate<boolean>(PO_TOKEN_WEBVIEW_NEEDED, true);
}

/** PoTokenWebView.JS_INTERFACE - the name the snippets in po_token.html call back through. */
const JS_INTERFACE: string = 'PoTokenWebView';

/** PoTokenWebView's USER_AGENT: the desktop UA BotGuard expects. */
const PO_TOKEN_USER_AGENT: string = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) '
  + 'AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.3';

/**
 * The driver AND the JavaScript interface in one object, exactly as the source's PoTokenWebView
 * is both the Kotlin API and the `@JavascriptInterface` receiver. The `on*` methods are the ones
 * listed in `methodList` below; everything else is ArkTS-side only.
 */
class PoTokenWebViewDriverImpl implements PoTokenWebViewDriver {
  private controller: webview.WebviewController;

  private botGuardResolve: ((value: string) => void) | null = null;
  private botGuardReject: ((error: Error) => void) | null = null;
  /** identifier -> the pending generatePoToken() call, so several can run in parallel. */
  private poTokenResolvers: Map<string, (value: string) => void> =
    new Map<string, (value: string) => void>();
  private poTokenRejecters: Map<string, (error: Error) => void> =
    new Map<string, (error: Error) => void>();

  constructor(controller: webview.WebviewController) {
    this.controller = controller;
  }

  /* ---- PoTokenWebViewDriver ---- */

  /** downloadAndRunBotguard()'s snippet (line 119), with the network half already done. */
  runBotGuard(challengeData: string): Promise<string> {
    return new Promise<string>((resolve: (value: string) => void,
      reject: (error: Error) => void): void => {
      this.botGuardResolve = resolve;
      this.botGuardReject = reject;
      this.evaluate(`try {
          data = ${challengeData}
          runBotGuard(data).then(function (result) {
            this.webPoSignalOutput = result.webPoSignalOutput
            ${JS_INTERFACE}.onRunBotguardResult(result.botguardResponse)
          }, function (error) {
            ${JS_INTERFACE}.onJsInitializationError(error + "\\n" + error.stack)
          })
        } catch (error) {
          ${JS_INTERFACE}.onJsInitializationError(error + "\\n" + error.stack)
        }`, reject);
    });
  }

  /** onRunBotguardResult()'s second snippet (line 169): `this.integrityToken = <u8>`. */
  setIntegrityToken(integrityTokenU8: string): Promise<void> {
    return this.controller.runJavaScript('this.integrityToken = ' + integrityTokenU8)
      .then((): void => {
        hilog.info(0x0000, TAG, 'BotGuard initialization finished');
      });
  }

  /**
   * generatePoToken()'s snippet (line 189). Resolves with the raw "97,98,99" u8 string - the
   * base64 conversion is PoTokenProviderImpl's, exactly as u8ToBase64 is applied on the Kotlin
   * side of onObtainPoTokenResult.
   */
  obtainPoToken(identifier: string, u8Identifier: string): Promise<string> {
    return new Promise<string>((resolve: (value: string) => void,
      reject: (error: Error) => void): void => {
      this.poTokenResolvers.set(identifier, resolve);
      this.poTokenRejecters.set(identifier, reject);
      this.evaluate(`try {
          identifier = "${identifier}"
          u8Identifier = ${u8Identifier}
          poTokenU8 = obtainPoToken(webPoSignalOutput, integrityToken, u8Identifier)
          poTokenU8String = ""
          for (i = 0; i < poTokenU8.length; i++) {
            if (i != 0) poTokenU8String += ","
            poTokenU8String += poTokenU8[i]
          }
          ${JS_INTERFACE}.onObtainPoTokenResult(identifier, poTokenU8String)
        } catch (error) {
          ${JS_INTERFACE}.onObtainPoTokenError(identifier, error + "\\n" + error.stack)
        }`, reject);
    });
  }

  /** close(): every still-pending call is failed rather than left hanging. */
  close(): void {
    const pending: Error = new Error('PoTokenWebView was closed');
    this.failInitialization(pending);
    this.poTokenRejecters.forEach((rejecter: (error: Error) => void): void => {
      rejecter(pending);
    });
    this.poTokenResolvers.clear();
    this.poTokenRejecters.clear();
  }

  /* ---- The JavaScript interface (methodList below) ---- */

  /** onRunBotguardResult(botguardResponse) - line 152. */
  onRunBotguardResult(botguardResponse: string): void {
    const resolve: ((value: string) => void) | null = this.botGuardResolve;
    this.botGuardResolve = null;
    this.botGuardReject = null;
    if (resolve !== null) {
      resolve(botguardResponse);
    }
  }

  /** onJsInitializationError(error) - line 140. */
  onJsInitializationError(error: string): void {
    hilog.error(0x0000, TAG, 'Initialization error from JavaScript: %{public}s', error);
    this.failInitialization(new Error(error));
  }

  /** onObtainPoTokenResult(identifier, poTokenU8) - line 223. */
  onObtainPoTokenResult(identifier: string, poTokenU8: string): void {
    const resolve: ((value: string) => void) | undefined =
      this.poTokenResolvers.get(identifier);
    this.poTokenResolvers.delete(identifier);
    this.poTokenRejecters.delete(identifier);
    if (resolve !== undefined) {
      resolve(poTokenU8);
    }
  }

  /** onObtainPoTokenError(identifier, error) - line 211. */
  onObtainPoTokenError(identifier: string, error: string): void {
    hilog.error(0x0000, TAG, 'obtainPoToken error from JavaScript: %{public}s', error);
    const reject: ((e: Error) => void) | undefined = this.poTokenRejecters.get(identifier);
    this.poTokenResolvers.delete(identifier);
    this.poTokenRejecters.delete(identifier);
    if (reject !== undefined) {
      reject(new Error(error));
    }
  }

  /* ---- internals ---- */

  private failInitialization(error: Error): void {
    const reject: ((e: Error) => void) | null = this.botGuardReject;
    this.botGuardResolve = null;
    this.botGuardReject = null;
    if (reject !== null) {
      reject(error);
    }
  }

  /**
   * The source's `webView.evaluateJavascript(...)` never throws at the caller; here a rejected
   * runJavaScript (no page loaded, a broken WebView) has to fail the pending promise instead of
   * leaving it open forever, which would hang the whole poToken path.
   */
  private evaluate(script: string, reject: (error: Error) => void): void {
    this.controller.runJavaScript(script).catch((err: Error): void => {
      hilog.error(0x0000, TAG, 'runJavaScript failed: %{public}s', err.message);
      reject(err);
    });
  }
}

@Component
export struct PoTokenWebView {
  private controller: webview.WebviewController = new webview.WebviewController();
  private driver: PoTokenWebViewDriverImpl =
    new PoTokenWebViewDriverImpl(this.controller);

  aboutToDisappear(): void {
    // Unregistering leaves the extractor on the nsig-free client, which is the documented
    // fallback rather than a failure (contract 2.3).
    PoTokenProviderImpl.getInstance().setDriver(null);
    this.driver.close();
  }

  build() {
    Web({ src: $rawfile('po_token.html'), controller: this.controller })
      .javaScriptAccess(true)
      // webView.addJavascriptInterface(this, JS_INTERFACE)
      .javaScriptProxy({
        object: this.driver,
        name: JS_INTERFACE,
        methodList: ['onRunBotguardResult', 'onJsInitializationError',
          'onObtainPoTokenResult', 'onObtainPoTokenError'],
        controller: this.controller
      })
      .userAgent(PO_TOKEN_USER_AGENT)
      // webViewSettings.blockNetworkLoads = true
      .blockNetwork(true)
      .width(1)
      .height(1)
      .hitTestBehavior(HitTestMode.Transparent)
      .onPageEnd((): void => {
        // Registering only once the BotGuard helpers in po_token.html exist is what keeps the
        // nsig-free path in charge until the WebView can actually answer.
        PoTokenProviderImpl.getInstance().setDriver(this.driver);
      })
  }
}
