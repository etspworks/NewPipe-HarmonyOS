/**
 * MediaSessionService — svc_av_session.
 *
 * Ports org.schabi.newpipe.player.mediasession.MediaSessionPlayerUi + PlayQueueNavigator +
 * the notification/foreground-service half of PlayerService.java.
 *
 * Substitutions taken in phase2-logic-contract.md §2.6 / §2.8 — do not re-open:
 *   - MediaSessionCompat + MediaSessionConnector  ->  @kit.AVSessionKit AVSession.
 *   - The foreground service + its media notification  ->  a BackgroundTasksKit continuous
 *     task under backgroundModes ["audioPlayback", "dataTransfer"]. The system publishes the
 *     media controls from the AVSession itself.
 *
 * The media card is AVSession's, not one this app builds - but NOT because of a permission. An
 * earlier revision of this header blamed ohos.permission.NOTIFICATION_CONTROLLER, and that was
 * wrong: notificationManager.publish() carries no @permission tag at all, this app already
 * publishes four notifications without it, and NOTIFICATION_CONTROLLER does not appear in
 * @ohos.notificationManager.d.ts anywhere - it governs managing ANOTHER app's notifications
 * (@systemapi).
 *
 * The real ceiling, measured in the SDK:
 *   - notification/notificationRequest.d.ts:351 - "A notification can contain a maximum of two
 *     buttons by default";
 *   - @ohos.notificationManager.d.ts:1264 - NOTIFICATION_CONTENT_SYSTEM_LIVE_VIEW: "A third-party
 *     application cannot directly create a notification of this type";
 *   - :1292 - NOTIFICATION_CONTENT_LIVE_VIEW: "Only system applications are supported";
 *   - and there is no API for button ORDER, nor for a compact-view subset.
 * So NewPipe's five slots and three compact choices cannot be drawn by anyone here. Re-read those
 * lines before concluding the platform has changed. What the system card does draw is one of two
 * fixed rows picked by the session type - see sessionType(); neither row has a Close button, and
 * the card's dismissal reaches the app as no event at all.
 *   - MediaBrowserService / Android Auto browse tree: collapsed into in-app navigation, so
 *     nothing here exposes a browsable tree.
 *
 * Only KEEP_BACKGROUND_RUNNING is needed, and it is already in module.json5.
 */

import { avSession } from '@kit.AVSessionKit';
import { common, wantAgent, Want, WantAgent } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { BackgroundWorkMode } from '../background/BackgroundWork';
import { ServiceLocator } from '../di/ServiceLocator';
import { CompositeDisposable, Disposable } from '../rx/Rx';
import { StreamInfo } from '../../model/extractor/StreamInfo';
import { Image } from '../../model/extractor/Image';
import {
  PlayableSource, PlayerService, PlayerPosition, PlayerStatus, QueueNavigator, RepeatMode, describeError
} from './PlayerService';
import {
  AV_LOOP_LIST, AV_LOOP_SEQUENCE, AV_LOOP_SHUFFLE, AV_LOOP_SINGLE, PlayerLoopState,
  fromLoopMode, toLoopMode
} from './LoopModeMapping';
import { PlayerPrefs } from './PlayerPrefs';
import { AppPreferences } from '../prefs/Preferences';
import { scale_to_square_image_in_notifications_key, show_thumbnail_key } from '../prefs/SettingsKeys';
import { KeyEvent } from '@kit.InputKit';
import { http } from '@kit.NetworkKit';
import { image } from '@kit.ImageKit';

const TAG: string = 'MediaSessionService';

/**
 * The queue half of MediaSessionPlayerUi (PlayQueueNavigator). The PlayQueue itself is owned
 * by another module, so the player screen supplies this; it is REQUIRED by start(), which is
 * what keeps every media-session command wired to a real effect instead of a no-op handler.
 */
