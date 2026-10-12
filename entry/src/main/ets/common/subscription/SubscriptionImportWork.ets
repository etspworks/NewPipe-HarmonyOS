/**
 * SubscriptionImportWorker, as the WorkManager job the confirmation dialog enqueues.
 *
 * It used to live inside SubscriptionsImportFragmentPage, which is why only that screen could
 * run an import. "Import from > Previous export" is not a screen in the source - it launches the
 * file picker straight from the Subscriptions overflow - so the job moved here, where both
 * callers reach it.
 */
import { promptAction } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { connection } from '@kit.NetworkKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { SubscriptionImportInput, SubscriptionImportMode } from '../../pages/ImportConfirmationDialogPage';
import { SubscriptionManager } from '../db/SubscriptionManager';
import { SubscriptionItem } from '../../model/app/SubscriptionData';
import { ServiceLocator } from '../di/ServiceLocator';
import { BackgroundWorkMode } from '../background/BackgroundWork';
import { CancellableProgress, IMPORT_CANCEL_EVENT, IMPORT_NOTIFICATION_ID } from '../notify/Notifications';
import { Localization } from '../i18n/Localization';

const TAG: string = 'SubscriptionImportWork';

/** SubscriptionImportWorker.WORK_NAME - the unique name the source enqueues the import under. */
const IMPORT_WORK_NAME: string = 'SubscriptionImportWorker';

/**
 * WorkManager.enqueueUniqueWork(WORK_NAME, APPEND_OR_REPLACE, req).
 *
 * androidx.work is not on HarmonyOS (dependency-decisions.json: androidx.work ->
 * BackgroundTasksKit), so the "unique work" queue is this promise chain keyed by the same unique
 * name: a second confirmation APPENDS to the running import instead of racing it, which is what
 * APPEND_OR_REPLACE buys. The job itself runs inside svc_background_work's dataTransfer
 * continuous task, so it survives the app going to the background the way the worker did.
 *
 * ponytail: a module-level chain, not a job store - WorkManager's persistence across a reboot is
 * already given up in common/background/BackgroundWork.ts, and one import chain is all the source
 * ever has.
 */
const importQueue: Map<string, Promise<void>> = new Map<string, Promise<void>>();

/** WorkManager.enqueueUniqueWork(WORK_NAME, APPEND_OR_REPLACE, req) - see importQueue. */
export function enqueueSubscriptionImport(context: common.Context,
  input: SubscriptionImportInput): void {
  const running: Promise<void> | undefined = importQueue.get(IMPORT_WORK_NAME);
  const head: Promise<void> = running === undefined ? Promise.resolve() : running;
  importQueue.set(IMPORT_WORK_NAME, head.then((): Promise<void> => runImport(context, input))
    .catch((err: BusinessError): void => {
      hilog.error(0x0000, TAG, 'import work failed: %{public}s', err.message);
    }));
}

/**
 * SubscriptionImportWorker.doWork(): loadSubscriptionsFromInput(input) then upsertAll of every
 * channel it resolves. Both halves live in svc_subscription_manager; the failure toast is the
 * worker's own Result.failure() path.
 */
async function runImport(context: common.Context,
  input: SubscriptionImportInput): Promise<void> {
  // Constraints.Builder().setRequiredNetworkType(NetworkType.CONNECTED): the source will not
  // even start the worker without a network, and the import is a long series of extractions.
  if (!hasNetwork()) {
    promptAction.showToast({
      message: $r('app.string.subscriptions_import_unsuccessful'), duration: 2000
    });
    return;
  }
  // createForegroundInfo(): the ongoing row, whose Cancel is createCancelPendingIntent(id).
  let cancelled: boolean = false;
  const notification: CancellableProgress = new CancellableProgress(
    ServiceLocator.get().notifications, IMPORT_NOTIFICATION_ID, IMPORT_CANCEL_EVENT);
  await notification.start((): void => {
    cancelled = true;
  });
  await ServiceLocator.get().backgroundWork.runWithBackgroundTask<void>(
    BackgroundWorkMode.DATA_TRANSFER, async (): Promise<void> => {
      try {
        const manager: SubscriptionManager = await SubscriptionManager.of(context);
        const items: SubscriptionItem[] =
          input.mode === SubscriptionImportMode.CHANNEL_URL
            ? await manager.importFromChannelUrl(input.serviceId, input.url)
            : await manager.importFromFile(input.serviceId, input.url, input.contentType);
        const title: string = Localization.getQuantity('import_subscriptions', '', items.length,
          items.length);
        // setForeground(createForegroundInfo(title)): the count is known from here on.
        notification.update(title, `0/${items.length}`);
        await manager.importSubscriptions(items, (done: number, channelName: string): void => {
          notification.update(title, `${channelName}  (${done}/${items.length})`);
        }, (): boolean => cancelled);
        // A cancelled worker ends without a word; only a finished one says so.
        if (!cancelled) {
          promptAction.showToast({
            message: $r('app.string.import_complete_toast'), duration: 2000
          });
        }
      } catch (err) {
        const error: BusinessError = err as BusinessError;
        hilog.error(0x0000, TAG, 'Error while processing subscription data: %{public}s',
          error.message);
        promptAction.showToast({
          message: $r('app.string.subscriptions_import_unsuccessful'), duration: 2000
        });
      } finally {
        await notification.finish();
      }
    });
}

/** NetworkType.CONNECTED. */
function hasNetwork(): boolean {
  try {
    return connection.hasDefaultNetSync();
  } catch (err) {
    // Unreadable connectivity is not a reason to refuse the import; the extraction reports it.
    return true;
  }
}
