/**
 * S3 - VideoAudioSettingsFragment (screen_video_audio_settings): the real preference tree, unstyled.
 *
 * STRUCTURE comes from res/xml/video_audio_settings.xml + VideoAudioSettingsFragment.java, NOT from
 * the capture: 26 rows in XML order (9 flat, then PreferenceCategory "Player" with 4, then
 * PreferenceCategory "Player behavior" with 13), 12 of them ListPreferences that open a
 * single-choice dialog, 13 SwitchPreferenceCompat rows and one nested PreferenceScreen that pushes
 * ExoPlayerSettingsFragment. There is no android:dependency and no setEnabled() anywhere in this
 * screen, so no row is ever disabled - and none is given a guard here either.
 *
 * Every `.id()` is the preference KEY VALUE from res/values/settings_keys.xml (the same slug the
 * capture's per-preference dumps and results/plan/action-contracts.json use), never the XML
 * resource name: `@string/default_resolution_key` resolves to `default_resolution`, while
 * `@string/autoplay_key` resolves to the literal `autoplay_key`. The row carries the id; the
 * Toggle takes no touch (HitTestMode.None), so the whole row is the one tappable control.
 *
 * Source behaviour reproduced here, from the fragment (not from a screenshot):
 *  - updateResolutionOptions(): ListHelper.getSortedResolutionList() splices
 *    @array/high_resolution_list_* in at index 1 ("best resolution" stays on top) when
 *    show_higher_resolutions is on, for default_resolution / default_popup_resolution /
 *    limit_mobile_data_usage; when it is off, a selected high resolution is forced back to index 0.
 *  - updateSeekOptions(): seek_duration drops every value whose seconds % 10 == 5 while
 *    use_inexact_seek_key is on, and a currently selected 5s-step value is raised by 5s with
 *    Toast(new_seek_duration_toast). Its labels come from the plural R.plurals.seconds, exactly as
 *    res.getQuantityString() does - not from the English @array/seek_duration_description.
 *  - minimize_on_exit_key -> minimize_on_exit_popup_key: the source raises an indefinite Snackbar
 *    offering to grant SYSTEM_ALERT_WINDOW. That permission is ungrantable on a self-signed
 *    HarmonyOS build (self-signed-capabilities.md), so this shows the same
 *    @string/permission_display_over_apps text as a toast and NEVER requests a permission; the
 *    popup player itself is the PiP/in-app substitution registered in the plan.
 *
 * PREFERRED_OPEN_ACTION_OPTIONS entries 6 and 7 were crossed in this port ("Enqueue" carried
 * `always_ask_player` and "Always ask" carried `enqueue`), which made each choice do the other's
 * job: the stored key is matched against RouterChoice keys in DeepLinkRouter, where `enqueue`
 * pairs with @string/enqueue_stream and `always_ask_player` is not a choice key at all. Fixed.
 *
 * S4 - state: every row reads its value from svc_preferences on aboutToAppear (getStringSync /
 * getBooleanSync with the XML android:defaultValue) and writes it back through the STATIC
 * AppPreferences.putString/putBoolean, which putSync + flush() so the write survives a relaunch.
 * The seven app:useSimpleSummaryProvider rows render `simpleSummaries`, re-derived from the row's
 * CURRENT entry list on every load, list rebuild and write - never a literal. `isLoading` /
 * `errorInfo` carry that write's in-flight and failed state.
 *
 * S5 - style: the run's style baseline plus this screen's own base.ui.json/base.png (density
 * 3.0). The 25 depth-1 dumps of this screen carry the gallery's leaked "Default resolution"
 * chooser and were used for NOTHING; the dialog is styled like the verified sibling settings
 * pages. No control, binding, route or handler changed in this pass.
 *
 * S6 - finalize: the two PreferenceCategory headers regained the 5dp ?attr/toolbar_shadow
 * band that settings_category_header_layout.xml puts at the top of its 14dp contrast
 * FrameLayout, and a failed preference write now has a visible surface. Press-state
 * highlighting (?attr/selectableItemBackground on the row) is deliberately NOT added: it
 * never appears in a still capture and the verified sibling settings pages ship without it.
 * The dialog was re-measured against fragment_ExoPlayerSettingsFragment's dump and already
 * matches it exactly (294vp card, 18/8vp title inset, 48vp rows, a 42vp CANCEL flush to the
 * card's bottom-right corner), so nothing there was touched.
 */
import { promptAction, router } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { ServiceLocator } from '../common/di/ServiceLocator';
import { Localization } from '../common/i18n/Localization';
import { PermissionHelper } from '../common/perm/PermissionHelper';
import { AppPreferences } from '../common/prefs/Preferences';
import { ChoiceIndicator } from '../components/ChoiceIndicator';
import {
  add_to_playlist_key,
  always_ask_open_action_key,
  audio_m4a_key,
  audio_webm_key,
  auto_queue_key,
  autoplay_always_key,
  autoplay_key,
  autoplay_never_key,
  autoplay_wifi_key,
  background_player_key,
  best_resolution_key,
  brightness_control_key,
  clear_queue_confirmation_key,
  default_audio_format_key,
  default_popup_resolution_key,
  default_popup_resolution_value,
  default_resolution_key,
  default_resolution_value,
  default_video_format_key,
  download_key,
  enqueue_key,
  ignore_hardware_media_buttons_key,
  left_gesture_control_key,
  limit_data_usage_none_key,
  limit_mobile_data_usage_key,
  minimize_on_exit_background_key,
  minimize_on_exit_key,
  minimize_on_exit_none_key,
  minimize_on_exit_popup_key,
  none_control_key,
  popup_player_key,
  popup_remember_size_pos_key,
  prefer_descriptive_audio_key,
  prefer_original_audio_key,
  preferred_open_action_key,
  resume_on_audio_focus_gain_key,
  right_gesture_control_key,
  seek_duration_default_value,
  seek_duration_key,
  seekbar_preview_thumbnail_high_quality,
  seekbar_preview_thumbnail_key,
  seekbar_preview_thumbnail_low_quality,
  seekbar_preview_thumbnail_none,
  show_higher_resolutions_key,
  show_info_key,
  show_play_with_kodi_key,
  start_main_player_fullscreen_key,
  use_external_audio_player_key,
  use_external_video_player_key,
  use_inexact_seek_key,
  video_3gp_key,
  video_mp4_key,
  video_player_key,
  video_webm_key,
  volume_control_key
} from '../common/prefs/SettingsKeys';
import { DIALOG_MASK_COLOR } from '../common/theme/ServiceTheme';
import { settingsListScroller } from '../common/settings/SettingsScroller';
import { BLACK_THEME_KEY, themedBackground } from '../common/theme/ThemeBackground';

const TAG: string = 'VideoAudioSettingsFragmentPage';

/** Toast.LENGTH_LONG - the length updateSeekOptions() uses. */
const TOAST_LONG_MS: number = 3500;

/* S5 - style only, LightSettingsTheme (the theme base.png renders in; SettingsActivity.onCreate
 * calls ThemeHelper.getSettingsThemeStyle). Reuses the run's style baseline (state.json
 * generation.styleBaseline, source S0004): primary / onPrimary / background / onSurface /
 * secondaryText, the 56vp toolbar with its 72vp title inset and the 20fp Medium bar title. The
 * preference-row metrics (16vp gutter, 16vp vertical padding, the 47x27vp switch) are measured
 * from THIS screen's base.ui.json at density 3.0; the colours are sampled from base.png. The 25
 * depth-1 dumps of this screen all carry the gallery's leaked "Default resolution" chooser, so
 * NOTHING here - the dialog least of all - is taken from them. */
/** ?attr/colorPrimary - the toolbar; base.png samples it (229,57,53). */
const COLOR_PRIMARY: Resource = $r('app.color.primary');
/** ?attr/actionColor - the Up glyph and the bar title. */
const COLOR_ON_PRIMARY: Resource = $r('app.color.on_primary');
/** ?attr/windowBackground - light_background_color, base.png's (238,238,238). */
const COLOR_SURFACE: Resource = $r('app.color.background');
/** ?android:textColorPrimary - #DE000000 over #EEEEEE is base.png's (31,31,31) row title. */
const COLOR_ON_SURFACE: Resource = $r('app.color.on_surface');
/** ?android:textColorSecondary - #8A000000 over #EEEEEE is base.png's (109,109,109) summary. */
const COLOR_SECONDARY_TEXT: Resource = $r('app.color.on_surface_variant');
/** The AlertDialog surface: white, per the one dialog this app's captures record. */
const COLOR_DIALOG_SURFACE: Resource = $r('app.color.dialog_surface');
/**
 * The AlertDialog's own button colour: ?attr/colorAccent under LightSettingsTheme, i.e.
 * light_settings_accent_color (#E53935). The settings screens are hosted by LightSettingsTheme and
 * an AlertDialog raised from one DOES inherit its colorAccent - the three sibling settings pages
 * (Content, Download, History) all use this resource, and QA confirms the difference: the Content
 * dialog's CANCEL is red, this screen's was black. An earlier note here claimed the opposite,
 * reading (0,0,0) off a low-fidelity capture; eleven tester cards say otherwise.
 */
const COLOR_ACCENT: Resource = $r('app.color.settings_accent');
/** The unchecked single-choice indicator, sampled (117,117,117) in that same dialog capture. */

