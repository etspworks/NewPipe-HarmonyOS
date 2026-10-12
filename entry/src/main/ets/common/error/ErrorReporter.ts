/*
 * svc_error_reporter - port of app/src/main/java/org/schabi/newpipe/error/ErrorUtil.kt and of
 * what ACRA did for this app.
 *
 * PLAN GAP, decided in phase2-logic-contract.md section 7 and recorded here: `ch.acra:acra-core`
 * has no port task, no substitution and no risks[] entry. It is not a Rule-11 port - ACRA only
 * installs an uncaught-exception handler and hands the crash to NewPipe's OWN ErrorActivity,
 * which is app code that migrates normally (AcraReportSender/AcraReportSenderFactory do nothing
 * but call ErrorUtil). HarmonyOS exposes exactly that catch natively, so the ACRA half is
 * `@ohos.app.ability.errorManager` `on('error')` and the rest is the ErrorUtil port below.
 *
 * The three escalating channels of ErrorUtil are preserved, with the ArkUI equivalent of each:
 *   - snackbar  -> components/ErrorSnackbar: the message with a REPORT action, for a
 *                  non-critical error where the user is looking at the app. ArkUI has no
 *                  Snackbar and this .ts service cannot build UI, so the shell registers the
 *                  presenter; before it has, the message is a plain toast.
 *   - notification -> svc_notification, for an error raised with no screen in front of the user.
 *   - error page -> the routed ErrorActivity equivalent, for a critical error.
 */

import { errorManager } from '@kit.AbilityKit';
import { promptAction } from '@kit.ArkUI';
import { ErrorInfo, ErrorInfoJson } from '../../model/app/ErrorInfo';
import { UserAction } from '../../model/enums/UserAction';
import { Localization } from '../i18n/Localization';
import { Notifications } from '../notify/Notifications';

/** ErrorUtil.ERROR_REPORT_NOTIFICATION_ID, verbatim. */
export const ERROR_REPORT_NOTIFICATION_ID: number = 5340681;

/** Where the error page reads its ErrorInfo from - the source's ErrorActivity.ERROR_INFO extra. */
export const ERROR_INFO_PARAM: string = 'errorInfo';

/** Opens the error page. Wired by EntryAbility, which owns the router. */
export type ErrorPageOpener = (info: ErrorInfoJson) => void;

/** Shows a snackbar whose action runs `onAction`. Registered by the UI layer. */
export type SnackbarPresenter = (message: string, actionLabel: string, onAction: () => void) => void;

export class ErrorReporter {
  private notifications: Notifications | null = null;
  private openErrorPage: ErrorPageOpener | null = null;
  private observerId: number = -1;
  private snackbarPresenter: SnackbarPresenter | null = null;
  /**
   * The source's MainActivity.KEY_IS_IN_BACKGROUND: when the app is backgrounded a crash opens a
   * notification instead of an activity. Kept as state rather than a preference, because it is
   * lifecycle information and EntryAbility already knows it.
   */
  private inBackground: boolean = true;

  /** Called once from EntryAbility through ServiceLocator. */
  init(notifications: Notifications, openErrorPage: ErrorPageOpener): void {
    this.notifications = notifications;
    this.openErrorPage = openErrorPage;
    this.registerUncaughtHandler();
  }

  setInBackground(inBackground: boolean): void {
    this.inBackground = inBackground;
  }

  setSnackbarPresenter(presenter: SnackbarPresenter): void {
    this.snackbarPresenter = presenter;
  }

  /**
   * The ACRA substitution: catch what nothing else caught and route it into the same
   * ErrorInfo pipeline the app already had.
   */
  private registerUncaughtHandler(): void {
    if (this.observerId !== -1) {
      return;
    }
    const observer: errorManager.ErrorObserver = {
      onUnhandledException: (errMsg: string): void => {
        const throwable: Error = new Error(errMsg);
        this.openActivity(ErrorInfo.fromThrowable(throwable, UserAction.UI_ERROR,
          'Uncaught exception'));
      }
    };
    this.observerId = errorManager.on('error', observer);
  }

  /** Releases the observer (Rule 8); called from EntryAbility.onDestroy. */
  async release(): Promise<void> {
    if (this.observerId === -1) {
      return;
    }
    const id: number = this.observerId;
    this.observerId = -1;
    try {
      await errorManager.off('error', id);
    } catch (err) {
      // the observer is gone either way
    }
  }

  /**
   * Port of ErrorUtil.openActivity(context, errorInfo): the error page, unless the app is in the
   * background, in which case a notification.
   */
  openActivity(errorInfo: ErrorInfo): void {
    if (this.inBackground) {
      this.createNotification(errorInfo);
      return;
    }
    const opener: ErrorPageOpener | null = this.openErrorPage;
    if (opener === null) {
      this.createNotification(errorInfo);
      return;
    }
    opener(errorInfo.toJson());
  }

  /**
   * Port of ErrorUtil.showSnackbar(context, errorInfo): a non-intrusive message for an error
   * that is not critical, whose REPORT action opens the error page. Falls back to a notification
   * when there is no UI to show it on.
   */
  showSnackbar(errorInfo: ErrorInfo): void {
    try {
      const message: string = Localization.getStringArgs(errorInfo.message.stringName,
        errorInfo.message.formatArgs);
      const presenter: SnackbarPresenter | null = this.snackbarPresenter;
      if (presenter !== null) {
        presenter(message, Localization.getString('error_snackbar_action').toUpperCase(),
          (): void => {
            this.openActivity(errorInfo);
          });
        return;
      }
      promptAction.showToast({
        message: message,
        duration: 4000
      });
    } catch (err) {
      // no UI context available: fall back to a notification, as the source does with no root view
      this.createNotification(errorInfo);
    }
  }

  /** Port of ErrorUtil.showUiErrorSnackbar(context, request, throwable). */
  showUiErrorSnackbar(request: string, throwable: Error): void {
    this.showSnackbar(ErrorInfo.fromThrowable(throwable, UserAction.UI_ERROR, request));
  }

  /**
   * Port of ErrorUtil.createNotification(context, errorInfo): a silent notification whose tap
   * opens the error page, plus the toast the source shows alongside it "otherwise the user is
   * confused".
   */
  createNotification(errorInfo: ErrorInfo): void {
    const notifications: Notifications | null = this.notifications;
    if (notifications !== null) {
      notifications.publishErrorReport(ERROR_REPORT_NOTIFICATION_ID, errorInfo)
        .catch((): void => {
          // a notification that cannot be posted must not raise a second error
        });
    }
    try {
      promptAction.showToast({
        message: Localization.getString('error_report_notification_toast'),
        duration: 2000
      });
    } catch (err) {
      // no UI context: the notification alone carries the report
    }
  }
}
