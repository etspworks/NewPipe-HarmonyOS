/*
 * S3 - port of PeertubeInstanceListFragment.InstanceListAdapter (item_instance.xml).
 *
 * ListAdapter<PeertubeInstance, TabViewHolder> over the fragment's currentList:
 *   submitList(list)                    -> InstanceListDataSource.submitList,
 *   onCreateViewHolder/onBindViewHolder -> the row below,
 *   swapItems(from, to)                 -> onMoveItem, raised by the List's own drag-sort,
 *   ItemTouchHelper.onSwiped(holder)    -> onSwipeRemove, raised by the row swipe,
 *   selectInstanceRB's checked-change   -> onSelectInstance, raised to the page.
 *
 * The adapter OWNS no state. The fragment holds the list, the selected instance and the JSON
 * write in onPause, so every row interaction is a callback up to the page - including the two
 * vetoes the source applies there and not here (a swipe on the SELECTED row is refused, and the
 * list is never allowed to become empty).
 *
 * The source's single-selection is a manually tracked `lastChecked` RadioButton across recycled
 * rows; here it is the page's one selected url, which is what a Radio group already expresses.
 * Because LazyForEach reuses a row while its key is unchanged, the key carries the selected flag -
 * otherwise picking another instance would leave both radios drawn as they were.
 *
 * No visual styling in this pass (S3): the card, its radius/elevation and the row metrics are S5.
 */

import { hilog } from '@kit.PerformanceAnalysisKit';
import { PeertubeInstance } from '../model/extractor/PeertubeInstance';
import { ServiceLocator } from '../common/di/ServiceLocator';

/** getItemCount()/getItem(position) over currentList, as the LazyForEach source. */
export class InstanceListDataSource implements IDataSource {
  private items: PeertubeInstance[] = [];
  private listeners: DataChangeListener[] = [];

  totalCount(): number {
    return this.items.length;
  }

  getData(index: number): PeertubeInstance {
    return this.items[index];
  }

  registerDataChangeListener(listener: DataChangeListener): void {
    if (this.listeners.indexOf(listener) < 0) {
      this.listeners.push(listener);
    }
  }

  unregisterDataChangeListener(listener: DataChangeListener): void {
    const pos: number = this.listeners.indexOf(listener);
    if (pos >= 0) {
      this.listeners.splice(pos, 1);
    }
  }

  /** submitList(list): the page owns the list and re-submits after every change. */
  submitList(items: PeertubeInstance[]): void {
    this.items = items;
    this.listeners.forEach((listener: DataChangeListener) => {
      listener.onDataReloaded();
    });
  }

  /** getCurrentList(), which the fragment copies before every mutation. */
  getCurrentList(): PeertubeInstance[] {
    return this.items;
  }
}

/**
 * swapItems(from, to) as ArkUI delivers the drag: the List's drag-sort raises ONE onMove(from, to)
 * on release, where ItemTouchHelper raised a Collections.swap per row of travel. Swapping the two
 * ends of a multi-row drag would scramble every row between them, so the row is spliced out and
 * back in - which is exactly what that run of adjacent swaps added up to. Out of range, or a move
 * that goes nowhere, returns the SAME array: the caller submits nothing and flags no save.
 */
export function moveInstance(list: PeertubeInstance[], from: number,
  to: number): PeertubeInstance[] {
  if (from === to || from < 0 || to < 0 || from >= list.length || to >= list.length) {
    return list;
  }
  const moved: PeertubeInstance[] = list.slice();
  moved.splice(to, 0, moved.splice(from, 1)[0]);
  return moved;
}

/** The one RadioButton group the recycled rows share (the source's `lastChecked` bookkeeping). */
const INSTANCE_RADIO_GROUP: string = 'peertube_instances';

/* S5 - style only. Every metric below is item_instance.xml's own (the CardView's 5/3dp margins,
 * its 5dp radius and 4dp elevation, the 24dp icon at 10dp, the 10dp text gutter, the name's 6dp
 * top and the url's 6dp bottom, and the handle's 16/12/10/12 padding), cross-checked against this
 * screen's base.ui.json at density 3.0. The colours are sampled from base.png. */
/** CardView's default light surface - the row card samples pure white. */
const COLOR_CARD: Resource = $r('app.color.surface');
/** ?android:textColorPrimary - #DE000000 over white is the capture's (33,33,33) instance name. */
const COLOR_ON_SURFACE: Resource = $r('app.color.on_surface');
/** ?android:textColorSecondary, the swipe label's colour. */
const COLOR_SECONDARY_TEXT: Resource = $r('app.color.on_surface_variant');
/** ?android:textColorLink - android:autoLink="web" draws the url black and underlined here. */
const COLOR_LINK: Resource = $r('app.color.accent');
/** ?attr/colorPrimary - selectInstanceRB's checked mark samples (229,57,53). */
const COLOR_PRIMARY: Resource = $r('app.color.primary');
/** The unchecked radio ring, per the one dialog capture this app records. */
const COLOR_RADIO_UNCHECKED: Resource = $r('app.color.on_surface_variant');
/** btn_radio_*_mtrl: a 20dp glyph centred in the capture's 32vp column, a 2dp ring, a 10dp dot. */
const RADIO_GLYPH_VP: number = 20;
const RADIO_RING_VP: number = 2;
const RADIO_DOT_VP: number = 10;
/** ic_drag_handle ships black and the capture draws it black. */
const COLOR_HANDLE: Resource = $r('app.color.accent');
/** app:cardElevation="4dp". */
const CARD_ELEVATION: number = 4;

