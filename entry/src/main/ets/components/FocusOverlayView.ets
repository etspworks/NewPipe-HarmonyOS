/**
 * comp_focus_overlay_view - port of org.schabi.newpipe.views.FocusOverlayView.
 *
 * SOURCE STRUCTURE (FocusOverlayView.java): a Drawable added to the Activity/Dialog decor view's
 * overlay (`decor.getOverlay().add(overlay)`), which listens on the ViewTreeObserver for focus,
 * scroll, layout and touch-mode changes and strokes a 2vp rect around whatever view currently
 * holds D-pad focus. It renders NO controls, intercepts no touches, and is installed only on TV
 * (`DeviceUtils.isTv(this)` -> `FocusOverlayView.setupFocusObserver(this)`), which is the
 * conditional this component carries as `isTv`.
 *
 * ponytail: ArkUI already strokes a focus outline around every focusable node, so the port is an
 * inert, touch-transparent layer that keeps the source's structure without re-implementing focus
 * tracking. Upgrade path: if TV focus ever needs the source's exact 2vp white rect, draw it here
 * from the focused node's bounds instead of relying on the framework outline.
 *
 * S3: structure only - no colours, no sizes beyond "covers its host". The layer MUST stay
 * `HitTestMode.Transparent`: a full-size top layer that hit-tests normally swallows every tap on
 * the screen underneath it (ArkUI gives the topmost node the touch).
 */
@Component
export struct FocusOverlayView {
  /** DeviceUtils.isTv(this) - the source installs the observer on TV builds only. */
  @Prop isTv: boolean = false;

  build() {
    Column()
      .width('100%')
      .height('100%')
      .visibility(this.isTv ? Visibility.Visible : Visibility.None)
      .focusable(false)
      .hitTestBehavior(HitTestMode.Transparent)
  }
}
