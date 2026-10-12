/**
 * S3 - NotificationSettingsFragment (screen_notification_settings): the real preference tree,
 * unstyled.
 *
 * 🟥 DISTINCT from NotificationsSettingsFragment (note the missing "s") and NOT the same screen,
 * even though both render res/xml/notifications_settings.xml. This one is a bare stub whose whole
 * body is addPreferencesFromResourceRegistry(): no SharedPreferences change listener, no
 * subscription loading, no device-notification snackbar, no notified/total channels summary. It is
 * NOT reachable from main_settings.xml - that row points at NotificationsSettingsFragment. Its only
 * live role is the preference-search index: SettingsResourceRegistry registers THIS class for
 * R.xml.notifications_settings, so a search-result push resolves here.
 *
 * Structure comes from res/xml/notifications_settings.xml, in XML order:
 *   1 PreferenceScreen player_notification_screen_key  -> pushes PlayerNotificationSettingsFragment
 *   2 SwitchPreference enable_streams_notifications    (defaultValue false)
 *   3 DurationListPreference streams_notifications_interval_key
 *   4 ListPreference streams_notifications_network_key
 *   5 Preference streams_notifications_channels_key    -> pushes NotificationModeConfigFragment
 * Rows 3-5 carry android:dependency="@string/enable_streams_notifications", so the switch's value
 * is the SOURCE's own enabled guard for them - not an invented one. Rows 3 and 4 declare
 * app:useSimpleSummaryProvider="true", so each summary is the CURRENTLY SELECTED entry's label and
 * is bound, never a literal.
 *
 * BasePreferenceFragment.onViewCreated calls setDivider(null) and pushes the PreferenceScreen title
 * (@string/notifications) into the host toolbar, so the list carries no separators and the page
 * renders that title beside the Up affordance (android.R.id.home is the slug).
 *
 * DurationListPreference.onAttached replaces the XML entry titles with
 * Localization.localizeDuration(seconds) for every positive entry value, which is why the interval
 * dialog's labels are computed from the entryValues array rather than taken from the description
 * array.
 *
 * S4 wiring:
 *  - every row reads and writes its preference through svc_preferences (AppPreferences, whose
 *    static putBoolean/putString flush, so a write survives a relaunch);
 *  - `preferenceList` is the XML row order and is what `rowEnabled()` reads to apply
 *    android:dependency to rows 3-5 - the SOURCE's own guard, not an invented one;
 *  - svc_notification is read ONCE on load: NotificationHelper.areNotificationsEnabledOnDevice().
 *    DEVIATION, reported to the orchestrator: the source stub has no updateEnabledState, so the
 *    OS state is NOT used to disable any row (that would make the contract's own
 *    enable_streams_notifications tap inert on a device with notifications switched off). It only
 *    swaps the master row's SUMMARY for @string/notifications_disabled, which is true and adds,
 *    removes and disables no control.
 * This class deliberately adds NO preference-change listener - unlike NotificationsSettingsFragment
 * it never reschedules NotificationWorker. No visual styling here; that is S5.
 */
import { router } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { Localization } from '../common/i18n/Localization';
import { ServiceLocator } from '../common/di/ServiceLocator';
import { Notifications } from '../common/notify/Notifications';
import { AppPreferences } from '../common/prefs/Preferences';
import { ChoiceIndicator } from '../components/ChoiceIndicator';
import {
  enable_streams_notifications,
  streams_notifications_channels_key,
  streams_notifications_interval_default,
  streams_notifications_interval_key,
  streams_notifications_network_any,
  streams_notifications_network_key,
  streams_notifications_network_wifi
} from '../common/prefs/SettingsKeys';
import { DIALOG_MASK_COLOR } from '../common/theme/ServiceTheme';
import { BLACK_THEME_KEY, themedBackground } from '../common/theme/ThemeBackground';

const TAG: string = 'NotificationSettingsFragmentPage';

/** The PreferenceScreen row of the XML; it is a nested screen, so it has no preference key. */
const PLAYER_NOTIFICATION_SCREEN_KEY: string = 'player_notification_screen_key';

/**
 * The first row of `preferenceList` that carries
 * android:dependency="@string/enable_streams_notifications" (rows 3-5 of the XML).
 */
const FIRST_DEPENDENT_ROW: number = 2;

