/**
 * S4 - SubscriptionsImportFragment (screen_subscriptions_import), PLUS the wiring of the overlay
 * it hosts (screen_import_confirmation_dialog): initViews() binds the instructions, the hint,
 * the supported sources and the button label from the current service's SubscriptionExtractor,
 * and input_button drives both the URL branch and the DocumentViewPicker file branch.
 *
 * fragment_import.xml is three views: R.id.info_text_view, R.id.input_text and R.id.input_button.
 * hostedBy screen_main_activity, which PUSHES this page; SubscriptionFragmentPage already carries
 * that push (import_from).
 *
 * Two navOut edges, both `present` in the plan but with DIFFERENT targets:
 *  - screen_custom_file_picker is presentation: page with its own routeUrl, so per the Stage-0
 *    convention it is generated as a router.pushUrl - wired below on input_button's file branch.
 *  - screen_import_confirmation_dialog is presentation: modal whose hostScreen is THIS screen, so
 *    it is an overlay mounted HERE, never a route. The source is an AlertDialog with no layout,
 *    so it is mounted with a CustomDialogController (autoCancel = its setCancelable(true)) and
 *    opened by input_button's URL branch, exactly as onImportClicked() does.
 *
 * Source facts S4 must honour and a shell must not pre-empt:
 *  - onImportClicked(): if input_text is VISIBLE and non-empty -> onImportUrl(value) ->
 *    ImportConfirmationDialog in ChannelUrlMode; otherwise onImportFile() -> a wildcard-mime file
 *    picker whose result goes to ImportConfirmationDialog in InputStreamMode. An EMPTY value
 *    silently does nothing - that is source behaviour, not a missing handler.
 *  - The import itself NEVER happens in the dialog: ImportConfirmationDialog enqueues the
 *    WorkManager job, which is enqueueImport() below.
 *  - input_text is VISIBLE only when supportedSources.contains(CHANNEL_URL); its hint comes from
 *    ServiceHelper.getImportInstructionsHint(currentServiceId).
 *  - The button LABEL is import_title when CHANNEL_URL is supported, else import_file_title.
 *  - info_text_view is getString(instructionsString, relatedUrl) + Linkify WEB_URLS, so the
 *    embedded URL is tappable. All three are bound in this screen's own S4, never a captured
 *    literal.
 *  - A TODO in initViews says multi-source services are not handled: only the FIRST supported
 *    source drives the UI. Port that limitation as-is.
 *  - The fragment sets its own title (import_title) in onResume via the host action bar.
 *  - File access goes through svc_file_access: phase2-logic-contract §2.4 routes every
 *    user-visible file pick to @kit.CoreFileKit DocumentViewPicker; the NoNonsense file picker
 *    port (screen_custom_file_picker) is the fallback path.
 */
import { promptAction, router } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { ImportConfirmationDialogPage, SubscriptionImportInput }
  from './ImportConfirmationDialogPage';
import { ServiceLocator } from '../common/di/ServiceLocator';
import { AppPreferences } from '../common/prefs/Preferences';
import { current_service_key } from '../common/prefs/SettingsKeys';
import { NewPipe } from '../common/extractor/core/NewPipe';
import { StreamingService } from '../common/extractor/core/StreamingService';
import { ContentSource, SubscriptionExtractor } from '../common/extractor/info/SubscriptionExtractor';
import { FileAccess, StoredFile } from '../common/file/FileAccess';
import { enqueueSubscriptionImport } from '../common/subscription/SubscriptionImportWork';
import { DIALOG_MASK_COLOR } from '../common/theme/ServiceTheme';
import { LinkKind, LinkSpan, linkify } from '../common/text/Linkify';
import { NewPipeTextView } from '../components/NewPipeTextView';
import { BLACK_THEME_KEY, themedBackground } from '../common/theme/ThemeBackground';

const TAG: string = 'SubscriptionsImportFragment';