@Component
export struct InstanceListAdapter {
  dataSource: InstanceListDataSource = new InstanceListDataSource();
  /** PeertubeHelper.getCurrentInstance().getUrl() - the row whose radio is checked. */
  @Prop selectedUrl: string = '';
  /** selectInstanceRB.onCheckedChange(true) -> selectInstance(instance) in the page. */
  onSelectInstance: (index: number) => void = (index: number): void => {
    hilog.debug(0x0000, 'NewPipe', 'InstanceListAdapter: onSelectInstance not bound (%{public}d)',
      index);
  };
  /** swapItems(fromPosition, toPosition) -> moveInstance(list) + submitList in the page. */
  onMoveItem: (fromIndex: number, toIndex: number) => void =
    (fromIndex: number, toIndex: number): void => {
      hilog.debug(0x0000, 'NewPipe', 'InstanceListAdapter: onMoveItem not bound (%{public}d)',
        fromIndex);
    };
  /** ItemTouchHelper.onSwiped(viewHolder) -> the page's remove-with-veto. */
  onSwipeRemove: (index: number) => void = (index: number): void => {
    hilog.debug(0x0000, 'NewPipe', 'InstanceListAdapter: onSwipeRemove not bound (%{public}d)',
      index);
  };

  /**
   * btn_radio_on_mtrl: AppCompat draws the CHECKED radio as a ring in ?attr/colorPrimary with a
   * dot at its centre. ArkUI's DOT indicator draws the inverse - a backplate filled with
   * checkedBackgroundColor and a white pie punched out of it - so the selected row rendered as a
   * solid red donut a third larger than the icon beside it. CUSTOM is the documented way to hand
   * the checked state its own drawing; the backplate is transparent, so this ring IS the glyph,
   * and the unchecked state keeps the component's own ring at the same 20vp diameter.
   */
  @Builder
  checkedRadioGlyph() {
    Stack() {
      // The stroke straddles the path, so an 18vp circle inside a 2vp ring measures 20vp across.
      Circle()
        .width(RADIO_GLYPH_VP - RADIO_RING_VP)
        .height(RADIO_GLYPH_VP - RADIO_RING_VP)
        .fill(Color.Transparent)
        .stroke(COLOR_PRIMARY)
        .strokeWidth(RADIO_RING_VP)
      Circle()
        .width(RADIO_DOT_VP)
        .height(RADIO_DOT_VP)
        .fill(COLOR_PRIMARY)
    }
    .width(RADIO_GLYPH_VP)
    .height(RADIO_GLYPH_VP)
  }

  /**
   * What the swipe uncovers. ItemTouchHelper paints no button - the row is DISMISSED once the
   * swipe passes the threshold - so this is a label, never a second tap target.
   */
  @Builder
  swipeRemoveArea() {
    Row() {
      Text($r('app.string.delete'))
        .fontSize(14)
        .fontColor(COLOR_SECONDARY_TEXT)
    }
    .height('100%')
    .padding({ left: 16, right: 16 })
    .justifyContent(FlexAlign.Center)
    .alignItems(VerticalAlign.Center)
  }