/** @array/streams_notifications_interval_values - the entryValues, in seconds. */
const INTERVAL_VALUES: string[] = ['900', '1800', '3600', '7200', '14400', '43200', '86400'];

/* S5 - style only, LightTheme (the theme every captured state of this screen renders in). Reuses
 * the run's style baseline (state.json generation.styleBaseline, source S0004): primary /
 * onPrimary / background / onSurface / secondaryText, the 56vp toolbar with its 72vp title inset
 * and the 20fp Medium bar title. The preference-row metrics (16vp gutter, 16vp vertical padding,
 * the 47x27vp switch) and the disabled-row grey are measured from THIS screen's own capture -
 * base.ui.json and pref_streams_notifications_interval_key.png. */
/** ?attr/colorPrimary - the toolbar; sampled (229,57,53) off base.png. */
const COLOR_PRIMARY: Resource = $r('app.color.primary');
/** ?attr/actionColor - the Up glyph and the bar title. */
const COLOR_ON_PRIMARY: Resource = $r('app.color.on_primary');
/** ?attr/windowBackground - light_background_color, the capture's #EEEEEE. */
const COLOR_SURFACE: Resource = $r('app.color.background');
/** ?android:textColorPrimary - #DE000000 over #EEEEEE is the capture's (31,31,31) title. */
const COLOR_ON_SURFACE: Resource = $r('app.color.on_surface');
/** ?android:textColorSecondary - #8A000000 over #EEEEEE is the capture's (109,109,109) summary. */
const COLOR_SECONDARY_TEXT: Resource = $r('app.color.on_surface_variant');
/**
 * A disabled preference row. The interval capture renders the three dependent rows greyed and
 * BOTH their title and summary sample (176,176,176) - one grey, not the row-wide disabledAlpha
 * the sibling settings pages assume, which no capture of theirs could measure. 238*(1-a)=176
 * gives a = 0.26 black.
 */
const COLOR_DISABLED_TEXT: Resource = $r('app.color.on_surface_disabled');
/** The AlertDialog surface: white, per the one dialog this app's captures record. */
const COLOR_DIALOG_SURFACE: Resource = $r('app.color.dialog_surface');
/**
 * The AlertDialog's own button colour. LightSettingsTheme overrides colorAccent to
 * light_settings_accent_color (#E53935), but the alert dialog does NOT inherit it: the one dialog
 * this app's captures record (fragment_ExoPlayerSettingsFragment) samples CANCEL at pure (0,0,0),
 * i.e. light_youtube_accent_color.
 */
const COLOR_ACCENT: Resource = $r('app.color.accent');
/** The unchecked single-choice indicator, sampled (117,117,117) in that same dialog capture. */

/** One ListPreference entry: an entryValues item and the entries label shown for it. */
interface PrefOption {
  label: ResourceStr;
  value: string;
}

/**
 * ListPreference's dialog: single choice over the preference's entries, plus CANCEL. One struct
 * serves both list rows - the host passes that preference's own title/options/selection, the way
 * the source builds one AlertDialog per preference from that preference's own arrays.
 *
 * The option list sits in a HEIGHT-BOUNDED Scroll: an unbounded one pushes CANCEL out of the frame
 * once the entry list is long.
 */
@CustomDialog
struct PreferenceChoiceDialog {
  controller?: CustomDialogController;
  title: ResourceStr = '';
  options: PrefOption[] = [];
  selected: string = '';
  /** The option rows are instantiated per entry, so they deliberately SHARE one id (rule 12). */
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
      .constraintSize({ maxHeight: 320 })

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
    // The AlertDialog card: 294vp wide, white, a 4vp radius - not the platform's rounded sheet.
    .width(294)
    .backgroundColor(COLOR_DIALOG_SURFACE)
    .borderRadius(4)
    .alignItems(HorizontalAlign.Start)
  }
}

