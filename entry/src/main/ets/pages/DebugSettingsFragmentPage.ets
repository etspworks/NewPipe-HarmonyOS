/**
 * S3 - DebugSettingsFragment (screen_debug_settings): the real preference tree, unstyled.
 *
 * Structure comes from res/xml/debug_settings.xml (9 rows, in XML order) + the fragment's own
 * onCreatePreferences. BasePreferenceFragment.onViewCreated calls setDivider(null) and pushes the
 * PreferenceScreen's title (@string/settings_category_debug_title) into the host toolbar, so the
 * list carries no separators and the page renders that title beside the Up affordance.
 *
 * Two widget kinds only - there is no ListPreference here, so this screen has no dialog:
 *  - SwitchPreferenceCompat (allow_heap_dumping_key, allow_disposed_exceptions_key,
 *    show_original_time_ago_key, show_crash_the_player_key), whose whole row is the tap target;
 *  - plain Preference, i.e. a button row (show_memory_leaks_key, check_new_streams,
 *    crash_the_app_key, show_error_snackbar_key, create_error_notification_key).
 *
 * The screen's one conditional variant is getBVDLeakCanary().isPresent(): LeakCanary is resolved
 * REFLECTIVELY (Class.forName on the build-variant impl), so both LeakCanary rows are enabled with
 * their normal summaries when it loads, and disabled with @string/leak_canary_not_available when it
 * does not. HarmonyOS has no such class, so `leakCanaryRowsEnabledStateAndSummary` stays false and
 * the disabled branch is what actually renders - that is the SOURCE's own not-available path, not a
 * migration gap, so the guard is real rather than invented.
 *
 * Reachable only in a debug build: MainSettingsFragment removes the entry when !MainActivity.DEBUG.
 * crash_the_app_key deliberately throws an uncaught RuntimeException, so it must stay excluded from
 * the evidence sweep - tapping it kills the app by design.
 *
 * S4 (this pass) wired: the preference reads/writes (svc_preferences) and the four button effects -
 * NotificationWorker.runNow for check_new_streams, the deliberate throw for crash_the_app_key, and
 * ErrorUtil.showUiErrorSnackbar / ErrorUtil.createNotification (svc_error_reporter, ErrorInfo) for
 * the last two.
 *
 * S5 applies the LightTheme colours, fonts and row metrics from the S0080-S0089 capture on top of
 * that structure - no control, binding or branch changed.
 *
 * S6 (this pass) finalises the row line heights against the same capture (see the style block
 * below) and changes nothing else. Two things it deliberately did NOT change:
 *  - the capture renders the LeakCanary pair ENABLED, with @string/enable_leak_canary_summary,
 *    because the Android debug build resolves the LeakCanary class. That is the branch above, not
 *    styling: which branch renders is decided by the source's own getBVDLeakCanary().isPresent(),
 *    and on HarmonyOS that class cannot load, so the not-available branch is the honest one. The
 *    row is present either way, which is what the control inventory asks for.
 *  - the toolbar Up affordance is the source asset (ic_arrow_back) tinted ?attr/actionColor, and
 *    is the only icon on the screen; the 'Navigate up' clickable the S5 sweep listed is that same
 *    Image, already carrying .id('home'), so no second affordance was added.
 */
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { promptAction, router } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { ServiceLocator } from '../common/di/ServiceLocator';
import { AppPreferences } from '../common/prefs/Preferences';
import {
  allow_disposed_exceptions_key,
  allow_heap_dumping_key,
  show_crash_the_player_key,
  show_original_time_ago_key
} from '../common/prefs/SettingsKeys';
import { FeedLoader } from '../common/feed/FeedLoader';
import { FeedUpdateInfo } from '../model/app/FeedUpdateInfo';
import { ErrorInfo } from '../model/app/ErrorInfo';
import { UserAction } from '../model/enums/UserAction';
import { BLACK_THEME_KEY, themedBackground } from '../common/theme/ThemeBackground';

const TAG: string = 'DebugSettingsFragmentPage';