/** One entry of a ListPreference: the persisted value and the description shown for it. */
interface PrefOption {
  value: string;
  label: ResourceStr;
}

/**
 * app:useSimpleSummaryProvider materialised: the summary each of the seven provider rows shows for
 * its CURRENT value, looked up through that row's CURRENT entry list. Rebuilt as a whole new
 * instance whenever a value or an entry list changes, which is what @State observes.
 */
class SimpleSummaries {
  defaultResolution: ResourceStr = '';
  defaultPopupResolution: ResourceStr = '';
  limitMobileDataUsage: ResourceStr = '';
  defaultVideoFormat: ResourceStr = '';
  defaultAudioFormat: ResourceStr = '';
  seekbarPreviewThumbnail: ResourceStr = '';
  seekDuration: ResourceStr = '';

  /*
   * The three ListPreference rows whose android:summary is a "... - %s" template rather than a
   * summary provider. ListPreference.getSummary() runs String.format(summary, getEntry()), so the
   * row ends with the entry the user picked; rendering the raw resource showed the template.
   */
  preferredOpenAction: string = '';
  minimizeOnExit: string = '';
  autoplay: string = '';
}

/** @array/resolution_list_description + @array/resolution_list_values. */
const RESOLUTION_BASE_OPTIONS: PrefOption[] = [
  { value: best_resolution_key, label: $r('app.string.best_resolution') },
  { value: '1080p60', label: '1080p60' },
  { value: '1080p', label: '1080p' },
  { value: '720p60', label: '720p60' },
  { value: '720p', label: '720p' },
  { value: '480p', label: '480p' },
  { value: '360p', label: '360p' },
  { value: '240p', label: '240p' },
  { value: '144p', label: '144p' }
];

/** @array/high_resolution_list_descriptions + @array/high_resolution_list_values. */
const HIGH_RESOLUTION_OPTIONS: PrefOption[] = [
  { value: '2160p', label: '2160p' },
  { value: '1440p', label: '1440p' }
];

/** @array/limit_data_usage_description_list + @array/limit_data_usage_values_list. */
const LIMIT_DATA_BASE_OPTIONS: PrefOption[] = [
  { value: limit_data_usage_none_key, label: $r('app.string.limit_data_usage_none_description') },
  { value: '1080p60', label: '1080p60' },
  { value: '1080p', label: '1080p' },
  { value: '720p60', label: '720p60' },
  { value: '720p', label: '720p' },
  { value: '480p', label: '480p' },
  { value: '360p', label: '360p' },
  { value: '240p', label: '240p' },
  { value: '144p', label: '144p' }
];

/**
 * @array/high_resolution_limit_data_usage_values_list. Its DESCRIPTIONS come from
 * @array/high_resolution_list_descriptions - updateResolutionOptions() pairs those two arrays.
 */
const HIGH_LIMIT_DATA_OPTIONS: PrefOption[] = [
  { value: '2160p', label: '2160p' },
  { value: '1440p', label: '1440p' }
];

/** @array/video_format_description_list + @array/video_format_values_list. */
const VIDEO_FORMAT_OPTIONS: PrefOption[] = [
  { value: video_mp4_key, label: 'MPEG-4' },
  { value: video_webm_key, label: 'WebM' },
  { value: video_3gp_key, label: '3GP' }
];

/** @array/audio_format_description_list + @array/audio_format_values_list. */
const AUDIO_FORMAT_OPTIONS: PrefOption[] = [
  { value: audio_m4a_key, label: 'M4A' },
  { value: audio_webm_key, label: 'WebM' }
];

/** @array/seekbar_preview_thumbnail_type_description + @array/seekbar_preview_thumbnail_type_key. */
const SEEKBAR_PREVIEW_OPTIONS: PrefOption[] = [
  { value: seekbar_preview_thumbnail_high_quality, label: $r('app.string.high_quality_larger') },
  { value: seekbar_preview_thumbnail_low_quality, label: $r('app.string.low_quality_smaller') },
  { value: seekbar_preview_thumbnail_none, label: $r('app.string.dont_show') }
];

/**
 * @array/preferred_open_action_description_list + @array/preferred_open_action_values_list.
 */
const PREFERRED_OPEN_ACTION_OPTIONS: PrefOption[] = [
  { value: show_info_key, label: $r('app.string.show_info') },
  { value: video_player_key, label: $r('app.string.video_player') },
  { value: background_player_key, label: $r('app.string.background_player') },
  { value: popup_player_key, label: $r('app.string.popup_player') },
  { value: download_key, label: $r('app.string.download') },
  { value: add_to_playlist_key, label: $r('app.string.add_to_playlist') },
  { value: enqueue_key, label: $r('app.string.enqueue_stream') },
  { value: always_ask_open_action_key, label: $r('app.string.always_ask_open_action') }
];

/** @array/minimize_on_exit_action_description + @array/minimize_on_exit_action_key. */
const MINIMIZE_ON_EXIT_OPTIONS: PrefOption[] = [
  { value: minimize_on_exit_none_key, label: $r('app.string.minimize_on_exit_none_description') },
  {
    value: minimize_on_exit_background_key,
    label: $r('app.string.minimize_on_exit_background_description')
  },
  { value: minimize_on_exit_popup_key, label: $r('app.string.minimize_on_exit_popup_description') }
];

/** @array/autoplay_type_description + @array/autoplay_type_key. */
const AUTOPLAY_OPTIONS: PrefOption[] = [
  { value: autoplay_always_key, label: $r('app.string.always') },
  { value: autoplay_wifi_key, label: $r('app.string.wifi_only') },
  { value: autoplay_never_key, label: $r('app.string.never') }
];

/** @array/left_gesture_control_description + @array/left_gesture_control_values. */
const LEFT_GESTURE_OPTIONS: PrefOption[] = [
  { value: brightness_control_key, label: $r('app.string.brightness') },
  { value: volume_control_key, label: $r('app.string.volume') },
  { value: none_control_key, label: $r('app.string.none') }
];

/** @array/right_gesture_control_description + @array/right_gesture_control_values - volume first. */
const RIGHT_GESTURE_OPTIONS: PrefOption[] = [
  { value: volume_control_key, label: $r('app.string.volume') },
  { value: brightness_control_key, label: $r('app.string.brightness') },
  { value: none_control_key, label: $r('app.string.none') }
];

/** @array/seek_duration_value; the labels are built from R.plurals.seconds at runtime. */
const SEEK_DURATION_VALUES: string[] = ['5000', '10000', '15000', '20000', '25000', '30000'];

/** DateUtils.SECOND_IN_MILLIS. */
const SECOND_IN_MILLIS: number = 1000;

/**
 * The ListPreference dialog - single choice over the preference's entries, plus CANCEL. One struct
 * serves all twelve rows; each instance is given its own `..._itemroot` id and its option rows
 * deliberately SHARE it (CLAUDE.md rule 12, list-row exception). The option list scrolls inside a
 * height-bounded box so CANCEL cannot be pushed off-frame by a long entry list (the resolution and
 * mobile-data lists reach eleven entries).
 */
@CustomDialog
struct PreferenceChoiceDialog {
  controller?: CustomDialogController;
  title: ResourceStr = '';
  options: PrefOption[] = [];
  selected: string = '';
  itemId: string = 'preference_choice_itemroot';
  onSelect: (value: string) => void = (value: string): void => {
    hilog.debug(0x0000, TAG, 'PreferenceChoiceDialog: select %{public}s not bound', value);
  };

  build() {
    Column() {
      // alertTitle: 20sp at the dialog's 24vp gutter, 18vp above and 8vp below (titleDivider).
      Text(this.title)
        .width('100%')
        .fontSize(20)
        .fontColor(COLOR_ON_SURFACE)
        .padding({ left: 24, right: 24, top: 18, bottom: 8 })

      // select_dialog_listview
      Scroll() {
        Column() {
          ForEach(this.options, (option: PrefOption) => {
            // select_dialog_singlechoice: a 48vp row, the indicator then 16sp at the 24vp gutter.
            Row() {
              // The reference's hollow ring, not ArkUI's filled disc - see ChoiceIndicator.
              ChoiceIndicator({ checked: option.value === this.selected })
                .margin({ right: 20 })
              Text(option.label)
                .layoutWeight(1)
                .fontSize(16)
                .fontColor(COLOR_ON_SURFACE)
            }
            .width('100%')
            .height(48)
            .padding({ left: 24, right: 24 })
            .alignItems(VerticalAlign.Center)
            .id(this.itemId)
            .onClick(() => {
              this.controller?.close();
              this.onSelect(option.value);
            })
          }, (option: PrefOption) => option.value)
        }
        .width('100%')
      }
      // 320 truncated the lists this dialog is actually used for: RESOLUTION_BASE_OPTIONS is
      // nine 48vp rows = 432vp, so the last entries were unreachable and TC-SETTINGS-657/658/659
      // report exactly that. 480 shows ten rows and still leaves the title and CANCEL in frame on
      // the folded Mate X7 - 480 + 60 title + 58 button is well inside the 827vp screen. A longer
      // list still scrolls, which is what this box is for.
      .constraintSize({ maxHeight: 480 })

      // buttonPanel: a borderless accent-coloured button, flush with the card's bottom-right. The
      // label goes through buttonLabel() because Widget.AppCompat.Button is textAllCaps and ArkUI
      // has no such attribute - the resource stays sentence case, the button shows CANCEL.
      Button(Localization.buttonLabel('cancel'))
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
    // The AlertDialog card: 294vp wide, white, a 4vp radius - not the platform's rounded sheet.
    .width(294)
    .backgroundColor(COLOR_DIALOG_SURFACE)
    .borderRadius(4)
    .alignItems(HorizontalAlign.Start)
  }
}

@Entry
@Component
export struct VideoAudioSettingsFragmentPage {
  /** ThemeHelper's black theme: the window background follows it. */
  @StorageProp(BLACK_THEME_KEY) blackTheme: boolean = false;