@Entry
@Component
export struct NotificationSettingsFragmentPage {
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
  /**
   * res/xml/notifications_settings.xml, in XML order - the rows this screen renders. Reading it
   * is how `rowEnabled()` knows which rows carry android:dependency.
   */
  @State preferenceList: string[] = [
    PLAYER_NOTIFICATION_SCREEN_KEY,
    enable_streams_notifications,
    streams_notifications_interval_key,
    streams_notifications_network_key,
    streams_notifications_channels_key
  ];
  /** SwitchPreference enable_streams_notifications, android:defaultValue="false". */
  @State enableStreamsNotifications: boolean = false;
  /** The persisted entryValues item of each list row; the summary is its label. */
  @State intervalValue: string = '';
  @State networkValue: string = '';
  /**
   * NotificationHelper.areNotificationsEnabledOnDevice(), read once on load. See the header:
   * it gates nothing, it only makes the master row's summary tell the truth.
   */
  @State notificationsEnabledOnDevice: boolean = true;
  /** This fragment sets no notified/total count of its own - that is NotificationsSettings'. */
  @State channelsSummary: string = '';
  /** The two dialogs' entries - DurationListPreference computes its own labels. */
  @State intervalOptions: PrefOption[] = [];
  @State networkOptions: PrefOption[] = [];
  @State isLoading: boolean = false;
  @State errorInfo: string = '';

  private intervalDialog: CustomDialogController = new CustomDialogController({
    maskColor: DIALOG_MASK_COLOR,
    customStyle: true,
    builder: PreferenceChoiceDialog({
      title: $r('app.string.streams_notifications_interval_title'),
      options: this.intervalOptions,
      selected: this.intervalValue,
      itemId: 'streams_notifications_interval_itemroot',
      onSelect: (value: string): void => {
        this.intervalValue = value;
        this.persistString(streams_notifications_interval_key, value);
      }
    })
  });

  private networkDialog: CustomDialogController = new CustomDialogController({
    maskColor: DIALOG_MASK_COLOR,
    customStyle: true,
    builder: PreferenceChoiceDialog({
      title: $r('app.string.streams_notifications_network_title'),
      options: this.networkOptions,
      selected: this.networkValue,
      itemId: 'streams_notifications_network_itemroot',
      onSelect: (value: string): void => {
        this.networkValue = value;
        this.persistString(streams_notifications_network_key, value);
      }
    })
  });

  aboutToAppear(): void {
    this.intervalOptions = this.buildIntervalOptions();
    const anyNetwork: PrefOption = {
      label: $r('app.string.any_network'),
      value: streams_notifications_network_any
    };
    const wifiOnly: PrefOption = {
      label: $r('app.string.wifi_only'),
      value: streams_notifications_network_wifi
    };
    this.networkOptions = [anyNetwork, wifiOnly];
    this.loadState();
  }

  /**
   * The plan's `isLoading`: the async load from svc_preferences (every row's persisted value) and
   * svc_notification (the device's notification state).
   */
  private loadState(): void {
    this.isLoading = true;
    const prefs: AppPreferences = AppPreferences.instance();
    // android:defaultValue="false" / streams_notifications_interval_default (14400 s) /
    // streams_notifications_network_default (= streams_notifications_network_wifi).
    this.enableStreamsNotifications = prefs.getBooleanSync(enable_streams_notifications, false);
    this.intervalValue =
      prefs.getStringSync(streams_notifications_interval_key,
        streams_notifications_interval_default);
    this.networkValue =
      prefs.getStringSync(streams_notifications_network_key, streams_notifications_network_wifi);

    const notify: Notifications = ServiceLocator.get().notifications;
    notify.areNotificationsEnabledOnDevice()
      .then((enabled: boolean): void => {
        this.notificationsEnabledOnDevice = enabled;
        this.errorInfo = '';
        this.isLoading = false;
      })
      .catch((err: Error): void => {
        this.errorInfo = err.message;
        hilog.error(0x0000, TAG, 'areNotificationsEnabledOnDevice: %{public}s', err.message);
        this.isLoading = false;
      });
  }

  /** editor.putBoolean(key, value).apply() - the static helper flushes, so it survives relaunch. */
  private persistBoolean(key: string, value: boolean): void {
    AppPreferences.putBoolean(key, value).catch((err: Error): void => {
      this.errorInfo = err.message;
      hilog.error(0x0000, TAG, 'putBoolean(%{public}s): %{public}s', key, err.message);
    });
  }

  /** editor.putString(key, value).apply(), flushed. */
  private persistString(key: string, value: string): void {
    AppPreferences.putString(key, value).catch((err: Error): void => {
      this.errorInfo = err.message;
      hilog.error(0x0000, TAG, 'putString(%{public}s): %{public}s', key, err.message);
    });
  }

