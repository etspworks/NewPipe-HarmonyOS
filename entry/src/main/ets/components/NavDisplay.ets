/**
 * S3 structure - NavDisplay (comp_nav_display_compose).
 *
 * Port of shared/src/commonMain/kotlin/net/newpipe/app/navigation/NavDisplay.kt plus the
 * Navigator it is injected with (net/newpipe/app/navigation/NavModule.kt).
 *
 * The source composable owns nothing itself: Koin hands it a Navigator built with
 * parametersOf(startDestination, onCloseRequest); it renders `backstack`'s top entry through
 * `entryProvider = koinEntryProvider()` and its `onBack` is `navigator.navigateUp()`.
 *
 * On HarmonyOS the entryProvider is a @BuilderParam the HOST supplies, because the
 * destination -> screen mapping (navModule(): Destination.About -> AboutScreen(),
 * Destination.Settings -> SettingsHomeScreen()) is the host's containment, not this
 * component's. The Navigator is held by the host so its onBackPress can drive navigateUp().
 */
import { Destination } from '../model/enums/Destination';

/**
 * Port of the @Singleton Navigator (NavModule.kt:40).
 *
 * `backstack = mutableStateListOf(startDestination)` - reassigned rather than mutated in place
 * so @Observed notifies the @ObjectLink holder.
 */
@Observed
export class Navigator {
  /** Navigation backstack in compose. Never empty: it is seeded with the start destination. */
  backstack: Destination[];

  /** ComposeActivity passes ::finish here. */
  private onCloseRequest: () => void;

  constructor(startDestination: Destination, onCloseRequest: () => void) {
    this.backstack = [startDestination];
    this.onCloseRequest = onCloseRequest;
  }

  /** The entry NavDisplay renders - the last element of the back stack. */
  top(): Destination {
    return this.backstack[this.backstack.length - 1];
  }

  /**
   * Navigator.navigateUp(): pops when more than one entry remains, otherwise logs
   * "Cannot remove the only entry in backstack!" and calls onCloseRequest().
   * Returns true in both branches - the press was handled either way.
   */
  navigateUp(): boolean {
    if (this.backstack.length > 1) {
      this.backstack = this.backstack.slice(0, this.backstack.length - 1);
      return true;
    }
    this.onCloseRequest();
    return true;
  }
}

@Component
export struct NavDisplay {
  /** The injected Navigator - owned by the host so its onBackPress can call navigateUp(). */
  @ObjectLink navigator: Navigator;

  /** entryProvider = koinEntryProvider(): the host maps a destination to its screen. */
  @BuilderParam entry: (destination: Destination) => void = this.defaultEntry;

  @Builder
  defaultEntry(destination: Destination) {
    Text(destination)
  }

  build() {
    // NavDisplay(backStack = backstack, ...) renders the top entry of the stack.
    Column() {
      this.entry(this.navigator.top())
    }
    .width('100%')
    .height('100%')
  }
}
