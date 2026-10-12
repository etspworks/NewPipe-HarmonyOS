/*
 * svc_notification - port of app/src/main/java/org/schabi/newpipe/local/feed/notifications/
 * NotificationHelper.kt, the update notification of NewVersionWorker.kt, and the error-report
 * notification of ErrorUtil.kt.
 *
 * Permission (phase2-logic-contract.md section 2.6, self-signed-capabilities.md): NO
 * `NOTIFICATION_CONTROLLER`. It is a system_core permission that a self-signed build cannot be
 * granted and whose presence gets the install REJECTED. Publishing a notification does not need
 * it - `notificationManager.publish` works without any permission - and media controls come from
 * AVSession, not from a notification this module posts. `module.json5` is not touched.
 *
 * Android notification CHANNELS map to HarmonyOS notification SLOTS, which are types rather than
 * app-defined ids: the source's three channels (streams / error report / app update) become
 * SOCIAL_COMMUNICATION, SERVICE_INFORMATION and CONTENT_INFORMATION. `areNotificationsEnabled()`
 * is the port of areNotificationsEnabledOnDevice(): a user can switch them off per app here too.
 *
 * The tap targets are WantAgents that deep-link back into this app through
 * `want.parameters.targetPage`, which is the same routing EntryAbility uses for every other
 * launch (the source used PendingIntents built by NavigationHelper).
 */

import { notificationManager } from '@kit.NotificationKit';
import { common, wantAgent, WantAgent } from '@kit.AbilityKit';
import { BusinessError, commonEventManager } from '@kit.BasicServicesKit';
import { image } from '@kit.ImageKit';
import { FeedUpdateInfo } from '../../model/app/FeedUpdateInfo';
import { StreamInfoItem } from '../../model/extractor/StreamInfoItem';
import { ErrorInfo } from '../../model/app/ErrorInfo';
import { Localization } from '../i18n/Localization';
import { loadPixelMap } from '../image/ImageLoader';
import { AppPreferences } from '../prefs/Preferences';
import { enable_streams_notifications } from '../prefs/SettingsKeys';
import { javaStringHashCode } from '../../model/app/FeedUpdateInfo';

/** NewVersionWorker's notification id, verbatim. */
export const UPDATE_NOTIFICATION_ID: number = 2000;

/** FeedLoadService.NOTIFICATION_ID, verbatim. */
export const FEED_LOAD_NOTIFICATION_ID: number = 7293450;
/** FeedLoadService.ACTION_CANCEL, verbatim: what its notification's Cancel button sends. */
export const FEED_LOAD_CANCEL_EVENT: string =
  'org.schabi.newpipe.local.feed.service.FeedLoadService.CANCEL';
/** SubscriptionImportWorker.NOTIFICATION_ID, verbatim. */
export const IMPORT_NOTIFICATION_ID: number = 4568;
/**
 * The import's Cancel event. The source's button is WorkManager.createCancelPendingIntent(id);
 * with no WorkManager here it is the same kind of broadcast FeedLoadService uses.
 */
export const IMPORT_CANCEL_EVENT: string =
  'org.schabi.newpipe.local.subscription.workers.SubscriptionImportWorker.CANCEL';
/** FeedLoadService.NOTIFICATION_SAMPLING_PERIOD: how often an ongoing row is re-posted. */
const PROGRESS_SAMPLING_PERIOD_MS: number = 1500;

export class Notifications {
  private bundleName: string = '';
  private abilityName: string = 'EntryAbility';
  private prefs: AppPreferences | null = null;

  /** Called once from EntryAbility through ServiceLocator. */
  init(bundleName: string, abilityName: string, prefs: AppPreferences): void {
    this.bundleName = bundleName;
    this.abilityName = abilityName;
    this.prefs = prefs;
  }

  /**
   * Port of NotificationHelper.areNotificationsEnabledOnDevice(context): the user can disable
   * this app's notifications in system settings.
   */
  async areNotificationsEnabledOnDevice(): Promise<boolean> {
    try {
      return await notificationManager.isNotificationEnabled();
    } catch (err) {
      return false;
    }
  }