  /**
   * TRUE when this screen sits in SettingsActivityPage's settings_fragment_holder, which draws the
   * one toolbar for whatever it holds; FALSE when this page is the pushed route and nothing above
   * it carries a bar. The host passes it explicitly, the way ChannelFragmentPage takes
   * `hostedInMainShell`: a host-set AppStorage flag still reads true underneath a page the host
   * pushed, and MainSettingsFragmentPage pushes this very screen from inside that host. The
   * default is FALSE, so an unset value falls through to DRAWING the bar rather than to none.
   */
  @Prop hostDrawsToolbar: boolean = false;
  /* ListPreference values, each with its android:defaultValue from the XML. */
  @State defaultResolution: string = default_resolution_value;
  @State defaultPopupResolution: string = default_popup_resolution_value;
  @State limitMobileDataUsage: string = limit_data_usage_none_key;
  @State defaultVideoFormat: string = video_mp4_key;
  @State defaultAudioFormat: string = audio_m4a_key;
  @State seekbarPreviewThumbnail: string = seekbar_preview_thumbnail_high_quality;
  @State preferredOpenAction: string = always_ask_open_action_key;
  @State minimizeOnExitKey: string = minimize_on_exit_background_key;
  @State autoplay: string = autoplay_wifi_key;
  @State leftGestureControl: string = brightness_control_key;
  @State rightGestureControl: string = volume_control_key;
  @State seekDuration: string = seek_duration_default_value;

  /* SwitchPreferenceCompat values, each with its android:defaultValue. */
  @State showHigherResolutions: boolean = false;
  @State preferOriginalAudio: boolean = true;
  @State preferDescriptiveAudio: boolean = false;
  @State useExternalVideoPlayer: boolean = false;
  @State useExternalAudioPlayer: boolean = false;
  @State showPlayWithKodi: boolean = false;
  @State startMainPlayerFullscreen: boolean = false;
  @State autoQueue: boolean = false;
  @State resumeOnAudioFocusGain: boolean = false;
  @State popupRememberSizePos: boolean = true;
  @State useInexactSeekKey: boolean = false;
  @State clearQueueConfirmation: boolean = false;
  @State ignoreHardwareMediaButtons: boolean = false;

  /* The entry lists the fragment REBUILDS at runtime; never hardcoded from the capture. */
  @State resolutionListPreferenceEntries3Rows: PrefOption[] = RESOLUTION_BASE_OPTIONS;
  @State limitDataOptions: PrefOption[] = LIMIT_DATA_BASE_OPTIONS;
  @State seekDurationEntries: PrefOption[] = [];

  /** The summary provider's output for the seven app:useSimpleSummaryProvider rows. */
  @State simpleSummaries: SimpleSummaries = new SimpleSummaries();

  /* A preference write is putSync + flush(); these hold that write's in-flight and failed state,
   * exactly as the sibling settings pages do. */
  @State isLoading: boolean = false;
  @State errorInfo: string = '';

  private defaultResolutionDialog: CustomDialogController = new CustomDialogController({
    maskColor: DIALOG_MASK_COLOR,
    customStyle: true,
    builder: PreferenceChoiceDialog({
      title: $r('app.string.default_resolution_title'),
      options: this.resolutionListPreferenceEntries3Rows,
      selected: this.defaultResolution,
      itemId: 'default_resolution_itemroot',
      onSelect: (value: string): void => {
        this.defaultResolution = value;
        this.persistString(default_resolution_key, value);
      }
    })
  });

  private defaultPopupResolutionDialog: CustomDialogController = new CustomDialogController({
    maskColor: DIALOG_MASK_COLOR,
    customStyle: true,
    builder: PreferenceChoiceDialog({
      title: $r('app.string.default_popup_resolution_title'),
      options: this.resolutionListPreferenceEntries3Rows,
      selected: this.defaultPopupResolution,
      itemId: 'default_popup_resolution_itemroot',
      onSelect: (value: string): void => {
        this.defaultPopupResolution = value;
        this.persistString(default_popup_resolution_key, value);
      }
    })
  });

  private limitMobileDataUsageDialog: CustomDialogController = new CustomDialogController({
    maskColor: DIALOG_MASK_COLOR,
    customStyle: true,
    builder: PreferenceChoiceDialog({
      title: $r('app.string.limit_mobile_data_usage_title'),
      options: this.limitDataOptions,
      selected: this.limitMobileDataUsage,
      itemId: 'limit_mobile_data_usage_itemroot',
      onSelect: (value: string): void => {
        this.limitMobileDataUsage = value;
        this.persistString(limit_mobile_data_usage_key, value);
      }
    })
  });

  private defaultVideoFormatDialog: CustomDialogController = new CustomDialogController({
    maskColor: DIALOG_MASK_COLOR,
    customStyle: true,
    builder: PreferenceChoiceDialog({
      title: $r('app.string.default_video_format_title'),
      options: VIDEO_FORMAT_OPTIONS,
      selected: this.defaultVideoFormat,
      itemId: 'default_video_format_itemroot',
      onSelect: (value: string): void => {
        this.defaultVideoFormat = value;
        this.persistString(default_video_format_key, value);
      }
    })
  });

  private defaultAudioFormatDialog: CustomDialogController = new CustomDialogController({
    maskColor: DIALOG_MASK_COLOR,
    customStyle: true,
    builder: PreferenceChoiceDialog({
      title: $r('app.string.default_audio_format_title'),
      options: AUDIO_FORMAT_OPTIONS,
      selected: this.defaultAudioFormat,
      itemId: 'default_audio_format_itemroot',
      onSelect: (value: string): void => {
        this.defaultAudioFormat = value;
        this.persistString(default_audio_format_key, value);
      }
    })
  });

  private seekbarPreviewDialog: CustomDialogController = new CustomDialogController({
    maskColor: DIALOG_MASK_COLOR,
    customStyle: true,
    builder: PreferenceChoiceDialog({
      title: $r('app.string.seekbar_preview_thumbnail_title'),
      options: SEEKBAR_PREVIEW_OPTIONS,
      selected: this.seekbarPreviewThumbnail,
      itemId: 'seekbar_preview_thumbnail_itemroot',
      onSelect: (value: string): void => {
        this.seekbarPreviewThumbnail = value;
        this.persistString(seekbar_preview_thumbnail_key, value);
      }
    })
  });

  private preferredOpenActionDialog: CustomDialogController = new CustomDialogController({
    maskColor: DIALOG_MASK_COLOR,
    customStyle: true,
    builder: PreferenceChoiceDialog({
      title: $r('app.string.preferred_open_action_settings_title'),
      options: PREFERRED_OPEN_ACTION_OPTIONS,
      selected: this.preferredOpenAction,
      itemId: 'preferred_open_action_itemroot',
      onSelect: (value: string): void => {
        this.preferredOpenAction = value;
        this.persistString(preferred_open_action_key, value);
      }
    })
  });

  private minimizeOnExitDialog: CustomDialogController = new CustomDialogController({
    maskColor: DIALOG_MASK_COLOR,
    customStyle: true,
    builder: PreferenceChoiceDialog({
      title: $r('app.string.minimize_on_exit_title'),
      options: MINIMIZE_ON_EXIT_OPTIONS,
      selected: this.minimizeOnExitKey,
      itemId: 'minimize_on_exit_itemroot',
      onSelect: (value: string): void => {
        this.onMinimizeOnExitPicked(value);
      }
    })
  });

  private autoplayDialog: CustomDialogController = new CustomDialogController({
    maskColor: DIALOG_MASK_COLOR,
    customStyle: true,
    builder: PreferenceChoiceDialog({
      title: $r('app.string.autoplay_title'),
      options: AUTOPLAY_OPTIONS,
      selected: this.autoplay,
      itemId: 'autoplay_itemroot',
      onSelect: (value: string): void => {
        this.autoplay = value;
        this.persistString(autoplay_key, value);
      }
    })
  });

  private leftGestureDialog: CustomDialogController = new CustomDialogController({
    maskColor: DIALOG_MASK_COLOR,
    customStyle: true,
    builder: PreferenceChoiceDialog({
      title: $r('app.string.left_gesture_control_title'),
      options: LEFT_GESTURE_OPTIONS,
      selected: this.leftGestureControl,
      itemId: 'left_gesture_control_itemroot',
      onSelect: (value: string): void => {
        this.leftGestureControl = value;
        this.persistString(left_gesture_control_key, value);
      }
    })
  });

