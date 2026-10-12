/**
 * S3 — ErrorActivity (screen_error_activity), structure from activity_error.xml +
 * toolbar_layout.xml + error_menu.xml + ErrorActivity.kt. SOURCE-ONLY, no captured state.
 *
 * The activity is opened only by ErrorUtil.getErrorActivityIntent with a Parcelable ERROR_INFO
 * extra that onCreate non-null asserts (`...ErrorInfo::class.java)!!`), so it CANNOT render
 * without one — the whole page is bound to that object (S4 reads it out of the router params).
 * There is no network call of its own: buildJson()/buildMarkdown() are pure string building and
 * the send step is delegated to the mail app, the clipboard or the browser.
 *
 * navOut is empty. The only navigation is android.R.id.home -> onBackPressed(), wired below.
 *
 * SHARE (menu_item_share_error): `@kit.ShareKit` does NOT exist in this SDK — no
 * kits/@kit.ShareKit.d.ts and no `systemShare` symbol anywhere under sdk/default/openharmony/ets.
 * The send path is an implicit want, `startAbility` with action 'ohos.want.action.sendData',
 * plus the @ohos.pasteboard copy + toast fallback. Wired in S4 through svc_share, not here.
 *
 * The privacy-policy AlertDialog is setCancelable(false) with exactly three exits (Read privacy
 * policy / Accept / Decline), so it REPLACES the body rather than sitting beside it — the same
 * convention DownloadDialogPage uses, and it keeps the dialog's slugs from coexisting with the
 * body's.
 *
 * conditionalVariants (stackTraces.size > 1, non-empty user comment, BASE_OS) all live inside
 * buildMarkdown()/buildInfo() string building, not in the view tree; they land in S4.
 *
 * S5 — styled from the SOURCE theme (this screen has no capture): activity_error.xml +
 * toolbar_layout.xml + values/dimens.xml, and the app-level style baseline in
 * state.json generation.styleBaseline. Style only.
 */
import { router } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError, deviceInfo } from '@kit.BasicServicesKit';
import { bundleManager, common } from '@kit.AbilityKit';

import { ErrorInfo, ErrorInfoJson } from '../model/app/ErrorInfo';
import { ERROR_INFO_PARAM } from '../common/error/ErrorReporter';
import { ShareUtils } from '../common/share/ShareUtils';
import { ServiceLocator } from '../common/di/ServiceLocator';
import { Localization } from '../common/i18n/Localization';
import { DIALOG_MASK_COLOR } from '../common/theme/ServiceTheme';
import { BLACK_THEME_KEY, themedBackground } from '../common/theme/ThemeBackground';

const TAG: string = 'ErrorActivityPage';
/** ErrorActivity.ERROR_EMAIL_ADDRESS. */
const ERROR_EMAIL_ADDRESS: string = 'crashreport@newpipe.schabi.org';
/** ErrorActivity.ERROR_GITHUB_ISSUE_URL. */
const ERROR_GITHUB_ISSUE_URL: string = 'https://github.com/TeamNewPipe/NewPipe/issues';

/* S5 sizes the toolbar icons; S3 only needs the boxes to exist. */
const ICON_SIZE: number = 24;
const TOOLBAR_HEIGHT: number = 56;
const ACTION_SIZE: number = 48;
/* @dimen/activity_horizontal_margin / activity_vertical_margin. */
const PAGE_MARGIN: number = 16;

/* S5 — baseline tokens (state.json generation.styleBaseline, source S0004). */
const C_ON_SURFACE: Resource = $r('app.color.on_surface');
const C_SECONDARY: Resource = $r('app.color.on_surface_variant');


@Entry
@Component
export struct ErrorActivityPage {
  /** ThemeHelper's black theme: the window background follows it. */
  @StorageProp(BLACK_THEME_KEY) blackTheme: boolean = false;

