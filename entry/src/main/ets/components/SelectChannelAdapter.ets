/*
 * S3 - port of SelectChannelFragment.SelectChannelAdapter (select_channel_item.xml).
 *
 * RecyclerView.Adapter over the fragment's `subscriptions` list:
 *   onCreateViewHolder/onBindViewHolder -> the row below (itemThumbnailView / itemTitleView),
 *   getItemCount()                      -> SelectChannelDataSource (IDataSource),
 *   holder.view.setOnClickListener(view -> clickedItem(position)) -> onItemClicked.
 *
 * The adapter OWNS no state: the fragment owns `subscriptions`, so the click is a callback up to
 * the page, which calls the host's OnSelectedListener and then dismiss()es.
 *
 * The row root keeps the source's OWN id, select_channel_itemroot, shared by every instance
 * (Rule 12's list-row exception: the replay resolves tap-card-N by index).
 */

import { shouldLoadImages } from '../common/image/ImageLoader';

/** select_channel_item.xml: a 42dp circular avatar, 3dp in from the start, 8dp before the title. */
const AVATAR_SIZE: number = 42;
/** ?attr/textAppearanceListItem on itemTitleView, 87% black on the #EEEEEE dialog panel. */
const ITEM_TITLE_TEXT_SIZE: number = 16;
const COLOR_ON_SURFACE: Resource = $r('app.color.on_surface');

/**
 * What the row binds out of a SubscriptionEntity - name and avatarUrl per the bindingContract,
 * plus the serviceId/url the click callback carries to onChannelSelected().
 */
export class SelectChannelRow {
  uid: number;
  serviceId: number;
  url: string;
  name: string;
  avatarUrl: string;

  constructor(uid: number, serviceId: number, url: string, name: string, avatarUrl: string) {
    this.uid = uid;
    this.serviceId = serviceId;
    this.url = url;
    this.name = name;
    this.avatarUrl = avatarUrl;
  }
}

/** getItemCount() / the fragment's `subscriptions`, as the LazyForEach source. */
export class SelectChannelDataSource implements IDataSource {
  private items: SelectChannelRow[] = [];
  private listeners: DataChangeListener[] = [];

  totalCount(): number {
    return this.items.length;
  }

  getData(index: number): SelectChannelRow {
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

  /** displayChannels(newSubscriptions): the page re-submits the whole list. */
  submitList(items: SelectChannelRow[]): void {
    this.items = items;
    this.listeners.forEach((listener: DataChangeListener) => {
      listener.onDataReloaded();
    });
  }
}

@Component
export struct SelectChannelAdapter {
  dataSource: SelectChannelDataSource = new SelectChannelDataSource();
  /** clickedItem(position) -> onChannelSelected(serviceId, url, name) then dismiss(), in the page. */
  onItemClicked: (item: SelectChannelRow) => void = (item: SelectChannelRow): void => {
    console.info('SelectChannelAdapter: onItemClicked not bound (' + item.name + ')');
  };

  build() {
    List() {
      LazyForEach(this.dataSource, (item: SelectChannelRow) => {
        ListItem() {
          Row() {
            // CoilHelper.loadAvatar(holder.thumbnailView, entry.getAvatarUrl()) over the
            // @drawable/placeholder_person src, clipped by @style/CircularImageView.
            if (shouldLoadImages()) {
              Image(item.avatarUrl.length === 0
                ? $r('app.media.placeholder_person')
                : item.avatarUrl)
                .id('itemThumbnailView')
                .alt($r('app.media.placeholder_person'))
                .width(AVATAR_SIZE)
                .height(AVATAR_SIZE)
                .borderRadius(AVATAR_SIZE / 2)
                .clip(true)
                .objectFit(ImageFit.Cover)
                .margin({ left: 3, right: 8 })
            } else {
              Image($r('app.media.placeholder_person'))
                .id('itemThumbnailView')
                .width(AVATAR_SIZE)
                .height(AVATAR_SIZE)
                .borderRadius(AVATAR_SIZE / 2)
                .clip(true)
                .objectFit(ImageFit.Cover)
                .margin({ left: 3, right: 8 })
            }

            // holder.titleView.setText(entry.getName()) - ?textAppearanceListItem, one line.
            Text(item.name)
              .id('itemTitleView')
              .fontSize(ITEM_TITLE_TEXT_SIZE)
              .fontColor(COLOR_ON_SURFACE)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .layoutWeight(1)
          }
          .id('select_channel_itemroot')
          .width('100%')
          .padding(5)
          .alignItems(VerticalAlign.Center)
          .onClick((): void => {
            this.onItemClicked(item);
          })
        }
      }, (item: SelectChannelRow) => item.uid.toString())
    }
    .width('100%')
    .height('100%')
  }
}