/** NavigationHelper pushes the Import from submenu's "previous export" entry with this id. */
const PREVIOUS_EXPORT_SERVICE_ID: number = -1;

@Entry
@Component
export struct SubscriptionsImportFragmentPage {
  /** ThemeHelper's black theme: the window background follows it. */
  @StorageProp(BLACK_THEME_KEY) blackTheme: boolean = false;

  /** setInfoText(getString(instructionsString, relatedUrl)) - bound, never a captured literal. */
  @State instructions: string = '';
  @State channelUrl: string = '';
  /** ServiceHelper.getImportInstructionsHint(currentServiceId). */
  @State inputHint: string = '';
  /** inputButton.setText(import_title) when CHANNEL_URL is supported, else import_file_title. */
  @State buttonLabel: Resource = $r('app.string.import_file_title');
  /** extractor.getSupportedSources(); empty when the service has no subscription extractor. */
  @State supportedSources: ContentSource[] = [];
  /**
   * The Import from submenu's "previous export" entry, which NavigationHelper pushes with
   * serviceId -1. It is not a service import: there are no instructions to show and no channel
   * URL branch, only the file the user exported earlier.
   */
  @State previousExport: boolean = false;
  /**
   * requestedServiceId(), resolved once by initViews(). Every import this screen raises belongs
   * to the service the CALLER named; currentServiceId() is the app-wide drawer selection and
   * describes a different screen's choice entirely - importing a SoundCloud export while YouTube
   * was selected sent the file to YouTube's extractor.
   */
  private importServiceId: number = PREVIOUS_EXPORT_SERVICE_ID;
  @State isLoading: boolean = false;
  @State errorInfo: string = '';
  /**
   * The arguments Bundle ImportConfirmationDialog.show(fragment, input) fills in. It is @State so
   * the dialog's @Prop picks up the input of THIS press; see showImportConfirmation().
   */
  @State pendingImportInput: SubscriptionImportInput =
    SubscriptionImportInput.channelUrl(0, '');

  /**
   * initViews(): the FIRST supported source drives the whole screen. The source's own TODO says
   * multi-source services are not handled, and that limitation is ported as-is.
   */
  aboutToAppear(): void {
    this.initViews();
  }

  /**
   * The caller says WHICH source was chosen - NavigationHelper.openSubscriptionsImportFragment
   * passes it - and this screen was discarding it, always describing the service selected in
   * preferences instead. So 'Previous export' and 'SoundCloud' both landed on YouTube's Google
   * Takeout instructions whenever YouTube was the active service.
   */
  private requestedServiceId(): number {
    const params: Record<string, Object> | undefined =
      router.getParams() as Record<string, Object> | undefined;
    if (params === undefined || params === null) {
      return SubscriptionsImportFragmentPage.currentServiceId();
    }
    const sid: Object | undefined = params['serviceId'];
    if (sid === undefined || sid === null) {
      return SubscriptionsImportFragmentPage.currentServiceId();
    }
    return Number(sid.toString());
  }

  private initViews(): void {
    this.isLoading = true;
    const requested: number = this.requestedServiceId();
    this.importServiceId = requested;
    this.previousExport = requested === PREVIOUS_EXPORT_SERVICE_ID;
    if (this.previousExport) {
      // No service to describe and no URL branch: the whole screen is "pick the file you exported".
      this.supportedSources = [];
      this.instructions = '';
      this.inputHint = '';
      this.buttonLabel = $r('app.string.import_file_title');
      this.isLoading = false;
      return;
    }
    const serviceId: number = requested;
    let relatedUrl: string = '';
    try {
      const service: StreamingService = NewPipe.getService(serviceId);
      const extractor: SubscriptionExtractor | null = service.getSubscriptionExtractor();
      if (extractor !== null) {
        this.supportedSources = extractor.getSupportedSources();
        const related: string | null = extractor.getRelatedUrl();
        relatedUrl = related === null ? '' : related;
      } else {
        this.supportedSources = [];
      }
    } catch (err) {
      // "Service does not support importing subscriptions" - the source finishes the activity;
      // here the screen simply offers nothing, which is the same end state without a crash.
      this.supportedSources = [];
      this.errorInfo = (err as BusinessError).message;
    }

    const supportsChannelUrl: boolean = this.supportsChannelUrl();
    this.buttonLabel = supportsChannelUrl
      ? $r('app.string.import_title') : $r('app.string.import_file_title');
    this.inputHint = SubscriptionsImportFragmentPage.importInstructionsHint(serviceId);
    this.instructions =
      SubscriptionsImportFragmentPage.importInstructions(serviceId, relatedUrl);
    this.isLoading = false;
  }

