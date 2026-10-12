/**
 * S3 - ExoPlayerSettingsFragment (screen_exoplayer_settings).
 *
 * res/xml/exoplayer_settings.xml: 4 rows, no navOut. hostedBy screen_settings_activity. Reached
 * from VideoAudioSettingsFragment (exoplayer_settings_key row), never from the settings root.
 *
 * TWO mounts, and they disagree about who draws the toolbar. The exoplayer_settings_key row calls
 * router.pushUrl, so on that path this page IS the route and nothing above it carries a bar - the
 * screen had no Up affordance at all (T-1512). A preference-search hit instead puts this page in
 * SettingsActivityPage's fragment holder, under the activity's own toolbar. The HOST says which
 * mount this is (hostDrawsToolbar below): the bar is drawn only when nobody above draws one, so
 * the holder mount keeps its single host toolbar instead of stacking a second one on top.
 *
 * Row 1 is a ListPreference: tapping it opens the single-choice dialog the capture records
 * (pref_progressive_load_interval_key.ui.json - alertTitle "Playback load interval size", five
 * CheckedTextViews, CANCEL). Entries/values come from @array/progressive_load_interval_*, carried
 * over as app.strarray resources, never hardcoded here.
 *
 * disabled_media_tunneling_automatically_key is a TRISTATE int backing the "Disable media
 * tunneling" summary: -1 not set, 1 auto-disabled by the device blacklist, 0 user override. Ported
 * verbatim from ExoPlayerSettingsFragment.onCreatePreferences: the automatic-info sentence is
 * appended while it reads 1, and switching the preference OFF writes 0 (user override), which
 * drops the sentence again.
 *
 * PORT CEILING, from the Phase-2 contract 2.5 (ExoPlayer -> AVPlayer + AVSession): AVPlayer exposes
 * no decoder-fallback, no setOutputSurface workaround and no tunneling switch, so three of these
 * four rows have no target-side CONSUMER. The source screen's own job is to PERSIST them, and it
 * does - so they persist here too, through the flushing AppPreferences statics.
 *
 * Every toggle is drawn with HitTestMode.None so the whole row is the one tappable control: the
 * row carries the source .id() slug and the replay taps its centre, which is the label, not the
 * switch.
 */
import { common } from '@kit.AbilityKit';
import { router } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { AppPreferences } from '../common/prefs/Preferences';
import {
  always_use_exoplayer_set_output_surface_workaround_key,
  disable_media_tunneling_key,
  disabled_media_tunneling_automatically_key,
  progressive_load_interval_default_value,
  progressive_load_interval_key,
  use_exoplayer_decoder_fallback_key
} from '../common/prefs/SettingsKeys';
import { DIALOG_MASK_COLOR } from '../common/theme/ServiceTheme';
import { settingsListScroller } from '../common/settings/SettingsScroller';
import { BLACK_THEME_KEY, themedBackground } from '../common/theme/ThemeBackground';

const TAG: string = 'ExoPlayerSettingsFragmentPage';
/** A row with no AVPlayer counterpart is shown disabled with the reason, like the caption row. */
const DISABLED_ALPHA: number = 0.5;

/* S5 - style only, LightTheme (the theme the captured states render in). Reuses the run's style
 * baseline (state.json generation.styleBaseline, source S0004): background / primary / onSurface /
 * secondaryText and the 16fp/14fp text pair. The preference-row metrics (16vp gutter, 16vp vertical
 * padding, the 47x27vp switch) and the AlertDialog surface are measured from THIS screen's own
 * capture - S0116 base.ui.json and the S0117 dialog - because an AndroidX preference row is not the
 * download-mission row the baseline was taken from. */
/** ?attr/windowBackground - light_background_color, the capture's #EEEEEE. */
const COLOR_SURFACE: Resource = $r('app.color.background');
/** ?attr/colorPrimary - the switch's checked track and the dialog's selected mark. */
const COLOR_PRIMARY: Resource = $r('app.color.primary');
/** ?attr/actionColor - the toolbar's Up glyph and its title. */
const COLOR_ON_PRIMARY: Resource = $r('app.color.on_primary');
/** ?attr/colorAccent in NewPipe's light theme is BLACK, which is what CANCEL renders as. */
const COLOR_ACCENT: Resource = $r('app.color.accent');
/** ?android:textColorPrimary - #DE000000 over #EEEEEE is the capture's (31,31,31) title. */
const COLOR_ON_SURFACE: Resource = $r('app.color.on_surface');
/** ?android:textColorSecondary - #8A000000 over #EEEEEE is the capture's (109,109,109) summary. */
const COLOR_SECONDARY_TEXT: Resource = $r('app.color.on_surface_variant');
/** The AlertDialog surface: white in the capture, NOT light_dialog_background_color. */
const COLOR_DIALOG_SURFACE: Resource = $r('app.color.dialog_surface');