export interface MediaQueueHandler extends QueueNavigator {
  /** Called when the system asks the session to stop (e.g. the notification's close). */
  stopPlayback(): void;
  /** Whether the QUEUE is shuffled. Repeat belongs to the player; shuffle belongs to the queue. */
  isShuffled(): boolean;
  /** Turn queue shuffle on or off. A playback with no queue has nothing to shuffle. */
  setShuffled(on: boolean): void;
}

/**
 * The handler for a playback no screen owns — background and popup started from a list. There is
 * no queue to navigate, so next/previous do nothing; stop is the system's close affordance and has
 * to reach the player, or the notification's X leaves audio running.
 */
class DetachedQueueHandler implements MediaQueueHandler {
  playNext(): void {
  }

  playPrevious(): void {
  }

  // There is no queue behind this playback, so shuffle has nothing to act on. This is the one
  // place a no-op is honest rather than a defect: the system card's repeat half still works,
  // because repeat lives on the player and not on the queue.
  isShuffled(): boolean {
    return false;
  }

  setShuffled(on: boolean): void {
  }

  stopPlayback(): void {
    PlayerService.getInstance().pause();
    MediaSessionService.getInstance().stop();
  }
}

export class MediaSessionService {
  private static instance: MediaSessionService | null = null;

  private session: avSession.AVSession | null = null;
  private context: common.UIAbilityContext | null = null;
  private backgroundRunning: boolean = false;
  private currentAssetId: string = '';
  /** The queue handler the current session was started with; shuffle is read back through it. */
  private queueHandler: MediaQueueHandler | null = null;
  private durationMs: number = 0;
  private readonly disposables: CompositeDisposable = new CompositeDisposable();

  static getInstance(): MediaSessionService {
    if (MediaSessionService.instance === null) {
      MediaSessionService.instance = new MediaSessionService();
    }
    return MediaSessionService.instance;
  }

  isActive(): boolean {
    return this.session !== null;
  }

  /**
   * Create + activate the AVSession and start the continuous task. Idempotent, like
   * MediaSessionPlayerUi.initPlayer() which destroys the previous session first.
   */
  async start(context: common.UIAbilityContext, handler: MediaQueueHandler): Promise<void> {
    await this.stop();
    this.context = context;

    const session: avSession.AVSession =
      await avSession.createAVSession(context, 'NewPipePlayer', MediaSessionService.sessionType());
    this.session = session;
    this.queueHandler = handler;
    // The popup's Previous / Next walk the same queue; a playback with none gets its seek pair.
    PlayerService.getInstance().setQueueNavigator(
      handler instanceof DetachedQueueHandler ? null : handler);
    // LoopModeMapping mirrors these numerically so the host suite can test it. If the SDK ever
    // renumbers the enum, fail loudly here rather than silently sending the wrong mode.
    if (avSession.LoopMode.LOOP_MODE_SEQUENCE as number !== AV_LOOP_SEQUENCE
      || avSession.LoopMode.LOOP_MODE_SINGLE as number !== AV_LOOP_SINGLE
      || avSession.LoopMode.LOOP_MODE_LIST as number !== AV_LOOP_LIST
      || avSession.LoopMode.LOOP_MODE_SHUFFLE as number !== AV_LOOP_SHUFFLE) {
      console.error(TAG + ': avSession.LoopMode values no longer match LoopModeMapping');
    }
    this.registerCommands(session, handler);
    try {
      await session.setLaunchAbility(await this.launchAgent(context));
    } catch (e) {
      // Not fatal: the controls still work, only the "tap the notification" route is lost.
      console.warn(TAG + ': setLaunchAbility failed: ' + describeError(e));
    }
    await session.activate();
    this.observePlayer();
    await this.startContinuousTask();
  }

