/**
 * comp_mini_player_bar - the collapsed player: MainPlayerUi's mini variant, docked at the bottom
 * of whatever screen is on top.
 *
 * WHY IT IS A COMPONENT AND NOT A @Builder. Upstream, EVERY screen is a Fragment inside
 * MainActivity, so activity_main.xml's fragment_player_holder - the hideable BottomSheet that
 * carries VideoDetailFragment collapsed - is part of the ONE Activity layout and is therefore
 * docked no matter which fragment is showing. This port made each fragment a router @Entry page
 * instead, so a bar living as a private @Builder inside MainActivityPage can only ever be drawn
 * on MainActivityPage; every screen reached by router.pushUrl structurally loses it (TC-KIOSK-175:
 * background playback starts on the Bandcamp album screen and no bar appears). This file is that
 * @Builder lifted out verbatim so a pushed page can dock it too.
 *
 * IT NEEDS NOTHING FROM ITS HOST. `PlayerService.state` and `PlayerService.currentInfo` are
 * BehaviorSubjects, so subscribing replays the current value immediately: mounting this component
 * anywhere is enough for it to know what is playing and whether to show itself at all. A host
 * docks it by putting `MiniPlayerBar()` last inside a bottom-aligned Stack - no state to pass, no
 * lifecycle to drive. While the player is IDLE the bar is Visibility.None, which takes it out of
 * layout entirely, so an always-mounted host costs nothing.
 *
 * The bar itself reopens the full player for the stream it shows; the three icons are queue,
 * play/pause and close, and they must not open the player with it.
 */
import { router } from '@kit.ArkUI';
import { PlayerService, PlayerStatus } from '../common/player/PlayerService';
import { MediaSessionService } from '../common/player/MediaSessionService';
import { StreamInfo } from '../model/extractor/StreamInfo';
import { choosePreferredImage } from '../common/image/ImageLoader';
import { CompositeDisposable } from '../common/rx/Rx';
import { BLACK_THEME_KEY, themedBackground } from '../common/theme/ThemeBackground';

/** ?android:attr/windowBackground = @color/light_background_color. Capture: #EEEEEE. */
const COLOR_SURFACE: Resource = $r('app.color.background');
/** ?android:textColorPrimary (87% black). Over #EEEEEE that is the measured #1F1F1F. */
const COLOR_ON_SURFACE: Resource = $r('app.color.on_surface');
/** ?android:textColorSecondary (54%), for the uploader line under the title. */
const COLOR_ON_SURFACE_VARIANT: Resource = $r('app.color.on_surface_variant');
const ICON_SIZE: number = 24;
/** The collapsed player's docked height: a 16:9 thumbnail at 68x38 plus its 8vp padding. */
const MINI_PLAYER_HEIGHT: number = 54;
/** How far a vertical drag on the bar has to travel before it counts as a swipe, in vp. */
const SWIPE_MIN_VP: number = 24;

@Component
export struct MiniPlayerBar {
  /** ThemeHelper's black theme: the window background follows it. */
  @StorageProp(BLACK_THEME_KEY) blackTheme: boolean = false;

  /**
   * `.id()` is APPLICATION-global, and a docked bar is by definition alive on more than one page
   * at once: MainActivityPage sits in the router stack under whatever was pushed on top of it, so
   * both copies exist together. Every host but the shell therefore passes a prefix of its own
   * ('playlist_', 'channel_', ...) so the four ids below stay unique. The default is empty, which
   * keeps the shell's bar on exactly the slugs it already had.
   */
  @Prop idPrefix: string = '';
  /**
   * Told whenever the bar's own visibility flips, for a host that has something ELSE at the bottom
   * of the screen and must keep it clear: ChannelFragmentPage's notify snackbar, which is docked
   * to the same edge, and CommentRepliesFragmentPage's list, which the bar overlays because that
   * page's root is a Stack. The default is a no-op, so every host that simply appends the bar to
   * a Column passes nothing - there the bar takes its own 54vp out of the list and no one has to
   * know it is there.
   */
  onVisibilityChange: (visible: boolean) => void = (): void => {
  };
  /** PlayerHolder.getInstance().isPlayerOpen(): the sheet is hidden while no player exists. */
  @State barVisible: boolean = false;
  /** What the bar shows: the current stream, and whether it is playing. */
  @State miniTitle: string = '';
  @State miniUploader: string = '';
  @State miniThumbnail: string = '';
  @State miniPlaying: boolean = false;
  /** Rule 8: every subscription is disposed in aboutToDisappear. */
  private disposables: CompositeDisposable = new CompositeDisposable();