  /** openPrivacyPolicyDialog(this, "EMAIL" | "GITHUB") — which branch Accept runs. */
  @State privacyDialogTarget: string = '';
  /** The dialog is setCancelable(false): only its own three buttons close it. */
  @State showPrivacyDialog: boolean = false;
  /** errorInfo.getMessage(this), linkified by setTextWithLinks — bound in S4. */
  @State errorMessage: string = '';
  /** buildInfo(errorInfo): userAction.message, request, languages, service, timestamp, os. */
  @State infoBlock: string = '';
  /** formErrorText(errorInfo.stackTraces) — traces joined with dashed separators. */
  @State stackTraces: string = '';
  /** ZonedDateTime.now().format(ISO_OFFSET_DATE_TIME), taken once at screen open. */
  @State timestamp: string = '';
  /** errorCommentBox — read by buildJson() as user_comment, prepended by buildMarkdown(). */
  @State userComment: string = '';
  /** addGuruMeditation(): the sorry text plus a newline and R.string.guru_meditation. */
  @State errorInfo: string | null = null;
  /** buildJson()/buildMarkdown() are pure string building; nothing here loads. */
  @State isLoading: boolean = false;

  /** The ERROR_INFO extra onCreate non-null asserts — the whole page is bound to it. */
  private report: ErrorInfo | null = null;

  aboutToAppear(): void {
    this.readArguments();
  }

  /** ErrorUtil.getErrorActivityIntent(): the ErrorInfo travels as its JSON record. */
  private readArguments(): void {
    const params: Record<string, Object> | undefined =
      router.getParams() as Record<string, Object> | undefined;
    // ZonedDateTime.now().format(ISO_OFFSET_DATE_TIME), taken once at screen open.
    this.timestamp = new Date().toISOString();
    if (params === undefined || params === null) {
      return;
    }
    const raw: Object | undefined = params[ERROR_INFO_PARAM];
    if (raw === undefined || raw === null) {
      return;
    }
    // The error NOTIFICATION hands the info over as a JSON string (want parameters carry plain
    // values); the in-app opener passes the object itself. The string used to be read as the
    // object, so opening a report from the shade crashed this page on stackTraces.join.
    const json: ErrorInfoJson = typeof raw === 'string'
      ? JSON.parse(raw as string) as ErrorInfoJson : raw as ErrorInfoJson;
    const info: ErrorInfo = ErrorInfo.fromJson(json);
    this.report = info;
    // setTextWithLinks(errorInfo.getMessage(this)).
    this.errorMessage = Localization.getStringArgs(info.message.stringName,
      info.message.formatArgs);
    this.stackTraces = ErrorActivityPage.formErrorText(info.stackTraces);
    this.infoBlock = this.buildInfoBlock(info);
    // addGuruMeditation(): the sorry text gains the easter egg.
    this.errorInfo = Localization.getString('guru_meditation');
  }

  /** formErrorText(stackTraces): the traces joined with the source's dashed separator. */
  private static formErrorText(traces: string[] | undefined): string {
    const separator: string = '-------------------------------------\n';
    return traces === undefined || traces === null ? '' : traces.join(separator);
  }

  /**
   * buildInfo(errorInfo): the metadata column, one value per info label, newline joined.
   *
   * The column is laid out beside errorInfoLabelsView, which renders R.string.info_labels - TEN
   * labels: What, Request, Content Language, Content Country, App Language, Service, Timestamp,
   * Package, Version, OS version. The two Texts line up only positionally, so this MUST emit
   * exactly ten lines in that order. It previously emitted six, merging content language and
   * country into one line and dropping app language, package and version entirely, which slid
   * every later value up onto the wrong label - the device showed "Content Country: YouTube",
   * "App Language: <timestamp>" and "Service: HarmonyOS". Any value that cannot be read still
   * has to occupy its line, so failures fall back to '' rather than being skipped.
   */
  private buildInfoBlock(info: ErrorInfo): string {
    let packageName: string = '';
    let versionName: string = '';
    try {
      const bundle: bundleManager.BundleInfo = bundleManager.getBundleInfoForSelfSync(
        bundleManager.BundleFlag.GET_BUNDLE_INFO_WITH_APPLICATION);
      packageName = bundle.name;
      versionName = bundle.versionName;
    } catch (err) {
      // A blank Package/Version row is correct here; the labels must not shift.
      const failure: BusinessError = err as BusinessError;
      hilog.warn(0x0000, TAG, 'bundle info unreadable: %{public}s', failure.message);
    }
    const lines: string[] = [
      info.userAction,
      info.request,
      Localization.getPreferredLocalization(),
      Localization.getPreferredContentCountry(),
      Localization.getAppLocale(),
      info.getServiceName(),
      this.timestamp,
      packageName,
      versionName,
      deviceInfo.osFullName + ' - ' + deviceInfo.sdkApiVersion
    ];
    return lines.join('\n');
  }