  /** supportedSources.contains(ContentSource.CHANNEL_URL). */
  private supportsChannelUrl(): boolean {
    return this.supportedSources.indexOf(ContentSource.CHANNEL_URL) >= 0;
  }

  /**
   * ServiceHelper.getImportInstructions(serviceId): YouTube (0) and SoundCloud (1) are the only
   * services with instructions; every other returns -1, which setInfoText renders as blank.
   * `relatedUrl` is the string's %1$s argument, and an empty one formats it away.
   */
  private static importInstructions(serviceId: number, relatedUrl: string): string {
    let template: Resource | null = null;
    if (serviceId === 0) {
      template = $r('app.string.import_youtube_instructions');
    } else if (serviceId === 1) {
      template = $r('app.string.import_soundcloud_instructions');
    }
    if (template === null) {
      return '';
    }
    try {
      const context: common.Context = getContext() as common.Context;
      return relatedUrl.length === 0
        ? context.resourceManager.getStringSync(template)
        : context.resourceManager.getStringSync(template, relatedUrl);
    } catch (err) {
      hilog.warn(0x0000, TAG, 'instructions lookup: %{public}s', (err as BusinessError).message);
      return '';
    }
  }

  /** ServiceHelper.getImportInstructionsHint(serviceId): SoundCloud only. */
  private static importInstructionsHint(serviceId: number): string {
    if (serviceId !== 1) {
      return '';
    }
    try {
      return (getContext() as common.Context).resourceManager
        .getStringSync($r('app.string.import_soundcloud_instructions_hint'));
    } catch (err) {
      hilog.warn(0x0000, TAG, 'hint lookup: %{public}s', (err as BusinessError).message);
      return '';
    }
  }

  /**
   * onImportFile(): the source launches a wildcard-mime picker and hands the result to
   * ImportConfirmationDialog in InputStreamMode. feat_saf_storage puts that on
   * @kit.CoreFileKit DocumentViewPicker (svc_file_access); feat_file_picker_fallback keeps the
   * ported NoNonsense picker (screen_custom_file_picker) as the path when the system picker
   * cannot be opened.
   */
  private async onImportFile(): Promise<void> {
    const access: FileAccess = ServiceLocator.get().fileAccess;
    try {
      const picked: StoredFile | null = await access.pickFileToOpen();
      if (picked === null) {
        // RESULT_CANCELED with a null dataString: onActivityResult does nothing at all.
        return;
      }
      // WHICH mode is decided by the menu entry the user came in through, never by the picked
      // file's MIME: DocumentViewPicker hands back a hard-coded default type, so the null
      // contentType SubscriptionManager.importFromFile branches PreviousExportMode on could
      // never come out of getType() - every file went to the Takeout-zip extractor instead.
      this.showImportConfirmation(this.previousExport
        ? SubscriptionImportInput.previousExport(this.importServiceId, picked.getUri())
        : SubscriptionImportInput.inputStream(this.importServiceId, picked.getUri(),
          picked.getType()));
    } catch (err) {
      hilog.warn(0x0000, TAG, 'DocumentViewPicker unavailable: %{public}s',
        (err as BusinessError).message);
      router.pushUrl({ url: 'pages/CustomFilePickerFragmentPage' })
        .catch((pushErr: BusinessError): void => {
          hilog.error(0x0000, TAG, 'file picker push failed: %{public}s', pushErr.message);
        });
    }
  }

