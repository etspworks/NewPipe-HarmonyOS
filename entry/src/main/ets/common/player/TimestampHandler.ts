/*
 * InternalUrlsHandler's timestamp half: a tapped `1:23` in a description or a comment is a
 * TimestampChange for the player. The stream already playing is sought to that second; any other
 * stream is opened and starts there.
 */

import { promptAction, router } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import { StreamInfo } from '../../model/extractor/StreamInfo';
import { PlayQueue, SimplePlayQueue, currentPlayQueue, setCurrentPlayQueue } from '../../model/app/PlayQueue';
import { PlayQueueItem } from '../../model/app/PlayQueueItem';
import { ExtractorHelper } from '../extractor/ExtractorHelper';
import { MediaSessionService } from './MediaSessionService';
import { PlayableSource, PlayerService } from './PlayerService';

export function openStreamAtTimestamp(serviceId: number, streamUrl: string, seconds: number): void {
  if (streamUrl.length === 0 || seconds < 0) {
    return;
  }
  const player: PlayerService = PlayerService.getInstance();
  const playing: StreamInfo | null = player.currentInfo.getValue();
  if (playing !== null && playing.getUrl() === streamUrl && player.hasPlayer()) {
    // "If the stream is already playing, we can just seek to the appropriate timestamp."
    player.seekTo(seconds * 1000);
    player.play();
    return;
  }
  if (playing !== null && player.hasPlayer() && !player.isMainVideoPlayer()) {
    // "when playing from a timestamp, keep the current player as-is": the popup (PiP) or the
    // background player takes the stream itself instead of a main player opening over it.
    playInCurrentPlayer(playing, serviceId, streamUrl, seconds).catch((err: BusinessError): void => {
      promptAction.showToast({ message: err.message, duration: 2000 });
    });
    return;
  }
  router.pushUrl({
    url: 'pages/VideoDetailFragmentPage',
    params: { 'serviceId': `${serviceId}`, 'url': streamUrl, 'startPosition': `${seconds}` }
  }).catch((err: BusinessError): void => {
    console.warn('TimestampHandler: open failed: ' + err.message);
  });
}

/**
 * Player.handleIntent(TimestampChange) for another stream: "we add the timestamped stream behind
 * the current video and start playing it" - enqueueNext + offsetIndex(1) - in the SAME player, at
 * that second. A live queue that is not the one this playback came from (a popup or background
 * start from a list publishes none) is the source's "no queue yet" case, built around what plays.
 */
async function playInCurrentPlayer(playing: StreamInfo, serviceId: number, streamUrl: string,
  seconds: number): Promise<void> {
  const info: StreamInfo = await ExtractorHelper.getStreamInfo(serviceId, streamUrl, false);
  const item: PlayQueueItem = PlayQueueItem.fromStreamInfo(info);
  const playingItem: PlayQueueItem = PlayQueueItem.fromStreamInfo(playing);
  const live: PlayQueue | null = currentPlayQueue.getValue();
  if (live !== null && playingItem.isSameItem(live.getItem())) {
    live.enqueueNext(item, true);
    live.offsetIndex(1);
  } else {
    setCurrentPlayQueue(new SimplePlayQueue(1, [playingItem, item]));
  }
  const player: PlayerService = PlayerService.getInstance();
  const source: PlayableSource | null = player.getSource();
  const audioOnly: boolean = source !== null && source.audioOnly;
  // The popup keeps its own resolution and its PiP surface; the background player stays audio.
  await player.prepare(info, audioOnly, audioOnly ? 0 : player.getTargetHeight(), '', false,
    seconds * 1000);
  await MediaSessionService.getInstance().setMetadata(info);
}