  /**
   * Port of NotificationHelper.areNewStreamsNotificationsEnabled(context): the app setting AND
   * the device setting, both.
   */
  async areNewStreamsNotificationsEnabled(): Promise<boolean> {
    const prefs: AppPreferences | null = this.prefs;
    if (prefs === null) {
      return false;
    }
    if (!prefs.getBooleanSync(enable_streams_notifications, false)) {
      return false;
    }
    return await this.areNotificationsEnabledOnDevice();
  }

  /** A WantAgent that cold-launches this app straight onto one page, with its parameters. */
  private async pageWantAgent(targetPage: string,
    params: Record<string, Object>): Promise<WantAgent> {
    const merged: Record<string, Object> = {};
    for (const key of Object.keys(params)) {
      merged[key] = params[key];
    }
    merged['targetPage'] = targetPage;

    const info: wantAgent.WantAgentInfo = {
      wants: [{
        bundleName: this.bundleName,
        abilityName: this.abilityName,
        parameters: merged
      }],
      actionType: wantAgent.OperationType.START_ABILITY,
      requestCode: javaStringHashCode(targetPage),
      wantAgentFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
    };
    return await wantAgent.getWantAgent(info);
  }

  /**
   * Port of displayNewStreamsNotifications(data): a grouped summary notification per channel,
   * plus one silent notification per new stream.
   */
  async displayNewStreamsNotifications(data: FeedUpdateInfo): Promise<void> {
    if (!await this.areNewStreamsNotificationsEnabled()) {
      return;
    }

    const newStreams: StreamInfoItem[] = data.newStreams;
    if (newStreams.length === 0) {
      return;
    }

    const summary: string = Localization.getQuantity('new_streams', '', newStreams.length,
      `${newStreams.length}`);

    // the source's InboxStyle summary: one line per new stream
    const lines: string[] = [];
    for (const stream of newStreams) {
      lines.push(stream.getName());
    }

    const avatarIcon: image.PixelMap | null = await loadPixelMap(data.avatarUrl);

    // opening the summary opens the channel page
    const channelWant: WantAgent = await this.pageWantAgent('ChannelFragment', {
      'serviceId': data.serviceId,
      'url': data.url,
      'name': data.name
    });

    const request: notificationManager.NotificationRequest = {
      id: data.pseudoId,
      notificationSlotType: notificationManager.SlotType.SOCIAL_COMMUNICATION,
      content: {
        notificationContentType: notificationManager.ContentType.NOTIFICATION_CONTENT_MULTILINE,
        multiLine: {
          title: data.name,
          text: summary,
          briefText: summary,
          longTitle: data.name,
          lines: lines
        }
      },
      groupName: data.url,
      badgeNumber: newStreams.length,
      tapDismissed: true,
      wantAgent: channelWant
    };
    if (avatarIcon !== null) {
      request.largeIcon = avatarIcon;
    }

    await this.publishQuietly(request);
    await this.showStreamNotifications(newStreams, data.serviceId, avatarIcon);
  }

  /** Port of the private showStreamNotifications(newStreams, serviceId, channelIcon). */
  private async showStreamNotifications(newStreams: StreamInfoItem[], serviceId: number,
    channelIcon: image.PixelMap | null): Promise<void> {
    for (const stream of newStreams) {
      // opening a stream notification plays it, as the source's getStreamIntent does
      const streamWant: WantAgent = await this.pageWantAgent('VideoDetailFragment', {
        'serviceId': serviceId,
        'url': stream.getUrl(),
        'name': stream.getName()
      });

      const request: notificationManager.NotificationRequest = {
        id: javaStringHashCode(stream.getUrl()),
        notificationSlotType: notificationManager.SlotType.SOCIAL_COMMUNICATION,
        content: {
          notificationContentType: notificationManager.ContentType.NOTIFICATION_CONTENT_BASIC_TEXT,
          normal: {
            title: stream.getName(),
            text: stream.getUploaderName()
          }
        },
        groupName: stream.getUploaderUrl() === null ? '' : stream.getUploaderUrl() as string,
        tapDismissed: true,
        // silent: avoid creating noise for individual stream notifications
        isAlertOnce: true,
        wantAgent: streamWant
      };
      if (channelIcon !== null) {
        request.largeIcon = channelIcon;
      }
      await this.publishQuietly(request);
    }
  }