  /**
   * The same thing `start()` does, for the playback paths that have no screen owning the player:
   * playOnBackgroundPlayer / playOnPopupPlayer from a list, and RouterActivityPage's background
   * choice. Those call PlayerService.prepare() and nothing else, so no AVSession was created and
   * no continuous task was requested — the system showed no media controls and HarmonyOS was free
   * to stop the audio the moment the app left the foreground.
   *
   * Guarded on isActive() rather than calling start() outright, because start() tears the previous
   * session down first and VideoDetailFragmentPage's session, with its real queue handler, must
   * survive a background start raised from underneath it.
   */
  async startDetached(context: common.UIAbilityContext, info: StreamInfo): Promise<void> {
    if (!this.isActive()) {
      await this.start(context, new DetachedQueueHandler());
    }
    await this.setMetadata(info);
  }

  /**
   * Mirrors the source's foreground service: audio keeps playing with the app backgrounded.
   *
   * A UIAbility has exactly ONE continuous task, so the request goes through BackgroundWork,
   * which owns it for every mode. Requesting "audioPlayback" here directly meant the download /
   * feed lane's own stopBackgroundRunning() cancelled the audio task (and, once an audio task
   * was live, its startBackgroundRunning() was refused outright) - which is why background
   * playback never survived a second start.
   */
  private async startContinuousTask(): Promise<void> {
    if (this.backgroundRunning) {
      return;
    }
    const held: boolean =
      await ServiceLocator.get().backgroundWork.start(BackgroundWorkMode.AUDIO_PLAYBACK);
    this.backgroundRunning = held;
    if (!held) {
      // Reported, never swallowed: without it playback dies when the app is backgrounded.
      console.error(TAG + ': continuous task refused, background audio will stop when the '
        + 'app leaves the foreground');
      PlayerService.getInstance().lastError.onNext(
        'Background playback unavailable: the system refused the continuous task');
    }
  }

  /**
   * The system card draws one of two FIXED rows, and the session TYPE picks it (AVSession guide,
   * "播控中心的控制样式"): 'audio' - favourite, previous, play/pause, next, loop mode; 'video' -
   * rewind, previous, play/pause, next, fast-forward. No type gives both Repeat and the seek pair,
   * so the type says what plays, as the platform defines it: the background player (audio-only)
   * gets Repeat, the popup and the main player (video) get Rewind / Fast-forward.
   */
  private static sessionType(): avSession.AVSessionType {
    const source: PlayableSource | null = PlayerService.getInstance().getSource();
    return source !== null && !source.audioOnly ? 'video' : 'audio';
  }

  /**
   * The card's seek step: SkipIntervals offers 10, 15 and 30 s only, so the nearest one to the
   * seek_duration setting labels the buttons. The step taken is always the setting itself.
   */
  private static skipInterval(): avSession.SkipIntervals {
    const seconds: number = PlayerPrefs.seekDurationMs() / 1000;
    if (seconds < 12.5) {
      return avSession.SkipIntervals.SECONDS_10;
    }
    return seconds < 22.5 ? avSession.SkipIntervals.SECONDS_15 : avSession.SkipIntervals.SECONDS_30;
  }

  private async launchAgent(context: common.UIAbilityContext): Promise<WantAgent> {
    const want: Want = {
      bundleName: context.abilityInfo.bundleName,
      abilityName: context.abilityInfo.name
    };
    const info: wantAgent.WantAgentInfo = {
      wants: [want],
      actionType: wantAgent.OperationType.START_ABILITY,
      requestCode: 0,
      actionFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
    };
    return wantAgent.getWantAgent(info);
  }

