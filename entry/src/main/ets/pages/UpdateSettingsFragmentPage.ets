/**
 * S3 - UpdateSettingsFragment (screen_update_settings): the real preference tree, unstyled.
 *
 * res/xml/update_settings.xml, in XML order:
 *   1 SwitchPreferenceCompat update_app_key   (defaultValue false) - updates_setting_title /
 *     updates_setting_description
 *   2 Preference manual_update_key            - manual_update_title / manual_update_description
 * No dependencies, no nested screens, no navOut. hostedBy screen_settings_activity, which PUSHES
 * this page (router.pushUrl) - SettingsActivityPage already carries that push.
 * BasePreferenceFragment.onViewCreated pushes @string/settings_category_updates_title into the host
 * toolbar and calls setDivider(null), so the page renders that title beside the Up affordance and
 * the list carries no separators.
 *
 * S4 wiring:
 *  - update_app_key's listener writes the preference AND, when the new value is true, enqueues
 *    NewVersionWorker.enqueueNewVersionCheckingWork(ctx, true) - one action, not two.
 *  - manual_update_key: Toast(checking_updates_toast) FIRST, then the same enqueue.
 *  - the enqueue is svc_update_check's checkNewVersion(isManual = true) - the port of
 *    NewVersionWorker.doWork() - run inside svc_background_work's dataTransfer continuous task,
 *    which is the substitution for the OneTimeWorkRequest androidx.work has no counterpart for
 *    (feat_periodic_background_work); the task is released in `finally` (rule 8) by
 *    runWithBackgroundTask itself. A newer version publishes the update notification through
 *    svc_notification, exactly as compareAppVersionAndShowNotification() does, and a MANUAL check
 *    that finds nothing shows app_update_unavailable_toast, which is that method's other arm.
 *  - the class also carries three STATIC helpers other screens call
 *    (askForConsentToUpdateChecks / setAutoUpdateCheckEnabled / wasUserAskedForConsent) writing
 *    update_check_consent_key. They belong to svc_update_check, not to this page.
 *
 * DISCLOSURE for the Phase-5 report: this screen is UNREACHABLE on a non-release build in the
 * source (MainSettingsFragment removes the row when !isReleaseApk() and force-writes
 * update_app_key=false; SettingsActivity drops R.xml.update_settings from the search index), and an
 * in-app APK self-update has no HarmonyOS analogue - the enqueue can only ever check for a new
 * version through newpipe_update_check, never install one.
 */
import { promptAction, router } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { ServiceLocator } from '../common/di/ServiceLocator';
import { Notifications } from '../common/notify/Notifications';
import { BackgroundWorkMode } from '../common/background/BackgroundWork';
import { AppPreferences } from '../common/prefs/Preferences';
import { update_app_key } from '../common/prefs/SettingsKeys';
import { UpdateCheck, UpdateCheckResult } from '../common/update/UpdateCheck';
import { BLACK_THEME_KEY, themedBackground } from '../common/theme/ThemeBackground';

const TAG: string = 'UpdateSettingsFragmentPage';

/** Toast.LENGTH_SHORT. */
const TOAST_SHORT_MS: number = 2000;

/* S5 - style only, LightSettingsTheme (the theme every captured state of this screen renders in).
 * Reuses the run's style baseline (state.json generation.styleBaseline, source S0004): primary /
 * onPrimary / background / onSurface / secondaryText and the 56vp toolbar with its 72vp title
 * inset and 20fp Medium bar title. The preference-row metrics (16vp gutter, 16vp vertical padding,
 * the 47x27vp switch) are measured from THIS screen's base.ui.json at density 3.0, and the colours
 * are sampled from base.png. */
/** ?attr/colorPrimary - the toolbar; the capture samples it (229,57,53). */
const COLOR_PRIMARY: Resource = $r('app.color.primary');
/** ?attr/actionColor - the Up glyph and the bar title. */
const COLOR_ON_PRIMARY: Resource = $r('app.color.on_primary');
/** ?attr/windowBackground - light_background_color, the capture's #EEEEEE. */
const COLOR_SURFACE: Resource = $r('app.color.background');
/** ?android:textColorPrimary - #DE000000 over #EEEEEE is the capture's (31,31,31) title. */
const COLOR_ON_SURFACE: Resource = $r('app.color.on_surface');
/** ?android:textColorSecondary - #8A000000 over #EEEEEE is the capture's (109,109,109) summary. */
const COLOR_SECONDARY_TEXT: Resource = $r('app.color.on_surface_variant');

@Entry
@Component
export struct UpdateSettingsFragmentPage {
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
   * SwitchPreferenceCompat update_app_key. The source's XML carries no defaultValue, so every
   * read there passes false and a release build asks the user instead; this port starts it ON,
   * which is the behaviour asked for - the row is listed, so the switch should mean something
   * before anybody touches it.
   */
  @State checkForUpdates: boolean = true;
  @State isLoading: boolean = false;
  @State errorInfo: string = '';

  aboutToAppear(): void {
    // addPreferencesFromResourceRegistry(): the switch shows its persisted value,
    // android:defaultValue="false".
    this.checkForUpdates = AppPreferences.instance().getBooleanSync(update_app_key, true);
  }

  /**
   * updatePreferenceChange: `defaultPreferences.edit().putBoolean(update_app_key, nVal).apply()`
   * and, when the new value is true, enqueueNewVersionCheckingWork(context, true).
   */
  private onCheckForUpdatesChanged(): void {
    this.checkForUpdates = !this.checkForUpdates;
    const enabled: boolean = this.checkForUpdates;
    AppPreferences.putBoolean(update_app_key, enabled)
      .then((): void => {
        if (enabled) {
          this.enqueueNewVersionCheckingWork();
        }
      })
      .catch((err: Error): void => {
        this.errorInfo = err.message;
        hilog.error(0x0000, TAG, 'putBoolean(update_app_key): %{public}s', err.message);
      });
  }

