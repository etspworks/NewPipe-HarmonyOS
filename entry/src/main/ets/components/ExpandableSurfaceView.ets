/*
 * S3 - port of org.schabi.newpipe.views.ExpandableSurfaceView (player.xml @+id/surfaceView).
 *
 * The Android view is a SurfaceView that re-measures itself from an aspect ratio and a resize
 * mode (FIT / FILL / ZOOM), scaling X or Y so the video fills the box the chosen way. On
 * HarmonyOS the equivalent surface is an XComponent of type SURFACE: its surfaceId is what
 * AVPlayer renders into, so this struct's one job beyond drawing is handing that id back to the
 * owner the moment the surface exists.
 *
 * The measure maths is reproduced as the scale the source applies in onLayout, so the three
 * resize modes stay three visibly different modes and not one.
 */
import { hilog } from '@kit.PerformanceAnalysisKit';

/** Port of AspectRatioFrameLayout.ResizeMode - the values setResizeMode() cycles through. */
export enum SurfaceResizeMode {
  FIT,
  FILL,
  ZOOM
}

@Component
export struct ExpandableSurfaceView {
  /** setAspectRatio(videoAspectRatio); 0 means "not known yet", as in the source. */
  @Prop videoAspectRatio: number = 0;
  /** setResizeMode(newResizeMode) - persisted by the player's resize button. */
  @Prop resizeMode: SurfaceResizeMode = SurfaceResizeMode.FIT;
  /** setHeights(base, max): the collapsed and expanded heights the detail screen computes. */
  @Prop baseHeight: number = 0;
  @Prop maxHeight: number = 0;

  /** The AVPlayer render target. The owner passes it to PlayerService when it arrives. */
  onSurfaceReady: (surfaceId: string) => void = (surfaceId: string): void => {
    hilog.debug(0x0000, 'NewPipe', 'ExpandableSurfaceView: surface %{public}s unbound', surfaceId);
  };
  /** Hands back the id THIS surface reported, so the owner cannot drop a newer one by mistake. */
  onSurfaceDestroyed: (surfaceId: string) => void = (surfaceId: string): void => {
    hilog.debug(0x0000, 'NewPipe', 'ExpandableSurfaceView: surface %{public}s destroyed, unbound',
      surfaceId);
  };
  /** The id onLoad reported. The controller is the owner's and is shared across rebuilds. */
  private surfaceId: string = '';

  /**
   * The owner supplies the controller so it can hand the same one to PiPWindow.create() -
   * PiP is the Phase-2 substitution for the popup player's float window, and it needs the
   * component controller, not just the surface id.
   */
  controller: XComponentController = new XComponentController();

  /**
   * onMeasure()/onLayout(): ZOOM scales the surface up until no letterbox remains, FILL stretches
   * to the box, FIT leaves the ratio alone. scaleX/scaleY are the two fields the source sets.
   */
  private scaleX(): number {
    if (this.videoAspectRatio <= 0 || this.resizeMode !== SurfaceResizeMode.ZOOM) {
      return 1.0;
    }
    return this.videoAspectRatio > 1.0 ? this.videoAspectRatio : 1.0;
  }

  private scaleY(): number {
    if (this.videoAspectRatio <= 0 || this.resizeMode !== SurfaceResizeMode.ZOOM) {
      return 1.0;
    }
    return this.videoAspectRatio > 1.0 ? 1.0 : 1.0 / this.videoAspectRatio;
  }

  build() {
    XComponent({
      id: 'surfaceView',
      type: XComponentType.SURFACE,
      controller: this.controller
    })
      .id('surfaceView')
      .width('100%')
      .height('100%')
      .scale({ x: this.scaleX(), y: this.scaleY() })
      .onLoad(() => {
        this.surfaceId = this.controller.getXComponentSurfaceId();
        this.onSurfaceReady(this.surfaceId);
      })
      .onDestroy(() => {
        this.onSurfaceDestroyed(this.surfaceId);
      })
  }
}