  /**
   * Every command MediaSessionConnector handled in the source, wired to the real player.
   * There is deliberately no empty handler here — an unwired media button is a defect.
   */
  private registerCommands(session: avSession.AVSession, handler: MediaQueueHandler): void {
    const player: PlayerService = PlayerService.getInstance();
    session.on('play', (): void => {
      player.play();
    });
    session.on('pause', (): void => {
      player.pause();
    });
    session.on('stop', (): void => {
      handler.stopPlayback();
    });
    session.on('playNext', (): void => {
      handler.playNext();
    });
    session.on('playPrevious', (): void => {
      handler.playPrevious();
    });
    session.on('seek', (time: number): void => {
      player.seekTo(time);
    });
    // fastForward()/fastRewind() step by the user's seek_duration, as the player's own do - the
    // source ignores any amount a controller sends, and the d.ts gives `time` no unit to trust.
    session.on('fastForward', (time?: number): void => {
      player.seekBy(PlayerPrefs.seekDurationMs());
    });
    session.on('rewind', (time?: number): void => {
      player.seekBy(-PlayerPrefs.seekDurationMs());
    });
    // ignore_hardware_media_buttons: the source swallows media-button events in its session.
    // Registering the key handler is what takes a headset's buttons away from the system's own
    // play/pause mapping, so it is registered only while the preference asks for that.
    if (PlayerPrefs.isIgnoringHardwareMediaButtons()) {
      session.on('handleKeyEvent', (event: KeyEvent): void => {
        console.info(TAG + ': hardware media button ignored, keyCode=' + event.key.code);
      });
    }
    session.on('setSpeed', (speed: number): void => {
      player.setSpeed(speed);
    });
    // The system card's repeat / shuffle control. AVSession folds both into one LoopMode, so this
    // splits it back out - see LoopModeMapping.ts.
    session.on('setLoopMode', (mode: avSession.LoopMode): void => {
      const wanted: PlayerLoopState = fromLoopMode(mode as number);
      console.info('LOOPMODE: setLoopMode ' + (mode as number)
        + ' -> repeat=' + wanted.repeat + ' shuffled=' + wanted.shuffled);
      MediaSessionService.getInstance().applyLoopState(handler, mode as number, wanted);
    });
  }

  /**
   * One LoopMode, split back into the two things this app owns.
   *
   * SHUFFLE carries no repeat information, so it sets shuffle and leaves the repeat mode alone.
   * Clearing a repeat choice because the user tapped shuffle would be a side effect nobody asked
   * for. Every other mode is a repeat mode, and turns shuffle off.
   *
   * The player mode is SET, not cycled: cycleNextRepeatMode() walks off -> one -> all, and
   * cycling until it matched would emit the intermediate states to every subscriber.
   *
   * ...EXCEPT when the controller hands back the mode we just published. MEASURED on BRA-AL00
   * (OpenHarmony 6.1.1.120): com.ohos.sceneboard's loop control sends `setLoopMode` carrying the
   * CURRENT mode on every tap - four taps at mode 0 all arrived as 0, four at mode 3 all as 3 -
   * so taken literally the control can never change anything and the card's button is dead. A
   * request to enter the mode you are already in is not a change request; from the one controller
   * that does this, it is the tap itself. So it is read as the cycle the button is drawn to do -
   * the same off -> one -> all walk the in-app repeat button and the reference's own notification
   * action perform. Shuffle is left alone, the mirror of the rule above.
   *
   * A controller that asks for a DIFFERENT mode still gets it applied exactly, below.
   */
  private applyLoopState(handler: MediaQueueHandler, mode: number,
    wanted: PlayerLoopState): void {
    const player: PlayerService = PlayerService.getInstance();
    const published: number = toLoopMode(player.getRepeatMode(), handler.isShuffled());
    if (mode === published) {
      player.cycleNextRepeatMode();
      this.pushPlaybackState(player.state.getValue(), player.currentPositionMs());
      return;
    }
    if (mode === AV_LOOP_SHUFFLE) {
      handler.setShuffled(true);
    } else {
      handler.setShuffled(false);
      player.setRepeatMode(wanted.repeat);
    }
    this.pushPlaybackState(player.state.getValue(), player.currentPositionMs());
  }