  build() {
    List() {
      LazyForEach(this.dataSource, (item: PeertubeInstance, index: number) => {
        ListItem() {
          // The RelativeLayout inside the CardView: what ItemTouchHelper swipes away.
          Row() {
            // instanceIcon: setImageResource(ic_placeholder_peertube) - a fixed drawable, so it
            // carries no id and no listener.
            // A 24dp glyph 10dp in from the card's left edge; the placeholder ships in colour,
            // so it takes no tint.
            Image($r('app.media.ic_placeholder_peertube'))
              .width(24)
              .height(24)
              .margin({ left: 10 })
              .objectFit(ImageFit.Contain)
              // An Image is draggable by default, and that SYSTEM drag lifts a pixelmap out of
              // the row instead of letting the List's drag-sort have the long-press.
              .draggable(false)

            Column() {
              // itemBinding.instanceName.setText(instance.getName())
              // ?textAppearanceListItem: 16sp on ?android:textColorPrimary, 6dp below the card top.
              Text(item.getName())
                .id('instanceName')
                .width('100%')
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .fontSize(16)
                .lineHeight(22)
                .fontColor(COLOR_ON_SURFACE)
                .margin({ top: 6 })

              // itemBinding.instanceUrl.setText(instance.getUrl()); android:autoLink="web" makes
              // Linkify attach a URLSpan, so the url IS tappable and opens it outside the app -
              // the source capture of this tap lands in the browser (isExternal). The adapter and
              // the fragment attach no listener of their own, which is why this calls the shared
              // opener directly instead of routing a callback up to the page.
              // ?textAppearanceListItemSecondary at 14sp, drawn as a link: the capture samples it
              // black and underlined.
              Text(item.getUrl())
                .id('instanceUrl')
                .onClick(() => {
                  ServiceLocator.get().share.openUrlInBrowser(item.getUrl())
                    .catch((err: Error): void => {
                      hilog.warn(0x0000, 'InstanceListAdapter',
                        'openUrlInBrowser failed: %{public}s', err.message);
                    });
                })
                .width('100%')
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .fontSize(14)
                .lineHeight(19)
                .fontColor(COLOR_LINK)
                .decoration({ type: TextDecorationType.Underline, color: COLOR_LINK })
                .margin({ bottom: 6 })
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)
            // android:layout_marginLeft="10dp" from instanceIcon.
            .margin({ left: 10 })

            // selectInstanceRB: one selection group across every row. Checking it calls
            // selectInstance(instance), which also raises Constants.KEY_MAIN_PAGE_CHANGE (S4).
            // The capture measures the radio at [819,476][915,572] - 32x32vp at density 3.0 -
            // but that is the VIEW: btn_radio_*_mtrl draws a 20dp glyph inside it, which is the
            // 20vp box plus the 6vp gutters below. Neither of ArkUI's built-in indicators is an
            // AppCompat radio (see checkedRadioGlyph), so the checked state is drawn here.
            Radio({
              value: item.getUrl(),
              group: INSTANCE_RADIO_GROUP,
              indicatorType: RadioIndicatorType.CUSTOM,
              indicatorBuilder: (): void => {
                this.checkedRadioGlyph();
              }
            })
              .id('selectInstanceRB')
              .checked(item.getUrl() === this.selectedUrl)
              .width(RADIO_GLYPH_VP)
              .height(RADIO_GLYPH_VP)
              .margin({ left: 6, right: 6 })
              .radioStyle({
                // The glyph is the builder's ring; a filled backplate is what made it a donut.
                checkedBackgroundColor: Color.Transparent,
                uncheckedBorderColor: COLOR_RADIO_UNCHECKED
              })
              .onChange((isChecked: boolean): void => {
                if (isChecked) {
                  this.onSelectInstance(index);
                }
              })

            // handle: the grip the row is held by. The drag itself is the List's, raised by the
            // ListItem's long-press wherever the row is held - a touch stream of our own here only
            // took the gesture away from it. The 24dp glyph inside the XML's 16/12/10/12 padding
            // is the capture's 50x48vp target.
            Image($r('app.media.ic_drag_handle'))
              .id('handle')
              .width(50)
              .height(48)
              .padding({ left: 16, top: 12, right: 10, bottom: 12 })
              .objectFit(ImageFit.Contain)
              .fillColor(COLOR_HANDLE)
              .draggable(false)
          }
          .id('instance_row_swipe')
          .width('100%')
          .alignItems(VerticalAlign.Center)
          // The CardView itself: 5dp side / 3dp vertical margins, a 5dp radius, 4dp elevation and
          // ?listPreferredItemHeightSmall as its floor.
          .constraintSize({ minHeight: 48 })
          .margin({ left: 5, right: 5, top: 3, bottom: 3 })
          .backgroundColor(COLOR_CARD)
          .borderRadius(5)
          .shadow({
            radius: CARD_ELEVATION,
            color: '#33000000',
            offsetX: 0,
            offsetY: 2
          })
        }
        // Rule 12 list-row exception: every row shares one id, resolved by index at replay.
        .id('instance_itemroot')
        .swipeAction({
          start: {
            builder: (): void => {
              this.swipeRemoveArea();
            },
            onAction: (): void => {
              this.onSwipeRemove(index);
            }
          },
          end: {
            builder: (): void => {
              this.swipeRemoveArea();
            },
            onAction: (): void => {
              this.onSwipeRemove(index);
            }
          }
        })
      }, (item: PeertubeInstance) => `${item.getUrl()}-${item.getUrl() === this.selectedUrl}`)
        // ItemTouchHelper's drag, as ArkUI spells it: the List lifts the held row, shuffles the
        // rest under it and clamps it to both ends by itself, then reports the one move on
        // release. A PanGesture of ours never beat the List's own scroll, which is why by touch
        // this list could not be reordered at all.
        .onMove((from: number, to: number): void => {
          this.onMoveItem(from, to);
        })
    }
    .width('100%')
    .height('100%')
    // The inner scrollbar's touch zone covers the handle at the row's right edge, and a finger
    // that lands on it grabs the bar instead of the row (AceScrollBar). The RecyclerView draws
    // no scrollbar here either.
    .scrollBar(BarState.Off)
  }
}
