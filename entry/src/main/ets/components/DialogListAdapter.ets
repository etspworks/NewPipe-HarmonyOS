/*
 * S3 - port of AddTabDialog.DialogListAdapter + AddTabDialog.ChooseTabListItem
 * (list_choose_tabs_dialog.xml): the BaseAdapter behind the "Choose Tab" dialog list.
 *
 * getView() binds tabIcon + tabName and nothing else; the CLICK is the dialog's
 * DialogInterface.OnClickListener (ChooseTabsFragment.addTab(availableTabs[which].tabId)), so it
 * is raised to the owner as onItemSelected(tabId) rather than handled here.
 */

import { hilog } from '@kit.PerformanceAnalysisKit';
import { mediaByName } from './SelectedTabsAdapter';

/** AddTabDialog.ChooseTabListItem: the icon is a drawable NAME, resolved at render time. */
export class ChooseTabListItem {
  tabId: number;
  itemName: string;
  itemIcon: string;

  constructor(tabId: number, itemName: string, itemIcon: string) {
    this.tabId = tabId;
    this.itemName = itemName;
    this.itemIcon = itemIcon;
  }
}

/** getCount() / getItem(position) over the availableTabs array. */
export class ChooseTabItemDataSource implements IDataSource {
  private items: ChooseTabListItem[] = [];
  private listeners: DataChangeListener[] = [];

  totalCount(): number {
    return this.items.length;
  }

  getData(index: number): ChooseTabListItem {
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

  submitList(items: ChooseTabListItem[]): void {
    this.items = items;
    this.listeners.forEach((listener: DataChangeListener) => {
      listener.onDataReloaded();
    });
  }
}

@Component
export struct DialogListAdapter {
  dataSource: ChooseTabItemDataSource = new ChooseTabItemDataSource();
  /** The dialog's OnClickListener: addTab(availableTabs[which].tabId). */
  onItemSelected: (tabId: number) => void = (tabId: number): void => {
    hilog.debug(0x0000, 'NewPipe', 'DialogListAdapter: onItemSelected not bound (%{public}d)',
      tabId);
  };

  build() {
    List() {
      LazyForEach(this.dataSource, (item: ChooseTabListItem, index: number) => {
        ListItem() {
          Row() {
            // getView(): `item.itemIcon > 0 ? item.itemIcon : fallbackIcon` (ic_whatshot).
            Image(mediaByName(item.itemIcon.length === 0 ? 'ic_whatshot' : item.itemIcon))
              .id('tabIcon')
              .width(24)
              .height(24)
              .objectFit(ImageFit.Contain)

            // ?textAppearanceListItem, one dialogPreferredPadding (24dp) past the icon.
            Text(item.itemName)
              .id('tabName')
              .fontSize(16)
              .fontColor($r('app.color.on_surface'))
              .maxLines(2)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .layoutWeight(1)
              .margin({ left: 24 })
          }
          // Rule 12 list-row exception: every row shares one id, resolved by index.
          .id('add_tab_dialog_itemroot')
          .width('100%')
          // ?listPreferredItemHeightSmall, inset by dialogPreferredPadding on both sides.
          .height(48)
          .padding({ left: 24, right: 24 })
          .alignItems(VerticalAlign.Center)
          .onClick((): void => {
            this.onItemSelected(item.tabId);
          })
        }
      }, (item: ChooseTabListItem, index: number) => `${item.tabId}-${index}`)
    }
    .id('select_dialog_listview')
    .width('100%')
    .height('100%')
  }
}
