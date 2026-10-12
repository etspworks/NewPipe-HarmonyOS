/*
 * Caption appearance - how a subtitle cue is drawn.
 *
 * THIS SCREEN HAS NO COUNTERPART IN THE SOURCE, and that is a deviation recorded on T-0190, not an
 * invention. Android NewPipe's Captions row starts Settings.ACTION_CAPTIONING_SETTINGS and then
 * READS what the user chose there through CaptioningManager. HarmonyOS NEXT has no such screen:
 * `bm dump -n com.huawei.hmos.settings` declares one accessibility uri, `accessibility_feature`,
 * which lands on the Accessibility root with no caption control on it, and
 * accessibility.getCaptionsManager() reads enabled=false with no public setter and no CLI able to
 * change it (docs/qa/evidence/fix-T-0190b/captions-probe.txt).
 *
 * So the only route left by which a user here can change how a cue looks is in the app, and this is
 * it. It offers exactly what caption_setting_description has always promised - "Modify player
 * caption text scale and background styles" - and nothing more. The system style still wins where a
 * device supplies one: resolveCueStyle() layers this override on top of it.
 *
 * Structure, toolbar and row metrics are AppearanceSettingsFragmentPage's; this page is reached the
 * same way, by router.pushUrl from that screen's Captions row.
 */

import { router } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';
import {
  CaptionBackground, CueStyle, DEFAULT_CUE_STYLE, resolveCueStyle, UserCaptionStyle
} from '../common/player/CaptionStyle';
import {
  readSystemCaptionStyle, readUserCaptionStyle, writeUserCaptionStyle
} from '../common/player/SystemCaptions';

const TAG: string = 'CaptionAppearanceFragmentPage';

const COLOR_PRIMARY: Resource = $r('app.color.primary');
const COLOR_ON_SURFACE: Resource = $r('app.color.on_surface');
const COLOR_SECONDARY_TEXT: Resource = $r('app.color.on_surface_variant');

/** The resolver's own range, which it clamps to anyway; the slider just never offers worse. */
const MIN_SCALE: number = 0.5;
const MAX_SCALE: number = 3.0;
const SCALE_STEP: number = 0.25;

/** One background choice: the stored value and the string the row shows. */
class BackgroundOption {
  readonly value: CaptionBackground;
  readonly label: Resource;

  constructor(value: CaptionBackground, label: Resource) {
    this.value = value;
    this.label = label;
  }
}

@Entry
@Component
struct CaptionAppearanceFragmentPage {
  // `scale` and `background` are CustomComponent attribute names - a state field of
  // either name shadows the builder method and the compiler refuses it.
  @State private textScale: number = 1;
  @State private cueBackground: CaptionBackground = CaptionBackground.BLACK;
  /** What the cue would look like with the draft above - the same resolver the player uses. */
  @State private preview: CueStyle = DEFAULT_CUE_STYLE;

  private readonly backgrounds: BackgroundOption[] = [
    new BackgroundOption(CaptionBackground.BLACK, $r('app.string.caption_background_black')),
    new BackgroundOption(CaptionBackground.TRANSPARENT,
      $r('app.string.caption_background_transparent')),
    new BackgroundOption(CaptionBackground.NONE, $r('app.string.caption_background_none'))
  ];

  aboutToAppear(): void {
    this.load();
  }

  private async load(): Promise<void> {
    const stored: UserCaptionStyle | null = await readUserCaptionStyle();
    if (stored !== null) {
      this.textScale = stored.scale;
      this.cueBackground = stored.background;
    }
    this.refreshPreview();
  }

  /**
   * The preview is drawn by resolveCueStyle(), not by this page's own arithmetic - so what the
   * user sees here is what the player will draw, including the system style underneath.
   */
  private refreshPreview(): void {
    const draft: UserCaptionStyle = { scale: this.textScale, background: this.cueBackground };
    this.preview = resolveCueStyle(readSystemCaptionStyle(), draft);
  }

  /** Write on every change: this screen has no OK button, like the preference rows it sits with. */
  private async store(): Promise<void> {
    this.refreshPreview();
    const draft: UserCaptionStyle = { scale: this.textScale, background: this.cueBackground };
    try {
      await writeUserCaptionStyle(draft);
    } catch (err) {
      hilog.warn(0x0000, TAG, 'caption style not stored');
    }
  }