  aboutToAppear(): void {
    // Keeps the bar in step with the player for its whole lifetime, both ways.
    this.disposables.add(PlayerService.getInstance().state
      .subscribeCallbacks((status: PlayerStatus): void => {
        this.barVisible = status !== PlayerStatus.IDLE;
        this.miniPlaying = status === PlayerStatus.PLAYING;
        this.onVisibilityChange(this.barVisible);
      }));
    // The bar needs to say WHAT is playing, which `state` does not carry.
    this.disposables.add(PlayerService.getInstance().currentInfo
      .subscribeCallbacks((info: StreamInfo | null): void => {
        this.miniTitle = info === null ? '' : info.getName();
        this.miniUploader = info === null ? '' : info.getUploaderName();
        const thumbnail: string | null =
          info === null ? null : choosePreferredImage(info.getThumbnails());
        this.miniThumbnail = thumbnail === null ? '' : thumbnail;
      }));
  }

  aboutToDisappear(): void {
    this.disposables.dispose();
  }

  build() {
    Row() {
      if (this.miniThumbnail.length > 0) {
        Image(this.miniThumbnail)
          .width(68)
          .height(38)
          .objectFit(ImageFit.Cover)
          .margin({ right: 8 })
      }
      Column() {
        Text(this.miniTitle)
          .fontSize(14)
          .fontColor(COLOR_ON_SURFACE)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
        if (this.miniUploader.length > 0) {
          Text(this.miniUploader)
            .fontSize(12)
            .fontColor(COLOR_ON_SURFACE_VARIANT)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
        }
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      // Only the text block carries the expand tap, so the icons beside it stay independent.
      .onClick((): void => {
        this.openCurrentStream();
      })

      Image($r('app.media.ic_playlist_play'))
        .width(ICON_SIZE)
        .height(ICON_SIZE)
        .fillColor(COLOR_ON_SURFACE)
        .margin({ left: 8 })
        .id(this.idPrefix + 'mini_player_queue')
        .onClick((): void => {
          router.pushUrl({ url: 'pages/PlayQueueActivityPage' });
        })
      Image(this.miniPlaying ? $r('app.media.ic_pause') : $r('app.media.ic_play_arrow'))
        .width(ICON_SIZE)
        .height(ICON_SIZE)
        .fillColor(COLOR_ON_SURFACE)
        .margin({ left: 8 })
        .id(this.idPrefix + 'mini_player_play_pause')
        .onClick((): void => {
          PlayerService.getInstance().togglePlayPause();
        })
      Image($r('app.media.ic_close'))
        .width(ICON_SIZE)
        .height(ICON_SIZE)
        .fillColor(COLOR_ON_SURFACE)
        .margin({ left: 8 })
        .id(this.idPrefix + 'mini_player_close')
        .onClick((): void => {
          this.closePlayer();
        })
    }
    .id(this.idPrefix + 'fragment_player_holder')
    .width('100%')
    .height(MINI_PLAYER_HEIGHT)
    .padding({ left: 8, right: 8 })
    .alignItems(VerticalAlign.Center)
    .backgroundColor(themedBackground(this.blackTheme))
    // Visibility.None, not a conditional root: the node leaves layout completely while the player
    // is IDLE, so a host can mount the bar unconditionally and still get its full height back.
    .visibility(this.barVisible ? Visibility.Visible : Visibility.None)
    // BottomSheetBehavior on the collapsed sheet: dragged up it expands into the full player
    // (FL-187), dragged down it goes to STATE_HIDDEN, whose cleanUp() stops the player (FL-188).
    .gesture(PanGesture({ direction: PanDirection.Vertical })
      .onActionEnd((event: GestureEvent): void => {
        if (event.offsetY < -SWIPE_MIN_VP) {
          this.openCurrentStream();
        } else if (event.offsetY > SWIPE_MIN_VP) {
          this.closePlayer();
        }
      }))
  }

  /**
   * Dismiss AND stop: release() drives the player to IDLE, and the state subscription takes the
   * bar down off that. A second tap cannot arrive - the bar is gone - and release() is safe on an
   * already-released player either way.
   */
  private closePlayer(): void {
    PlayerService.getInstance().release();
    MediaSessionService.getInstance().stop();
  }

  /** Tapping the bar reopens VideoDetailFragment on the stream the player is on. */
  private openCurrentStream(): void {
    const info: StreamInfo | null = PlayerService.getInstance().currentInfo.getValue();
    if (info === null) {
      return;
    }
    router.pushUrl({
      url: 'pages/VideoDetailFragmentPage',
      params: {
        'serviceId': info.getServiceId(),
        'url': info.getUrl(),
        'name': info.getName()
      }
    });
  }
}
