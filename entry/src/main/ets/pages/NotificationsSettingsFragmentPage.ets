/**
 * S3 - NotificationsSettingsFragment (screen_notifications_settings): the real preference tree,
 * unstyled.
 *
 * 🟥 The REAL notifications screen - the one main_settings.xml links to. See
 * screen_notification_settings (NotificationSettingsFragment, no "s") for the near-identically
 * named stub that serves the SAME res/xml/notifications_settings.xml from the preference-search
 * index. Two classes, two screens, one XML - so the five rows below are structurally identical to
 * that page's, and everything this class adds is behaviour the stub does not have.
 *
 * Structure from res/xml/notifications_settings.xml, in XML order (rows 3-5 carry
 * android:dependency="@string/enable_streams_notifications", rows 3-4 useSimpleSummaryProvider):
 *   1 PreferenceScreen player_notification_screen_key  -> pushes PlayerNotificationSettingsFragment
 *   2 SwitchPreference enable_streams_notifications    (defaultValue false)
 *   3 DurationListPreference streams_notifications_interval_key
 *   4 ListPreference streams_notifications_network_key
 *   5 Preference streams_notifications_channels_key    -> pushes NotificationModeConfigFragment
 *
 * What this class adds over the stub, and who owns it:
 *  - onSharedPreferenceChanged (registered in onStart, unregistered in onStop) reschedules or
 *    cancels NotificationWorker for the interval/network/enable keys. It is a listener on the
 *    PREFERENCE STORE, not on the rows, so any writer of those keys triggers it - S4 wires it on
 *    svc_preferences, not in the row handlers here.
 *  - updateEnabledState(areNotificationsEnabledOnDevice), re-run on every onResume:
 *    conditionalVariant #1. On API 33+ only the master switch follows the OS setting (player
 *    notifications are exempt there); below 33 the WHOLE preferenceScreen is disabled. HarmonyOS
 *    NEXT is API 12+ with the same exemption, so the 33+ arm is the one that can render, and it is
 *    spelled as the row guard below rather than as a dead pre-33 branch.
 *  - conditionalVariant #2: while notifications are off on the device, an indefinite snackbar
 *    (notifications_disabled) with a Settings action opens the OS notification settings. It exists
 *    ONLY in that state, so it is an ArkUI `if`, not a row that is always drawn.
 *  - the channels summary is a LIVE DB count - `notified/total` over the subscription table
 *    (SubscriptionManager.subscriptions(), counted by notificationMode != DISABLED) - and stays
 *    bound; never a captured literal.
 *
 * BasePreferenceFragment.onViewCreated calls setDivider(null) and pushes the PreferenceScreen title
 * (@string/notifications) into the host toolbar (android.R.id.home is the Up slug).
 *
 * S4 wiring:
 *  - every row reads and writes its preference through svc_preferences (AppPreferences, whose
 *    static putBoolean/putString flush, so a write survives a relaunch);
 *  - onSharedPreferenceChanged is reproduced as `rescheduleNotificationWorker()`, called after
 *    each of the three writes it listens for. androidx.work's periodic worker is a WorkScheduler
 *    deferred task (common/notify/NotificationWorker.ts + workers/NotificationWorkerAbility.ets):
 *    the interval and the network requirement (Wi-Fi for UNMETERED, any for CONNECTED) are the
 *    task's own conditions, and the system runs the check with the app closed;
 *  - the channels summary is SubscriptionManager.subscriptions() counted by
 *    notificationMode != DISABLED, re-read on every onPageShow, exactly as onResume does;
 *  - the snackbar's Settings action is notificationManager.openNotificationSettings(context),
 *    the port of NotificationHelper.openNewPipeSystemNotificationSettings().
 * No visual styling here; that is S5.
 */
import { router } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { common } from '@kit.AbilityKit';
import { notificationManager } from '@kit.NotificationKit';
import { Localization } from '../common/i18n/Localization';
import { ServiceLocator } from '../common/di/ServiceLocator';
import { Notifications } from '../common/notify/Notifications';
import { MIN_REPEAT_MS, NotificationWorker, ScheduleOptions } from '../common/notify/NotificationWorker';
import { AppPreferences } from '../common/prefs/Preferences';
import { SubscriptionManager } from '../common/db/SubscriptionManager';
import { SubscriptionEntity } from '../model/db/entity/SubscriptionEntity';
import { NotificationMode } from '../model/enums/NotificationMode';
import { ChoiceIndicator } from '../components/ChoiceIndicator';
import {
  enable_streams_notifications,
  streams_notifications_interval_default,
  streams_notifications_interval_key,
  streams_notifications_network_any,
  streams_notifications_network_key,
  streams_notifications_network_wifi
} from '../common/prefs/SettingsKeys';
import { DIALOG_MASK_COLOR } from '../common/theme/ServiceTheme';
import { settingsListScroller } from '../common/settings/SettingsScroller';
import { BLACK_THEME_KEY, themedBackground } from '../common/theme/ThemeBackground';

