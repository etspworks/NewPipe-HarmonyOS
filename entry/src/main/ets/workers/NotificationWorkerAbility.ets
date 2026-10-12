/*
 * Port of NotificationWorker.createWork(): the periodic new-streams check, run by WorkScheduler in
 * its own extension process. It wires only what the check needs - the preference store, the
 * strings, the extractor and the notification poster - because the app's ServiceLocator holds
 * pieces this process may not load (the continuous-task and media modules are blocked here).
 *
 * The flow is the source's: nothing unless new-streams notifications are on in the app and on the
 * device; load the feed of every channel with notifications on, ignoring the outdated threshold;
 * one notification per channel that really has new streams.
 */

import { workScheduler, WorkSchedulerExtensionAbility } from '@kit.BackgroundTasksKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { AppPreferences } from '../common/prefs/Preferences';
import { Localization } from '../common/i18n/Localization';
import { Notifications } from '../common/notify/Notifications';
import { NewPipe } from '../common/extractor/core/NewPipe';
import { Localization as ExtractorLocalization } from '../common/extractor/downloader/Localization';
import { ContentCountry } from '../common/extractor/localization/ContentCountry';
import { DownloaderImpl } from '../common/net/Downloader';
import { ReCaptchaCookieStore } from '../common/net/ReCaptchaCookieStore';
import { PeertubeInstances } from '../common/extractor/PeertubeInstances';
import { FeedLoader } from '../common/feed/FeedLoader';
import { FeedUpdateInfo } from '../model/app/FeedUpdateInfo';
import { youtube_restricted_mode_enabled } from '../common/prefs/SettingsKeys';

const TAG: string = 'NotificationWorker';
/** The ability a tapped notification opens. */
const ENTRY_ABILITY: string = 'EntryAbility';

export default class NotificationWorkerAbility extends WorkSchedulerExtensionAbility {
  onWorkStart(work: workScheduler.WorkInfo): void {
    hilog.info(0x0000, TAG, 'onWorkStart %{public}d', work.workId);
    this.checkNewStreams().catch((err: Error): void => {
      // doOnError: logged; the source's error notification needs the app's error page.
      hilog.error(0x0000, TAG, 'Error while displaying streams notifications: %{public}s',
        err.message);
    });
  }

  onWorkStop(work: workScheduler.WorkInfo): void {
    hilog.info(0x0000, TAG, 'onWorkStop %{public}d', work.workId);
  }

  private async checkNewStreams(): Promise<void> {
    const prefs: AppPreferences = new AppPreferences();
    prefs.init(this.context);
    Localization.init(this.context, prefs, false);
    const notifications: Notifications = new Notifications();
    notifications.init(this.context.applicationInfo.name, ENTRY_ABILITY, prefs);
    if (!await notifications.areNewStreamsNotificationsEnabled()) {
      // the user can disable streams notifications in the device's app settings
      return;
    }

    // App.onCreate's extractor half: the downloader, the content language/country, the cookies
    // and the selected PeerTube instance - the same calls EntryAbility makes.
    const localization: ExtractorLocalization | null =
      ExtractorLocalization.fromLocalizationCode(Localization.getPreferredLocalization());
    const country: string = Localization.getPreferredContentCountry();
    NewPipe.init(DownloaderImpl.getInstance(),
      localization !== null ? localization : ExtractorLocalization.DEFAULT,
      country.length > 0 ? new ContentCountry(country) : null);
    ReCaptchaCookieStore.getInstance().restoreToDownloader();
    DownloaderImpl.getInstance().updateYoutubeRestrictedModeCookies(
      prefs.getBooleanSync(youtube_restricted_mode_enabled, false));
    PeertubeInstances.initFromPreferences();

    const loader: FeedLoader = await FeedLoader.of(this.context);
    const feed: FeedUpdateInfo[] =
      await loader.startLoading(FeedLoader.GROUP_NOTIFICATION_ENABLED, true);
    let posted: number = 0;
    for (const info of feed) {
      // filter out feedUpdateInfo items (i.e. channels) with nothing new
      if (info.newStreams.length > 0) {
        await notifications.displayNewStreamsNotifications(info);
        posted++;
      }
    }
    hilog.info(0x0000, TAG, 'checked %{public}d channel(s), %{public}d with new streams',
      feed.length, posted);
  }
}
