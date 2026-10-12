/*
 * S3 - port of org.schabi.newpipe.info_list.StreamSegmentAdapter + StreamSegmentItem
 * (item_stream_segment.xml), the CHAPTERS list the player's items-list panel shows when
 * segmentsButton is pressed.
 *
 * ArkUI has no adapter object, so the split is the one InfoListAdapter already uses: the backing
 * list and its notify* mutations become an IDataSource, and onCreateViewHolder becomes the row
 * this struct renders. Selection state (selectSegment / currentIndex) is a @Prop index, because
 * the source's only use of it is highlighting one row.
 *
 * Rule 12's list-row exception: every row carries the SAME id, the source's own
 * @+id/stream_segment_itemroot, and the replay resolves a row by index.
 */
import { hilog } from '@kit.PerformanceAnalysisKit';
import { Localization } from '../common/i18n/Localization';
import { StreamSegment } from '../model/extractor/StreamSegment';

/** setItems(info) / clear(): the adapter's backing list. */
export class StreamSegmentDataSource implements IDataSource {
  private items: StreamSegment[] = [];
  private listeners: DataChangeListener[] = [];

  totalCount(): number {
    return this.items.length;
  }

  getData(index: number): StreamSegment {
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

  /** Port of setItems(info): returns true when the stream actually has segments. */
  setItems(segments: StreamSegment[]): boolean {
    this.items = segments.slice();
    this.notifyReloaded();
    return this.items.length > 0;
  }

  clear(): void {
    if (this.items.length === 0) {
      return;
    }
    this.items = [];
    this.notifyReloaded();
  }

  private notifyReloaded(): void {
    this.listeners.forEach((listener: DataChangeListener) => {
      listener.onDataReloaded();
    });
  }
}

@Component
export struct StreamSegmentAdapter {
  dataSource: StreamSegmentDataSource = new StreamSegmentDataSource();
  /** currentIndex - the segment the playhead is inside; selectSegmentAt() moves it. */
  @Prop currentIndex: number = 0;
  /** StreamSegmentListener.onItemClick(item, seconds) -> player.seekTo(seconds * 1000). */
  onItemClick: (segment: StreamSegment) => void = (segment: StreamSegment): void => {
    hilog.debug(0x0000, 'NewPipe', 'StreamSegmentAdapter: click %{public}s unbound',
      segment.getTitle());
  };
  /** StreamSegmentListener.onItemLongClick(item, seconds) -> share the url at that offset. */
  onItemLongClick: (segment: StreamSegment) => void = (segment: StreamSegment): void => {
    hilog.debug(0x0000, 'NewPipe', 'StreamSegmentAdapter: long-click %{public}s unbound',
      segment.getTitle());
  };

  /** previewUrl is nullable in the extractor model; an empty string renders no frame. */
  private previewUrlOf(segment: StreamSegment): string {
    const url: string | null = segment.getPreviewUrl();
    return url === null ? '' : url;
  }

  /** textViewChannel is GONE when the segment names no channel. */
  private channelOf(segment: StreamSegment): string {
    const name: string | null = segment.getChannelName();
    return name === null ? '' : name;
  }

  build() {
    List() {
      LazyForEach(this.dataSource, (segment: StreamSegment, index: number) => {
        ListItem() {
          Row() {
            Image(this.previewUrlOf(segment))
              .id('previewImage')
              .width(80)
              .height(45)
              .objectFit(ImageFit.Cover)

            Column() {
              Text(segment.getTitle())
                .id('textViewTitle')
              if (this.channelOf(segment).length > 0) {
                Text(this.channelOf(segment))
                  .id('textViewChannel')
              }
              // list_stream_segment_item.xml binds the start as a TIMESTAMP - the reference's
              // rows read 00:00 / 00:05, not "0s" / "5s". Same formatter the seekbar uses.
              Text(Localization.getDurationString(segment.getStartTimeSeconds()))
                .id('textViewStartSeconds')
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)
          }
          // The whole row is the tap target, not the inner Text - an inner-child handler is the
          // "visible but untappable" bug class.
          .id('stream_segment_itemroot')
          .width('100%')
          .onClick(() => {
            this.onItemClick(segment);
          })
          .gesture(LongPressGesture().onAction(() => {
            this.onItemLongClick(segment);
          }))
        }
      }, (segment: StreamSegment, index: number) => `${index}-${segment.getStartTimeSeconds()}`)
    }
    .id('itemsList')
    .width('100%')
    .height('100%')
    .cachedCount(5)
  }
}