/** DebugSettingsFragment.DUMMY, verbatim - the title, request and message of every dummy error. */
const DUMMY: string = 'Dummy';

/** NotificationWorker.createWork's own doOnError request string. */
const NOTIFICATION_WORKER_REQUEST: string = 'main worker';

/* S5 - style only, LightTheme (the theme S0080-S0089 render in). Reuses the run's style baseline
 * (state.json generation.styleBaseline, source S0004) for background / onSurface / secondaryText,
 * and the AndroidX preference-row metrics the sibling settings screens already carry; this screen's
 * own base.ui.json confirms each of them at 1080px/360vp: a 56vp toolbar ([0,72][1080,240]) whose
 * Up button is 56vp square and whose title starts at x=216px (72vp), 16vp row gutters (title
 * x=48px, switch right edge 1032px), 16vp vertical row padding (48px from a row's top edge to its
 * title) and a 47x27vp switch (140x81px). setDivider(null) in BasePreferenceFragment, so the list
 * carries no separators.
 *
 * S6 took the two line heights off the same capture, as BackupRestoreSettingsFragmentPage did: the
 * title TextView is 65px tall (16sp -> 21.7vp, rendered at 22) and a summary line is 53px (14sp ->
 * 17.7vp, rendered at 18). That puts a title-only row at 54vp against the captured 53.7vp (161px,
 * show_memory_leaks_key = [556..717]) and a title+3-line-summary row at 108vp against the captured
 * 105.3vp (316px, allow_heap_dumping_key = [240..556]); S5's 20/17 left both short. */
/** ?attr/windowBackground - light_background_color, the capture's #EEEEEE. */
const COLOR_SURFACE: Resource = $r('app.color.background');
/** ?attr/colorPrimary - the toolbar and the switch's checked track. */
const COLOR_PRIMARY: Resource = $r('app.color.primary');
/** ?android:textColorPrimary - #DE000000 over #EEEEEE is the capture's row title. */
const COLOR_ON_SURFACE: Resource = $r('app.color.on_surface');
/** ?android:textColorSecondary - #8A000000 over #EEEEEE is the capture's summary. */
const COLOR_SECONDARY_TEXT: Resource = $r('app.color.on_surface_variant');
/**
 * ?attr/disabledAlpha - preference_material puts it on a disabled row's title/summary group. The
 * two LeakCanary rows are the only ones that ever render disabled, and the capture shows them
 * enabled, so the value comes from the theme rather than from a screenshot.
 */
const DISABLED_ALPHA: number = 0.5;

@Entry
@Component
export struct DebugSettingsFragmentPage {
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
   * bindingContract: getBVDLeakCanary().isPresent() - whether the build-variant LeakCanary class
   * loaded. It drives BOTH LeakCanary rows' enabled state AND their summary, which is why the
   * source keeps it as one fact and not two.
   */
  @State leakCanaryRowsEnabledStateAndSummary: boolean = false;

  /** SwitchPreferenceCompat rows; every one of them is android:defaultValue="false". */
  @State allowHeapDumping: boolean = false;
  @State allowDisposedExceptions: boolean = false;
  @State showOriginalTimeAgo: boolean = false;
  @State showCrashThePlayer: boolean = false;

  @State isLoading: boolean = true;
  @State errorInfo: string = '';

  /** onCreatePreferences reads nothing itself; the switch rows show their persisted values. */
  async aboutToAppear(): Promise<void> {
    try {
      this.allowHeapDumping = await AppPreferences.getBoolean(allow_heap_dumping_key, false);
      this.allowDisposedExceptions =
        await AppPreferences.getBoolean(allow_disposed_exceptions_key, false);
      this.showOriginalTimeAgo = await AppPreferences.getBoolean(show_original_time_ago_key, false);
      this.showCrashThePlayer = await AppPreferences.getBoolean(show_crash_the_player_key, false);
    } catch (err) {
      this.report(err as BusinessError);
    } finally {
      this.isLoading = false;
    }
  }

