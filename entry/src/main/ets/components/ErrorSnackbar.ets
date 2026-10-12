/*
 * The Snackbar ErrorUtil.showSnackbar() raises for a non-critical error: the error message at the
 * bottom of the screen with a yellow REPORT action that opens the error report, gone after
 * Snackbar.LENGTH_LONG.
 *
 * ArkUI has no Snackbar, so this is a non-modal custom dialog pinned to the bottom. ErrorReporter
 * is a .ts service and cannot build UI, so the shell registers this presenter with it once it has
 * a UIContext; until then ErrorReporter keeps its toast.
 */
import { ComponentContent, UIContext } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { ServiceLocator } from '../common/di/ServiceLocator';

/** Snackbar.LENGTH_LONG. */
const SNACKBAR_DURATION_MS: number = 2750;

class SnackbarParams {
  readonly message: string;
  readonly actionLabel: string;
  readonly onAction: () => void;

  constructor(message: string, actionLabel: string, onAction: () => void) {
    this.message = message;
    this.actionLabel = actionLabel;
    this.onAction = onAction;
  }
}

/** Material's snackbar: light text on #323232, the action in Color.YELLOW (setActionTextColor). */
@Builder
function errorSnackbar(params: SnackbarParams) {
  Row() {
    Text(params.message)
      .id('snackbar_text')
      .layoutWeight(1)
      .fontSize(14)
      .fontColor('#DEFFFFFF')
      .maxLines(2)
      .textOverflow({ overflow: TextOverflow.Ellipsis })
    Text(params.actionLabel)
      .id('snackbar_action')
      .fontSize(14)
      .fontWeight(FontWeight.Medium)
      .fontColor(Color.Yellow)
      .padding({ left: 8, right: 8, top: 12, bottom: 12 })
      .onClick(() => {
        params.onAction();
      })
  }
  .width('100%')
  .constraintSize({ minHeight: 48 })
  .padding({ left: 16, right: 8 })
  .borderRadius(4)
  .backgroundColor('#323232')
}

/** Hands ErrorReporter a presenter bound to this window's UIContext. */
export function registerErrorSnackbar(uiContext: UIContext): void {
  ServiceLocator.get().errorReporter.setSnackbarPresenter(
    (message: string, actionLabel: string, onAction: () => void): void => {
      let content: ComponentContent<SnackbarParams> | null = null;
      const dismiss = (): void => {
        const shown: ComponentContent<SnackbarParams> | null = content;
        content = null;
        if (shown !== null) {
          uiContext.getPromptAction().closeCustomDialog(shown).catch((err: BusinessError): void => {
            hilog.warn(0x0000, 'ErrorSnackbar', 'dismiss failed: %{public}s', err.message);
          });
        }
      };
      content = new ComponentContent(uiContext, wrapBuilder(errorSnackbar),
        new SnackbarParams(message, actionLabel, (): void => {
          dismiss();
          onAction();
        }));
      uiContext.getPromptAction().openCustomDialog(content, {
        alignment: DialogAlignment.Bottom,
        isModal: false,
        autoCancel: false
      }).then((): void => {
        setTimeout(dismiss, SNACKBAR_DURATION_MS);
      }).catch((err: BusinessError): void => {
        hilog.warn(0x0000, 'ErrorSnackbar', 'show failed: %{public}s', err.message);
      });
    });
}