  /** buildJson(): what the e-mail and the share sheet carry. */
  private buildJson(): string {
    const info: ErrorInfo | null = this.report;
    if (info === null) {
      return '';
    }
    const record: Record<string, string> = {
      'user_action': info.userAction,
      'request': info.request,
      'content_language': Localization.getPreferredLocalization(),
      'content_country': Localization.getPreferredContentCountry(),
      'service': info.getServiceName(),
      'time': this.timestamp,
      'os': 'HarmonyOS',
      'user_comment': this.userComment,
      'exceptions': info.stackTraces.join('\n')
    };
    return JSON.stringify(record);
  }

  /**
   * buildMarkdown(): the user comment first, then the metadata, then the stack traces — a single
   * collapsed details block titled "Exceptions (N)" once there is more than one.
   */
  private buildMarkdown(): string {
    const info: ErrorInfo | null = this.report;
    if (info === null) {
      return '';
    }
    let out: string = '';
    // A non-empty user comment is prepended to the report.
    if (this.userComment.length > 0) {
      out += this.userComment + '\n\n';
    }
    out += '## Exception\n';
    out += '* __User Action:__ ' + info.userAction + '\n';
    out += '* __Request:__ ' + info.request + '\n';
    out += '* __Content Country:__ ' + Localization.getPreferredContentCountry() + '\n';
    out += '* __Content Language:__ ' + Localization.getPreferredLocalization() + '\n';
    out += '* __Service:__ ' + info.getServiceName() + '\n';
    out += '* __Version:__ ' + this.timestamp + '\n';
    out += '* __OS:__ HarmonyOS\n\n';

    const traces: string[] = info.stackTraces;
    if (traces.length > 1) {
      // More than one crash log: all of them go inside ONE collapsed block, each numbered.
      out += '<details><summary><b>Exceptions (' + traces.length + ')</b></summary><p>\n\n';
      for (let i: number = 0; i < traces.length; i++) {
        out += '### Crash log ' + (i + 1) + '\n```\n' + traces[i] + '\n```\n';
      }
      out += '</p></details>\n';
    } else if (traces.length === 1) {
      out += '<details><summary><b>Crash log</b></summary><p>\n\n```\n' + traces[0]
        + '\n```\n</p></details>\n';
    }
    return out;
  }

  /** BUTTON_NEUTRAL: ShareUtils.openUrlInApp(context, R.string.privacy_policy_url). */
  private openPrivacyPolicy(): void {
    const share: ShareUtils = ServiceLocator.get().share;
    share.openUrlInBrowser(Localization.getString('privacy_policy_url'))
      .catch((err: BusinessError): void => {
        hilog.error(0x0000, TAG, 'privacy policy: %{public}s', err.message);
      });
  }

  /** BUTTON_POSITIVE: runs the EMAIL (ACTION_SENDTO mailto) or the GITHUB branch. */
  private acceptPrivacyPolicy(): void {
    this.showPrivacyDialog = false;
    const share: ShareUtils = ServiceLocator.get().share;
    if (this.privacyDialogTarget === 'EMAIL') {
      // ACTION_SENDTO mailto: with EXTRA_EMAIL, EXTRA_SUBJECT and EXTRA_TEXT = buildJson(). The
      // HarmonyOS form is the same mailto uri under ohos.want.action.sendToData, which a mail app
      // declares (Huawei Email does, as ComposeMail): the draft opens addressed and filled in.
      this.composeReportMail();
    } else {
      share.openUrlInBrowser(ERROR_GITHUB_ISSUE_URL)
        .catch((err: BusinessError): void => {
          hilog.error(0x0000, TAG, 'github issues: %{public}s', err.message);
        });
    }
  }

