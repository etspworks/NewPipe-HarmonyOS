/**
 * S4 - EmptyFragment (screen_empty). State + argument binding, no visual styling.
 *
 * MOUNTED by screen_video_detail as a TabContent (the placeholder tab of the source TabAdapter);
 * the struct name must stay the file name because VideoDetailFragmentPage instantiates it. It is
 * also a registered route, but nothing pushes it.
 *
 * The whole source is EmptyFragment (verbatim, codegraph):
 *   private static final String SHOW_MESSAGE = "SHOW_MESSAGE";
 *   newInstance(showMessage) -> bundle.putBoolean(SHOW_MESSAGE, showMessage)
 *   onCreateView: showMessage = getArguments().getBoolean(SHOW_MESSAGE);
 *                 findViewById(R.id.empty_state_view).setVisibility(showMessage ? VISIBLE : GONE);
 * newInstance(false) is the silent placeholder VideoDetailFragment puts in the Related and
 * Description tabs before updateTabs(info) swaps in the real fragment; newInstance(true) is the
 * visible "nothing here" page (EMPTY_TAB_TAG) shown when every detail tab is disabled. That is
 * the SHOW_MESSAGE conditional variant - a real ArkUI `if`, never one flattened layout.
 *
 * S4 binds that argument two ways, because this struct is reached two ways and both are the same
 * bundle in the source:
 *   - MOUNTED: the host passes it, which is what @Prop is (newInstance(true|false)).
 *   - LAUNCHED: EntryAbility forwards every want.parameter as this page's router params, so a
 *     deep link carrying SHOW_MESSAGE reads it here. Absent, the default stays false - the source
 *     default of a bundle whose boolean was never put.
 * The value is NEVER a literal chosen for the screenshot: with no argument the page really is
 * blank, exactly like the pre-StreamInfo tab placeholder.
 *
 * View tree, from fragment_empty.xml + the included list_empty_view.xml:
 *   RelativeLayout > NestedScrollView (NEITHER carries an android:id) > include empty_state_view
 *     > LinearLayout(vertical, gravity=center) > NewPipeTextView "¯\_(ツ)_/¯"
 *                                             > NewPipeTextView @string/empty_list_subtitle
 * EmptyFragment defines ZERO interactive controls: the scroll view is neither identified nor
 * clickable (action-contract S0115 records it under omittedControls, actions: []), so it gets no
 * .id() and no onClick - there is no source slug to copy and inventing one would break the replay
 * matcher. The 90dp top offset, the centring and the type scale are S5's job.
 */
import { router } from '@kit.ArkUI';
import { BLACK_THEME_KEY, themedBackground } from '../common/theme/ThemeBackground';

/** EmptyFragment.SHOW_MESSAGE - the single key newInstance() puts in the arguments bundle. */
const SHOW_MESSAGE: string = 'SHOW_MESSAGE';

/** Fold an argument key so SHOW_MESSAGE, showMessage and show_message are one key. */
function normaliseArgKey(key: string): string {
  return key.toLowerCase().split('_').join('');
}

@Entry
@Component
export struct EmptyFragmentPage {
  /** ThemeHelper's black theme: the window background follows it. */
  @StorageProp(BLACK_THEME_KEY) blackTheme: boolean = false;

  /** The SHOW_MESSAGE argument as the MOUNTING host passes it: newInstance(true|false). */
  @Prop messageVisibility: boolean = false;
  /**
   * getArguments().getBoolean(SHOW_MESSAGE) - what empty_state_view's visibility branches on.
   * The source reads the argument ONCE, in onCreateView, and a host that wants the other variant
   * builds a NEW EmptyFragment, so this is derived once rather than watched.
   */
  @State showMessage: boolean = false;

  aboutToAppear(): void {
    // Whichever side delivered the argument wins; none delivering it leaves the source default
    // (getBoolean on a key the bundle never had). A MOUNTING host supplies it by initialising
    // either field - VideoDetailFragmentPage's EMPTY_TAB_TAG tab passes showMessage: true - so
    // an absent launch argument must not overwrite what the host already set.
    const launched: boolean | null = this.readLaunchArgument();
    if (launched !== null) {
      this.showMessage = launched;
    } else if (this.messageVisibility) {
      this.showMessage = true;
    }
  }

  /**
   * The launched half of the argument: the want parameter EntryAbility forwards as this page's
   * router param. null means this launch carried no SHOW_MESSAGE at all.
   */
  private readLaunchArgument(): boolean | null {
    const params: Record<string, Object> | undefined =
      router.getParams() as Record<string, Object> | undefined;
    if (params === undefined || params === null) {
      return null;
    }
    // The key's spelling is NOT ours to choose. The source constant is SHOW_MESSAGE, but the
    // capture records this state's launchArgs as {"showMessage": "true"} and the replay
    // deep-links it with exactly that key, so an exact-match read misses every real launch.
    // Match on the normalised key (case folded, underscores dropped) and both spellings land
    // on the same argument.
    const wanted: string = normaliseArgKey(SHOW_MESSAGE);
    const keys: string[] = Object.keys(params);
    for (const key of keys) {
      if (normaliseArgKey(key) !== wanted) {
        continue;
      }
      const raw: Object | undefined = params[key];
      if (raw === undefined || raw === null) {
        return null;
      }
      // A pushing page hands over the real boolean; a want parameter is always a string.
      return typeof raw === 'boolean' ? raw as boolean : raw.toString() === 'true';
    }
    return null;
  }

  build() {
    // RelativeLayout root. Carries the page-identity marker only.
    Column() {
      // NestedScrollView - no android:id in the source, so no .id() here. Its one child stays a
      // container so the GONE branch leaves Scroll with a child rather than none.
      Scroll() {
        Column() {
          // include @+id/empty_state_view: setVisibility(showMessage ? VISIBLE : GONE). The
          // false arm is the silent placeholder - the source draws nothing at all there.
          if (this.showMessage) {
            // list_empty_view.xml LinearLayout(vertical, gravity=center, minHeight=128dp).
            // S5, measured off S0115 (1080px / 360vp, density 3.0): the include sits 90dp below
            // the scroll top ([510-240]/3), the block is exactly 128vp tall ([894-510]/3) with
            // its two lines centred in it, and the 6dp gap is [726-708]/3.
            Column() {
              Text('¯\\_(ツ)_/¯')
                // textAppearance?android:attr/textAppearanceLarge = 22sp; the glyph measures
                // #1F1F1F on the #EEEEEE ground, which is textColorPrimary #DE000000 composited.
                .fontSize(22)
                .fontColor($r('app.color.on_surface'))
              Text($r('app.string.empty_list_subtitle'))
                // Default NewPipeTextView appearance: 14sp at textColorSecondary #8A000000
                // (measured #6D6D6D over #EEEEEE), gravity=center, paddingHorizontal=16dp.
                .fontSize(14)
                .fontColor($r('app.color.on_surface_variant'))
                .textAlign(TextAlign.Center)
                .margin({ top: 6 })
                .padding({ left: 16, right: 16 })
            }
            .id('empty_state_view')
            .width('100%')
            .constraintSize({ minHeight: 128 })
            .justifyContent(FlexAlign.Center)
            .alignItems(HorizontalAlign.Center)
            .margin({ top: 90 })
          }
        }
        .width('100%')
      }
      .width('100%')
      .height('100%')
    }
    .id('EmptyFragmentPage')
    .width('100%')
    .height('100%')
    // fragment_holder's ground in the capture: @color/light_background_color, sampled #EEEEEE.
    .backgroundColor(themedBackground(this.blackTheme))
  }
}