  private rightGestureDialog: CustomDialogController = new CustomDialogController({
    maskColor: DIALOG_MASK_COLOR,
    customStyle: true,
    builder: PreferenceChoiceDialog({
      title: $r('app.string.right_gesture_control_title'),
      options: RIGHT_GESTURE_OPTIONS,
      selected: this.rightGestureControl,
      itemId: 'right_gesture_control_itemroot',
      onSelect: (value: string): void => {
        this.rightGestureControl = value;
        this.persistString(right_gesture_control_key, value);
      }
    })
  });

  private seekDurationDialog: CustomDialogController = new CustomDialogController({
    maskColor: DIALOG_MASK_COLOR,
    customStyle: true,
    builder: PreferenceChoiceDialog({
      title: $r('app.string.seek_duration_title'),
      options: this.seekDurationEntries,
      selected: this.seekDuration,
      itemId: 'seek_duration_itemroot',
      onSelect: (value: string): void => {
        this.seekDuration = value;
        this.persistString(seek_duration_key, value);
      }
    })
  });

  /** Rule 8: a dialog still on screen when the page pops would outlive it. */
  aboutToDisappear(): void {
    this.defaultResolutionDialog.close();
    this.defaultPopupResolutionDialog.close();
    this.limitMobileDataUsageDialog.close();
    this.defaultVideoFormatDialog.close();
    this.defaultAudioFormatDialog.close();
    this.seekbarPreviewDialog.close();
    this.preferredOpenActionDialog.close();
    this.minimizeOnExitDialog.close();
    this.autoplayDialog.close();
    this.leftGestureDialog.close();
    this.rightGestureDialog.close();
    this.seekDurationDialog.close();
  }

  /** onCreatePreferences(): inflate the rows, then updateSeekOptions() + updateResolutionOptions(). */
  aboutToAppear(): void {
    try {
      this.loadPreferences();
    } catch (err) {
      hilog.error(0x0000, TAG, 'loadPreferences: %{public}s', (err as Error).message);
    }
    this.applySeekOptions();
    this.applyResolutionOptions();
  }

  private loadPreferences(): void {
    const prefs: AppPreferences = AppPreferences.instance();
    this.defaultResolution = prefs.getStringSync(default_resolution_key, default_resolution_value);
    this.defaultPopupResolution =
      prefs.getStringSync(default_popup_resolution_key, default_popup_resolution_value);
    this.limitMobileDataUsage =
      prefs.getStringSync(limit_mobile_data_usage_key, limit_data_usage_none_key);
    this.defaultVideoFormat = prefs.getStringSync(default_video_format_key, video_mp4_key);
    this.defaultAudioFormat = prefs.getStringSync(default_audio_format_key, audio_m4a_key);
    this.seekbarPreviewThumbnail =
      prefs.getStringSync(seekbar_preview_thumbnail_key, seekbar_preview_thumbnail_high_quality);
    this.preferredOpenAction =
      prefs.getStringSync(preferred_open_action_key, always_ask_open_action_key);
    this.minimizeOnExitKey =
      prefs.getStringSync(minimize_on_exit_key, minimize_on_exit_background_key);
    this.autoplay = prefs.getStringSync(autoplay_key, autoplay_wifi_key);
    this.leftGestureControl = prefs.getStringSync(left_gesture_control_key, brightness_control_key);
    this.rightGestureControl = prefs.getStringSync(right_gesture_control_key, volume_control_key);
    this.seekDuration = prefs.getStringSync(seek_duration_key, seek_duration_default_value);

    this.showHigherResolutions = prefs.getBooleanSync(show_higher_resolutions_key, false);
    this.preferOriginalAudio = prefs.getBooleanSync(prefer_original_audio_key, true);
    this.preferDescriptiveAudio = prefs.getBooleanSync(prefer_descriptive_audio_key, false);
    this.useExternalVideoPlayer = prefs.getBooleanSync(use_external_video_player_key, false);
    this.useExternalAudioPlayer = prefs.getBooleanSync(use_external_audio_player_key, false);
    this.showPlayWithKodi = prefs.getBooleanSync(show_play_with_kodi_key, false);
    this.startMainPlayerFullscreen = prefs.getBooleanSync(start_main_player_fullscreen_key, false);
    this.autoQueue = prefs.getBooleanSync(auto_queue_key, false);
    this.resumeOnAudioFocusGain = prefs.getBooleanSync(resume_on_audio_focus_gain_key, false);
    this.popupRememberSizePos = prefs.getBooleanSync(popup_remember_size_pos_key, true);
    this.useInexactSeekKey = prefs.getBooleanSync(use_inexact_seek_key, false);
    this.clearQueueConfirmation = prefs.getBooleanSync(clear_queue_confirmation_key, false);
    this.ignoreHardwareMediaButtons = prefs.getBooleanSync(ignore_hardware_media_buttons_key, false);
  }

  /* //////////////////////////////////////////////////////////////////////////
  // updateResolutionOptions() / updateSeekOptions()
  ////////////////////////////////////////////////////////////////////////// */

  /** ListHelper.getSortedResolutionList(): the additional entries go in at index 1. */
  private sortedResolutionList(base: PrefOption[], additional: PrefOption[],
    showHigherResolutions: boolean): PrefOption[] {
    if (!showHigherResolutions) {
      return base;
    }
    const merged: PrefOption[] = [];
    merged.push(base[0]);
    for (const option of additional) {
      merged.push(option);
    }
    for (let i = 1; i < base.length; i++) {
      merged.push(base[i]);
    }
    return merged;
  }

  /** ListHelper.isHighResolutionSelected(). */
  private isHighResolutionSelected(additional: PrefOption[], selected: string): boolean {
    for (const option of additional) {
      if (option.value === selected) {
        return true;
      }
    }
    return false;
  }

  private applyResolutionOptions(): void {
    const showHigher: boolean = this.showHigherResolutions;
    this.resolutionListPreferenceEntries3Rows =
      this.sortedResolutionList(RESOLUTION_BASE_OPTIONS, HIGH_RESOLUTION_OPTIONS, showHigher);
    this.limitDataOptions =
      this.sortedResolutionList(LIMIT_DATA_BASE_OPTIONS, HIGH_LIMIT_DATA_OPTIONS, showHigher);
    if (showHigher) {
      this.refreshSimpleSummaries();
      return;
    }
    // "Show higher resolution" off: a selected high resolution falls back to index 0.
    if (this.isHighResolutionSelected(HIGH_RESOLUTION_OPTIONS, this.defaultResolution)) {
      this.defaultResolution = RESOLUTION_BASE_OPTIONS[0].value;
      this.persistString(default_resolution_key, this.defaultResolution);
    }
    if (this.isHighResolutionSelected(HIGH_RESOLUTION_OPTIONS, this.defaultPopupResolution)) {
      this.defaultPopupResolution = RESOLUTION_BASE_OPTIONS[0].value;
      this.persistString(default_popup_resolution_key, this.defaultPopupResolution);
    }
    if (this.isHighResolutionSelected(HIGH_LIMIT_DATA_OPTIONS, this.limitMobileDataUsage)) {
      this.limitMobileDataUsage = LIMIT_DATA_BASE_OPTIONS[0].value;
      this.persistString(limit_mobile_data_usage_key, this.limitMobileDataUsage);
    }
    this.refreshSimpleSummaries();
  }

  /** res.getQuantityString(R.plurals.seconds, n) + String.format(..., n). */
  private secondsLabel(seconds: number): string {
    try {
      const context: common.Context = getContext(this) as common.Context;
      const template: string =
        context.resourceManager.getPluralStringValueSync($r('app.plural.seconds'), seconds);
      return template.replace('%d', seconds.toString());
    } catch (err) {
      // Resources.NotFoundException: the translation is missing, show the plain number.
      hilog.warn(0x0000, TAG, 'plural seconds: %{public}s', (err as Error).message);
      return seconds.toString();
    }
  }

  private buildSeekOptions(inexactSeek: boolean): PrefOption[] {
    const options: PrefOption[] = [];
    for (const durationValue of SEEK_DURATION_VALUES) {
      const seconds: number = parseInt(durationValue, 10) / SECOND_IN_MILLIS;
      // ExoPlayer cannot seek 5 seconds in audio when using inexact seek.
      if (inexactSeek && seconds % 10 === 5) {
        continue;
      }
      options.push({ value: durationValue, label: this.secondsLabel(seconds) });
    }
    return options;
  }

  private applySeekOptions(): void {
    const inexactSeek: boolean = this.useInexactSeekKey;
    this.seekDurationEntries = this.buildSeekOptions(inexactSeek);
    const selectedSeconds: number = parseInt(this.seekDuration, 10) / SECOND_IN_MILLIS;
    if (Number.isNaN(selectedSeconds)) {
      this.refreshSimpleSummaries();
      return;
    }
    if (inexactSeek && selectedSeconds % 10 === 5) {
      const newDuration: number = selectedSeconds + 5;
      this.seekDuration = (newDuration * SECOND_IN_MILLIS).toString();
      this.persistString(seek_duration_key, this.seekDuration);
      promptAction.showToast({
        message: $r('app.string.new_seek_duration_toast', newDuration),
        duration: TOAST_LONG_MS
      });
    }
    this.refreshSimpleSummaries();
  }

  /* //////////////////////////////////////////////////////////////////////////
  // Row handlers
  ////////////////////////////////////////////////////////////////////////// */