  /** Keep the system controls in step with the real player (contract §1: streams are Rx). */
  private observePlayer(): void {
    const player: PlayerService = PlayerService.getInstance();
    const stateSub: Disposable = player.state.subscribeCallbacks(
      (status: PlayerStatus): void => {
        this.pushPlaybackState(status, player.currentPositionMs());
      },
      (error: Error): void => {
        console.warn(TAG + ': player state stream failed: ' + error.message);
      });
    const positionSub: Disposable = player.position.subscribeCallbacks(
      (position: PlayerPosition): void => {
        if (position.durationMs > 0) {
          this.durationMs = position.durationMs;
        }
        this.pushPlaybackState(player.state.getValue(), position.positionMs);
      },
      (error: Error): void => {
        console.warn(TAG + ': player position stream failed: ' + error.message);
      });
    // A2: the card must follow a repeat change made in the APP, not only a position tick.
    const repeatSub: Disposable = player.repeatMode.subscribeCallbacks(
      (mode: RepeatMode): void => {
        this.pushPlaybackState(player.state.getValue(), player.currentPositionMs());
      },
      (error: Error): void => {
        console.warn(TAG + ': player repeat stream failed: ' + error.message);
      });
    this.disposables.add(stateSub);
    this.disposables.add(positionSub);
    this.disposables.add(repeatSub);
  }

  private pushPlaybackState(status: PlayerStatus | null, positionMs: number): void {
    const session: avSession.AVSession | null = this.session;
    if (session === null) {
      return;
    }
    const speed: number | null = PlayerService.getInstance().appliedSpeed.getValue();
    // AVPlayer.currentTime is -1 when there is no valid position (idle/initialized/stopped,
    // and by default for a live stream), and the native session rejects the WHOLE state
    // object when elapsedTime < 0 ("native invalid parameters"). Clamp instead of dropping
    // the update, so the state/duration/speed still reach the system controls.
    const position: avSession.PlaybackPosition = {
      elapsedTime: positionMs > 0 ? positionMs : 0,
      updateTime: new Date().getTime()
    };
    const handler: MediaQueueHandler | null = this.queueHandler;
    const state: avSession.AVPlaybackState = {
      state: MediaSessionService.toAvState(status),
      position: position,
      duration: this.durationMs,
      speed: speed !== null ? speed : 1.0,
      // The system card's repeat/shuffle control reads this. Without it the card has neither,
      // while the player has both (item 6).
      loopMode: toLoopMode(PlayerService.getInstance().getRepeatMode(),
        handler !== null && handler.isShuffled()) as avSession.LoopMode
    };
    session.setAVPlaybackState(state).catch((err: BusinessError): void => {
      console.warn(TAG + ': setAVPlaybackState failed: ' + err.message);
    });
  }

  private static toAvState(status: PlayerStatus | null): avSession.PlaybackState {
    if (status === PlayerStatus.PLAYING) {
      return avSession.PlaybackState.PLAYBACK_STATE_PLAY;
    } else if (status === PlayerStatus.PAUSED) {
      return avSession.PlaybackState.PLAYBACK_STATE_PAUSE;
    } else if (status === PlayerStatus.BUFFERING) {
      return avSession.PlaybackState.PLAYBACK_STATE_BUFFERING;
    } else if (status === PlayerStatus.COMPLETED) {
      return avSession.PlaybackState.PLAYBACK_STATE_COMPLETED;
    } else if (status === PlayerStatus.ERROR) {
      return avSession.PlaybackState.PLAYBACK_STATE_ERROR;
    }
    return avSession.PlaybackState.PLAYBACK_STATE_IDLE;
  }

  /** Port of MediaSessionPlayerUi.buildMediaMetadata(). */
  async setMetadata(info: StreamInfo): Promise<void> {
    const session: avSession.AVSession | null = this.session;
    if (session === null) {
      return;
    }
    this.currentAssetId = info.getUrl();
    this.durationMs = info.duration > 0 ? info.duration * 1000 : 0;
    const metadata: avSession.AVMetadata = {
      assetId: this.currentAssetId,
      title: info.getName(),
      artist: info.uploaderName,
      author: info.uploaderName,
      duration: this.durationMs,
      mediaImage: await MediaSessionService.artwork(info.thumbnails),
      skipIntervals: MediaSessionService.skipInterval()
    };
    try {
      await session.setAVMetadata(metadata);
    } catch (e) {
      console.warn(TAG + ': setAVMetadata failed: ' + describeError(e));
    }
  }