  /**
   * screen_import_confirmation_dialog, raised by onImportUrl() and by the file-picker result.
   * ImportConfirmationDialog.show(fragment, input) builds a NEW dialog carrying the input in its
   * arguments bundle, so the controller is built at open() time with the input of that press;
   * autoCancel mirrors setCancelable(true) - tapping outside or Back dismisses without importing.
   */
  private importConfirmationDialog: CustomDialogController = new CustomDialogController({
      maskColor: DIALOG_MASK_COLOR,
      builder: ImportConfirmationDialogPage({
        importInput: this.pendingImportInput,
        onConfirm: (confirmed: SubscriptionImportInput): void => {
          this.enqueueImport(confirmed);
        }
      }),
      autoCancel: true,
      // S6 fixes what S5 could not see without the SDK contract: `width` is honoured ONLY while
      // the dialog keeps its own container - customStyle:true documents that "the width, height,
      // border width, border style, border color and shadow width cannot be set", so the 86%
      // was being dropped and the card rendered full-bleed. The container therefore stays on and
      // is styled to disappear behind the builder's own AlertDialog card: cornerRadius 2 replaces
      // the 32vp HarmonyOS default (otherwise it clips the card's 2vp corners), and 86% of 360vp
      // is the 310vp card S0142 measures (x 75..1004 of 1080). Android AlertDialogs are centred
      // vertically - the card sits at y 968..1443 of 2340 - which DialogAlignment.Default, the
      // system's own placement, does not promise.
      alignment: DialogAlignment.Center,
      cornerRadius: 2,
      width: '86%'
  });

  /**
   * ImportConfirmationDialog.show(fragment, input). Also the entry point this screen's own S4
   * calls with the DocumentViewPicker result (InputStreamMode / PreviousExportMode).
   *
   * The controller above is a MEMBER initialised where it is declared, which ArkUI requires: a
   * CustomDialogController built inside a method renders its card and still dismisses on the
   * scrim, but the builder's own onClick handlers never fire - the dialog came up with OK and
   * CANCEL both dead. The input therefore travels through this @State instead of being closed
   * over at construction; @Prop copies it into the dialog on the way in, which is the same
   * one-way hand-over the arguments Bundle was.
   */
  private showImportConfirmation(input: SubscriptionImportInput): void {
    this.pendingImportInput = input;
    this.importConfirmationDialog.open();
  }

  /** WorkManager.enqueueUniqueWork(WORK_NAME, APPEND_OR_REPLACE, req) - see the work module. */
  private enqueueImport(input: SubscriptionImportInput): void {
    enqueueSubscriptionImport(getContext(this) as common.Context, input);
  }

  /**
   * ServiceHelper's currentServiceId: the preference holds the service NAME (Constants
   * .KEY_STREAMING_SERVICE == current_service_key). YouTube - the first registered service - is
   * the source's own default for an unknown name.
   */
  private static currentServiceId(): number {
    try {
      const name: string = AppPreferences.instance().getStringSync(current_service_key, '');
      if (name.length !== 0) {
        const service: StreamingService = NewPipe.getServiceByName(name);
        return service.getServiceId();
      }
    } catch (err) {
      // fall through to the default service
    }
    const services: StreamingService[] = NewPipe.getServices();
    return services.length === 0 ? 0 : services[0].getServiceId();
  }