const TAG: string = 'NotificationsSettingsFragmentPage';

/** @array/streams_notifications_interval_values - the entryValues, in seconds. */
const INTERVAL_VALUES: string[] = ['900', '1800', '3600', '7200', '14400', '43200', '86400'];

/* S5 - style only, LightSettingsTheme (the theme every captured state of this screen renders in;
 * SettingsActivity.onCreate calls ThemeHelper.getSettingsThemeStyle). Reuses the run's style
 * baseline (state.json generation.styleBaseline, source S0004): primary / onPrimary / background /
 * onSurface / secondaryText, the 56vp toolbar with its 72vp title inset and the 20fp Medium bar
 * title. The preference-row metrics (16vp gutter, 16vp vertical padding, the 47x27vp switch) come
 * from THIS screen's own base.ui.json; the AlertDialog and snackbar have no capture on this screen
 * and are noted where they are taken from instead. */
/** ?attr/colorPrimary - the toolbar; sampled (229,57,53) off the sibling screen's base.png. */
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
 * A disabled preference row. The sibling screen's interval capture renders the dependent rows
 * greyed with BOTH title and summary at (176,176,176); 238*(1-a)=176 gives a = 0.26 black.
 */
const COLOR_DISABLED_TEXT: Resource = $r('app.color.on_surface_disabled');
/** The AlertDialog surface: white, per the one dialog this app's captures record. */
const COLOR_DIALOG_SURFACE: Resource = $r('app.color.dialog_surface');
/**
 * The AlertDialog's own button colour: ?attr/colorAccent under LightSettingsTheme, i.e.
 * light_settings_accent_color (#E53935). The settings screens are hosted by LightSettingsTheme and
 * an AlertDialog raised from one DOES inherit its colorAccent - the sibling settings pages
 * (Video and audio, Content, Download, History) all use this resource. The earlier note here
 * claimed the opposite, reading (0,0,0) off a low-fidelity capture; QA measured this screen's
 * CANCEL at RGB(0,0,0) and filed it.
 */
const COLOR_ACCENT: Resource = $r('app.color.settings_accent');
/** The unchecked single-choice indicator, sampled (117,117,117) in that same dialog capture. */
/**
 * Widget.Design.Snackbar, which NewPipe never restyles (no snackbar item in res/values/styles.xml):
 * design_snackbar_background_color over the list, white 14sp text. No captured state of this screen
 * has the device's notifications off, so the snackbar is styled from that theme, not from pixels.
 */
const COLOR_SNACKBAR_SURFACE: string = '#323232';
/**
 * The snackbar action is ?attr/colorAccent resolved against the HOST activity, which for
 * SettingsActivity is LightSettingsTheme -> light_settings_accent_color.
 */
const COLOR_SNACKBAR_ACTION: Resource = $r('app.color.settings_accent');

/** One ListPreference entry: an entryValues item and the entries label shown for it. */
interface PrefOption {
  label: ResourceStr;
  value: string;
}

