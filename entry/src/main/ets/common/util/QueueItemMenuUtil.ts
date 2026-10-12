/*
 * QueueItemMenuUtil's two actions that need more than the row: the channel of a queue item whose
 * uploader url was never filled in (fetchUploaderUrlIfSparse), and the system sound settings the
 * queue screen's overflow opens (Settings.ACTION_SOUND_SETTINGS).
 */

import { router } from '@kit.ArkUI';
import { common, Want } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { PlayQueueItem } from '../../model/app/PlayQueueItem';
import { StreamInfo } from '../../model/extractor/StreamInfo';
import { ExtractorHelper } from '../extractor/ExtractorHelper';

const TAG: string = 'QueueItemMenuUtil';

/**
 * menu_item_channel_details -> fetchUploaderUrlIfSparse(): a sparse item (one built from a list
 * that carried no uploader url) has the stream fetched first, so the channel page is never opened
 * on an empty url.
 */
export async function openChannelOfQueueItem(item: PlayQueueItem): Promise<void> {
  let url: string | null = item.getUploaderUrl();
  let name: string = item.getUploader();
  if (url === null || url.length === 0) {
    try {
      const info: StreamInfo =
        await ExtractorHelper.getStreamInfo(item.getServiceId(), item.getUrl(), false);
      url = info.getUploaderUrl();
      name = info.getUploaderName();
    } catch (err) {
      console.warn(TAG + ': uploader url not fetched: ' + (err as BusinessError).message);
    }
  }
  if (url === null || url.length === 0) {
    return;
  }
  router.pushUrl({
    url: 'pages/ChannelFragmentPage',
    params: { serviceId: item.getServiceId(), url: url, name: name }
  }).catch((err: BusinessError): void => {
    console.warn(TAG + ': channel push failed: ' + err.message);
  });
}

/** Settings.ACTION_SOUND_SETTINGS: the Settings app's own "Sounds & vibration" page. */
export function openSystemSoundSettings(context: common.UIAbilityContext): void {
  const want: Want = {
    bundleName: 'com.huawei.hmos.settings',
    abilityName: 'com.huawei.hmos.settings.MainAbility',
    uri: 'volume_settings'
  };
  context.startAbility(want).catch((err: BusinessError): void => {
    console.warn(TAG + ': sound settings not opened: ' + err.message);
  });
}
