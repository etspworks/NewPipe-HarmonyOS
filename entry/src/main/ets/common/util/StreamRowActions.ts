/*
 * What a stream row's context menu DOES, once for every list that has one.
 *
 * T-0118 moved the menu's entry list into buildStreamMenuActions(); these are the handlers behind
 * it. Every screen was carrying its own copy of the same three routines - start the stream in
 * place, append it to the live queue, write it into the watch history - and the screens that did
 * not carry them simply left the entries out, which is the defect T-0118 and this card report.
 */
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { promptAction } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { StreamInfoItem } from '../../model/extractor/StreamInfoItem';
import { StreamInfo } from '../../model/extractor/StreamInfo';
import { PlayQueueItem } from '../../model/app/PlayQueueItem';
import { PlayQueue, currentPlayQueue, enqueueOnCurrentPlayQueue } from '../../model/app/PlayQueue';
import { PlayerService } from '../player/PlayerService';
import { PlayerPrefs } from '../player/PlayerPrefs';

import { MediaSessionService } from '../player/MediaSessionService';
import { ExtractorHelper } from '../extractor/ExtractorHelper';
import { ServiceLocator } from '../di/ServiceLocator';
import { BackgroundWorkMode } from '../background/BackgroundWork';
import { AppDatabase } from '../db/AppDatabase';
import { HistoryRecordManager } from '../db/HistoryRecordManager';
import { Localization } from '../i18n/Localization';
import { show_hold_to_append_key } from '../prefs/SettingsKeys';

const TAG: string = 'StreamRowActions';

/**
 * NavigationHelper.playOnBackgroundPlayer() / playOnPopupPlayer(): resolve the stream, hand it to
 * the shared player and start the session, WITHOUT leaving the screen the user is on. Without the
 * session there is no AVSession and no continuous task, so the audio stops as soon as the app is
 * backgrounded.
 */
export async function startStreamInPlace(context: common.UIAbilityContext, serviceId: number,
  url: string, audioOnly: boolean): Promise<void> {
  try {
    const info: StreamInfo = await ServiceLocator.get().backgroundWork.runWithBackgroundTask(
      BackgroundWorkMode.DATA_TRANSFER,
      (): Promise<StreamInfo> => ExtractorHelper.getStreamInfo(serviceId, url, false));
    await PlayerService.getInstance().prepare(info, audioOnly,
      audioOnly ? 0 : PlayerPrefs.defaultPlaybackHeight());
    await MediaSessionService.getInstance().startDetached(context, info);
  } catch (err) {
    const failure: BusinessError = err as BusinessError;
    promptAction.showToast({ message: failure.message, duration: 2000 });
  }
}

/** NavigationHelper.enqueueOnPlayer(): APPEND to the live queue, leaving playback alone. */
export function enqueueStream(item: StreamInfoItem): void {
  enqueueOnCurrentPlayQueue([PlayQueueItem.fromStreamInfoItem(item)]);
}

/**
 * PlayButtonHelper.showHoldToAppendToastIfNeeded(): "Hold to enqueue" after a play control's tap,
 * unless show_hold_to_append is off. promptAction replaces a visible toast rather than queueing
 * behind it, so a control that toasts its own message first passes a delay of one short toast.
 */
export function showHoldToAppendTip(delayMillis: number = 0): void {
  let enabled: boolean = true;
  try {
    enabled = ServiceLocator.get().preferences.getBooleanSync(show_hold_to_append_key, true);
  } catch (err) {
    enabled = true;
  }
  if (!enabled) {
    return;
  }
  const show = (): void => {
    promptAction.showToast({ message: Localization.getString('hold_to_append'), duration: 2000 });
  };
  if (delayMillis <= 0) {
    show();
  } else {
    setTimeout(show, delayMillis);
  }
}

/**
 * NavigationHelper.enqueueOnPlayer(context, queue, type): the items join the END of the running
 * player's queue, with the "Enqueued" toast. Returns false when no player is running - there is
 * no queue to join then, and the caller starts the items in that player instead.
 */
export function enqueueAllOnPlayer(items: PlayQueueItem[]): boolean {
  promptAction.showToast({ message: Localization.getString('enqueued'), duration: 2000 });
  const player: PlayerService = PlayerService.getInstance();
  if (currentPlayQueue.getValue() === null || !player.hasPlayer()
    || player.currentInfo.getValue() === null) {
    return false;
  }
  enqueueOnCurrentPlayQueue(items);
  return true;
}

/**
 * NavigationHelper.enqueueNextOnPlayer(): the stream goes RIGHT AFTER the playing one, with the
 * source's "Enqueued next" toast.
 */
export function enqueueNextStream(item: StreamInfoItem): void {
  const queue: PlayQueue | null = currentPlayQueue.getValue();
  if (queue === null) {
    return;
  }
  promptAction.showToast({ message: Localization.getString('enqueued_next'), duration: 2000 });
  queue.enqueueNext(PlayQueueItem.fromStreamInfoItem(item), false);
}

/** StreamDialogDefaultEntry.MARK_AS_WATCHED -> recordManager.markAsWatched(item). */
export async function markStreamAsWatched(context: common.Context,
  item: StreamInfoItem): Promise<void> {
  try {
    const db: AppDatabase = await AppDatabase.getInstance(context);
    await new HistoryRecordManager(db).markAsWatched(item);
  } catch (err) {
    const failure: BusinessError = err as BusinessError;
    hilog.warn(0x0000, TAG, 'markAsWatched: %{public}s', failure.message);
    promptAction.showToast({ message: failure.message, duration: 2000 });
  }
}