  /** errorEmailSubject: "Exception in <app_name> <versionName>". */
  private errorEmailSubject(): string {
    let versionName: string = '';
    try {
      versionName = bundleManager.getBundleInfoForSelfSync(
        bundleManager.BundleFlag.GET_BUNDLE_INFO_DEFAULT).versionName;
    } catch (err) {
      versionName = '';
    }
    return 'Exception in ' + Localization.getString('app_name') + ' ' + versionName;
  }

  /**
   * ShareUtils.openIntentInApp(mailto): no mail app installed is the source's "no app to open
   * this" case, which the share sheet still covers here rather than dropping the report.
   */
  private composeReportMail(): void {
    const uri: string = 'mailto:' + ERROR_EMAIL_ADDRESS
      + '?subject=' + encodeURIComponent(this.errorEmailSubject())
      + '&body=' + encodeURIComponent(this.buildJson());
    const context: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
    context.startAbility({ action: 'ohos.want.action.sendToData', uri: uri })
      .catch((err: BusinessError): void => {
        hilog.warn(0x0000, TAG, 'no mail app: %{public}s', err.message);
        ServiceLocator.get().share.shareText(this.errorEmailSubject(), this.buildJson());
      });
  }

  /** BUTTON_NEGATIVE: a null listener in the source — it only closes the dialog. */
  private declinePrivacyPolicy(): void {
    this.showPrivacyDialog = false;
  }

  /** ShareUtils.copyToClipboard(this, buildMarkdown()). */
  private copyForGitHub(): void {
    const share: ShareUtils = ServiceLocator.get().share;
    share.copyToClipboard(this.buildMarkdown())
      .catch((err: BusinessError): void => {
        hilog.error(0x0000, TAG, 'copy report: %{public}s', err.message);
      });
  }

  /** menu_item_share_error: shares buildJson() through svc_share. */
  private shareErrorReport(): void {
    const share: ShareUtils = ServiceLocator.get().share;
    share.shareText(Localization.getString('error_report_title'), this.buildJson())
      .catch((err: BusinessError): void => {
        hilog.error(0x0000, TAG, 'share report: %{public}s', err.message);
      });
  }