/** One entry of @array/progressive_load_interval_values with its description. */
interface LoadIntervalOption {
  value: string;
  description: string;
}

/**
 * The ListPreference dialog: single choice over the five load-interval entries, plus CANCEL.
 * The option rows are instantiated per entry, so they deliberately share one `...itemroot` id -
 * the replay resolves them by index (CLAUDE.md rule 12, list-row exception).
 */
@CustomDialog
struct ProgressiveLoadIntervalDialog {
  controller?: CustomDialogController;
  options: LoadIntervalOption[] = [];
  selected: string = '';
  onSelect: (value: string) => void = (value: string): void => {
    hilog.debug(0x0000, TAG, 'ProgressiveLoadIntervalDialog: select %{public}s not bound', value);
  };

  build() {
    Column() {
      // alertTitle: 20sp at the dialog's 24vp gutter, 18vp above / 8vp below (titleDivider).
      Text($r('app.string.progressive_load_interval_title'))
        .width('100%')
        .fontSize(20)
        .fontColor(COLOR_ON_SURFACE)
        .padding({ left: 24, right: 24, top: 18, bottom: 8 })

      ForEach(this.options, (option: LoadIntervalOption) => {
        // select_dialog_listview: 48vp rows, 16sp text at the same 24vp gutter.
        Row() {
          Text(option.description)
            .layoutWeight(1)
            .fontSize(16)
            .fontColor(COLOR_ON_SURFACE)
          if (option.value === this.selected) {
            Image($r('app.media.ic_done'))
              .width(24)
              .height(24)
              .objectFit(ImageFit.Contain)
              // The capture marks the current entry in ?attr/colorPrimary.
              .fillColor(COLOR_PRIMARY)
          }
        }
        .width('100%')
        .height(48)
        .padding({ left: 24, right: 24 })
        .alignItems(VerticalAlign.Center)
        .id('progressive_load_interval_itemroot')
        .onClick(() => {
          this.controller?.close();
          this.onSelect(option.value);
        })
      }, (option: LoadIntervalOption) => option.value)

      // buttonPanel: a borderless accent-coloured button, flush with the card's bottom-right.
      Button($r('app.string.cancel'))
        .id('button2')
        .height(42)
        .backgroundColor(Color.Transparent)
        .fontSize(14)
        .fontWeight(FontWeight.Medium)
        .fontColor(COLOR_ACCENT)
        .alignSelf(ItemAlign.End)
        .margin({ top: 4 })
        .onClick(() => {
          this.controller?.close();
        })
    }
    // The capture's card: 294vp wide, white, a 4vp radius - not the platform's rounded sheet.
    .width(294)
    .backgroundColor(COLOR_DIALOG_SURFACE)
    .borderRadius(4)
    .alignItems(HorizontalAlign.Start)
  }
}

@Entry
@Component
export struct ExoPlayerSettingsFragmentPage {
  /** ThemeHelper's black theme: the window background follows it. */
  @StorageProp(BLACK_THEME_KEY) blackTheme: boolean = false;

  /** The stored ListPreference value and the description that fills the summary's %s. */
  @State progressiveLoadIntervalValue: string = progressive_load_interval_default_value;
  @State progressiveLoadIntervalDescription: string = progressive_load_interval_default_value;
  @State loadIntervalOptions: LoadIntervalOption[] = [];
  @State useExoPlayerDecoderFallback: boolean = false;
  @State disableMediaTunneling: boolean = false;
  /** TRISTATE: -1 not set, 1 auto-disabled by the device blacklist, 0 user override. */
  @State disabledMediaTunnelingAutomaticallyKey: number = -1;
  @State alwaysUseSetOutputSurfaceWorkaround: boolean = false;
  /**
   * ExoPlayerSettingsFragment's `summaryText` - the base summary the source sets on the
   * disable_media_tunneling preference. The automatic-info sentence is appended to it while the
   * tristate reads 1 (the conditional below), and switching the preference OFF writes 0, which
   * drops the sentence again - the port of `p.setSummary(R.string.disable_media_tunneling_summary)`.
   */
  @State disableMediaTunnelingSummary: string = '';
  /**
   * The source reads SharedPreferences synchronously in onCreatePreferences; `preferences` here is
   * reached through the async statics, so the four rows below are drawn from their defaults for the
   * first frames. Nothing is HIDDEN while it is true - the rows are the screen - it only holds back
   * the error line, which would otherwise flash before the read has had a chance to succeed.
   */
  @State isLoading: boolean = true;
  /**
   * ErrorPanelHelper equivalent. The source fragment has no error path at all (SharedPreferences
   * reads cannot fail), but `AppPreferences.instance()` throws when the store was never
   * initialised, so on this side a failed read/write is real and must not vanish silently.
   */
  @State errorInfo: string = '';