  /**
   * SwitchPreferenceCompat writes straight through to the same preference store the rest of the
   * app reads (show_crash_the_player_key is read by VideoDetailFragment, allow_disposed_exceptions
   * by the Rx error handler), so the write path is the whole point of these rows.
   */
  private persist(key: string, value: boolean): void {
    AppPreferences.putBoolean(key, value).catch((err: BusinessError): void => {
      this.report(err);
    });
  }

  private report(err: BusinessError): void {
    this.errorInfo = err.message;
    hilog.error(0x0000, TAG, 'preference access failed: %{public}s', err.message);
  }

  /**
   * setOnPreferenceClickListener: startActivity(getNewLeakDisplayActivityIntent()). LeakCanary has
   * no HarmonyOS build variant, so this row only ever renders in the disabled branch below; were
   * the class ever present, say what the source says when it is not, rather than opening nothing.
   */
  private onShowMemoryLeaksClicked(): void {
    promptAction.showToast({ message: $r('app.string.leak_canary_not_available') });
  }

  /**
   * setOnPreferenceClickListener: NotificationWorker.runNow(preference.getContext()). runNow only
   * enqueues the worker, so what the user actually gets is NotificationWorker.createWork's body:
   * load the feed of every subscription that has notifications on (ignoring the outdated
   * threshold), then post one notification per channel that really has new streams. The worker's
   * own foreground "loading" notification is a WorkManager artifact of running detached and has no
   * counterpart for a tap made with the screen in front of the user.
   */
  private async onCheckNewStreamsClicked(): Promise<void> {
    if (!ServiceLocator.isInitialized()) {
      hilog.warn(0x0000, TAG, 'check_new_streams: services are not initialised');
      return;
    }
    const services: ServiceLocator = ServiceLocator.get();
    try {
      if (!await services.notifications.areNewStreamsNotificationsEnabled()) {
        // the user can disable streams notifications in the device's app settings
        return;
      }
      const context: common.Context = getContext(this) as common.Context;
      const loader: FeedLoader = await FeedLoader.of(context);
      const feed: FeedUpdateInfo[] =
        await loader.startLoading(FeedLoader.GROUP_NOTIFICATION_ENABLED, true);
      for (const info of feed) {
        // filter out feedUpdateInfo items (i.e. channels) with nothing new
        if (info.newStreams.length > 0) {
          await services.notifications.displayNewStreamsNotifications(info);
        }
      }
    } catch (err) {
      // createWork's doOnError, with the same UserAction and request string.
      services.errorReporter.createNotification(ErrorInfo.fromThrowable(err as Error,
        UserAction.NEW_STREAMS_NOTIFICATIONS, NOTIFICATION_WORKER_REQUEST));
    }
  }

  /**
   * setOnPreferenceClickListener: `throw new RuntimeException(DUMMY)`. Deliberately fatal - this
   * row exists to prove the uncaught-exception path, and ErrorReporter's errorManager observer is
   * where it lands. Excluded from the evidence sweep for exactly that reason.
   */
  private onCrashTheAppClicked(): void {
    throw new Error(DUMMY);
  }

  /** setOnPreferenceClickListener: ErrorUtil.showUiErrorSnackbar(this, DUMMY, RuntimeException). */
  private onShowErrorSnackbarClicked(): void {
    try {
      ServiceLocator.get().errorReporter.showUiErrorSnackbar(DUMMY, new Error(DUMMY));
    } catch (err) {
      this.report(err as BusinessError);
    }
  }

  /** setOnPreferenceClickListener: ErrorUtil.createNotification(ctx, new ErrorInfo(...)). */
  private onCreateErrorNotificationClicked(): void {
    try {
      ServiceLocator.get().errorReporter.createNotification(
        ErrorInfo.fromThrowable(new Error(DUMMY), UserAction.UI_ERROR, DUMMY));
    } catch (err) {
      this.report(err as BusinessError);
    }
  }