  @Builder
  privacyDialogBody() {
    // AlertDialog.Builder: setTitle + setMessage over a card, with the neutral button at the
    // start of the button bar and negative/positive at its end.
    Column() {
      Text($r('app.string.privacy_policy_title'))
        .id('privacy_policy_title')
        .width('100%')
        .fontSize(20)
        .fontColor(C_ON_SURFACE)
        .margin({ bottom: 16 })

      Text($r('app.string.start_accept_privacy_policy'))
        .id('start_accept_privacy_policy')
        .width('100%')
        .fontSize(16)
        .fontColor(C_SECONDARY)

      Row() {
        Text($r('app.string.read_privacy_policy'))
          .id('Read privacy policy')
          .height(48)
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.accent'))
          .onClick(() => {
            this.openPrivacyPolicy();
          })

        Blank()

        Text($r('app.string.decline'))
          .id('Decline')
          .height(48)
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.accent'))
          .margin({ right: 16 })
          .onClick(() => {
            this.declinePrivacyPolicy();
          })

        Text($r('app.string.accept'))
          .id('Accept')
          .height(48)
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.accent'))
          .onClick(() => {
            this.acceptPrivacyPolicy();
          })
      }
      .width('100%')
      .margin({ top: 8 })
      .alignItems(VerticalAlign.Center)
    }
    .width('86%')
    .padding(24)
    .backgroundColor($r('app.color.dialog_surface'))
    .borderRadius(4)
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  errorBody() {
    Column() {
      // toolbar_layout.xml: the activity toolbar error_menu.xml inflates into.
      Row() {
        // android.R.id.home -> onBackPressed().
        Image($r('app.media.ic_arrow_back'))
          .id('home')
          .width(TOOLBAR_HEIGHT)
          .height(TOOLBAR_HEIGHT)
          .padding((TOOLBAR_HEIGHT - ICON_SIZE) / 2)
          .objectFit(ImageFit.Contain)
          .fillColor($r('app.color.on_primary'))
          .accessibilityText('Navigate up')
          .onClick(() => {
            router.back();
          })

        // Widget.AppCompat.Toolbar.Title: 20sp medium, 16dp past the navigation button.
        Text($r('app.string.error_report_title'))
          .id('error_report_title')
          .layoutWeight(1)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .fontSize(20)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.on_primary'))
          .margin({ left: 16, right: 16 })

        Image($r('app.media.ic_share'))
          .id('menu_item_share_error')
          .accessibilityText($r('app.string.share'))
          .width(ACTION_SIZE)
          .height(ACTION_SIZE)
          .padding((ACTION_SIZE - ICON_SIZE) / 2)
          .objectFit(ImageFit.Contain)
          .fillColor($r('app.color.on_primary'))
          .onClick(() => {
            this.shareErrorReport();
          })
      }
      .width('100%')
      // Toolbar: ?attr/actionBarSize tall, android:background="?attr/colorPrimary".
      .height(TOOLBAR_HEIGHT)
      .alignItems(VerticalAlign.Center)
      .backgroundColor($r('app.color.primary'))

      // ScrollView > the one vertical LinearLayout that holds the whole report.
      Scroll() {
        Column() {
          // errorSorryView: @string/sorry_string, with addGuruMeditation() appending a newline
          // plus @string/guru_meditation (an easter egg).
          Text(this.errorInfo === null
            ? Localization.getString('sorry_string')
            : Localization.getString('sorry_string') + '\n' + this.errorInfo)
            .id('errorSorryView')
            .width('100%')
            .textAlign(TextAlign.Center)
            // textAppearanceLarge, android:textStyle="bold".
            .fontSize(22)
            .fontWeight(FontWeight.Bold)
            .fontColor(C_ON_SURFACE)

          Text($r('app.string.what_happened_headline'))
            .fontSize(18)
            .fontColor(C_ON_SURFACE)
            .margin({ top: PAGE_MARGIN })

          // setTextWithLinks(errorInfo.getMessage(this)) — linkified in S4.
          Text(this.errorMessage)
            .id('errorMessageView')
            // android:textColor="?attr/colorAccent".
            .fontSize(14)
            .fontColor($r('app.color.accent'))

          Text($r('app.string.what_device_headline'))
            .fontSize(18)
            .fontColor(C_ON_SURFACE)
            .margin({ top: PAGE_MARGIN })

          Row() {
            Text($r('app.string.info_labels'))
              .id('errorInfoLabelsView')
              .fontSize(14)
              .fontColor($r('app.color.accent'))

            // The HorizontalScrollView the metadata column sits in.
            Scroll() {
              Text(this.infoBlock)
                .id('errorInfosView')
                .fontSize(14)
                .fontColor(C_ON_SURFACE)
            }
            .scrollable(ScrollDirection.Horizontal)
            .scrollBar(BarState.Off)
            .layoutWeight(1)
            // android:paddingLeft="16dp" on the HorizontalScrollView.
            .padding({ left: PAGE_MARGIN })
          }
          .width('100%')
          .alignItems(VerticalAlign.Top)

          Text($r('app.string.error_details_headline'))
            .fontSize(18)
            .fontColor(C_ON_SURFACE)
            .margin({ top: PAGE_MARGIN })

          // errorView: typeface="monospace", textIsSelectable, inside a HorizontalScrollView.
          Scroll() {
            Text(this.stackTraces)
              .id('errorView')
              .fontFamily('monospace')
              .fontSize(14)
              .fontColor(C_ON_SURFACE)
              .copyOption(CopyOptions.LocalDevice)
          }
          .scrollable(ScrollDirection.Horizontal)
          .scrollBar(BarState.Off)
          .width('100%')

          Text($r('app.string.your_comment'))
            .fontSize(18)
            .fontColor(C_ON_SURFACE)
            .margin({ top: PAGE_MARGIN })

          TextInput({ text: this.userComment })
            .id('errorCommentBox')
            .width('100%')
            .fontSize(14)
            .fontColor(C_ON_SURFACE)
            .backgroundColor($r('app.color.surface'))
            .margin({ top: 4 })
            .onChange((value: string) => {
              this.userComment = value;
            })

          // android:textAllCaps, which Widget.AppCompat.Button carries: the reference reads
          // REPORT VIA E-MAIL / COPY FORMATTED REPORT / REPORT ON GITHUB. Localization
          // .buttonLabel() is the port's locale-aware equivalent, already used elsewhere.
          Button(Localization.buttonLabel('error_report_button_text'))
            .id('errorReportEmailButton')
            .width('100%')
            .type(ButtonType.Normal)
            .backgroundColor($r('app.color.surface_variant'))
            .fontSize(14)
            .fontColor(C_ON_SURFACE)
            .borderRadius(2)
            .height(40)
            .margin({ top: 8 })
            .onClick(() => {
              this.privacyDialogTarget = 'EMAIL';
              this.showPrivacyDialog = true;
            })

          Text($r('app.string.error_report_open_github_notice'))
            .width('100%')
            .fontWeight(FontWeight.Bold)
            .fontSize(14)
            .fontColor(C_ON_SURFACE)
            .margin({ top: 10, bottom: 5 })

          // android:textAllCaps, which Widget.AppCompat.Button carries: the reference reads
          // REPORT VIA E-MAIL / COPY FORMATTED REPORT / REPORT ON GITHUB. Localization
          // .buttonLabel() is the port's locale-aware equivalent, already used elsewhere.
          Button(Localization.buttonLabel('copy_for_github'))
            .id('errorReportCopyButton')
            .width('100%')
            .type(ButtonType.Normal)
            .backgroundColor($r('app.color.surface_variant'))
            .fontSize(14)
            .fontColor(C_ON_SURFACE)
            .borderRadius(2)
            .height(40)
            .margin({ top: 8 })
            .onClick(() => {
              this.copyForGitHub();
            })

          // android:textAllCaps, which Widget.AppCompat.Button carries: the reference reads
          // REPORT VIA E-MAIL / COPY FORMATTED REPORT / REPORT ON GITHUB. Localization
          // .buttonLabel() is the port's locale-aware equivalent, already used elsewhere.
          Button(Localization.buttonLabel('error_report_open_issue_button_text'))
            .id('errorReportGitHubButton')
            .width('100%')
            .type(ButtonType.Normal)
            .backgroundColor($r('app.color.surface_variant'))
            .fontSize(14)
            .fontColor(C_ON_SURFACE)
            .borderRadius(2)
            .height(40)
            .margin({ top: 8 })
            .onClick(() => {
              this.privacyDialogTarget = 'GITHUB';
              this.showPrivacyDialog = true;
            })
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
        // activity_horizontal_margin / activity_vertical_margin on the report column.
        .padding(PAGE_MARGIN)
      }
      .id('scrollView')
      .width('100%')
      .layoutWeight(1)
      .align(Alignment.TopStart)
    }
    .width('100%')
    .height('100%')
  }

  build() {
    // The privacy notice is an AlertDialog OVER the report, not a screen that replaces it.
    Stack() {
      this.errorBody()

      // setCancelable(false): the scrim swallows every tap, so the three buttons are the only
      // exits — exactly as the source dialog behaves.
      if (this.showPrivacyDialog) {
        Column() {
          this.privacyDialogBody()
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
        .backgroundColor(DIALOG_MASK_COLOR)
        // Like every other dialog: the dim fades in and reaches under the system bars.
        .transition(TransitionEffect.OPACITY.animation({ duration: 200 }))
        .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
      }
    }
    .id('ErrorActivityPage')
    .width('100%')
    .height('100%')
    // ?attr/windowBackground = @color/light_background_color in the light theme.
    .backgroundColor(themedBackground(this.blackTheme))
  }
}
