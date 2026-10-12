/*
 * S3 - BlankFragment (screen_blank).
 *
 * STRUCTURE from fragment_blank.xml, which is exactly three children of a RelativeLayout:
 * @+id/blank_page_content (the included main_bg.xml - the 40sp app name over the
 * "tap the magnifying glass" subtitle), @+id/error_panel (android:visibility="gone"), and an
 * unnamed 4dp toolbar-shadow strip pinned to the top.
 *
 * ONE class, two roles: the default blank landing tab, and the fallback MainFragment substitutes
 * when Tab.getFragment(context) throws - which is the only way the error panel is ever shown.
 * The two-arg constructor takes that ErrorInfo, and when it is non-null blank_page_content is set
 * GONE and ErrorPanelHelper renders the panel instead. Its retry callback is null here, so the
 * panel offers NO retry button - only the action and open-in-browser entries.
 *
 * The title is the hard-coded literal "NewPipe", re-applied on every resume: it is NOT a bound
 * value, so the literal is correct here, not a transcription.
 *
 * hostedBy screen_main: MainFragmentPage mounts this struct as a TabContent child; it is never
 * pushed as a route. No navOut, no data, no menu of its own - the search action belongs to the
 * hosting MainFragment.
 */
import { ErrorInfo } from '../model/app/ErrorInfo';
import { ShareUtils } from '../common/share/ShareUtils';
import { ServiceLocator } from '../common/di/ServiceLocator';
import { Localization } from '../common/i18n/Localization';
import { BLACK_THEME_KEY, themedBackground } from '../common/theme/ThemeBackground';

/** The 4dp ?attr/toolbar_shadow strip at the top of fragment_blank.xml. */
const TOOLBAR_SHADOW_HEIGHT: number = 4;
/** fragment_blank.xml: the error panel sits 50dp below the shadow, centred. */
const ERROR_PANEL_TOP: number = 50;

@Entry
@Component
export struct BlankFragmentPage {
  /** ThemeHelper's black theme: the window background follows it. */
  @StorageProp(BLACK_THEME_KEY) blackTheme: boolean = false;

  /** setTitle("NewPipe") in onCreateView and again in onResume - a hard-coded literal. */
  @Prop actionBarTitle: string = 'NewPipe';
  /** errorPanel = new ErrorPanelHelper(this, view, null): retry is null, so there is no retry. */
  @Prop errorPanel: boolean = false;
  /** The ErrorInfo the two-arg constructor was handed; null on the blank landing path. */
  @State errorInfo: ErrorInfo | null = null;
  /** BaseFragment's loading flag; this screen loads nothing, so it never turns on. */
  @State isLoading: boolean = false;

  /** ErrorPanelHelper's message line: errorInfo.message resolved against the string table. */
  private errorMessageText(): string {
    const info: ErrorInfo | null = this.errorInfo;
    return info === null ? '' : Localization.getString(info.message.stringName);
  }

  private share(): ShareUtils {
    return ServiceLocator.get().share;
  }

  /** ErrorPanelHelper's open-in-browser entry: errorInfo.openInBrowserUrl. */
  private openInBrowser(): void {
    const info: ErrorInfo | null = this.errorInfo;
    if (info === null || info.openInBrowserUrl === null) {
      return;
    }
    this.share().openUrlInBrowser(info.openInBrowserUrl);
  }

  /** ErrorPanelHelper's action entry: report the error through svc_error_reporter. */
  private reportError(): void {
    const info: ErrorInfo | null = this.errorInfo;
    if (info === null) {
      return;
    }
    ServiceLocator.get().errorReporter.openActivity(info);
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      // errorInfo != null -> blank_page_content is GONE and the panel takes its place.
      if (this.errorInfo === null) {
        // main_bg.xml: 16dp side padding, a 40sp sans-serif-condensed app name 30dp down with
        // 20dp under it, then the textAppearanceMedium (18sp) subtitle, both centred.
        Column() {
          Text($r('app.string.app_name'))
            .fontSize(40)
            .fontFamily('sans-serif-condensed')
            .fontColor($r('app.color.on_surface'))
            .margin({ top: 30, bottom: 20 })
          Text($r('app.string.main_bg_subtitle'))
            .width('100%')
            .textAlign(TextAlign.Center)
            .fontSize(18)
            .fontColor($r('app.color.on_surface_variant'))
        }
        .id('blank_page_content')
        .width('100%')
        .height('100%')
        .padding({ left: 16, right: 16 })
        .alignItems(HorizontalAlign.Center)
      } else {
        // error_panel.xml: 16dp padding, centred, the message bold at 16sp.
        Column() {
          Text(this.errorMessageText())
            .id('error_message_view')
            .fontSize(16)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.on_surface'))
            .textAlign(TextAlign.Center)
            .width('100%')

          Button($r('app.string.error_snackbar_action'))
            .id('error_action_button')
            .fontSize(16)
            .fontColor($r('app.color.on_primary'))
            .backgroundColor($r('app.color.primary'))
            .margin({ top: 12 })
            .onClick(() => {
              this.reportError();
            })

          Button(Localization.buttonLabel('open_in_browser'))
            .id('error_open_in_browser')
            .fontSize(16)
            .fontColor($r('app.color.on_primary'))
            .backgroundColor($r('app.color.primary'))
            .margin({ top: 12 })
            .onClick(() => {
              this.openInBrowser();
            })
        }
        .id('error_panel')
        .width('100%')
        .padding(16)
        .alignItems(HorizontalAlign.Center)
        .margin({ top: ERROR_PANEL_TOP })
      }

      // The decorative ?attr/toolbar_shadow strip, alignParentTop: toolbar_shadow_light.xml is
      // a top-down gradient from @color/light_shadow_start_color to transparent.
      Row()
        .width('100%')
        .height(TOOLBAR_SHADOW_HEIGHT)
        .linearGradient({
          angle: 180,
          colors: [[$r('app.color.shadow_start'), 0.0], ['#00000000', 1.0]]
        })
    }
    .id('BlankFragmentPage')
    .width('100%')
    .height('100%')
    .backgroundColor(themedBackground(this.blackTheme))
  }
}
