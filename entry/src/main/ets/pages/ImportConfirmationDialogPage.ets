/**
 * S4 - ImportConfirmationDialog (screen_import_confirmation_dialog). presentation: modal.
 *
 * NOT a routed page: an OVERLAY whose hostScreen is screen_subscriptions_import. It is mounted
 * with a CustomDialogController in SubscriptionsImportFragmentPage, which is the shape of the
 * source - ImportConfirmationDialog.onCreateDialog returns a plain AlertDialog with NO layout at
 * all (read verbatim, codegraph):
 *   setMessage(R.string.import_network_expensive_warning)
 *   setCancelable(true)                     -> autoCancel on the host's controller
 *   setNegativeButton(R.string.cancel, null)-> dismiss, enqueue nothing
 *   setPositiveButton(R.string.ok, ...)     -> the whole behaviour of this screen
 * The positive branch, in order: Constraints(NetworkType.CONNECTED); read the
 * SubscriptionImportInput out of the arguments Bundle; OneTimeWorkRequest for
 * SubscriptionImportWorker with setInputData(input.toData()) and
 * setExpedited(RUN_AS_NON_EXPEDITED_WORK_REQUEST); WorkManager.enqueueUniqueWork(
 * SubscriptionImportWorker.WORK_NAME, APPEND_OR_REPLACE, req); then dismiss().
 *
 * THE IMPORT ITSELF NEVER RUNS HERE - this screen only enqueues. `show(fragment, input)` builds a
 * NEW dialog whose arguments bundle carries that input, so the value this dialog acts on is its
 * OWN argument, handed over at open() time by the host (never a literal, never host state read
 * behind its back). The enqueue lives in the host, which owns svc_background_work and
 * svc_subscription_manager; this dialog hands it the input it was created with and dismisses.
 *
 * The two buttons are AlertDialog BUTTON_POSITIVE / BUTTON_NEGATIVE: they have no android:id at
 * all, so their only identity is their text and .id('OK') / .id('Cancel') is the slug the capture
 * recorded (action contract S0142).
 */
import { hilog } from '@kit.PerformanceAnalysisKit';

const TAG: string = 'ImportConfirmationDialog';

/**
 * S6 - the AlertDialog button's own press feedback, the one state S5 left unstyled. A borderless
 * AppCompat dialog button rests on the card and ripples with ?attr/colorControlHighlight, which
 * is #1F000000 in the light theme. NewPipe's own light_ripple_color is deliberately NOT used
 * here: S0142 is a plain AppCompat dialog (353747 pure-white pixels, not the app's themed
 * light_dialog_background_color), so the app token would be the right value on the wrong dialog.
 */
@Styles
function dialogButtonNormal() {
  .backgroundColor(Color.Transparent)
}

@Styles
function dialogButtonPressed() {
  .backgroundColor('#1F000000')
}

/**
 * SubscriptionImportWorker.kt:227 - `sealed class SubscriptionImportInput` and its three modes:
 *   ChannelUrlMode(serviceId, url) / InputStreamMode(serviceId, url) / PreviousExportMode(url).
 * It is the dialog's one argument, so it is declared with the dialog rather than in the data
 * layer, which already exposes the three import calls it maps onto (SubscriptionManager).
 */
export enum SubscriptionImportMode {
  /** ChannelUrlMode: a channel/user page the service turns into a subscription list. */
  CHANNEL_URL,
  /** InputStreamMode: a service export file the user picked (may be a Takeout zip). */
  INPUT_STREAM,
  /** PreviousExportMode: a file this app exported before - always JSON. */
  PREVIOUS_EXPORT
}

export class SubscriptionImportInput {
  // Plain fields, not `readonly`: the dialog takes this as an @Prop, which deep-copies the value
  // on the way in - the same one-way hand-over the arguments Bundle was.
  mode: SubscriptionImportMode;
  /** PreviousExportMode carries no service; the export file names one per item. */
  serviceId: number;
  /** The channel url, or the picked file's uri. */
  url: string;
  /** The picked file's MIME type; null for a previous export (SubscriptionManager's contract). */
  contentType: string | null;

  constructor(mode: SubscriptionImportMode, serviceId: number, url: string,
    contentType: string | null) {
    this.mode = mode;
    this.serviceId = serviceId;
    this.url = url;
    this.contentType = contentType;
  }