  build() {
    // RelativeLayout: info_text_view fills everything ABOVE inputs_panel, which is pinned to the
    // bottom edge. A Column with the weight on the text is the same layout without the anchors.
    Column() {
      // toolbar_layout.xml, set as the support action bar with home-as-up and the fragment's own
      // R.string.import_title. base.ui.json: [0,72][1080,240] = ?attr/actionBarSize (56vp) on
      // ?attr/colorPrimary #E53935, the Up button a 56vp box and the title inset to 72vp.
      Row() {
        Image($r('app.media.ic_arrow_back'))
          .id('home')
          .accessibilityText($r('app.string.navigate_back'))
          .width(56)
          .height(56)
          .padding(16)
          .objectFit(ImageFit.Contain)
          .fillColor($r('app.color.on_primary'))
          .onClick(() => {
            router.back();
          })

        Text($r('app.string.import_title'))
          .fontSize(20)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.on_primary'))
          .margin({ left: 16 })
      }
      .width('100%')
      .height(56)
      .alignItems(VerticalAlign.Center)
      .backgroundColor($r('app.color.primary'))

      // setInfoText(): Linkify.addLinks(infoTextView, Linkify.WEB_URLS) - only the url is a link,
      // and tapping it opens it outside the app.
      Column() {
        NewPipeTextView({
          slug: 'info_text_view',
          content: this.instructions,
          linkSpans: linkify(this.instructions, [LinkKind.WEB_URL]),
          copyOnLongPress: false,
          // TextAppearance.AppCompat.Body1.
          textSizeFp: 16,
          onLinkTapped: (span: LinkSpan): void => {
            const url: string | null = span.url;
            if (url !== null) {
              ServiceLocator.get().share.openUrlInBrowser(url);
            }
          }
        })
      }
      .width('100%')
      .layoutWeight(1)
      .padding(16)
      // gravity center_vertical.
      .justifyContent(FlexAlign.Center)
      .alignItems(HorizontalAlign.Start)

      Column() {
        // input_text is GONE unless supportedSources.contains(CHANNEL_URL); its hint comes from
        // ServiceHelper.getImportInstructionsHint(currentServiceId).
        if (this.supportedSources.indexOf(ContentSource.CHANNEL_URL) >= 0) {
          TextInput({ text: this.channelUrl, placeholder: this.inputHint })
            .id('input_text')
            .onChange((value: string): void => {
              this.channelUrl = value;
            })
            .width('100%')
            .height(48)
            .fontSize(16)
            .fontColor($r('app.color.on_surface'))
            .placeholderColor($r('app.color.on_surface_variant'))
            .backgroundColor(Color.Transparent)
            .borderRadius(0)
            .padding({ left: 0, right: 0 })
            .showUnderline(true)
            .margin({ bottom: 8 })
        }

        // android:background="?attr/selectableItemBackground": a borderless 48vp-tall button.
        // base.ui.json puts it at [408,2148][672,2292].
        Button(this.buttonLabel)
          .id('input_button')
          .type(ButtonType.Normal)
          .height(48)
          .borderRadius(2)
          .backgroundColor(Color.Transparent)
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.on_surface'))
          .padding({ left: 16, right: 16 })
          .onClick(() => {
            // onImportClicked(): a VISIBLE, non-empty input_text is the URL branch (onImportUrl
            // -> ImportConfirmationDialog in ChannelUrlMode); otherwise onImportFile() launches
            // the wildcard-mime picker, whose result reaches the same dialog in InputStreamMode.
            // An EMPTY value silently does nothing - source behaviour, not a missing handler.
            if (this.supportsChannelUrl() && this.channelUrl.length > 0) {
              this.showImportConfirmation(
                SubscriptionImportInput.channelUrl(this.importServiceId, this.channelUrl));
            } else if (!this.supportsChannelUrl()) {
              this.onImportFile();
            }
          })
      }
      .id('inputs_panel')
      .width('100%')
      .padding(16)
      .alignItems(HorizontalAlign.Center)
    }
    .id('SubscriptionsImportFragmentPage')
    .width('100%')
    .height('100%')
    .backgroundColor(themedBackground(this.blackTheme))
  }
}