  build() {
    Column() {
      // toolbar_layout.xml, as AppearanceSettingsFragmentPage draws it: nothing above this page
      // draws a bar, so the Up affordance lives here.
      Row() {
        Image($r('app.media.ic_arrow_back'))
          .id('home')
          .accessibilityText($r('app.string.navigate_back'))
          .objectFit(ImageFit.Contain)
          .width(56)
          .height(56)
          .padding(16)
          .fillColor($r('app.color.on_primary'))
          .onClick(() => {
            router.back();
          })

        Text($r('app.string.caption_appearance_title'))
          .layoutWeight(1)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .fontSize(20)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.on_primary'))
          .margin({ left: 16 })
      }
      .width('100%')
      .height(56)
      .alignItems(VerticalAlign.Center)
      .backgroundColor(COLOR_PRIMARY)

      List() {
        // -- The preview ----------------------------------------------------------
        // Without this the "Requires app restart" in caption_setting_description is a real cost to
        // the user: they would change a number, leave, and only then find out what it did. The
        // reference does not need one because the system screen it opens has its own.
        ListItem() {
          Stack() {
            Text($r('app.string.caption_preview_sample'))
              .id('captionPreview')
              .textAlign(TextAlign.Center)
              .fontSize(this.preview.fontSizeFp)
              .fontColor(this.preview.fontColor)
              .backgroundColor(this.preview.backgroundColor)
              .padding({ left: 8, right: 8, top: 2, bottom: 2 })
          }
          .id('captionPreviewPanel')
          .width('100%')
          .height(140)
          // A cue is drawn over video, so the preview needs a dark ground to be judged against.
          .backgroundColor('#FF202020')
          .alignContent(Alignment.Center)
        }

        // -- Text scale -----------------------------------------------------------
        ListItem() {
          Column() {
            Row() {
              Text($r('app.string.caption_scale_title'))
                .layoutWeight(1)
                .fontSize(16)
                .lineHeight(20)
                .fontColor(COLOR_ON_SURFACE)
              Text(`${Math.round(this.textScale * 100)}%`)
                .id('captionScaleValue')
                .fontSize(14)
                .fontColor(COLOR_SECONDARY_TEXT)
            }
            .width('100%')

            Slider({
              value: this.textScale,
              min: MIN_SCALE,
              max: MAX_SCALE,
              step: SCALE_STEP,
              style: SliderStyle.OutSet
            })
              .id('captionScaleSlider')
              .width('100%')
              .selectedColor(COLOR_PRIMARY)
              .onChange((value: number, mode: SliderChangeMode) => {
                this.textScale = value;
                // Dragging fires continuously; the store is cheap, but only the settled value is
                // worth writing.
                if (mode === SliderChangeMode.End || mode === SliderChangeMode.Click) {
                  this.store();
                } else {
                  this.refreshPreview();
                }
              })
          }
          .width('100%')
          .padding({ left: 16, right: 16, top: 16, bottom: 16 })
          .alignItems(HorizontalAlign.Start)
        }

        // -- Background -----------------------------------------------------------
        ListItem() {
          Text($r('app.string.caption_background_title'))
            .width('100%')
            .fontSize(16)
            .lineHeight(20)
            .fontColor(COLOR_ON_SURFACE)
            .padding({ left: 16, right: 16, top: 16, bottom: 8 })
        }

        ForEach(this.backgrounds, (option: BackgroundOption) => {
          ListItem() {
            Row() {
              Text(option.label)
                .layoutWeight(1)
                .fontSize(16)
                .lineHeight(20)
                .fontColor(COLOR_ON_SURFACE)
              Radio({ value: option.value, group: 'caption_background' })
                .checked(this.cueBackground === option.value)
                .onClick(() => {
                  this.cueBackground = option.value;
                  this.store();
                })
            }
            .id(`caption_background_${option.value}`)
            .width('100%')
            .padding({ left: 16, right: 16, top: 12, bottom: 12 })
            .alignItems(VerticalAlign.Center)
            .onClick(() => {
              this.cueBackground = option.value;
              this.store();
            })
          }
        }, (option: BackgroundOption) => option.value)
      }
      .id('recycler_view')
      .layoutWeight(1)
      .width('100%')
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.surface'))
  }
}
