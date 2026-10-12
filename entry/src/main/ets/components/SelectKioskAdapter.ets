/*
 * S3 - port of SelectKioskFragment.SelectKioskAdapter (select_kiosk_item.xml).
 *
 * The odd one of the four pickers: its list is built SYNCHRONOUSLY in the adapter constructor
 * from the in-process service registry
 *   for (StreamingService service : NewPipe.getServices())
 *     for (String kioskId : service.getKioskList().getAvailableKiosks())
 * so there is no RxJava load, no progressBar and NO empty-state view anywhere in
 * select_kiosk_fragment.xml. The row image carries no android:src either - the icon is set at
 * bind time from ServiceHelper.getIcon(serviceId).
 *
 * The row root keeps the source's OWN id, select_kiosk_itemroot, shared by every instance
 * (Rule 12's list-row exception).
 */

import { mediaByName } from './SelectedTabsAdapter';

/** select_kiosk_item.xml: a 48x42 glyph, 5dp before the title. */
const ICON_WIDTH: number = 48;
const ICON_HEIGHT: number = 42;
/** ?attr/textAppearanceListItem on itemTitleView - S0224 measures the row title line box at
 *  65px of 2340 at density 3.0, i.e. 16fp on the 52dp row. */
const ITEM_TITLE_TEXT_SIZE: number = 16;
const COLOR_ON_SURFACE: Resource = $r('app.color.on_surface');

/** Port of ServiceHelper.getIcon(serviceId) (ServiceHelper.kt:27-36) - the drawable's base name. */
export function serviceIconName(serviceId: number): string {
  if (serviceId === 0) {
    return 'ic_smart_display';
  }
  if (serviceId === 1) {
    return 'ic_cloud';
  }
  if (serviceId === 2) {
    return 'ic_placeholder_media_ccc';
  }
  if (serviceId === 3) {
    return 'ic_placeholder_peertube';
  }
  if (serviceId === 4) {
    return 'ic_placeholder_bandcamp';
  }
  return 'ic_circle';
}

/** SelectKioskAdapter.Entry(icon, serviceId, kioskId, kioskName). */
export class SelectKioskRow {
  serviceId: number;
  kioskId: string;
  /** format(service_kiosk_string, serviceName, getTranslatedKioskName(kioskId)). */
  kioskName: string;

  constructor(serviceId: number, kioskId: string, kioskName: string) {
    this.serviceId = serviceId;
    this.kioskId = kioskId;
    this.kioskName = kioskName;
  }

  /** ServiceHelper.getIcon(service.getServiceId()) - the row's icon field. */
  iconName(): string {
    return serviceIconName(this.serviceId);
  }
}

/** getItemCount() / the adapter's `kioskList`, as the LazyForEach source. */
export class SelectKioskDataSource implements IDataSource {
  private items: SelectKioskRow[] = [];
  private listeners: DataChangeListener[] = [];

  totalCount(): number {
    return this.items.length;
  }

  getData(index: number): SelectKioskRow {
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

  submitList(items: SelectKioskRow[]): void {
    this.items = items;
    this.listeners.forEach((listener: DataChangeListener) => {
      listener.onDataReloaded();
    });
  }
}

@Component
export struct SelectKioskAdapter {
  dataSource: SelectKioskDataSource = new SelectKioskDataSource();
  /** holder.view.setOnClickListener(view -> clickedItem(entry)) - by ENTRY, not by position. */
  onItemClicked: (item: SelectKioskRow) => void = (item: SelectKioskRow): void => {
    console.info('SelectKioskAdapter: onItemClicked not bound (' + item.kioskId + ')');
  };

  build() {
    List() {
      LazyForEach(this.dataSource, (item: SelectKioskRow) => {
        ListItem() {
          Row() {
            Image(mediaByName(item.iconName()))
              .id('itemThumbnailView')
              .width(ICON_WIDTH)
              .height(ICON_HEIGHT)
              .objectFit(ImageFit.Contain)
              // app:tint="@color/contrastColor" on the item ImageView - every service glyph
              // renders as a solid black silhouette in S0224, media.ccc and PeerTube included.
              .fillColor($r('app.color.contrastColor'))
              .margin({ right: 5 })

            // holder.titleView.setText(entry.kioskName) - ?textAppearanceListItem, one line.
            Text(item.kioskName)
              .id('itemTitleView')
              .fontSize(ITEM_TITLE_TEXT_SIZE)
              .fontColor(COLOR_ON_SURFACE)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .layoutWeight(1)
          }
          .id('select_kiosk_itemroot')
          .width('100%')
          .padding(5)
          .alignItems(VerticalAlign.Center)
          .onClick((): void => {
            this.onItemClicked(item);
          })
        }
      }, (item: SelectKioskRow) => item.serviceId.toString() + '/' + item.kioskId)
    }
    .width('100%')
    .height('100%')
  }
}