  /**
   * DurationListPreference.onAttached: every entryValues item is read as seconds and its title
   * replaced with Localization.localizeDuration(seconds) (a non-positive value would keep the
   * XML title, but this array has none).
   */
  private buildIntervalOptions(): PrefOption[] {
    const options: PrefOption[] = [];
    for (const value of INTERVAL_VALUES) {
      const option: PrefOption = {
        label: Localization.localizeDuration(parseInt(value, 10)),
        value: value
      };
      options.push(option);
    }
    return options;
  }

  /** app:useSimpleSummaryProvider - the summary is the selected entry's label. */
  private labelOf(options: PrefOption[], value: string): ResourceStr {
    for (const option of options) {
      if (option.value === value) {
        return option.label;
      }
    }
    return '';
  }

  build() {
    Column() {
      if (!this.hostDrawsToolbar) {
        // toolbar_layout.xml: the host activity's Up affordance plus the PreferenceScreen title that
        // BasePreferenceFragment.onViewCreated pushes into it. android.R.id.home is the slug.
        Row() {
          // The 24vp glyph centred in a 56vp (?attr/actionBarSize) target - base.ui.json puts the
          // Up button at [0,72][168,240], i.e. 56x56vp at density 3.0. The SVG ships with a black
          // fill, so the toolbar's ?attr/actionColor tint is applied here.
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

          // Widget.AppCompat.Toolbar.Title: 20sp medium, 16vp past the navigation button (the
          // capture puts the title at x=216 of 1080 - 72vp at density 3.0).
          Text($r('app.string.notifications'))
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

      // The preference RecyclerView (id/recycler_view in the capture); setDivider(null).
      List() {
        // -- PreferenceScreen: player_notification_screen_key --------------------------------
        // android:fragment=PlayerNotificationSettingsFragment - a nested screen, i.e. a push.
        ListItem() {
          Row() {
            Column() {
              Text($r('app.string.settings_category_player_notification_title'))
                .width('100%')
                .fontSize(16)
                .lineHeight(20)
                .fontColor(COLOR_ON_SURFACE)
              Text($r('app.string.settings_category_player_notification_summary'))
                .width('100%')
                .fontSize(14)
                .lineHeight(17)
                .fontColor(COLOR_SECONDARY_TEXT)
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)
          }
          .id('player_notification_screen')
          .width('100%')
          .padding({ left: 16, right: 16, top: 16, bottom: 16 })
          .alignItems(VerticalAlign.Center)
          .onClick(() => {
            router.pushUrl({ url: 'pages/PlayerNotificationSettingsFragmentPage' });
          })
        }

        // -- SwitchPreference: enable_streams_notifications ----------------------------------
        ListItem() {
          Row() {
            Column() {
              Text($r('app.string.enable_streams_notifications_title'))
                .width('100%')
                .fontSize(16)
                .lineHeight(20)
                .fontColor(COLOR_ON_SURFACE)
              // The setting cannot take effect while the OS has this app's notifications off;
              // the source family's own message for that state is @string/notifications_disabled.
              Text(this.notificationsEnabledOnDevice
                ? $r('app.string.enable_streams_notifications_summary')
                : $r('app.string.notifications_disabled'))
                .width('100%')
                .fontSize(14)
                .lineHeight(17)
                .fontColor(COLOR_SECONDARY_TEXT)
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)

            // widget_frame: a 47x27vp switch against the row's 16vp right gutter (the capture's
            // [892,551][1032,632] at density 3.0). The whole row is the one tappable control, so
            // the switch takes no touch.
            Toggle({ type: ToggleType.Switch, isOn: this.enableStreamsNotifications })
              .hitTestBehavior(HitTestMode.None)
              .width(47)
              .height(27)
              .margin({ left: 16 })
              .selectedColor(COLOR_PRIMARY)
          }
          .id('enable_streams_notifications')
          .width('100%')
          .padding({ left: 16, right: 16, top: 16, bottom: 16 })
          .alignItems(VerticalAlign.Center)
          .onClick(() => {
            this.enableStreamsNotifications = !this.enableStreamsNotifications;
            this.persistBoolean(enable_streams_notifications, this.enableStreamsNotifications);
          })
        }

        // -- DurationListPreference: streams_notifications_interval_key ----------------------
        // android:dependency="@string/enable_streams_notifications" - the SOURCE's own guard.
        ListItem() {
          Row() {
            Column() {
              Text($r('app.string.streams_notifications_interval_title'))
                .width('100%')
                .fontSize(16)
                .lineHeight(20)
                .fontColor(this.rowEnabled(streams_notifications_interval_key)
                  ? COLOR_ON_SURFACE : COLOR_DISABLED_TEXT)
              Text(this.labelOf(this.intervalOptions, this.intervalValue))
                .width('100%')
                .fontSize(14)
                .lineHeight(17)
                .fontColor(this.rowEnabled(streams_notifications_interval_key)
                  ? COLOR_SECONDARY_TEXT : COLOR_DISABLED_TEXT)
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)
          }
          .id('streams_notifications_interval')
          .width('100%')
          .padding({ left: 16, right: 16, top: 16, bottom: 16 })
          .alignItems(VerticalAlign.Center)
          .enabled(this.rowEnabled(streams_notifications_interval_key))
          .onClick(() => {
            this.intervalDialog.open();
          })
        }

        // -- ListPreference: streams_notifications_network_key -------------------------------
        ListItem() {
          Row() {
            Column() {
              Text($r('app.string.streams_notifications_network_title'))
                .width('100%')
                .fontSize(16)
                .lineHeight(20)
                .fontColor(this.rowEnabled(streams_notifications_network_key)
                  ? COLOR_ON_SURFACE : COLOR_DISABLED_TEXT)
              Text(this.labelOf(this.networkOptions, this.networkValue))
                .width('100%')
                .fontSize(14)
                .lineHeight(17)
                .fontColor(this.rowEnabled(streams_notifications_network_key)
                  ? COLOR_SECONDARY_TEXT : COLOR_DISABLED_TEXT)
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)
          }
          .id('streams_notifications_network')
          .width('100%')
          .padding({ left: 16, right: 16, top: 16, bottom: 16 })
          .alignItems(VerticalAlign.Center)
          .enabled(this.rowEnabled(streams_notifications_network_key))
          .onClick(() => {
            this.networkDialog.open();
          })
        }

        // -- Preference: streams_notifications_channels_key ----------------------------------
        // android:fragment=NotificationModeConfigFragment. This fragment sets NO notified/total
        // summary - that belongs to NotificationsSettingsFragment - so the line stays bound.
        ListItem() {
          Row() {
            Column() {
              Text($r('app.string.channels'))
                .width('100%')
                .fontSize(16)
                .lineHeight(20)
                .fontColor(this.rowEnabled(streams_notifications_channels_key)
                  ? COLOR_ON_SURFACE : COLOR_DISABLED_TEXT)
              // preference_material gives the summary View.GONE when the Preference has none, and
              // this fragment sets none - base.ui.json's Channels row carries a title and nothing
              // else, and is 161px (one line) tall where every other row is 218px.
              Text(this.channelsSummary)
                .width('100%')
                .fontSize(14)
                .lineHeight(17)
                .fontColor(this.rowEnabled(streams_notifications_channels_key)
                  ? COLOR_SECONDARY_TEXT : COLOR_DISABLED_TEXT)
                .visibility(this.channelsSummary.length > 0 ? Visibility.Visible : Visibility.None)
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)
          }
          .id('streams_notifications_channels')
          .width('100%')
          .padding({ left: 16, right: 16, top: 16, bottom: 16 })
          .alignItems(VerticalAlign.Center)
          .enabled(this.rowEnabled(streams_notifications_channels_key))
          .onClick(() => {
            router.pushUrl({ url: 'pages/NotificationModeConfigFragmentPage' });
          })
        }
      }
      .width('100%')
      .layoutWeight(1)
      // setDivider(null): the list carries no separators and no surface of its own.
      .divider(null)
      .backgroundColor(themedBackground(this.blackTheme))
    }
    .id('NotificationSettingsFragmentPage')
    .width('100%')
    .height('100%')
    .backgroundColor(themedBackground(this.blackTheme))
  }

  /**
   * android:dependency="@string/enable_streams_notifications": the rows from FIRST_DEPENDENT_ROW
   * on follow the master switch, the two above it never do. The row order is `preferenceList`,
   * i.e. the XML's own, so this is the source's guard rather than a hand-picked one.
   */
  private rowEnabled(key: string): boolean {
    if (this.preferenceList.indexOf(key) < FIRST_DEPENDENT_ROW) {
      return true;
    }
    return this.enableStreamsNotifications;
  }
}