  /** manualUpdateClick: Toast(checking_updates_toast) FIRST, then the same enqueue. */
  private onManualUpdateClicked(): void {
    promptAction.showToast({
      message: $r('app.string.checking_updates_toast'),
      duration: TOAST_SHORT_MS
    });
    this.enqueueNewVersionCheckingWork();
  }

  /**
   * NewVersionWorker.enqueueNewVersionCheckingWork(context, isManual = true): both call sites on
   * this screen pass true, so the check ignores the enabled-setting throttle and the expiry, as
   * the source's IS_MANUAL input datum does.
   */
  private enqueueNewVersionCheckingWork(): void {
    if (this.isLoading) {
      return;
    }
    this.isLoading = true;
    this.runNewVersionCheck()
      .then((): void => {
        this.errorInfo = '';
        this.isLoading = false;
      })
      .catch((err: Error): void => {
        // doWork(): "Could not fetch NewPipe API: probably network problem" -> Result.failure().
        // The source's Worker fails silently because nothing is on screen waiting for it; here
        // both call sites are a tap on THIS screen, so the failure has to be said out loud -
        // otherwise the tap has no answer at all, which reads as "nothing happened". The other
        // arm of runNewVersionCheck already answers with app_update_unavailable_toast, so this
        // is the same channel and never reports a false up-to-date result.
        this.errorInfo = err.message;
        promptAction.showToast({
          message: $r('app.string.network_error'),
          duration: TOAST_SHORT_MS
        });
        hilog.warn(0x0000, TAG, 'new version check: %{public}s', err.message);
        this.isLoading = false;
      });
  }

  /** doWork() -> checkNewVersion() -> handleResponse() -> compareAppVersionAndShowNotification(). */
  private async runNewVersionCheck(): Promise<void> {
    const updateCheck: UpdateCheck = ServiceLocator.get().updateCheck;
    const result: UpdateCheckResult = await ServiceLocator.get().backgroundWork
      .runWithBackgroundTask(BackgroundWorkMode.DATA_TRANSFER,
        (): Promise<UpdateCheckResult> => {
          return updateCheck.checkNewVersion(true);
        });

    const failure: Error | null = result.error;
    if (failure !== null) {
      throw failure;
    }
    if (!result.updateAvailable) {
      // BuildConfig.VERSION_CODE >= versionCode with IS_MANUAL: the up-to-date toast.
      promptAction.showToast({
        message: $r('app.string.app_update_unavailable_toast'),
        duration: TOAST_SHORT_MS
      });
      return;
    }
    const notifications: Notifications = ServiceLocator.get().notifications;
    await notifications.publishUpdateAvailable(result.versionName, result.apkLocationUrl);
  }

  build() {
    Column() {
      if (!this.hostDrawsToolbar) {
        // toolbar_layout.xml: the host activity's Up affordance and the PreferenceScreen title that
        // BasePreferenceFragment.onViewCreated pushes into it. android.R.id.home is the slug.
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

          // Widget.AppCompat.Toolbar.Title: 20sp medium, 16vp past the navigation button (the
          // capture puts the title at x=216 of 1080 - 72vp at density 3.0).
          Text($r('app.string.settings_category_updates_title'))
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
        // -- SwitchPreferenceCompat: update_app_key -------------------------------------------
        ListItem() {
          Row() {
            Column() {
              Text($r('app.string.updates_setting_title'))
                .width('100%')
                .fontSize(16)
                .lineHeight(20)
                .fontColor(COLOR_ON_SURFACE)
              Text($r('app.string.updates_setting_description'))
                .width('100%')
                .fontSize(14)
                .lineHeight(17)
                .fontColor(COLOR_SECONDARY_TEXT)
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)

            // widget_frame: a 47x27vp switch against the row's 16vp right gutter (base.ui.json's
            // [892,333][1032,414] at density 3.0). The whole row is the one tappable control, so
            // the switch takes no touch.
            Toggle({ type: ToggleType.Switch, isOn: this.checkForUpdates })
              .hitTestBehavior(HitTestMode.None)
              .width(47)
              .height(27)
              .margin({ left: 16 })
              .selectedColor(COLOR_PRIMARY)
          }
          .id('update_app_key')
          .width('100%')
          .padding({ left: 16, right: 16, top: 16, bottom: 16 })
          .alignItems(VerticalAlign.Center)
          .onClick(() => {
            this.onCheckForUpdatesChanged();
          })
        }

        // -- Preference: manual_update_key ----------------------------------------------------
        ListItem() {
          Row() {
            Column() {
              Text($r('app.string.manual_update_title'))
                .width('100%')
                .fontSize(16)
                .lineHeight(20)
                .fontColor(COLOR_ON_SURFACE)
              Text($r('app.string.manual_update_description'))
                .width('100%')
                .fontSize(14)
                .lineHeight(17)
                .fontColor(COLOR_SECONDARY_TEXT)
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)
          }
          .id('manual_update_key')
          .width('100%')
          .padding({ left: 16, right: 16, top: 16, bottom: 16 })
          .alignItems(VerticalAlign.Center)
          .onClick(() => {
            this.onManualUpdateClicked();
          })
        }
      }
      .width('100%')
      .layoutWeight(1)
      // setDivider(null): the list carries no separators and no surface of its own.
      .divider(null)
      .backgroundColor(themedBackground(this.blackTheme))
    }
    .id('UpdateSettingsFragmentPage')
    .width('100%')
    .height('100%')
    .backgroundColor(themedBackground(this.blackTheme))
  }
}
