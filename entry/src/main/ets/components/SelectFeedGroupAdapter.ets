/*
 * S3 - port of SelectFeedGroupFragment.SelectFeedGroupAdapter (select_feed_group_item.xml).
 *
 * The structural twin of SelectChannelAdapter with ONE difference the source insists on: the row
 * image is a LOCAL drawable resolved from the FeedGroupIcon enum
 * (holder.thumbnailView.setImageResource(entry.getIcon().getDrawableResource())) - no image
 * loader, no network, so there is no shouldLoadImages() branch here.
 *
 * The row root keeps the source's OWN id, select_feed_group_itemroot, shared by every instance
 * (Rule 12's list-row exception).
 */

import { FeedGroupIcon, feedGroupIconDrawable } from '../model/enums/FeedGroupIcon';
import { mediaByName } from './SelectedTabsAdapter';

/** select_feed_group_item.xml: a 24dp glyph, 3dp in from the start, 8dp before the title. */
const ICON_SIZE: number = 24;
/** ?attr/textAppearanceListItem on itemTitleView; the glyph carries no android:tint in the
 *  source item layout, so it is drawn as authored on the #EEEEEE panel. */
const ITEM_TITLE_TEXT_SIZE: number = 16;
const COLOR_ON_SURFACE: Resource = $r('app.color.on_surface');

/** What the row binds out of a FeedGroupEntity: uid, name and icon. */
export class SelectFeedGroupRow {
  uid: number;
  name: string;
  icon: FeedGroupIcon;

  constructor(uid: number, name: string, icon: FeedGroupIcon) {
    this.uid = uid;
    this.name = name;
    this.icon = icon;
  }

  /** FeedGroupIcon.getDrawableResource() - the migrated media resource's base name. */
  drawableName(): string {
    return feedGroupIconDrawable(this.icon);
  }
}

/** getItemCount() / the fragment's `feedGroups`, as the LazyForEach source. */
export class SelectFeedGroupDataSource implements IDataSource {
  private items: SelectFeedGroupRow[] = [];
  private listeners: DataChangeListener[] = [];

  totalCount(): number {
    return this.items.length;
  }

  getData(index: number): SelectFeedGroupRow {
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

  /** displayFeedGroups(newFeedGroups): the page re-submits the whole list. */
  submitList(items: SelectFeedGroupRow[]): void {
    this.items = items;
    this.listeners.forEach((listener: DataChangeListener) => {
      listener.onDataReloaded();
    });
  }
}

@Component
export struct SelectFeedGroupAdapter {
  dataSource: SelectFeedGroupDataSource = new SelectFeedGroupDataSource();
  /** holder.view.setOnClickListener(view -> clickedItem(position)), raised up to the page. */
  onItemClicked: (item: SelectFeedGroupRow) => void = (item: SelectFeedGroupRow): void => {
    console.info('SelectFeedGroupAdapter: onItemClicked not bound (' + item.name + ')');
  };

  build() {
    List() {
      LazyForEach(this.dataSource, (item: SelectFeedGroupRow) => {
        ListItem() {
          Row() {
            Image(mediaByName(item.drawableName()))
              .id('itemThumbnailView')
              .width(ICON_SIZE)
              .height(ICON_SIZE)
              .objectFit(ImageFit.Contain)
              .margin({ left: 3, right: 8 })

            // holder.titleView.setText(entry.getName()) - ?textAppearanceListItem, one line.
            Text(item.name)
              .id('itemTitleView')
              .fontSize(ITEM_TITLE_TEXT_SIZE)
              .fontColor(COLOR_ON_SURFACE)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .layoutWeight(1)
              .margin({ left: 8, top: 6, bottom: 6 })
          }
          .id('select_feed_group_itemroot')
          .width('100%')
          .padding(5)
          .alignItems(VerticalAlign.Center)
          .onClick((): void => {
            this.onItemClicked(item);
          })
        }
      }, (item: SelectFeedGroupRow) => item.uid.toString())
    }
    .width('100%')
    .height('100%')
  }
}