  /**
   * TRUE when this screen sits in SettingsActivityPage's settings_fragment_holder, which draws the
   * one toolbar for whatever it holds; FALSE when this page is the pushed route and nothing above
   * it carries a bar. The host passes it explicitly, the way every other holder-mounted settings
   * page takes it.
   *
   * It used to be read off `router.getState().name`, which has to have been renamed to this page
   * by the time this initialiser runs. On the push from VideoAudioSettingsFragment that holds -
   * but VideoAudio can ITSELF be search-mounted in the holder, and its exoplayer_settings_key row
   * then pushes from a route still named SettingsActivityPage. A read that lost that race drew no
   * bar at all and left the screen with no Up affordance, which is the defect that push was fixed
   * for. The prop has no race to lose, and defaults to FALSE, so an unset value falls through to
   * DRAWING the bar rather than to drawing none.
   */
  @Prop hostDrawsToolbar: boolean = false;

  private loadIntervalDialog: CustomDialogController = new CustomDialogController({
    maskColor: DIALOG_MASK_COLOR,
    // customStyle: the card below paints its own surface, so the system container adds none.
    customStyle: true,
    builder: ProgressiveLoadIntervalDialog({
      options: this.loadIntervalOptions,
      selected: this.progressiveLoadIntervalValue,
      onSelect: (value: string): void => {
        this.onProgressiveLoadIntervalPicked(value);
      }
    })
  });

  async aboutToAppear(): Promise<void> {
    try {
      await this.loadPreferences();
    } catch (err) {
      this.report(err as BusinessError);
    } finally {
      this.isLoading = false;
    }
  }

  private async loadPreferences(): Promise<void> {
    const context: common.Context = getContext(this) as common.Context;
    const descriptions: string[] =
      context.resourceManager.getStringArrayByNameSync('progressive_load_interval_descriptions');
    const values: string[] =
      context.resourceManager.getStringArrayByNameSync('progressive_load_interval_values');
    const options: LoadIntervalOption[] = [];
    for (let i = 0; i < values.length && i < descriptions.length; i++) {
      const option: LoadIntervalOption = { value: values[i], description: descriptions[i] };
      options.push(option);
    }
    this.loadIntervalOptions = options;

    this.progressiveLoadIntervalValue =
      await AppPreferences.getString(progressive_load_interval_key,
        progressive_load_interval_default_value);
    this.progressiveLoadIntervalDescription = this.describe(this.progressiveLoadIntervalValue);
    this.useExoPlayerDecoderFallback =
      await AppPreferences.getBoolean(use_exoplayer_decoder_fallback_key, false);
    this.disableMediaTunneling = await AppPreferences.getBoolean(disable_media_tunneling_key, false);
    this.disabledMediaTunnelingAutomaticallyKey =
      await AppPreferences.getInt(disabled_media_tunneling_automatically_key, -1);
    this.alwaysUseSetOutputSurfaceWorkaround =
      await AppPreferences.getBoolean(always_use_exoplayer_set_output_surface_workaround_key, false);
    this.disableMediaTunnelingSummary =
      context.resourceManager.getStringByNameSync('disable_media_tunneling_summary');
  }

  /** A failed read or write surfaces instead of being dropped. */
  private report(err: BusinessError): void {
    this.errorInfo = err.message;
    hilog.error(0x0000, TAG, 'preference access failed: %{public}s', this.errorInfo);
  }

  /** The entry description for a stored value; the raw value if the arrays do not carry it. */
  private describe(value: string): string {
    for (const option of this.loadIntervalOptions) {
      if (option.value === value) {
        return option.description;
      }
    }
    return value;
  }

  private async onProgressiveLoadIntervalPicked(value: string): Promise<void> {
    this.progressiveLoadIntervalValue = value;
    this.progressiveLoadIntervalDescription = this.describe(value);
    try {
      await AppPreferences.putString(progressive_load_interval_key, value);
    } catch (err) {
      this.report(err as BusinessError);
    }
  }