  /**
   * Port of NewVersionWorker.compareAppVersionAndShowNotification()'s notification half:
   * tapping it opens the apk location in a browser.
   */
  async publishUpdateAvailable(versionName: string, apkLocationUrl: string): Promise<void> {
    if (!await this.areNotificationsEnabledOnDevice()) {
      return;
    }
    const info: wantAgent.WantAgentInfo = {
      wants: [{ action: 'ohos.want.action.viewData', uri: apkLocationUrl }],
      actionType: wantAgent.OperationType.START_ABILITY,
      requestCode: UPDATE_NOTIFICATION_ID,
      wantAgentFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
    };
    const agent: WantAgent = await wantAgent.getWantAgent(info);

    const request: notificationManager.NotificationRequest = {
      id: UPDATE_NOTIFICATION_ID,
      notificationSlotType: notificationManager.SlotType.CONTENT_INFORMATION,
      content: {
        notificationContentType: notificationManager.ContentType.NOTIFICATION_CONTENT_BASIC_TEXT,
        normal: {
          title: Localization.getString('app_update_available_notification_title'),
          text: Localization.getStringArgs('app_update_available_notification_text', [versionName])
        }
      },
      tapDismissed: true,
      wantAgent: agent
    };
    await this.publishQuietly(request);
  }

  /**
   * Port of ErrorUtil.createNotification()'s notification half: silent, and tapping it opens the
   * error page with the ErrorInfo.
   */
  async publishErrorReport(notificationId: number, errorInfo: ErrorInfo): Promise<void> {
    if (!await this.areNotificationsEnabledOnDevice()) {
      return;
    }
    const agent: WantAgent = await this.pageWantAgent('ErrorActivity', {
      'errorInfo': JSON.stringify(errorInfo.toJson())
    });

    const request: notificationManager.NotificationRequest = {
      id: notificationId,
      notificationSlotType: notificationManager.SlotType.SERVICE_INFORMATION,
      content: {
        notificationContentType: notificationManager.ContentType.NOTIFICATION_CONTENT_BASIC_TEXT,
        normal: {
          title: Localization.getString('error_report_notification_title'),
          text: Localization.getStringArgs(errorInfo.message.stringName,
            errorInfo.message.formatArgs)
        }
      },
      tapDismissed: true,
      isAlertOnce: true,
      wantAgent: agent
    };
    await this.publishQuietly(request);
  }

  /**
   * The platform's "Allow notifications?" prompt, asked once, where the source asks for
   * POST_NOTIFICATIONS: at the moment a download starts.
   *
   * `requestEnableNotification` resolves when the user allows or has already allowed, and rejects
   * straight away (1600004) once they have denied it - so this never nags. A denial leaves the
   * Settings > Notifications row as the way back, which is what it is for.
   */
  async ensureEnabled(context: common.UIAbilityContext): Promise<boolean> {
    try {
      if (await notificationManager.isNotificationEnabled()) {
        return true;
      }
      await notificationManager.requestEnableNotification(context);
      return true;
    } catch (err) {
      return false;
    }
  }

  /**
   * Port of DownloadManagerService's plain download rows (the ongoing one and the failed ones).
   * Tapping opens DownloadActivity - the Downloads screen with its toolbar - as mOpenDownloadList
   * does; the bare MissionsFragment page it used to open has neither title nor menu.
   */
  async publishDownloadProgress(notificationId: number, title: string, text: string,
    ongoing: boolean): Promise<void> {
    if (!await this.areNotificationsEnabledOnDevice()) {
      return;
    }
    const agent: WantAgent = await this.pageWantAgent('DownloadActivity', {});
    const request: notificationManager.NotificationRequest = {
      id: notificationId,
      notificationSlotType: notificationManager.SlotType.SERVICE_INFORMATION,
      content: {
        notificationContentType: notificationManager.ContentType.NOTIFICATION_CONTENT_BASIC_TEXT,
        normal: { title: title, text: text }
      },
      isOngoing: ongoing,
      isAlertOnce: true,
      tapDismissed: !ongoing,
      wantAgent: agent
    };
    await this.publishQuietly(request);
  }

