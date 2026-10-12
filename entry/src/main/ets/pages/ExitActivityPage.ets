/**
 * S2 shell - ExitActivity (screen_exit_activity). SOURCE-ONLY, no captured state.
 *
 * NO UI AT ALL in the source: android:theme=@android:style/Theme.NoDisplay, and onCreate is
 * exactly `finishAndRemoveTask(); NavigationHelper.restartApp(this)` - it never sets a content
 * view. Its real purpose is the static helper exitAndRemoveFromRecentApps(activity), started
 * with NEW_TASK | EXCLUDE_FROM_RECENTS | CLEAR_TASK | NO_ANIMATION so the app vanishes from
 * recents; PanicResponderActivity is its only caller.
 *
 * On HarmonyOS the ProcessPhoenix-style self-restart is replaced by re-initialising in place
 * (phase2-logic-contract §2.7: reopen relationalStore, re-read preferences, rebuild the tab
 * set), so the page holds no UI and only carries the plan's single navOut edge:
 *   replace -> screen_main_activity  ==  router.replaceUrl('pages/MainActivityPage')
 * `replace` is correct here and is the SOURCE's kind: the source finishes itself, so Back must
 * not return to this route. The re-init call itself is S4.
 */
import { router } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { BLACK_THEME_KEY, themedBackground } from '../common/theme/ThemeBackground';

const TAG: string = 'ExitActivityPage';

@Entry
@Component
export struct ExitActivityPage {
  /** ThemeHelper's black theme: the window background follows it. */
  @StorageProp(BLACK_THEME_KEY) blackTheme: boolean = false;

  onPageShow(): void {
    this.restartApp();
  }

  /**
   * onCreate(): finishAndRemoveTask() then NavigationHelper.restartApp(this). HarmonyOS cannot
   * self-restart a process, so the substitution is a re-initialise in place: the whole back
   * stack is dropped (finishAndRemoveTask + CLEAR_TASK) and MainActivity is loaded as the new
   * root in the same call, so Back can never return to this route.
   */
  private restartApp(): void {
    router.clear();
    router.replaceUrl({ url: 'pages/MainActivityPage' })
      .catch((err: BusinessError): void => {
        hilog.error(0x0000, TAG, 'restart failed: %{public}s', err.message);
      });
  }

  build() {
    Column() {
    }
    .id('ExitActivityPage')
    .width('100%')
    .height('100%')
    // android:theme="@android:style/Theme.NoDisplay": the source draws nothing at all. The
    // page still exists for one frame here, so it carries the app's own window background
    // rather than showing through to black.
    .backgroundColor(themedBackground(this.blackTheme))
  }
}