  /**
   * MediaSessionPlayerUi / NotificationUtil.setLargeIcon(): no artwork at all when show_thumbnail
   * is off, and the centre square of it when scale_to_square_image_in_notifications is on.
   */
  private static async artwork(thumbnails: Image[]): Promise<string | image.PixelMap> {
    let showThumbnail: boolean = true;
    let square: boolean = false;
    try {
      showThumbnail = AppPreferences.instance().getBooleanSync(show_thumbnail_key, true);
      square = AppPreferences.instance()
        .getBooleanSync(scale_to_square_image_in_notifications_key, false);
    } catch (e) {
      showThumbnail = true;
    }
    const url: string = MediaSessionService.largestThumbnail(thumbnails);
    if (!showThumbnail || url.length === 0) {
      return '';
    }
    if (!square) {
      return url;
    }
    try {
      return await MediaSessionService.squareOf(url);
    } catch (e) {
      console.warn(TAG + ': square artwork failed, using the full image: ' + describeError(e));
      return url;
    }
  }

  /** getBitmapWithSquareAspectRatio(): the centre square of the image, min(w, h) a side. */
  private static async squareOf(url: string): Promise<image.PixelMap> {
    const request: http.HttpRequest = http.createHttp();
    try {
      const response: http.HttpResponse = await request.request(url, {
        method: http.RequestMethod.GET,
        expectDataType: http.HttpDataType.ARRAY_BUFFER,
        connectTimeout: 15000,
        readTimeout: 15000
      });
      const source: image.ImageSource = image.createImageSource(response.result as ArrayBuffer);
      try {
        const pixels: image.PixelMap = await source.createPixelMap();
        const info: image.ImageInfo = await pixels.getImageInfo();
        const side: number = Math.min(info.size.width, info.size.height);
        await pixels.crop({
          x: Math.floor((info.size.width - side) / 2),
          y: Math.floor((info.size.height - side) / 2),
          size: { width: side, height: side }
        });
        return pixels;
      } finally {
        source.release();
      }
    } finally {
      request.destroy();
    }
  }

  private static largestThumbnail(thumbnails: Image[]): string {
    let chosen: Image | null = null;
    for (const image of thumbnails) {
      if (image.getUrl().length === 0) {
        continue;
      }
      if (chosen === null || image.getWidth() > chosen.getWidth()) {
        chosen = image;
      }
    }
    return chosen !== null ? chosen.getUrl() : '';
  }

  /** Release order mirrors destroyPlayer(): unsubscribe, drop the task, destroy the session. */
  async stop(): Promise<void> {
    this.disposables.clear();
    PlayerService.getInstance().setQueueNavigator(null);
    if (this.backgroundRunning) {
      this.backgroundRunning = false;
      try {
        await ServiceLocator.get().backgroundWork.stop(BackgroundWorkMode.AUDIO_PLAYBACK);
      } catch (e) {
        console.warn(TAG + ': releasing the audio continuous task failed: ' + describeError(e));
      }
    }
    const session: avSession.AVSession | null = this.session;
    if (session === null) {
      this.context = null;
      return;
    }
    try {
      await session.deactivate();
    } catch (e) {
      console.warn(TAG + ': deactivate failed: ' + describeError(e));
    } finally {
      try {
        await session.destroy();
      } catch (e) {
        console.warn(TAG + ': destroy failed: ' + describeError(e));
      } finally {
        this.session = null;
        this.context = null;
        this.currentAssetId = '';
        this.durationMs = 0;
      }
    }
  }
}