  private async onUseDecoderFallbackChanged(enabled: boolean): Promise<void> {
    this.useExoPlayerDecoderFallback = enabled;
    try {
      await AppPreferences.putBoolean(use_exoplayer_decoder_fallback_key, enabled);
    } catch (err) {
      this.report(err as BusinessError);
    }
  }

  /**
   * ExoPlayerSettingsFragment.java:34-43 verbatim: switching the preference OFF records the user
   * override (0), which is what drops the automatic-info sentence from the summary.
   */
  private async onDisableMediaTunnelingChanged(enabled: boolean): Promise<void> {
    this.disableMediaTunneling = enabled;
    try {
      await AppPreferences.putBoolean(disable_media_tunneling_key, enabled);
      if (!enabled) {
        await AppPreferences.putInt(disabled_media_tunneling_automatically_key, 0);
        this.disabledMediaTunnelingAutomaticallyKey = 0;
      }
    } catch (err) {
      this.report(err as BusinessError);
    }
  }

  private async onSetOutputSurfaceWorkaroundChanged(enabled: boolean): Promise<void> {
    this.alwaysUseSetOutputSurfaceWorkaround = enabled;
    try {
      await AppPreferences.putBoolean(always_use_exoplayer_set_output_surface_workaround_key,
        enabled);
    } catch (err) {
      this.report(err as BusinessError);
    }
  }