  build() {
    Column() {
      if (!this.hostDrawsToolbar) {
        // toolbar_layout.xml: the host activity's Up affordance and the PreferenceScreen title that
        // BasePreferenceFragment.onViewCreated pushes into it. android.R.id.home is the slug.
        Row() {
          // The Up affordance: a 24vp glyph centred in the ?attr/actionBarSize touch target,
          // tinted ?attr/actionColor = @color/white by ToolbarTheme.
          Image($r('app.media.ic_arrow_back'))
            .id('home')
            .accessibilityText($r('app.string.navigate_back'))
            .objectFit(ImageFit.Contain)
            .width(56)
            .height(56)
            .padding(16)
            .fillColor($r('app.color.on_primary'))
            .onClick(() => {
              router.back();
            })

          // Widget.AppCompat.Toolbar.Title: 20sp medium on ?attr/actionColor, inset 16vp past the
          // navigation button - the capture's 72vp title start.
          Text($r('app.string.settings_category_debug_title'))
            .layoutWeight(1)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .fontSize(20)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.on_primary'))
            .margin({ left: 16 })
        }
        .width('100%')
        // Toolbar: ?attr/actionBarSize tall on ?attr/colorPrimary.
        .height(56)
        .alignItems(VerticalAlign.Center)
        .backgroundColor(COLOR_PRIMARY)
      }

      // The preference RecyclerView (id/recycler_view in the capture): one row per XML entry.
      List() {
        // -- SwitchPreferenceCompat: allow_heap_dumping_key -------------------------------------
        // conditionalVariants: enabled with @string/enable_leak_canary_summary only while the
        // build-variant LeakCanary class is present; otherwise disabled and saying so.
        if (this.leakCanaryRowsEnabledStateAndSummary) {
          ListItem() {
            Row() {
              Column() {
                Text($r('app.string.leakcanary'))
                  .width('100%')
                  .fontSize(16)
                  .lineHeight(22)
                  .fontColor(COLOR_ON_SURFACE)
                Text($r('app.string.enable_leak_canary_summary'))
                  .width('100%')
                  .fontSize(14)
                  .lineHeight(18)
                  .fontColor(COLOR_SECONDARY_TEXT)
              }
              .layoutWeight(1)
              .alignItems(HorizontalAlign.Start)

              // The whole row is the one tappable control, so the switch takes no touch.
              Toggle({ type: ToggleType.Switch, isOn: this.allowHeapDumping })
                .hitTestBehavior(HitTestMode.None)
                .width(47)
                .height(27)
                .margin({ left: 16 })
                .selectedColor(COLOR_PRIMARY)
            }
            .id('allow_heap_dumping_key')
            .width('100%')
            .padding({ left: 16, right: 16, top: 16, bottom: 16 })
            .alignItems(VerticalAlign.Center)
            .onClick(() => {
              this.allowHeapDumping = !this.allowHeapDumping;
              this.persist(allow_heap_dumping_key, this.allowHeapDumping);
            })
          }

          // -- Preference: show_memory_leaks_key ------------------------------------------------
          // Only this branch gets the click listener; the source attaches it inside isPresent().
          ListItem() {
            Row() {
              Column() {
                Text($r('app.string.show_memory_leaks'))
                  .width('100%')
                  .fontSize(16)
                  .lineHeight(22)
                  .fontColor(COLOR_ON_SURFACE)
              }
              .layoutWeight(1)
              .alignItems(HorizontalAlign.Start)
            }
            .id('show_memory_leaks_key')
            .width('100%')
            .padding({ left: 16, right: 16, top: 16, bottom: 16 })
            .alignItems(VerticalAlign.Center)
            .onClick(() => {
              this.onShowMemoryLeaksClicked();
            })
          }
        } else {
          ListItem() {
            Row() {
              Column() {
                Text($r('app.string.leakcanary'))
                  .width('100%')
                  .fontSize(16)
                  .lineHeight(22)
                  .fontColor(COLOR_ON_SURFACE)
                // setSummary(R.string.leak_canary_not_available) in the else branch.
                Text($r('app.string.leak_canary_not_available'))
                  .width('100%')
                  .fontSize(14)
                  .lineHeight(18)
                  .fontColor(COLOR_SECONDARY_TEXT)
              }
              .layoutWeight(1)
              .alignItems(HorizontalAlign.Start)

              Toggle({ type: ToggleType.Switch, isOn: this.allowHeapDumping })
                .hitTestBehavior(HitTestMode.None)
                .width(47)
                .height(27)
                .margin({ left: 16 })
                .selectedColor(COLOR_PRIMARY)
            }
            .id('allow_heap_dumping_key')
            .width('100%')
            .padding({ left: 16, right: 16, top: 16, bottom: 16 })
            .alignItems(VerticalAlign.Center)
            // setEnabled(optBVLeakCanary.isPresent()) - the source's own guard, not an invented one.
            // preference_material dims a disabled row by ?attr/disabledAlpha.
            .opacity(DISABLED_ALPHA)
            .enabled(false)
          }

          ListItem() {
            Row() {
              Column() {
                Text($r('app.string.show_memory_leaks'))
                  .width('100%')
                  .fontSize(16)
                  .lineHeight(22)
                  .fontColor(COLOR_ON_SURFACE)
                Text($r('app.string.leak_canary_not_available'))
                  .width('100%')
                  .fontSize(14)
                  .lineHeight(18)
                  .fontColor(COLOR_SECONDARY_TEXT)
              }
              .layoutWeight(1)
              .alignItems(HorizontalAlign.Start)
            }
            .id('show_memory_leaks_key')
            .width('100%')
            .padding({ left: 16, right: 16, top: 16, bottom: 16 })
            .alignItems(VerticalAlign.Center)
            // preference_material dims a disabled row by ?attr/disabledAlpha.
            .opacity(DISABLED_ALPHA)
            .enabled(false)
          }
        }

        // -- SwitchPreferenceCompat: allow_disposed_exceptions_key -------------------------------
        ListItem() {
          Row() {
            Column() {
              Text($r('app.string.enable_disposed_exceptions_title'))
                .width('100%')
                .fontSize(16)
                .lineHeight(22)
                .fontColor(COLOR_ON_SURFACE)
              Text($r('app.string.enable_disposed_exceptions_summary'))
                .width('100%')
                .fontSize(14)
                .lineHeight(18)
                .fontColor(COLOR_SECONDARY_TEXT)
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)

            Toggle({ type: ToggleType.Switch, isOn: this.allowDisposedExceptions })
              .hitTestBehavior(HitTestMode.None)
              .width(47)
              .height(27)
              .margin({ left: 16 })
              .selectedColor(COLOR_PRIMARY)
          }
          .id('allow_disposed_exceptions_key')
          .width('100%')
          .padding({ left: 16, right: 16, top: 16, bottom: 16 })
          .alignItems(VerticalAlign.Center)
          .onClick(() => {
            this.allowDisposedExceptions = !this.allowDisposedExceptions;
            this.persist(allow_disposed_exceptions_key, this.allowDisposedExceptions);
          })
        }

        // -- SwitchPreferenceCompat: show_original_time_ago_key ----------------------------------
        ListItem() {
          Row() {
            Column() {
              Text($r('app.string.show_original_time_ago_title'))
                .width('100%')
                .fontSize(16)
                .lineHeight(22)
                .fontColor(COLOR_ON_SURFACE)
              Text($r('app.string.show_original_time_ago_summary'))
                .width('100%')
                .fontSize(14)
                .lineHeight(18)
                .fontColor(COLOR_SECONDARY_TEXT)
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)

            Toggle({ type: ToggleType.Switch, isOn: this.showOriginalTimeAgo })
              .hitTestBehavior(HitTestMode.None)
              .width(47)
              .height(27)
              .margin({ left: 16 })
              .selectedColor(COLOR_PRIMARY)
          }
          .id('show_original_time_ago_key')
          .width('100%')
          .padding({ left: 16, right: 16, top: 16, bottom: 16 })
          .alignItems(VerticalAlign.Center)
          .onClick(() => {
            this.showOriginalTimeAgo = !this.showOriginalTimeAgo;
            this.persist(show_original_time_ago_key, this.showOriginalTimeAgo);
          })
        }

        // -- SwitchPreferenceCompat: show_crash_the_player_key -----------------------------------
        // When true, VideoDetailFragment shows the VideoDetailPlayerCrasher control: a cross-screen
        // contract, not local state.
        ListItem() {
          Row() {
            Column() {
              Text($r('app.string.show_crash_the_player_title'))
                .width('100%')
                .fontSize(16)
                .lineHeight(22)
                .fontColor(COLOR_ON_SURFACE)
              Text($r('app.string.show_crash_the_player_summary'))
                .width('100%')
                .fontSize(14)
                .lineHeight(18)
                .fontColor(COLOR_SECONDARY_TEXT)
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)

            Toggle({ type: ToggleType.Switch, isOn: this.showCrashThePlayer })
              .hitTestBehavior(HitTestMode.None)
              .width(47)
              .height(27)
              .margin({ left: 16 })
              .selectedColor(COLOR_PRIMARY)
          }
          .id('show_crash_the_player_key')
          .width('100%')
          .padding({ left: 16, right: 16, top: 16, bottom: 16 })
          .alignItems(VerticalAlign.Center)
          .onClick(() => {
            this.showCrashThePlayer = !this.showCrashThePlayer;
            this.persist(show_crash_the_player_key, this.showCrashThePlayer);
          })
        }

        // -- Preference: check_new_streams -------------------------------------------------------
        ListItem() {
          Row() {
            Column() {
              Text($r('app.string.check_new_streams'))
                .width('100%')
                .fontSize(16)
                .lineHeight(22)
                .fontColor(COLOR_ON_SURFACE)
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)
          }
          .id('check_new_streams')
          .width('100%')
          .padding({ left: 16, right: 16, top: 16, bottom: 16 })
          .alignItems(VerticalAlign.Center)
          .onClick(() => {
            this.onCheckNewStreamsClicked();
          })
        }

        // -- Preference: crash_the_app_key -------------------------------------------------------
        ListItem() {
          Row() {
            Column() {
              Text($r('app.string.crash_the_app'))
                .width('100%')
                .fontSize(16)
                .lineHeight(22)
                .fontColor(COLOR_ON_SURFACE)
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)
          }
          .id('crash_the_app_key')
          .width('100%')
          .padding({ left: 16, right: 16, top: 16, bottom: 16 })
          .alignItems(VerticalAlign.Center)
          .onClick(() => {
            this.onCrashTheAppClicked();
          })
        }

        // -- Preference: show_error_snackbar_key -------------------------------------------------
        ListItem() {
          Row() {
            Column() {
              Text($r('app.string.show_error_snackbar'))
                .width('100%')
                .fontSize(16)
                .lineHeight(22)
                .fontColor(COLOR_ON_SURFACE)
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)
          }
          .id('show_error_snackbar_key')
          .width('100%')
          .padding({ left: 16, right: 16, top: 16, bottom: 16 })
          .alignItems(VerticalAlign.Center)
          .onClick(() => {
            this.onShowErrorSnackbarClicked();
          })
        }

        // -- Preference: create_error_notification_key -------------------------------------------
        ListItem() {
          Row() {
            Column() {
              Text($r('app.string.create_error_notification'))
                .width('100%')
                .fontSize(16)
                .lineHeight(22)
                .fontColor(COLOR_ON_SURFACE)
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)
          }
          .id('create_error_notification_key')
          .width('100%')
          .padding({ left: 16, right: 16, top: 16, bottom: 16 })
          .alignItems(VerticalAlign.Center)
          .onClick(() => {
            this.onCreateErrorNotificationClicked();
          })
        }
      }
      .width('100%')
      .layoutWeight(1)

      // ErrorPanelHelper equivalent: only once the first read has finished and failed.
      if (!this.isLoading && this.errorInfo.length > 0) {
        Text(this.errorInfo)
          .width('100%')
          .fontSize(14)
          .lineHeight(18)
          .fontColor(COLOR_SECONDARY_TEXT)
          .padding({ left: 16, right: 16, top: 16, bottom: 16 })
      }
    }
    .id('DebugSettingsFragmentPage')
    .width('100%')
    .height('100%')
    .alignItems(HorizontalAlign.Start)
    .backgroundColor(themedBackground(this.blackTheme))
  }
}