  static channelUrl(serviceId: number, url: string): SubscriptionImportInput {
    return new SubscriptionImportInput(SubscriptionImportMode.CHANNEL_URL, serviceId, url, null);
  }

  static inputStream(serviceId: number, fileUri: string,
    contentType: string): SubscriptionImportInput {
    return new SubscriptionImportInput(SubscriptionImportMode.INPUT_STREAM, serviceId, fileUri,
      contentType);
  }

  static previousExport(serviceId: number, fileUri: string): SubscriptionImportInput {
    return new SubscriptionImportInput(SubscriptionImportMode.PREVIOUS_EXPORT, serviceId, fileUri,
      null);
  }
}

@CustomDialog
export struct ImportConfirmationDialogPage {
  controller?: CustomDialogController;
  /** requireArguments()'s INPUT key: what show(fragment, input) put in the bundle. */
  @Prop importInput: SubscriptionImportInput = SubscriptionImportInput.channelUrl(0, '');
  /**
   * BUTTON_POSITIVE's WorkManager.enqueueUniqueWork(...). The host supplies it when it opens the
   * dialog; an unbound dialog says so rather than silently swallowing the confirmation.
   */
  onConfirm: (input: SubscriptionImportInput) => void = (input: SubscriptionImportInput): void => {
    hilog.warn(0x0000, TAG, 'confirmed but no enqueue is bound: mode=%{public}d url=%{public}s',
      input.mode, input.url);
  };

  /**
   * S5 - the AlertDialog idiom, measured off S0142 (1080px / 360vp, density 3.0). The card's own
   * white rect is x 75..1004, y 968..1443: 310vp wide, 158.3vp tall, centred, corners ~1.3vp.
   * Down the card: textSpacerNoTitle 18vp ([1022-968]/3), the message block 78.7vp (4 lines at
   * 19.7vp), a 4vp gap, the 42vp button row ([1396-1270]/3), 16vp below it. The message ink starts
   * 24.3vp in from the card edge - AlertDialog's 24dp horizontal padding.
   *
   * Colours are sampled, not assumed: the card is #FFFFFF (NOT the app's own
   * light_dialog_background_color #EEEEEE - this is a plain AppCompat AlertDialog, and 353747 of
   * its pixels are pure white), the message is #212121 = textColorPrimary #DE000000 over white,
   * and both button labels are pure #000000, uppercased by Android's textAllCaps button style.
   */
  build() {
    Column() {
      Text($r('app.string.import_network_expensive_warning'))
        .width('100%')
        .fontSize(16)
        .fontColor($r('app.color.on_surface'))
        .lineHeight(20)
        .margin({ top: 18 })
        .padding({ left: 24, right: 24 })

      Row() {
        // BUTTON_NEGATIVE - `setNegativeButton(R.string.cancel, null)`. A null listener is not an
        // unwired button: AlertDialog dismisses on any button press, and cancel's whole behaviour
        // is that dismissal WITHOUT an enqueue. close() is that behaviour, in full.
        // The label keeps its string resource; the child form only carries textAllCaps, which
        // ButtonAttribute cannot express (labelStyle has no text case).
        Button() {
          Text($r('app.string.cancel'))
            .textCase(TextCase.UpperCase)
            .fontSize(14)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.accent'))
        }
        .id('Cancel')
        .type(ButtonType.Normal)
        .stateStyles({ normal: dialogButtonNormal, pressed: dialogButtonPressed })
        .height(42)
        .padding({ left: 16, right: 16 })
        .onClick(() => {
          this.controller?.close();
        })

        // BUTTON_POSITIVE - enqueue the unique import work, THEN dismiss(), in the source's order.
        Button() {
          Text($r('app.string.ok'))
            .textCase(TextCase.UpperCase)
            .fontSize(14)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.accent'))
        }
        .id('OK')
        .type(ButtonType.Normal)
        .stateStyles({ normal: dialogButtonNormal, pressed: dialogButtonPressed })
        .height(42)
        .padding({ left: 16, right: 16 })
        .onClick(() => {
          this.onConfirm(this.importInput);
          this.controller?.close();
        })
      }
      .width('100%')
      .justifyContent(FlexAlign.End)
      .margin({ top: 4 })
      .padding({ right: 16, bottom: 16 })
    }
    .width('100%')
    .backgroundColor($r('app.color.dialog_surface'))
    .borderRadius(2)
  }
}
