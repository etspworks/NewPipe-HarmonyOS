/**
 * S4 - PanicResponderActivity (screen_panic_responder_activity). Captured state S0009.
 *
 * NO UI AT ALL in the source: theme @android:style/Theme.NoDisplay, launchMode=singleInstance,
 * noHistory=true, exported with an intent-filter for info.guardianproject.panic.action.TRIGGER
 * so a panic-button app (Ripple / Panic Kit) can wipe NewPipe off the screen and out of recents.
 * onCreate is the whole class (verbatim, codegraph):
 *   final Intent intent = getIntent();
 *   if (intent != null && PANIC_TRIGGER_ACTION.equals(intent.getAction())) {
 *       ExitActivity.exitAndRemoveFromRecentApps(this);   // TODO: clear the search results
 *   }
 *   finishAndRemoveTask();
 * ExitActivity.exitAndRemoveFromRecentApps starts ExitActivity with NEW_TASK |
 * EXCLUDE_FROM_RECENTS | CLEAR_TASK | NO_ANIMATION, and ExitActivity.onCreate is
 * `finishAndRemoveTask(); NavigationHelper.restartApp(this)`.
 *
 * navOut: replace -> screen_exit_activity. `replace` is the SOURCE's kind - the activity always
 * ends with finishAndRemoveTask(), so Back must never return to this route.
 *
 * S4 binds the branch to the real launch argument. HarmonyOS delivers the trigger as a want, and
 * EntryAbility forwards every want.parameter to this page's router params, so `action` is
 * getIntent().getAction(). No argument at all means no want reached this page - the source
 * Activity is only ever started BY its intent-filter, so there is no started task to finish, and
 * finishAndRemoveTask() below says exactly that rather than closing the app under a plain launch.
 *
 * Substitution, and the one place the two arms genuinely differ (self-signed-capabilities.md:
 * there is no ExitActivity-style second task, and no ArkTS API removes the app from recents):
 *  - the PANIC arm hands the route to ExitActivityPage, which does `router.clear()` +
 *    replaceUrl(MainActivity) - the source's CLEAR_TASK + restartApp, in place. Terminating the
 *    ability on top of that would kill the restart ExitActivity exists to perform, so the exit
 *    page owns the finish on this arm.
 *  - the OTHER arm has nothing to hand over, so finishAndRemoveTask() is terminateSelf().
 */
import { router } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';

const TAG: string = 'PanicResponderActivity';

/** PanicResponderActivity.PANIC_TRIGGER_ACTION, verbatim. */
const PANIC_TRIGGER_ACTION: string = 'info.guardianproject.panic.action.TRIGGER';

/** The want parameter carrying the launching action; intent.getAction() on the source side. */
const ACTION_PARAM: string = 'action';

@Entry
@Component
export struct PanicResponderActivityPage {
  /** intent.getAction() - read from the launching want; empty means no want reached this page. */
  @State getAction: string = '';
  /** Set once ExitActivityPage has the route: it performs this page's finish from there. */
  private handedToExit: boolean = false;

  aboutToAppear(): void {
    this.readArguments();
  }

  onPageShow(): void {
    // onCreate(), in its own order: the branch first, then the unconditional finish.
    if (this.getAction === PANIC_TRIGGER_ACTION) {
      // ExitActivity.exitAndRemoveFromRecentApps(this)
      this.handedToExit = true;
      router.replaceUrl({ url: 'pages/ExitActivityPage' })
        .catch((err: BusinessError): void => {
          this.handedToExit = false;
          hilog.error(0x0000, TAG, 'exit route failed: %{public}s', err.message);
        });
    }
    this.finishAndRemoveTask();
  }

  /** getIntent().getAction(), as EntryAbility forwarded it. */
  private readArguments(): void {
    const params: Record<string, Object> | undefined =
      router.getParams() as Record<string, Object> | undefined;
    if (params === undefined || params === null) {
      return;
    }
    const raw: Object | undefined = params[ACTION_PARAM];
    if (raw === undefined || raw === null) {
      return;
    }
    this.getAction = raw.toString();
  }

  /**
   * finishAndRemoveTask(), called on BOTH arms exactly as onCreate does. It terminates the
   * ability, which is this app's whole task; the two cases that do not terminate are named in
   * the header - a launch that carried no want action (nothing was ever started), and the panic
   * arm, whose ExitActivityPage performs the finish plus the restart the source expects.
   */
  private finishAndRemoveTask(): void {
    if (this.getAction.length === 0) {
      hilog.info(0x0000, TAG, '%{public}s', 'no panic want delivered this launch; nothing to finish');
      return;
    }
    if (this.handedToExit) {
      return;
    }
    const context: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
    context.terminateSelf()
      .catch((err: BusinessError): void => {
        hilog.error(0x0000, TAG, 'terminateSelf failed: %{public}s', err.message);
      });
  }

  build() {
    Column() {
      // Theme.NoDisplay: the source draws NOTHING in either branch, and controlInventory is
      // empty (action contract S0009 has no actions), so there is no control to render here -
      // inventing one would be a control the source does not have. The branch itself is kept
      // because the plan's conditional variant must be a real ArkUI `if` on its own bound field
      // (getAction); both arms render an empty container, exactly like Theme.NoDisplay.
      if (this.getAction === PANIC_TRIGGER_ACTION) {
        Column()
          .width('100%')
          .height('100%')
      } else {
        Column()
          .width('100%')
          .height('100%')
      }
    }
    .id('PanicResponderActivityPage')
    .width('100%')
    .height('100%')
    // S5 has exactly one style fact to carry over, and it is a THEME fact, not a view:
    // @android:style/Theme.NoDisplay is windowIsTranslucent with a null windowBackground, and
    // S0009 confirms it - the capture holds no node of this activity at all, only the system
    // status bar and whatever was already on screen. So the page paints nothing. Colour,
    // spacing, typography and icons have no subject here; every one of them would be an
    // invented control, which is why none was added.
    .backgroundColor(Color.Transparent)
  }
}