  /** The label the row shows for its current value (app:useSimpleSummaryProvider). */
  private labelOf(options: PrefOption[], value: string): ResourceStr {
    for (const option of options) {
      if (option.value === value) {
        return option.label;
      }
    }
    return '';
  }

  /** SummaryProvider.provideSummary(): re-derive every provider row's summary from its own list. */
  private refreshSimpleSummaries(): void {
    const next: SimpleSummaries = new SimpleSummaries();
    next.defaultResolution =
      this.labelOf(this.resolutionListPreferenceEntries3Rows, this.defaultResolution);
    next.defaultPopupResolution =
      this.labelOf(this.resolutionListPreferenceEntries3Rows, this.defaultPopupResolution);
    next.limitMobileDataUsage = this.labelOf(this.limitDataOptions, this.limitMobileDataUsage);
    next.defaultVideoFormat = this.labelOf(VIDEO_FORMAT_OPTIONS, this.defaultVideoFormat);
    next.defaultAudioFormat = this.labelOf(AUDIO_FORMAT_OPTIONS, this.defaultAudioFormat);
    next.seekbarPreviewThumbnail =
      this.labelOf(SEEKBAR_PREVIEW_OPTIONS, this.seekbarPreviewThumbnail);
    next.seekDuration = this.labelOf(this.seekDurationEntries, this.seekDuration);
    next.preferredOpenAction = this.formattedSummary('preferred_open_action_settings_summary',
      PREFERRED_OPEN_ACTION_OPTIONS, this.preferredOpenAction);
    next.minimizeOnExit = this.formattedSummary('minimize_on_exit_summary',
      MINIMIZE_ON_EXIT_OPTIONS, this.minimizeOnExitKey);
    next.autoplay =
      this.formattedSummary('autoplay_summary', AUTOPLAY_OPTIONS, this.autoplay);
    this.simpleSummaries = next;
  }

  /** ListPreference.getSummary(): String.format(android:summary, the entry for the value held). */
  private formattedSummary(summaryName: string, options: PrefOption[], value: string): string {
    return Localization.getStringArgs(summaryName, [this.textOf(this.labelOf(options, value))]);
  }

  /** A ResourceStr as the plain text it resolves to, so it can be a format argument. */
  private textOf(label: ResourceStr): string {
    if (typeof label === 'string') {
      return label;
    }
    try {
      const context: common.Context = getContext(this) as common.Context;
      return context.resourceManager.getStringSync(label.id);
    } catch (err) {
      // Resources.NotFoundException: keep the rest of the summary rather than dropping the row.
      hilog.warn(0x0000, TAG, 'summary entry: %{public}s', (err as Error).message);
      return '';
    }
  }

  /** editor.putString(key, value).apply(), flushed so the write survives a relaunch. */
  private persistString(key: string, value: string): void {
    this.isLoading = true;
    AppPreferences.putString(key, value)
      .then((): void => {
        this.errorInfo = '';
        this.isLoading = false;
      })
      .catch((err: Error): void => {
        this.errorInfo = err.message;
        this.isLoading = false;
        hilog.error(0x0000, TAG, 'putString(%{public}s): %{public}s', key, err.message);
      });
    this.refreshSimpleSummaries();
  }

  /** editor.putBoolean(key, value).apply(), flushed for the same reason. */
  private persistBoolean(key: string, value: boolean): void {
    this.isLoading = true;
    AppPreferences.putBoolean(key, value)
      .then((): void => {
        this.errorInfo = '';
        this.isLoading = false;
      })
      .catch((err: Error): void => {
        this.errorInfo = err.message;
        this.isLoading = false;
        hilog.error(0x0000, TAG, 'putBoolean(%{public}s): %{public}s', key, err.message);
      });
  }

  /** show_higher_resolutions_key -> updateResolutionOptions(), through the source's listener. */
  private onShowHigherResolutionsChanged(): void {
    this.showHigherResolutions = !this.showHigherResolutions;
    this.persistBoolean(show_higher_resolutions_key, this.showHigherResolutions);
    this.applyResolutionOptions();
  }

  /** use_inexact_seek_key -> updateSeekOptions(), through the source's listener. */
  private onUseInexactSeekChanged(): void {
    this.useInexactSeekKey = !this.useInexactSeekKey;
    this.persistBoolean(use_inexact_seek_key, this.useInexactSeekKey);
    this.applySeekOptions();
  }

  /**
   * The Snackbar arm of the listener. SYSTEM_ALERT_WINDOW is ungrantable on a self-signed build, so
   * the message is shown and NO permission is requested - the popup player itself is the
   * PiP/in-app substitution.
   */
  private onMinimizeOnExitPicked(value: string): void {
    this.minimizeOnExitKey = value;
    this.persistString(minimize_on_exit_key, value);
    // `!Settings.canDrawOverlays(getContext())` ports to svc_permissions'
    // PermissionHelper.isPopupEnabled() (isPopupEnabledElseAsk): SYSTEM_FLOAT_WINDOW is ungrantable
    // on a self-signed build, so it only REPORTS whether PiP is there and never requests anything.
    const permissions: PermissionHelper = ServiceLocator.get().permissions;
    if (value === minimize_on_exit_popup_key && !permissions.isPopupEnabled()) {
      promptAction.showToast({
        message: $r('app.string.permission_display_over_apps'),
        duration: TOAST_LONG_MS
      });
    }
  }