  /**
   * Port of FeedLoadService.createNotification() / SubscriptionImportWorker.createForegroundInfo():
   * an ongoing row with ONE action, Cancel. A third-party notification draws at most two actions,
   * so the source's single button fits. The button is a WantAgent that sends `cancelEvent` as a
   * common event addressed to this bundle only - the source's RECEIVER_NOT_EXPORTED broadcast -
   * and CancellableProgress turns it back into a call. Never throws: a row that cannot be posted
   * must not take the job down with it.
   */
  async publishCancellableProgress(notificationId: number, title: string, text: string,
    cancelEvent: string): Promise<void> {
    try {
      if (!await this.areNotificationsEnabledOnDevice()) {
        return;
      }
      const info: wantAgent.WantAgentInfo = {
        wants: [{ bundleName: this.bundleName, action: cancelEvent }],
        actionType: wantAgent.OperationType.SEND_COMMON_EVENT,
        requestCode: notificationId,
        wantAgentFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
      };
      const cancelAgent: WantAgent = await wantAgent.getWantAgent(info);
      const request: notificationManager.NotificationRequest = {
        id: notificationId,
        notificationSlotType: notificationManager.SlotType.SERVICE_INFORMATION,
        content: {
          notificationContentType: notificationManager.ContentType.NOTIFICATION_CONTENT_BASIC_TEXT,
          normal: { title: title, text: text }
        },
        actionButtons: [{ title: Localization.getString('cancel'), wantAgent: cancelAgent }],
        isOngoing: true,
        isAlertOnce: true,
        // the row stays until the job has actually stopped and finish() removes it
        tapDismissed: false
      };
      await this.publishQuietly(request);
    } catch (err) {
      // no WantAgent, no row: the job runs on, as it did before it had one
    }
  }

  /**
   * DownloadManagerService.notifyFinishedDownload()'s row: BigTextStyle becomes a long-text
   * notification, the count as its title and the finished file names as its body.
   */
  async publishDownloadsFinished(notificationId: number, title: string,
    names: string): Promise<void> {
    if (!await this.areNotificationsEnabledOnDevice()) {
      return;
    }
    const agent: WantAgent = await this.pageWantAgent('DownloadActivity', {});
    // setDeleteIntent(ACTION_RESET_DOWNLOAD_FINISHED). A removalWantAgent may only publish a
    // common event (it cannot start an ability), which onDownloadsFinishedRemoved() receives.
    const removalInfo: wantAgent.WantAgentInfo = {
      wants: [{ action: this.downloadsFinishedRemovedEvent() }],
      actionType: wantAgent.OperationType.SEND_COMMON_EVENT,
      requestCode: notificationId,
      wantAgentFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
    };
    const removal: WantAgent = await wantAgent.getWantAgent(removalInfo);
    const request: notificationManager.NotificationRequest = {
      id: notificationId,
      notificationSlotType: notificationManager.SlotType.SERVICE_INFORMATION,
      removalWantAgent: removal,
      content: {
        notificationContentType: notificationManager.ContentType.NOTIFICATION_CONTENT_LONG_TEXT,
        longText: {
          title: title,
          text: names,
          longText: names,
          // none of the three long-text fields may be empty
          briefText: title,
          expandedTitle: title
        }
      },
      tapDismissed: true,
      wantAgent: agent
    };
    await this.publishQuietly(request);
  }

  /** DownloadManagerService.ACTION_RESET_DOWNLOAD_FINISHED: APPLICATION_ID + the action name. */
  private downloadsFinishedRemovedEvent(): string {
    return `${this.bundleName}.reset_download_finished`;
  }

