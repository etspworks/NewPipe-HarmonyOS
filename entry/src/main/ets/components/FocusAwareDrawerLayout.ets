/**
 * comp_focus_aware_drawer_layout - port of org.schabi.newpipe.views.FocusAwareDrawerLayout,
 * the ROOT of res/layout/activity_main.xml.
 *
 * SOURCE STRUCTURE (activity_main.xml): a DrawerLayout with exactly two children -
 *   1. the content (FocusAwareCoordinator: fragment_holder + toolbar_layout + fragment_player_holder)
 *   2. the start-gravity drawer panel (include drawer_layout -> NavigationView + drawer_header)
 * The Java subclass adds nothing structural: it only overrides addFocusables /
 * onRequestFocusInDescendants / openDrawer so D-pad focus stays inside an open drawer. ArkUI's
 * SideBarContainer already scopes focus to the visible sidebar, so the override has no analogue
 * and the two slots are the whole port.
 *
 * `SideBarContainer(Overlay)` is DrawerLayout: the sidebar floats over the content instead of
 * pushing it, which is what `android:layout_gravity="start"` on a DrawerLayout child does.
 *
 * S3: structure only - no widths, colours or dividers (S5 takes those from the capture).
 */
/**
 * S5: the NavigationView measures 840px = 280vp in the captured state S0008, which is exactly
 * drawer_layout's wrap_content over drawer_header's fixed content
 * (16 + 48 + 12 + 176 + 12 + 16). DrawerLayout has no resize handle, so min and max pin the
 * sidebar to that one width rather than leaving SideBarContainer's draggable range in place.
 */
const DRAWER_WIDTH: number = 280;
/** ViewDragHelper's edge size (DrawerLayout: 20dp) - a drag must START this close to the edge. */
const EDGE_SIZE: number = 20;

@Component
export struct FocusAwareDrawerLayout {
  /** DrawerLayout open/closed. Two-way: the toolbar toggle and a row tap drive it from the page,
   *  a swipe-dismiss drives it from here (source: DrawerLayout.SimpleDrawerListener). */
  @Link drawerOpen: boolean;
  /** DrawerLayout.LOCK_MODE_LOCKED_CLOSED (MainActivity.updateDrawerNavigation): no edge swipe. */
  @Prop drawerLocked: boolean = false;
  /** Where the current touch went down on the content, for the edge check below. */
  private touchDownX: number = Number.MAX_VALUE;

  @Builder
  emptySlot(): void {
    Column()
  }

  /** activity_main.xml child 1 - FocusAwareCoordinator. */
  @BuilderParam contentSlot: () => void = this.emptySlot;
  /** activity_main.xml child 2 - the start drawer (drawer_layout include). */
  @BuilderParam drawerSlot: () => void = this.emptySlot;

  build() {
    SideBarContainer(SideBarContainerType.Overlay) {
      // First child = the sidebar (the drawer panel).
      Column() {
        this.drawerSlot()
      }
      .width('100%')
      .height('100%')

      // Second child = the content behind it.
      Column() {
        this.contentSlot()
      }
      .width('100%')
      .height('100%')
      .onTouch((event: TouchEvent) => {
        if (event.type === TouchType.Down && event.touches.length > 0) {
          this.touchDownX = event.touches[0].x;
        }
      })
      // DrawerLayout's edge drag: a rightward drag that starts within EDGE_SIZE of the start edge
      // opens the drawer. Priority, so it beats the tab pager's own pan from the edge; any other
      // pan is rejected below and the content scrolls as before. On gesture-navigation devices
      // the system Back swipe owns the outermost edge, as on Android 10+.
      .priorityGesture(PanGesture({ direction: PanDirection.Right })
        .onActionStart(() => {
          this.drawerOpen = true;
        }))
      .onGestureJudgeBegin((info: GestureInfo, event: BaseGestureEvent): GestureJudgeResult => {
        if (info.type === GestureControl.GestureType.PAN_GESTURE &&
          (this.drawerOpen || this.drawerLocked || this.touchDownX > EDGE_SIZE)) {
          return GestureJudgeResult.REJECT;
        }
        return GestureJudgeResult.CONTINUE;
      })
    }
    .sideBarWidth(DRAWER_WIDTH)
    .minSideBarWidth(DRAWER_WIDTH)
    .maxSideBarWidth(DRAWER_WIDTH)
    // SideBarContainer rules its own line between the sidebar and the content; DrawerLayout
    // draws none, so it is turned off rather than styled.
    .divider(null)
    .showSideBar(this.drawerOpen)
    // The source's only drawer affordance is the toolbar hamburger. SideBarContainer draws its
    // OWN floating control button unless this is false - that would be a control the source has
    // no equivalent for, i.e. an invented one.
    .showControlButton(false)
    .sideBarPosition(SideBarPosition.Start)
    .autoHide(false)
    .width('100%')
    .height('100%')
    .onChange((open: boolean) => {
      this.drawerOpen = open;
    })
    // Dragging the open drawer (or its scrim) towards the start edge closes it; the page's
    // onDrawerClosed then applies a changed service. Parallel, so the drawer's rows and list
    // keep their own taps and vertical scroll.
    .parallelGesture(PanGesture({ direction: PanDirection.Left })
      .onActionStart(() => {
        if (this.drawerOpen) {
          this.drawerOpen = false;
        }
      }))
  }
}