  build() {
    Column() {
      if (!this.hostDrawsToolbar) {
        // toolbar_layout.xml: the host activity's Up affordance plus the PreferenceScreen title that
        // BasePreferenceFragment.onViewCreated pushes into it.
        Row() {
          // The 24vp glyph centred in a 56vp (?attr/actionBarSize) target - base.ui.json puts the
          // Up button at [0,72][168,240]. The SVG ships black, so the bar's tint is applied here.
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

          // Widget.AppCompat.Toolbar.Title: 20sp medium, 16vp past the navigation button (base.ui
          // .json puts "Video and audio" at x=216 of 1080 - 72vp at density 3.0, 81px = 27vp tall).
          Text($r('app.string.settings_category_video_audio_title'))
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

      // The preference RecyclerView (id/recycler_view); BasePreferenceFragment setDivider(null).
      List({ scroller: settingsListScroller }) {
        /* ── flat head ─────────────────────────────────────────────────── */
        // ListPreference default_resolution_key
        ListItem() {
          Row() {
            Column() {
              Text($r('app.string.default_resolution_title'))
                .width('100%')
                .fontSize(16)
                .lineHeight(20)
                .fontColor(COLOR_ON_SURFACE)
              Text(this.simpleSummaries.defaultResolution)
                .width('100%')
                .fontSize(14)
                .lineHeight(17)
                .fontColor(COLOR_SECONDARY_TEXT)
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)
          }
          .id('default_resolution')
          .width('100%')
          .padding({ left: 16, right: 16, top: 16, bottom: 16 })
          .alignItems(VerticalAlign.Center)
          .onClick(() => {
            this.defaultResolutionDialog.open();
          })
        }

        // ListPreference default_popup_resolution_key
        ListItem() {
          Row() {
            Column() {
              Text($r('app.string.default_popup_resolution_title'))
                .width('100%')
                .fontSize(16)
                .lineHeight(20)
                .fontColor(COLOR_ON_SURFACE)
              Text(this.simpleSummaries.defaultPopupResolution)
                .width('100%')
                .fontSize(14)
                .lineHeight(17)
                .fontColor(COLOR_SECONDARY_TEXT)
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)
          }
          .id('default_popup_resolution')
          .width('100%')
          .padding({ left: 16, right: 16, top: 16, bottom: 16 })
          .alignItems(VerticalAlign.Center)
          .onClick(() => {
            this.defaultPopupResolutionDialog.open();
          })
        }

        // ListPreference limit_mobile_data_usage_key
        ListItem() {
          Row() {
            Column() {
              Text($r('app.string.limit_mobile_data_usage_title'))
                .width('100%')
                .fontSize(16)
                .lineHeight(20)
                .fontColor(COLOR_ON_SURFACE)
              Text(this.simpleSummaries.limitMobileDataUsage)
                .width('100%')
                .fontSize(14)
                .lineHeight(17)
                .fontColor(COLOR_SECONDARY_TEXT)
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)
          }
          .id('limit_mobile_data_usage')
          .width('100%')
          .padding({ left: 16, right: 16, top: 16, bottom: 16 })
          .alignItems(VerticalAlign.Center)
          .onClick(() => {
            this.limitMobileDataUsageDialog.open();
          })
        }

        // SwitchPreferenceCompat show_higher_resolutions_key
        ListItem() {
          Row() {
            Column() {
              Text($r('app.string.show_higher_resolutions_title'))
                .width('100%')
                .fontSize(16)
                .lineHeight(20)
                .fontColor(COLOR_ON_SURFACE)
              Text($r('app.string.show_higher_resolutions_summary'))
                .width('100%')
                .fontSize(14)
                .lineHeight(17)
                .fontColor(COLOR_SECONDARY_TEXT)
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)

            // widget_frame: a 47x27vp switch against the row's 16vp right gutter (base.ui.json's
            // [892,962][1032,1043] at density 3.0). The whole row is the one tappable control, so
            // the switch takes no touch.
            Toggle({ type: ToggleType.Switch, isOn: this.showHigherResolutions })
              .hitTestBehavior(HitTestMode.None)
              .width(47)
              .height(27)
              .margin({ left: 16 })
              .selectedColor(COLOR_PRIMARY)
          }
          .id('show_higher_resolutions')
          .width('100%')
          .padding({ left: 16, right: 16, top: 16, bottom: 16 })
          .alignItems(VerticalAlign.Center)
          .onClick(() => {
            this.onShowHigherResolutionsChanged();
          })
        }

        // ListPreference default_video_format_key
        ListItem() {
          Row() {
            Column() {
              Text($r('app.string.default_video_format_title'))
                .width('100%')
                .fontSize(16)
                .lineHeight(20)
                .fontColor(COLOR_ON_SURFACE)
              Text(this.simpleSummaries.defaultVideoFormat)
                .width('100%')
                .fontSize(14)
                .lineHeight(17)
                .fontColor(COLOR_SECONDARY_TEXT)
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)
          }
          .id('default_video_format')
          .width('100%')
          .padding({ left: 16, right: 16, top: 16, bottom: 16 })
          .alignItems(VerticalAlign.Center)
          .onClick(() => {
            this.defaultVideoFormatDialog.open();
          })
        }

        // ListPreference default_audio_format_key
        ListItem() {
          Row() {
            Column() {
              Text($r('app.string.default_audio_format_title'))
                .width('100%')
                .fontSize(16)
                .lineHeight(20)
                .fontColor(COLOR_ON_SURFACE)
              Text(this.simpleSummaries.defaultAudioFormat)
                .width('100%')
                .fontSize(14)
                .lineHeight(17)
                .fontColor(COLOR_SECONDARY_TEXT)
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)
          }
          .id('default_audio_format')
          .width('100%')
          .padding({ left: 16, right: 16, top: 16, bottom: 16 })
          .alignItems(VerticalAlign.Center)
          .onClick(() => {
            this.defaultAudioFormatDialog.open();
          })
        }

        // SwitchPreferenceCompat prefer_original_audio_key
        ListItem() {
          Row() {
            Column() {
              Text($r('app.string.prefer_original_audio_title'))
                .width('100%')
                .fontSize(16)
                .lineHeight(20)
                .fontColor(COLOR_ON_SURFACE)
              Text($r('app.string.prefer_original_audio_summary'))
                .width('100%')
                .fontSize(14)
                .lineHeight(17)
                .fontColor(COLOR_SECONDARY_TEXT)
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)

            // widget_frame: a 47x27vp switch against the row's 16vp right gutter (base.ui.json's
            // [892,962][1032,1043] at density 3.0). The whole row is the one tappable control, so
            // the switch takes no touch.
            Toggle({ type: ToggleType.Switch, isOn: this.preferOriginalAudio })
              .hitTestBehavior(HitTestMode.None)
              .width(47)
              .height(27)
              .margin({ left: 16 })
              .selectedColor(COLOR_PRIMARY)
          }
          .id('prefer_original_audio')
          .width('100%')
          .padding({ left: 16, right: 16, top: 16, bottom: 16 })
          .alignItems(VerticalAlign.Center)
          .onClick(() => {
            this.preferOriginalAudio = !this.preferOriginalAudio;
            this.persistBoolean(prefer_original_audio_key, this.preferOriginalAudio);
          })
        }

        // SwitchPreferenceCompat prefer_descriptive_audio_key
        ListItem() {
          Row() {
            Column() {
              Text($r('app.string.prefer_descriptive_audio_title'))
                .width('100%')
                .fontSize(16)
                .lineHeight(20)
                .fontColor(COLOR_ON_SURFACE)
              Text($r('app.string.prefer_descriptive_audio_summary'))
                .width('100%')
                .fontSize(14)
                .lineHeight(17)
                .fontColor(COLOR_SECONDARY_TEXT)
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)

            // widget_frame: a 47x27vp switch against the row's 16vp right gutter (base.ui.json's
            // [892,962][1032,1043] at density 3.0). The whole row is the one tappable control, so
            // the switch takes no touch.
            Toggle({ type: ToggleType.Switch, isOn: this.preferDescriptiveAudio })
              .hitTestBehavior(HitTestMode.None)
              .width(47)
              .height(27)
              .margin({ left: 16 })
              .selectedColor(COLOR_PRIMARY)
          }
          .id('prefer_descriptive_audio')
          .width('100%')
          .padding({ left: 16, right: 16, top: 16, bottom: 16 })
          .alignItems(VerticalAlign.Center)
          .onClick(() => {
            this.preferDescriptiveAudio = !this.preferDescriptiveAudio;
            this.persistBoolean(prefer_descriptive_audio_key, this.preferDescriptiveAudio);
          })
        }

        // Nested PreferenceScreen android:fragment=ExoPlayerSettingsFragment
        ListItem() {
          Row() {
            Column() {
              Text($r('app.string.settings_category_exoplayer_title'))
                .width('100%')
                .fontSize(16)
                .lineHeight(20)
                .fontColor(COLOR_ON_SURFACE)
              Text($r('app.string.settings_category_exoplayer_summary'))
                .width('100%')
                .fontSize(14)
                .lineHeight(17)
                .fontColor(COLOR_SECONDARY_TEXT)
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)
          }
          .id('exoplayer_settings_key')
          .width('100%')
          .padding({ left: 16, right: 16, top: 16, bottom: 16 })
          .alignItems(VerticalAlign.Center)
          .onClick(() => {
            router.pushUrl({ url: 'pages/ExoPlayerSettingsFragmentPage' });
          })
        }

        /* ── PreferenceCategory: settings_category_player_title ─────────── */
        ListItem() {
          // res/layout/settings_category_header_layout.xml - a header, never a tappable row: a
          // 14vp ?attr/contrast_background_color band, the 1vp ?attr/separator_color rule, then a
          // 14sp bold ?android:textColorPrimary title at the list's 16vp gutter. Below base.png's
          // fold, so it is styled from that source layout, not from pixels.
          Column() {
            Column() {
              // The 5dp ?attr/toolbar_shadow View this FrameLayout carries at its top:
              // toolbar_shadow_light.xml is a -90 deg shape gradient from
              // @color/light_shadow_start_color (#5A000000) down to fully transparent.
              Column()
                .width('100%')
                .height(5)
                .linearGradient({
                  angle: 180,
                  colors: [[$r('app.color.shadow_start'), 0.0], ['#00000000', 1.0]]
                })
            }
            .width('100%')
            .height(14)
            .backgroundColor($r('app.color.contrast_background'))

            Divider()
              .strokeWidth(1)
              .color($r('app.color.separator'))

            Text($r('app.string.settings_category_player_title'))
              .width('100%')
              .fontSize(14)
              .fontWeight(FontWeight.Bold)
              .fontColor(COLOR_ON_SURFACE)
              .padding({ left: 16, right: 16, top: 16 })
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)
        }

        // SwitchPreferenceCompat use_external_video_player_key
        ListItem() {
          Row() {
            Column() {
              Text($r('app.string.use_external_video_player_title'))
                .width('100%')
                .fontSize(16)
                .lineHeight(20)
                .fontColor(COLOR_ON_SURFACE)
              Text($r('app.string.use_external_video_player_summary'))
                .width('100%')
                .fontSize(14)
                .lineHeight(17)
                .fontColor(COLOR_SECONDARY_TEXT)
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)

            // widget_frame: a 47x27vp switch against the row's 16vp right gutter (base.ui.json's
            // [892,962][1032,1043] at density 3.0). The whole row is the one tappable control, so
            // the switch takes no touch.
            Toggle({ type: ToggleType.Switch, isOn: this.useExternalVideoPlayer })
              .hitTestBehavior(HitTestMode.None)
              .width(47)
              .height(27)
              .margin({ left: 16 })
              .selectedColor(COLOR_PRIMARY)
          }
          .id('use_external_video_player')
          .width('100%')
          .padding({ left: 16, right: 16, top: 16, bottom: 16 })
          .alignItems(VerticalAlign.Center)
          .onClick(() => {
            this.useExternalVideoPlayer = !this.useExternalVideoPlayer;
            this.persistBoolean(use_external_video_player_key, this.useExternalVideoPlayer);
          })
        }

        // SwitchPreferenceCompat use_external_audio_player_key - the XML gives it NO summary.
        ListItem() {
          Row() {
            Column() {
              Text($r('app.string.use_external_audio_player_title'))
                .width('100%')
                .fontSize(16)
                .lineHeight(20)
                .fontColor(COLOR_ON_SURFACE)
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)

            // widget_frame: a 47x27vp switch against the row's 16vp right gutter (base.ui.json's
            // [892,962][1032,1043] at density 3.0). The whole row is the one tappable control, so
            // the switch takes no touch.
            Toggle({ type: ToggleType.Switch, isOn: this.useExternalAudioPlayer })
              .hitTestBehavior(HitTestMode.None)
              .width(47)
              .height(27)
              .margin({ left: 16 })
              .selectedColor(COLOR_PRIMARY)
          }
          .id('use_external_audio_player')
          .width('100%')
          .padding({ left: 16, right: 16, top: 16, bottom: 16 })
          .alignItems(VerticalAlign.Center)
          .onClick(() => {
            this.useExternalAudioPlayer = !this.useExternalAudioPlayer;
            this.persistBoolean(use_external_audio_player_key, this.useExternalAudioPlayer);
          })
        }

        // SwitchPreferenceCompat show_play_with_kodi_key
        ListItem() {
          Row() {
            Column() {
              Text($r('app.string.show_play_with_kodi_title'))
                .width('100%')
                .fontSize(16)
                .lineHeight(20)
                .fontColor(COLOR_ON_SURFACE)
              Text($r('app.string.show_play_with_kodi_summary'))
                .width('100%')
                .fontSize(14)
                .lineHeight(17)
                .fontColor(COLOR_SECONDARY_TEXT)
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)

            // widget_frame: a 47x27vp switch against the row's 16vp right gutter (base.ui.json's
            // [892,962][1032,1043] at density 3.0). The whole row is the one tappable control, so
            // the switch takes no touch.
            Toggle({ type: ToggleType.Switch, isOn: this.showPlayWithKodi })
              .hitTestBehavior(HitTestMode.None)
              .width(47)
              .height(27)
              .margin({ left: 16 })
              .selectedColor(COLOR_PRIMARY)
          }
          .id('show_play_with_kodi')
          .width('100%')
          .padding({ left: 16, right: 16, top: 16, bottom: 16 })
          .alignItems(VerticalAlign.Center)
          .onClick(() => {
            this.showPlayWithKodi = !this.showPlayWithKodi;
            this.persistBoolean(show_play_with_kodi_key, this.showPlayWithKodi);
          })
        }

        // ListPreference seekbar_preview_thumbnail_key
        ListItem() {
          Row() {
            Column() {
              Text($r('app.string.seekbar_preview_thumbnail_title'))
                .width('100%')
                .fontSize(16)
                .lineHeight(20)
                .fontColor(COLOR_ON_SURFACE)
              Text(this.simpleSummaries.seekbarPreviewThumbnail)
                .width('100%')
                .fontSize(14)
                .lineHeight(17)
                .fontColor(COLOR_SECONDARY_TEXT)
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)
          }
          .id('seekbar_preview_thumbnail_key')
          .width('100%')
          .padding({ left: 16, right: 16, top: 16, bottom: 16 })
          .alignItems(VerticalAlign.Center)
          .onClick(() => {
            this.seekbarPreviewDialog.open();
          })
        }

        /* ── PreferenceCategory: settings_category_player_behavior_title ── */
        ListItem() {
          // res/layout/settings_category_header_layout.xml - a header, never a tappable row: a
          // 14vp ?attr/contrast_background_color band, the 1vp ?attr/separator_color rule, then a
          // 14sp bold ?android:textColorPrimary title at the list's 16vp gutter. Below base.png's
          // fold, so it is styled from that source layout, not from pixels.
          Column() {
            Column() {
              // The 5dp ?attr/toolbar_shadow View this FrameLayout carries at its top:
              // toolbar_shadow_light.xml is a -90 deg shape gradient from
              // @color/light_shadow_start_color (#5A000000) down to fully transparent.
              Column()
                .width('100%')
                .height(5)
                .linearGradient({
                  angle: 180,
                  colors: [[$r('app.color.shadow_start'), 0.0], ['#00000000', 1.0]]
                })
            }
            .width('100%')
            .height(14)
            .backgroundColor($r('app.color.contrast_background'))

            Divider()
              .strokeWidth(1)
              .color($r('app.color.separator'))

            Text($r('app.string.settings_category_player_behavior_title'))
              .width('100%')
              .fontSize(14)
              .fontWeight(FontWeight.Bold)
              .fontColor(COLOR_ON_SURFACE)
              .padding({ left: 16, right: 16, top: 16 })
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)
        }

        // ListPreference preferred_open_action_key - android:summary is a "%s" template.
        ListItem() {
          Row() {
            Column() {
              Text($r('app.string.preferred_open_action_settings_title'))
                .width('100%')
                .fontSize(16)
                .lineHeight(20)
                .fontColor(COLOR_ON_SURFACE)
              Text(this.simpleSummaries.preferredOpenAction)
                .width('100%')
                .fontSize(14)
                .lineHeight(17)
                .fontColor(COLOR_SECONDARY_TEXT)
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)
          }
          .id('preferred_open_action_key')
          .width('100%')
          .padding({ left: 16, right: 16, top: 16, bottom: 16 })
          .alignItems(VerticalAlign.Center)
          .onClick(() => {
            this.preferredOpenActionDialog.open();
          })
        }

        // ListPreference minimize_on_exit_key - android:summary is a "%s" template.
        ListItem() {
          Row() {
            Column() {
              Text($r('app.string.minimize_on_exit_title'))
                .width('100%')
                .fontSize(16)
                .lineHeight(20)
                .fontColor(COLOR_ON_SURFACE)
              Text(this.simpleSummaries.minimizeOnExit)
                .width('100%')
                .fontSize(14)
                .lineHeight(17)
                .fontColor(COLOR_SECONDARY_TEXT)
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)
          }
          .id('minimize_on_exit_key')
          .width('100%')
          .padding({ left: 16, right: 16, top: 16, bottom: 16 })
          .alignItems(VerticalAlign.Center)
          .onClick(() => {
            this.minimizeOnExitDialog.open();
          })
        }

        // SwitchPreferenceCompat start_main_player_fullscreen_key
        ListItem() {
          Row() {
            Column() {
              Text($r('app.string.start_main_player_fullscreen_title'))
                .width('100%')
                .fontSize(16)
                .lineHeight(20)
                .fontColor(COLOR_ON_SURFACE)
              Text($r('app.string.start_main_player_fullscreen_summary'))
                .width('100%')
                .fontSize(14)
                .lineHeight(17)
                .fontColor(COLOR_SECONDARY_TEXT)
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)

            // widget_frame: a 47x27vp switch against the row's 16vp right gutter (base.ui.json's
            // [892,962][1032,1043] at density 3.0). The whole row is the one tappable control, so
            // the switch takes no touch.
            Toggle({ type: ToggleType.Switch, isOn: this.startMainPlayerFullscreen })
              .hitTestBehavior(HitTestMode.None)
              .width(47)
              .height(27)
              .margin({ left: 16 })
              .selectedColor(COLOR_PRIMARY)
          }
          .id('start_main_player_fullscreen_key')
          .width('100%')
          .padding({ left: 16, right: 16, top: 16, bottom: 16 })
          .alignItems(VerticalAlign.Center)
          .onClick(() => {
            this.startMainPlayerFullscreen = !this.startMainPlayerFullscreen;
            this.persistBoolean(start_main_player_fullscreen_key, this.startMainPlayerFullscreen);
          })
        }

        // ListPreference autoplay_key - android:summary is a "%s" template.
        ListItem() {
          Row() {
            Column() {
              Text($r('app.string.autoplay_title'))
                .width('100%')
                .fontSize(16)
                .lineHeight(20)
                .fontColor(COLOR_ON_SURFACE)
              Text(this.simpleSummaries.autoplay)
                .width('100%')
                .fontSize(14)
                .lineHeight(17)
                .fontColor(COLOR_SECONDARY_TEXT)
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)
          }
          .id('autoplay_key')
          .width('100%')
          .padding({ left: 16, right: 16, top: 16, bottom: 16 })
          .alignItems(VerticalAlign.Center)
          .onClick(() => {
            this.autoplayDialog.open();
          })
        }

        // SwitchPreferenceCompat auto_queue_key
        ListItem() {
          Row() {
            Column() {
              Text($r('app.string.auto_queue_title'))
                .width('100%')
                .fontSize(16)
                .lineHeight(20)
                .fontColor(COLOR_ON_SURFACE)
              Text($r('app.string.auto_queue_summary'))
                .width('100%')
                .fontSize(14)
                .lineHeight(17)
                .fontColor(COLOR_SECONDARY_TEXT)
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)

            // widget_frame: a 47x27vp switch against the row's 16vp right gutter (base.ui.json's
            // [892,962][1032,1043] at density 3.0). The whole row is the one tappable control, so
            // the switch takes no touch.
            Toggle({ type: ToggleType.Switch, isOn: this.autoQueue })
              .hitTestBehavior(HitTestMode.None)
              .width(47)
              .height(27)
              .margin({ left: 16 })
              .selectedColor(COLOR_PRIMARY)
          }
          .id('auto_queue_key')
          .width('100%')
          .padding({ left: 16, right: 16, top: 16, bottom: 16 })
          .alignItems(VerticalAlign.Center)
          .onClick(() => {
            this.autoQueue = !this.autoQueue;
            this.persistBoolean(auto_queue_key, this.autoQueue);
          })
        }

        // SwitchPreferenceCompat resume_on_audio_focus_gain_key
        ListItem() {
          Row() {
            Column() {
              Text($r('app.string.resume_on_audio_focus_gain_title'))
                .width('100%')
                .fontSize(16)
                .lineHeight(20)
                .fontColor(COLOR_ON_SURFACE)
              Text($r('app.string.resume_on_audio_focus_gain_summary'))
                .width('100%')
                .fontSize(14)
                .lineHeight(17)
                .fontColor(COLOR_SECONDARY_TEXT)
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)

            // widget_frame: a 47x27vp switch against the row's 16vp right gutter (base.ui.json's
            // [892,962][1032,1043] at density 3.0). The whole row is the one tappable control, so
            // the switch takes no touch.
            Toggle({ type: ToggleType.Switch, isOn: this.resumeOnAudioFocusGain })
              .hitTestBehavior(HitTestMode.None)
              .width(47)
              .height(27)
              .margin({ left: 16 })
              .selectedColor(COLOR_PRIMARY)
          }
          .id('resume_on_audio_focus_gain')
          .width('100%')
          .padding({ left: 16, right: 16, top: 16, bottom: 16 })
          .alignItems(VerticalAlign.Center)
          .onClick(() => {
            this.resumeOnAudioFocusGain = !this.resumeOnAudioFocusGain;
            this.persistBoolean(resume_on_audio_focus_gain_key, this.resumeOnAudioFocusGain);
          })
        }

        // ListPreference left_gesture_control_key - static android:summary.
        ListItem() {
          Row() {
            Column() {
              Text($r('app.string.left_gesture_control_title'))
                .width('100%')
                .fontSize(16)
                .lineHeight(20)
                .fontColor(COLOR_ON_SURFACE)
              Text($r('app.string.left_gesture_control_summary'))
                .width('100%')
                .fontSize(14)
                .lineHeight(17)
                .fontColor(COLOR_SECONDARY_TEXT)
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)
          }
          .id('left_gesture_control')
          .width('100%')
          .padding({ left: 16, right: 16, top: 16, bottom: 16 })
          .alignItems(VerticalAlign.Center)
          .onClick(() => {
            this.leftGestureDialog.open();
          })
        }

        // ListPreference right_gesture_control_key - static android:summary.
        ListItem() {
          Row() {
            Column() {
              Text($r('app.string.right_gesture_control_title'))
                .width('100%')
                .fontSize(16)
                .lineHeight(20)
                .fontColor(COLOR_ON_SURFACE)
              Text($r('app.string.right_gesture_control_summary'))
                .width('100%')
                .fontSize(14)
                .lineHeight(17)
                .fontColor(COLOR_SECONDARY_TEXT)
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)
          }
          .id('right_gesture_control')
          .width('100%')
          .padding({ left: 16, right: 16, top: 16, bottom: 16 })
          .alignItems(VerticalAlign.Center)
          .onClick(() => {
            this.rightGestureDialog.open();
          })
        }

        // SwitchPreferenceCompat popup_remember_size_pos_key
        ListItem() {
          Row() {
            Column() {
              Text($r('app.string.popup_remember_size_pos_title'))
                .width('100%')
                .fontSize(16)
                .lineHeight(20)
                .fontColor(COLOR_ON_SURFACE)
              Text($r('app.string.popup_remember_size_pos_summary'))
                .width('100%')
                .fontSize(14)
                .lineHeight(17)
                .fontColor(COLOR_SECONDARY_TEXT)
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)

            // widget_frame: a 47x27vp switch against the row's 16vp right gutter (base.ui.json's
            // [892,962][1032,1043] at density 3.0). The whole row is the one tappable control, so
            // the switch takes no touch.
            Toggle({ type: ToggleType.Switch, isOn: this.popupRememberSizePos })
              .hitTestBehavior(HitTestMode.None)
              .width(47)
              .height(27)
              .margin({ left: 16 })
              .selectedColor(COLOR_PRIMARY)
          }
          .id('popup_remember_size_pos_key')
          .width('100%')
          .padding({ left: 16, right: 16, top: 16, bottom: 16 })
          .alignItems(VerticalAlign.Center)
          .onClick(() => {
            this.popupRememberSizePos = !this.popupRememberSizePos;
            this.persistBoolean(popup_remember_size_pos_key, this.popupRememberSizePos);
          })
        }

        // SwitchPreferenceCompat use_inexact_seek_key
        ListItem() {
          Row() {
            Column() {
              Text($r('app.string.use_inexact_seek_title'))
                .width('100%')
                .fontSize(16)
                .lineHeight(20)
                .fontColor(COLOR_ON_SURFACE)
              Text($r('app.string.use_inexact_seek_summary'))
                .width('100%')
                .fontSize(14)
                .lineHeight(17)
                .fontColor(COLOR_SECONDARY_TEXT)
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)

            // widget_frame: a 47x27vp switch against the row's 16vp right gutter (base.ui.json's
            // [892,962][1032,1043] at density 3.0). The whole row is the one tappable control, so
            // the switch takes no touch.
            Toggle({ type: ToggleType.Switch, isOn: this.useInexactSeekKey })
              .hitTestBehavior(HitTestMode.None)
              .width(47)
              .height(27)
              .margin({ left: 16 })
              .selectedColor(COLOR_PRIMARY)
          }
          .id('use_inexact_seek_key')
          .width('100%')
          .padding({ left: 16, right: 16, top: 16, bottom: 16 })
          .alignItems(VerticalAlign.Center)
          .onClick(() => {
            this.onUseInexactSeekChanged();
          })
        }

        // ListPreference seek_duration_key
        ListItem() {
          Row() {
            Column() {
              Text($r('app.string.seek_duration_title'))
                .width('100%')
                .fontSize(16)
                .lineHeight(20)
                .fontColor(COLOR_ON_SURFACE)
              Text(this.simpleSummaries.seekDuration)
                .width('100%')
                .fontSize(14)
                .lineHeight(17)
                .fontColor(COLOR_SECONDARY_TEXT)
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)
          }
          .id('seek_duration')
          .width('100%')
          .padding({ left: 16, right: 16, top: 16, bottom: 16 })
          .alignItems(VerticalAlign.Center)
          .onClick(() => {
            this.seekDurationDialog.open();
          })
        }

        // SwitchPreferenceCompat clear_queue_confirmation_key
        ListItem() {
          Row() {
            Column() {
              Text($r('app.string.clear_queue_confirmation_title'))
                .width('100%')
                .fontSize(16)
                .lineHeight(20)
                .fontColor(COLOR_ON_SURFACE)
              Text($r('app.string.clear_queue_confirmation_summary'))
                .width('100%')
                .fontSize(14)
                .lineHeight(17)
                .fontColor(COLOR_SECONDARY_TEXT)
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)

            // widget_frame: a 47x27vp switch against the row's 16vp right gutter (base.ui.json's
            // [892,962][1032,1043] at density 3.0). The whole row is the one tappable control, so
            // the switch takes no touch.
            Toggle({ type: ToggleType.Switch, isOn: this.clearQueueConfirmation })
              .hitTestBehavior(HitTestMode.None)
              .width(47)
              .height(27)
              .margin({ left: 16 })
              .selectedColor(COLOR_PRIMARY)
          }
          .id('clear_queue_confirmation_key')
          .width('100%')
          .padding({ left: 16, right: 16, top: 16, bottom: 16 })
          .alignItems(VerticalAlign.Center)
          .onClick(() => {
            this.clearQueueConfirmation = !this.clearQueueConfirmation;
            this.persistBoolean(clear_queue_confirmation_key, this.clearQueueConfirmation);
          })
        }

        // SwitchPreferenceCompat ignore_hardware_media_buttons_key
        ListItem() {
          Row() {
            Column() {
              Text($r('app.string.ignore_hardware_media_buttons_title'))
                .width('100%')
                .fontSize(16)
                .lineHeight(20)
                .fontColor(COLOR_ON_SURFACE)
              Text($r('app.string.ignore_hardware_media_buttons_summary'))
                .width('100%')
                .fontSize(14)
                .lineHeight(17)
                .fontColor(COLOR_SECONDARY_TEXT)
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)

            // widget_frame: a 47x27vp switch against the row's 16vp right gutter (base.ui.json's
            // [892,962][1032,1043] at density 3.0). The whole row is the one tappable control, so
            // the switch takes no touch.
            Toggle({ type: ToggleType.Switch, isOn: this.ignoreHardwareMediaButtons })
              .hitTestBehavior(HitTestMode.None)
              .width(47)
              .height(27)
              .margin({ left: 16 })
              .selectedColor(COLOR_PRIMARY)
          }
          .id('ignore_hardware_media_buttons_key')
          .width('100%')
          .padding({ left: 16, right: 16, top: 16, bottom: 16 })
          .alignItems(VerticalAlign.Center)
          .onClick(() => {
            this.ignoreHardwareMediaButtons = !this.ignoreHardwareMediaButtons;
            this.persistBoolean(ignore_hardware_media_buttons_key, this.ignoreHardwareMediaButtons);
          })
        }
      }
      .width('100%')
      .layoutWeight(1)
      // setDivider(null): the list carries no separators and no surface of its own.
      .divider(null)
      .backgroundColor(themedBackground(this.blackTheme))

      // S6: the only visual a failed preference write has. editor.apply() is silent on Android,
      // so this never shows on the happy path and the screen stays pixel-identical to base.png;
      // it exists so a putSync/flush() failure is not swallowed. Same treatment, same metrics as
      // the verified sibling settings pages.
      if (!this.isLoading && this.errorInfo.length > 0) {
        Text(this.errorInfo)
          .width('100%')
          .fontSize(14)
          .lineHeight(18)
          .fontColor(COLOR_SECONDARY_TEXT)
          .padding({ left: 16, right: 16, top: 16, bottom: 16 })
      }
    }
    .id('VideoAudioSettingsFragmentPage')
    .width('100%')
    .height('100%')
    .backgroundColor(themedBackground(this.blackTheme))
  }
}