  /**
   * onStartCommand(ACTION_RESET_DOWNLOAD_FINISHED): `reset` runs whenever the finished row is
   * removed - swiped away, cleared with the rest of the shade, or tapped (which opens the
   * Downloads screen, whose clear resets the count anyway). The subscription lives as long as
   * the process does, which is as long as the count itself does.
   */
  async onDownloadsFinishedRemoved(reset: () => void): Promise<void> {
    const info: commonEventManager.CommonEventSubscribeInfo = {
      events: [this.downloadsFinishedRemovedEvent()]
    };
    const subscriber: commonEventManager.CommonEventSubscriber =
      await commonEventManager.createSubscriber(info);
    commonEventManager.subscribe(subscriber,
      (err: BusinessError, data: commonEventManager.CommonEventData): void => {
        if (err) {
          return;
        }
        reset();
      });
  }

  async cancel(notificationId: number): Promise<void> {
    try {
      await notificationManager.cancel(notificationId);
    } catch (err) {
      // cancelling a notification that is already gone is the success case
    }
  }

  /**
   * A notification that cannot be posted must never take the caller down with it - the source
   * guards every notify() with areNotificationsEnabled() for the same reason.
   */
  private async publishQuietly(request: notificationManager.NotificationRequest): Promise<void> {
    try {
      await notificationManager.publish(request);
    } catch (err) {
      // the user disabled notifications between the check and the publish, or the slot is off
    }
  }
}

/**
 * One running job's ongoing row - FeedLoadService's or SubscriptionImportWorker's: re-posted at
 * most every PROGRESS_SAMPLING_PERIOD_MS (the source's throttleLatest), its Cancel button wired
 * to `onCancel` while the job runs (the source's BroadcastReceiver), and removed once the job
 * ends however it ended (doOnTerminate -> notificationManager.cancel).
 */
export class CancellableProgress {
  private readonly notifications: Notifications;
  private readonly notificationId: number;
  private readonly cancelEvent: string;
  private subscriber: commonEventManager.CommonEventSubscriber | null = null;
  private lastPostedAt: number = 0;
  /** Posts run one after another, so the cancel in finish() is never overtaken by a late post. */
  private posting: Promise<void> = Promise.resolve();

  constructor(notifications: Notifications, notificationId: number, cancelEvent: string) {
    this.notifications = notifications;
    this.notificationId = notificationId;
    this.cancelEvent = cancelEvent;
  }

  /** registerReceiver(ACTION_CANCEL). Without it the row still shows; Cancel just does nothing. */
  async start(onCancel: () => void): Promise<void> {
    try {
      const info: commonEventManager.CommonEventSubscribeInfo = { events: [this.cancelEvent] };
      const subscriber: commonEventManager.CommonEventSubscriber =
        await commonEventManager.createSubscriber(info);
      commonEventManager.subscribe(subscriber, (err: BusinessError): void => {
        if (err === null || err === undefined || err.code === 0) {
          onCancel();
        }
      });
      this.subscriber = subscriber;
    } catch (err) {
      this.subscriber = null;
    }
  }

  /** updateNotificationProgress(state), sampled. */
  update(title: string, text: string): void {
    const now: number = Date.now();
    if (now - this.lastPostedAt < PROGRESS_SAMPLING_PERIOD_MS) {
      return;
    }
    this.lastPostedAt = now;
    this.posting = this.posting.then((): Promise<void> => this.notifications
      .publishCancellableProgress(this.notificationId, title, text, this.cancelEvent));
  }

  /** unregisterReceiver + notificationManager.cancel(NOTIFICATION_ID). */
  async finish(): Promise<void> {
    const subscriber: commonEventManager.CommonEventSubscriber | null = this.subscriber;
    this.subscriber = null;
    if (subscriber !== null) {
      try {
        commonEventManager.unsubscribe(subscriber);
      } catch (err) {
        // already gone
      }
    }
    await this.posting;
    await this.notifications.cancel(this.notificationId);
  }
}
