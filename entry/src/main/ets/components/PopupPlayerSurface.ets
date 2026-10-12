/*
 * The surface a LIST screen needs to open the popup player without leaving itself.
 *
 * NavigationHelper.playOnPopupPlayer() opens the float window over whatever screen the user is
 * on - the playlist stays visible behind it. The port could not do that: SYSTEM_FLOAT_WINDOW is
 * ungrantable to a self-signed build, so the popup is PiP, and PiPWindow renders FROM an
 * XComponent surface (PiPConfiguration.componentController). No list screen had one, so every
 * popup entry point pushed VideoDetailFragmentPage - the only owner of a surface - and the user
 * landed on the standard player, which is exactly what TC-LIBRARY-252 reports.
 *
 * This is that missing surface, and nothing else: an XComponent the host mounts while it opens a
 * popup. It is 1x1 and fully transparent, because PiP composites the video into its own window
 * at its own size - the in-page node only has to exist and be bound to the AVPlayer. The host
 * keeps it mounted for as long as the window is up, since PiP renders from it.
 */
import { PipCoverNode } from './PipCoverNode';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { promptAction, router } from '@kit.ArkUI';
import { PipOutcome, PlayerService } from '../common/player/PlayerService';
import { PlayerPrefs } from '../common/player/PlayerPrefs';
import { MediaSessionService } from '../common/player/MediaSessionService';
import { ExtractorHelper } from '../common/extractor/ExtractorHelper';
import { StreamInfo } from '../model/extractor/StreamInfo';
import { ServiceLocator } from '../common/di/ServiceLocator';
import { BackgroundWorkMode } from '../common/background/BackgroundWork';
import { PermissionHelper } from '../common/perm/PermissionHelper';
import {
  default_popup_resolution_key, default_popup_resolution_value
} from '../common/prefs/SettingsKeys';
import { preferredHeightOf } from '../common/settings/PreferredHeight';

const TAG: string = 'PopupPlayerSurface';

/**
 * openPopupPlayer(), for a list screen that has just bound its surface: fetch the stream, prepare
 * it, start the session and hand the surface to PiP.
 *
 * This lived inline on each host as a private onPopupSurfaceReady(). Two screens had it, two did
 * not, and the two that did not still pushed VideoDetailFragmentPage - which is the whole of what
 * TC-LIBRARY-252, TC-LIBRARY-257 and this card report, three times over. A per-page copy is what
 * let a screen be missed, so the body lives here once and every host calls it.
 *
 * `onClosed` is raised whenever the host should UNMOUNT its surface: at once when PiP could not
 * take it (no permission, unavailable, or an error), or later when the float window is closed.
 * PiP renders FROM the surface, so it must stay mounted for as long as the window is up.
 */
export async function openPopupOnSurface(context: common.UIAbilityContext, serviceId: number,
  url: string, controller: XComponentController, onClosed: () => void): Promise<void> {
  const permissions: PermissionHelper = ServiceLocator.get().permissions;
  try {
    const info: StreamInfo = await ServiceLocator.get().backgroundWork.runWithBackgroundTask(
      BackgroundWorkMode.DATA_TRANSFER,
      (): Promise<StreamInfo> => ExtractorHelper.getStreamInfo(serviceId, url, false));
    // audioOnly false: the popup is a VIDEO window, and PiP renders the picture from the surface
    // the host just bound.
    //
    // T-0197: this called prepare() with NO height, so `Default popup resolution` - declared,
    // written by the settings screen, indexed by preference search - was read by nothing and the
    // resolver picked its own rendition. Measured on the handset with the preference at 480p: the
    // port served 360p where the reference served 480p. prepare() already clamps a height it
    // cannot build, so passing the preference is the whole fix, and it covers every list screen
    // because they all route through this one function.
    // computeDefaultResolution(): the mobile-data limit lowers it on a metered network.
    const popupHeight: number = preferredHeightOf(PlayerPrefs.computeDefaultResolution(
      default_popup_resolution_key, default_popup_resolution_value));
    await PlayerService.getInstance().prepare(info, false, popupHeight);
    await MediaSessionService.getInstance().startDetached(context, info);
    if (!permissions.isPopupEnabled()) {
      // isPopupEnabledElseAsk(activity): without the popup permission the source never opens one.
      // Playback is already running, so the mini player is what remains visible.
      hilog.info(0x0000, TAG, 'popup player: not permitted, the mini player carries it');
      onClosed();
      return;
    }
    const outcome: PipOutcome = await PlayerService.getInstance().enterPip(context, controller, new PipCoverNode());
    if (outcome === PipOutcome.PIP) {
      // setPipSurfaceListener, not setPipClosedListener: this host only has to unmount a 1x1
      // surface, and that is right whether the user closed the window or the app stopped PiP
      // itself. The closed listener is the detail page's navigate-away and must not fire on the
      // second case.
      PlayerService.getInstance().setPipSurfaceListener(onClosed);
      // The popup's fullscreen button: no screen of a list can play in fullscreen, so the main
      // player opens for this stream, the way the mini player's tap reopens it, and goes fullscreen.
      PlayerService.getInstance().setPipRestoredListener((): void => {
        const playing: StreamInfo | null = PlayerService.getInstance().currentInfo.getValue();
        const shown: StreamInfo = playing !== null ? playing : info;
        router.pushUrl({
          url: 'pages/VideoDetailFragmentPage',
          params: {
            'serviceId': shown.getServiceId(),
            'url': shown.getUrl(),
            'name': shown.getName(),
            'fullscreen': 'true'
          }
        }).catch((err: BusinessError): void => {
          hilog.error(0x0000, TAG, 'popup restore: %{public}s', err.message);
        });
      });
      return;
    }
    hilog.info(0x0000, TAG, 'popup player: PiP unavailable, the mini player carries it');
    onClosed();
  } catch (err) {
    const failure: BusinessError = err as BusinessError;
    hilog.error(0x0000, TAG, 'popup player: %{public}s', failure.message);
    promptAction.showToast({ message: failure.message, duration: 2000 });
    onClosed();
  }
}

@Component
export struct PopupPlayerSurface {
  /** The host's controller: what it hands to PlayerService.enterPip(). */
  controller: XComponentController = new XComponentController();
  /** Raised once the surface is bound to the player and PiP can be started from it. */
  onSurfaceReady: () => void = (): void => {
    hilog.debug(0x0000, TAG, 'PopupPlayerSurface: onSurfaceReady not bound');
  };

  build() {
    XComponent({
      type: XComponentType.SURFACE,
      controller: this.controller
    })
      .id('popup_player_surface')
      .width(1)
      .height(1)
      .opacity(0)
      // It must never take a touch: it sits over the list while the popup is open.
      .hitTestBehavior(HitTestMode.None)
      .onLoad((): void => {
        const surfaceId: string = this.controller.getXComponentSurfaceId();
        hilog.info(0x0000, TAG, 'popup surface ready: %{public}s', surfaceId);
        PlayerService.getInstance().setSurfaceId(surfaceId);
        this.onSurfaceReady();
      })
  }
}