/**
 * ListPreference's dialog: single choice over the preference's entries, plus CANCEL. The option
 * list sits in a HEIGHT-BOUNDED Scroll so CANCEL cannot be pushed out of the frame.
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
export struct NotificationsSettingsFragmentPage {
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
  /** SwitchPreference enable_streams_notifications, android:defaultValue="false". */
  @State enableStreamsNotifications: boolean = false;
  /**
   * updateEnabledState(NotificationHelper.areNotificationsEnabledOnDevice(context)), re-read on
   * every onResume. It drives BOTH the master switch's enabled state and whether the snackbar
   * exists at all, which is why the source keeps it as one fact.
   */
  @State screenSwitchEnabledState: boolean = true;
  /** The persisted entryValues item of each list row; the summary is its label. */
  @State intervalValue: string = '';
  @State networkValue: string = '';
  /** `"$notified/${subscriptions.size}"` - the live DB count of updateSubscriptions(). */
  @State channelsRowSummary: string = '';
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
        // onSharedPreferenceChanged(streams_notifications_interval_key):
        // NotificationWorker.schedule(context, ScheduleOptions.from(context), true)
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
        // onSharedPreferenceChanged(streams_notifications_network_key): same forced reschedule.
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
    // onCreatePreferences: the same check onResume makes, done here too to prevent flickering.
    this.loadPreferences();
    this.refreshDeviceState();
  }

  /** onResume(): re-read the device state and (re-)create the subscription loader. */
  onPageShow(): void {
    this.refreshDeviceState();
  }

  /** onPause(): loader?.dispose() - the snackbar is state here, so it goes with the page. */
  onPageHide(): void {
    this.isLoading = false;
  }

  private context(): common.UIAbilityContext {
    return getContext(this) as common.UIAbilityContext;
  }

  /** svc_preferences: every row's persisted value, read synchronously as the source does. */
  private loadPreferences(): void {
    const prefs: AppPreferences = AppPreferences.instance();
    this.enableStreamsNotifications = prefs.getBooleanSync(enable_streams_notifications, false);
    this.intervalValue =
      prefs.getStringSync(streams_notifications_interval_key,
        streams_notifications_interval_default);
    this.networkValue =
      prefs.getStringSync(streams_notifications_network_key, streams_notifications_network_wifi);
  }

  /**
   * onResume()'s two asynchronous halves: updateEnabledState(areNotificationsEnabledOnDevice())
   * and the SubscriptionManager loader whose result is updateSubscriptions().
   */
  private refreshDeviceState(): void {
    this.isLoading = true;
    const notify: Notifications = ServiceLocator.get().notifications;
    notify.areNotificationsEnabledOnDevice()
      .then((enabled: boolean): void => {
        this.screenSwitchEnabledState = enabled;
      })
      .catch((err: Error): void => {
        this.errorInfo = err.message;
        hilog.error(0x0000, TAG, 'areNotificationsEnabledOnDevice: %{public}s', err.message);
      });

    this.updateSubscriptions()
      .then((): void => {
        this.errorInfo = '';
        this.isLoading = false;
      })
      .catch((err: Error): void => {
        // onError(e): ErrorInfo(e, UserAction.SUBSCRIPTION_GET, "Get subscriptions list")
        this.errorInfo = err.message;
        hilog.error(0x0000, TAG, 'Get subscriptions list: %{public}s', err.message);
        this.isLoading = false;
      });
  }

  /**
   * updateSubscriptions(subscriptions): the channels row summary is
   * `"$notified/${subscriptions.size}"`, counted by notificationMode != DISABLED.
   */
  private async updateSubscriptions(): Promise<void> {
    const manager: SubscriptionManager = await SubscriptionManager.of(this.context());
    const subscriptions: SubscriptionEntity[] = await manager.subscriptions();
    let notified: number = 0;
    for (const subscription of subscriptions) {
      if (subscription.notificationMode !== NotificationMode.DISABLED) {
        notified++;
      }
    }
    this.channelsRowSummary = `${notified}/${subscriptions.length}`;
  }

  /** editor.putBoolean(key, value).apply(), flushed, then the listener the source registers. */
  private persistBoolean(key: string, value: boolean): void {
    AppPreferences.putBoolean(key, value)
      .then((): void => {
        this.onSharedPreferenceChanged();
      })
      .catch((err: Error): void => {
        this.errorInfo = err.message;
        hilog.error(0x0000, TAG, 'putBoolean(%{public}s): %{public}s', key, err.message);
      });
  }

  /** editor.putString(key, value).apply(), flushed, then the same listener. */
  private persistString(key: string, value: string): void {
    AppPreferences.putString(key, value)
      .then((): void => {
        this.onSharedPreferenceChanged();
      })
      .catch((err: Error): void => {
        this.errorInfo = err.message;
        hilog.error(0x0000, TAG, 'putString(%{public}s): %{public}s', key, err.message);
      });
  }

  /**
   * onSharedPreferenceChanged: all three keys this screen writes are keys the source's listener
   * acts on, so every write reaches the (substituted) worker.
   */
  private onSharedPreferenceChanged(): void {
    this.rescheduleNotificationWorker().catch((err: Error): void => {
      this.errorInfo = err.message;
      hilog.error(0x0000, TAG, 'reschedule streams notifications: %{public}s', err.message);
    });
  }

  /**
   * onSharedPreferenceChanged's worker half: enable_streams_notifications schedules or cancels
   * (NotificationWorker.schedule / cancel), and a new interval or network replaces the scheduled
   * task (schedule(..., force = true)). Scheduling also needs the device switch, as
   * areNotificationsEnabled(context) does.
   */
  private async rescheduleNotificationWorker(): Promise<void> {
    const notify: Notifications = ServiceLocator.get().notifications;
    const prefs: AppPreferences = AppPreferences.instance();
    const bundleName: string = this.context().applicationInfo.name;
    const enabled: boolean = await notify.areNewStreamsNotificationsEnabled();
    if (enabled) {
      await NotificationWorker.schedule(bundleName, ScheduleOptions.from(prefs), true);
    } else {
      NotificationWorker.cancel(bundleName, prefs);
    }
  }

  /**
   * DurationListPreference.onAttached: every entryValues item is read as seconds and its title
   * replaced with Localization.localizeDuration(seconds).
   *
   * An interval below the work scheduler's minimum is still offered and stored, as in the source,
   * but runs at that minimum - so its label says so, here and in the row summary.
   */
  private buildIntervalOptions(): PrefOption[] {
    const options: PrefOption[] = [];
    for (const value of INTERVAL_VALUES) {
      const seconds: number = parseInt(value, 10);
      const label: string = Localization.localizeDuration(seconds);
      const option: PrefOption = {
        label: seconds * 1000 < MIN_REPEAT_MS
          ? Localization.getStringArgs('streams_notifications_interval_clamped',
            [label, Localization.localizeDuration(MIN_REPEAT_MS / 1000)])
          : label,
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

      // conditionalVariant #2: the snackbar exists ONLY while the device has notifications off.
      // Snackbar.make(listView, notifications_disabled, LENGTH_INDEFINITE).setAction(settings){...}
      // Widget.Design.Snackbar metrics: a 48vp minimum bar, 16vp gutters, the message at 14sp on
      // white and the action 8vp further out in ?attr/colorAccent, uppercased by the widget.
      if (!this.screenSwitchEnabledState) {
        Row() {
          Text($r('app.string.notifications_disabled'))
            .layoutWeight(1)
            .fontSize(14)
            .fontColor(COLOR_ON_PRIMARY)
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Text($r('app.string.settings'))
            .id('notifications_disabled_snackbar_action')
            .fontSize(14)
            .fontWeight(FontWeight.Medium)
            .fontColor(COLOR_SNACKBAR_ACTION)
            .textCase(TextCase.UpperCase)
            .margin({ left: 8 })
            .onClick(() => {
              this.openSystemNotificationSettings();
            })
        }
        .width('100%')
        .constraintSize({ minHeight: 48 })
        .padding({ left: 16, right: 16, top: 14, bottom: 14 })
        .alignItems(VerticalAlign.Center)
        .backgroundColor(COLOR_SNACKBAR_SURFACE)
      }

      // The preference RecyclerView (id/recycler_view in the capture); setDivider(null).
      List({ scroller: settingsListScroller }) {
        // -- PreferenceScreen: player_notification_screen_key --------------------------------
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
        // conditionalVariant #1, 33+ arm: updateEnabledState puts the OS notification setting on
        // THIS row (streamsNotificationsPreference.isEnabled = enabled).
        ListItem() {
          Row() {
            Column() {
              Text($r('app.string.enable_streams_notifications_title'))
                .width('100%')
                .fontSize(16)
                .lineHeight(20)
                .fontColor(this.screenSwitchEnabledState
                  ? COLOR_ON_SURFACE : COLOR_DISABLED_TEXT)
              Text($r('app.string.enable_streams_notifications_summary'))
                .width('100%')
                .fontSize(14)
                .lineHeight(17)
                .fontColor(this.screenSwitchEnabledState
                  ? COLOR_SECONDARY_TEXT : COLOR_DISABLED_TEXT)
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)

            // widget_frame: a 47x27vp switch against the row's 16vp right gutter (base.ui.json's
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
          // streamsNotificationsPreference.isEnabled = enabled: a disabled Preference row is not
          // clickable either, so the greyed ink above and this guard are one fact, and the guard
          // reads the source's own condition. It only ever goes false while the OS has this app's
          // notifications switched off - the state the snackbar above renders in.
          .enabled(this.screenSwitchEnabledState)
          .onClick(() => {
            this.enableStreamsNotifications = !this.enableStreamsNotifications;
            // onSharedPreferenceChanged(enable_streams_notifications): schedule() when the
            // notifications were previously disabled, cancel() when the user just turned them off.
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
                .fontColor(this.dependentRowEnabled() ? COLOR_ON_SURFACE : COLOR_DISABLED_TEXT)
              Text(this.labelOf(this.intervalOptions, this.intervalValue))
                .width('100%')
                .fontSize(14)
                .lineHeight(17)
                .fontColor(this.dependentRowEnabled() ? COLOR_SECONDARY_TEXT : COLOR_DISABLED_TEXT)
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)
          }
          .id('streams_notifications_interval')
          .width('100%')
          .padding({ left: 16, right: 16, top: 16, bottom: 16 })
          .alignItems(VerticalAlign.Center)
          .enabled(this.dependentRowEnabled())
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
                .fontColor(this.dependentRowEnabled() ? COLOR_ON_SURFACE : COLOR_DISABLED_TEXT)
              Text(this.labelOf(this.networkOptions, this.networkValue))
                .width('100%')
                .fontSize(14)
                .lineHeight(17)
                .fontColor(this.dependentRowEnabled() ? COLOR_SECONDARY_TEXT : COLOR_DISABLED_TEXT)
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)
          }
          .id('streams_notifications_network')
          .width('100%')
          .padding({ left: 16, right: 16, top: 16, bottom: 16 })
          .alignItems(VerticalAlign.Center)
          .enabled(this.dependentRowEnabled())
          .onClick(() => {
            this.networkDialog.open();
          })
        }

        // -- Preference: streams_notifications_channels_key ----------------------------------
        // The summary is updateSubscriptions()'s notified/total count, bound in S4.
        ListItem() {
          Row() {
            Column() {
              Text($r('app.string.channels'))
                .width('100%')
                .fontSize(16)
                .lineHeight(20)
                .fontColor(this.dependentRowEnabled() ? COLOR_ON_SURFACE : COLOR_DISABLED_TEXT)
              // base.ui.json's Channels row carries the notified/total line ("1/1"); the summary
              // is View.GONE until updateSubscriptions() has produced it, exactly as
              // preference_material hides a Preference with no summary.
              Text(this.channelsRowSummary)
                .width('100%')
                .fontSize(14)
                .lineHeight(17)
                .fontColor(this.dependentRowEnabled() ? COLOR_SECONDARY_TEXT : COLOR_DISABLED_TEXT)
                .visibility(this.channelsRowSummary.length > 0
                  ? Visibility.Visible : Visibility.None)
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)
          }
          .id('streams_notifications_channels')
          .width('100%')
          .padding({ left: 16, right: 16, top: 16, bottom: 16 })
          .alignItems(VerticalAlign.Center)
          .enabled(this.dependentRowEnabled())
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
    .id('NotificationsSettingsFragmentPage')
    .width('100%')
    .height('100%')
    .backgroundColor(themedBackground(this.blackTheme))
  }

  /**
   * conditionalVariant #1, the API 33+ arm: updateEnabledState puts the OS notification setting
   * on the MASTER SWITCH only (player notifications are exempt on 33+), so the rows below it
   * follow nothing but their own android:dependency="@string/enable_streams_notifications".
   * The pre-33 arm - `preferenceScreen.isEnabled = enabled`, i.e. the whole screen - cannot
   * render on HarmonyOS NEXT (API 12+ has the same exemption), so it is recorded, not built.
   */
  private dependentRowEnabled(): boolean {
    if (!this.enableStreamsNotifications) {
      return false;
    }
    return true;
  }

  /**
   * NotificationHelper.openNewPipeSystemNotificationSettings(context): the OS notification
   * settings for THIS app - notificationManager.openNotificationSettings(context), which the
   * system shows as a semi-modal over the app.
   *
   * Before the sheet, the platform's own "Allow notifications?" prompt
   * (requestEnableNotification) - the HarmonyOS counterpart of the source's POST_NOTIFICATIONS
   * request - which resolves on Allow (or when already allowed). It is shown once per install:
   * after a Deny it rejects with 1600004 straight away, and that is when the sheet is the only
   * way left, so the rejection falls through to it.
   */
  private openSystemNotificationSettings(): void {
    notificationManager.requestEnableNotification(this.context())
      .then((): void => {
        this.refreshDeviceState();
      })
      .catch((): void => {
        this.openSystemNotificationSheet();
      });
  }

  private openSystemNotificationSheet(): void {
    notificationManager.openNotificationSettings(this.context())
      .then((): void => {
        // the sheet is dismissed by the user; onPageShow re-reads the resulting device state
        this.refreshDeviceState();
      })
      .catch((err: Error): void => {
        this.errorInfo = err.message;
        hilog.error(0x0000, TAG, 'openNotificationSettings: %{public}s', err.message);
      });
  }
}