  /** The PreferenceScreen's four rows; the bar above them belongs to the mount, not to them. */
  @Builder
  preferenceRows() {
    Column() {
      // -- ListPreference: progressive_load_interval ----------------------------
      Row() {
        Column() {
          Text($r('app.string.progressive_load_interval_title'))
            .width('100%')
            .fontSize(16)
            .lineHeight(20)
            .fontColor(COLOR_ON_SURFACE)
          Text($r('app.string.progressive_load_interval_summary',
            this.progressiveLoadIntervalDescription))
            .width('100%')
            .fontSize(14)
            .lineHeight(17)
            .fontColor(COLOR_SECONDARY_TEXT)
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
      }
      .id('progressive_load_interval')
      .width('100%')
      .padding({ left: 16, right: 16, top: 16, bottom: 16 })
      .alignItems(VerticalAlign.Center)
      .onClick(() => {
        this.loadIntervalDialog.open();
      })

      // -- SwitchPreferenceCompat: use_exoplayer_decoder_fallback_key -----------
      Row() {
        Column() {
          Text($r('app.string.use_exoplayer_decoder_fallback_title'))
            .width('100%')
            .fontSize(16)
            .lineHeight(20)
            .fontColor(COLOR_ON_SURFACE)
          Text($r('app.string.use_exoplayer_decoder_fallback_summary'))
            .width('100%')
            .fontSize(14)
            .lineHeight(17)
            .fontColor(COLOR_SECONDARY_TEXT)
          Text($r('app.string.avplayer_switch_unavailable_note'))
            .width('100%')
            .fontSize(14)
            .lineHeight(17)
            .fontColor(COLOR_SECONDARY_TEXT)
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)

        // widget_frame: a 47x27vp switch sitting against the row's 16vp right gutter.
        Toggle({ type: ToggleType.Switch, isOn: this.useExoPlayerDecoderFallback })
          .hitTestBehavior(HitTestMode.None)
          .width(47)
          .height(27)
          .margin({ left: 16 })
          .selectedColor(COLOR_PRIMARY)
      }
      .id('use_exoplayer_decoder_fallback_key')
      .width('100%')
      .padding({ left: 16, right: 16, top: 16, bottom: 16 })
      .alignItems(VerticalAlign.Center)
      .onClick(() => {
        this.onUseDecoderFallbackChanged(!this.useExoPlayerDecoderFallback);
      })
      // AVPlayer picks its decoder itself and exposes no fallback switch.
      .opacity(DISABLED_ALPHA)
      .enabled(false)

      // -- SwitchPreferenceCompat: disable_media_tunneling_key ------------------
      Row() {
        Column() {
          Text($r('app.string.disable_media_tunneling_title'))
            .width('100%')
            .fontSize(16)
            .lineHeight(20)
            .fontColor(COLOR_ON_SURFACE)
          Text(this.disableMediaTunnelingSummary)
            .width('100%')
            .fontSize(14)
            .lineHeight(17)
            .fontColor(COLOR_SECONDARY_TEXT)
          // conditionalVariants: the blacklist auto-disabled it, so the info sentence is appended.
          if (this.disabledMediaTunnelingAutomaticallyKey === 1) {
            Text($r('app.string.disable_media_tunneling_automatic_info'))
              .width('100%')
              .fontSize(14)
              .lineHeight(17)
              .fontColor(COLOR_SECONDARY_TEXT)
          }
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)

        // widget_frame: a 47x27vp switch sitting against the row's 16vp right gutter.
        Toggle({ type: ToggleType.Switch, isOn: this.disableMediaTunneling })
          .hitTestBehavior(HitTestMode.None)
          .width(47)
          .height(27)
          .margin({ left: 16 })
          .selectedColor(COLOR_PRIMARY)
      }
      .id('disable_media_tunneling_key')
      .width('100%')
      .padding({ left: 16, right: 16, top: 16, bottom: 16 })
      .alignItems(VerticalAlign.Center)
      .onClick(() => {
        this.onDisableMediaTunnelingChanged(!this.disableMediaTunneling);
      })

      // -- SwitchPreferenceCompat: always_use_..._set_output_surface_workaround --
      Row() {
        Column() {
          Text($r('app.string.always_use_exoplayer_set_output_surface_workaround_title'))
            .width('100%')
            .fontSize(16)
            .lineHeight(20)
            .fontColor(COLOR_ON_SURFACE)
          Text($r('app.string.avplayer_switch_unavailable_note'))
            .width('100%')
            .fontSize(14)
            .lineHeight(17)
            .fontColor(COLOR_SECONDARY_TEXT)
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)

        // widget_frame: a 47x27vp switch sitting against the row's 16vp right gutter.
        Toggle({ type: ToggleType.Switch, isOn: this.alwaysUseSetOutputSurfaceWorkaround })
          .hitTestBehavior(HitTestMode.None)
          .width(47)
          .height(27)
          .margin({ left: 16 })
          .selectedColor(COLOR_PRIMARY)
      }
      .id('always_use_exoplayer_set_output_surface_workaround_key')
      .width('100%')
      .padding({ left: 16, right: 16, top: 16, bottom: 16 })
      .alignItems(VerticalAlign.Center)
      .onClick(() => {
        this.onSetOutputSurfaceWorkaroundChanged(!this.alwaysUseSetOutputSurfaceWorkaround);
      })
      // AVPlayer renders into the XComponent surface it is given; there is no workaround to turn on.
      .opacity(DISABLED_ALPHA)
      .enabled(false)

      // ErrorPanelHelper equivalent: only once the read has actually finished and failed.
      if (!this.isLoading && this.errorInfo.length > 0) {
        Text(this.errorInfo)
          .width('100%')
          .fontSize(14)
          .lineHeight(17)
          .fontColor(COLOR_SECONDARY_TEXT)
          .padding({ left: 16, right: 16, top: 16, bottom: 16 })
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  build() {
    Column() {
      // toolbar_layout.xml: the host activity's Up affordance and the PreferenceScreen title that
      // BasePreferenceFragment.onViewCreated pushes into it. android.R.id.home is the slug.
      if (!this.hostDrawsToolbar) {
        Row() {
          // The 24vp glyph centred in a 56vp (?attr/actionBarSize) target, as every other pushed
          // preference screen draws it. The SVG ships black, so the bar's tint is applied here.
          Image($r('app.media.ic_arrow_back'))
            .id('home')
            .accessibilityText($r('app.string.navigate_back'))
            .width(56)
            .height(56)
            .padding(16)
            .objectFit(ImageFit.Contain)
            .fillColor(COLOR_ON_PRIMARY)
            .onClick(() => {
              router.back();
            })

          // Widget.AppCompat.Toolbar.Title: 20sp medium, 16vp past the navigation button.
          Text($r('app.string.settings_category_exoplayer_title'))
            .layoutWeight(1)
            .fontSize(20)
            .fontWeight(FontWeight.Medium)
            .fontColor(COLOR_ON_PRIMARY)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .margin({ left: 16 })
        }
        .width('100%')
        .height(56)
        .alignItems(VerticalAlign.Center)
        .backgroundColor(COLOR_PRIMARY)
      }

      // The source's rows live in a RecyclerView, so they scroll. They very nearly filled the
      // frame already; with 56vp of toolbar above them the last summary would otherwise clip.
      Scroll(settingsListScroller) {
        this.preferenceRows()
      }
      .width('100%')
      .layoutWeight(1)
      .align(Alignment.TopStart)
    }
    .id('ExoPlayerSettingsFragmentPage')
    .width('100%')
    .height('100%')
    .alignItems(HorizontalAlign.Start)
    .backgroundColor(themedBackground(this.blackTheme))
  }
}
