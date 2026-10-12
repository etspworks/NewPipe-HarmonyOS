/*
 * S3 — the app's generic action-list dialog (org.schabi.newpipe.info_list.dialog.InfoItemDialog):
 * a title plus a list of entries, one handler each. BookmarkFragment's long-press menu is the
 * same shape — an AlertDialog.Builder().setItems(items, action) whose entries are Rename, Delete
 * and, only when the thumbnail is permanent, Unset playlist thumbnail.
 */
import { hilog } from '@kit.PerformanceAnalysisKit';
import { ServiceLocator } from '../common/di/ServiceLocator';
import { PlayQueue, currentPlayQueue } from '../model/app/PlayQueue';
import { AppPreferences } from '../common/prefs/Preferences';
import { enable_watch_history_key, show_play_with_kodi_key } from '../common/prefs/SettingsKeys';
import { playWithKore } from '../common/util/KoreUtils';

/* S5 — style only. No capture state opens this dialog, so the values come from the source's own
 * theme: a Material alert with 24dp gutters, a 20sp title and 48dp setItems rows. */
const DIALOG_GUTTER: number = 24;
const DIALOG_TITLE_SIZE: number = 20;
const DIALOG_ROW_HEIGHT: number = 48;
const DIALOG_BODY_SIZE: number = 16;
const DIALOG_RADIUS: number = 4;
/** ?android:textColorPrimary (87% black). */
const COLOR_ON_SURFACE: Resource = $r('app.color.on_surface');

/** One `setItems` entry: its label, the `.id()` slug the replay taps, and what it does. */
export class DialogAction {
  readonly label: ResourceStr;
  readonly idSlug: string;
  readonly run: () => void;

  constructor(label: ResourceStr, idSlug: string, run: () => void) {
    this.label = label;
    this.idSlug = idSlug;
    this.run = run;
  }
}

/**
 * InfoItemDialog.Builder: the entries EVERY stream row carries, in the source's order.
 *
 * The source builds one dialog for every list that holds stream rows, so the menu is the same
 * wherever it is raised. This port inlined the list per screen instead, and the copies drifted:
 * the feed had all nine entries, search results had three, History four. Measured on the
 * reference, long press on "Me at the zoo":
 *
 *   search results: Enqueue / Start playing in the background / Start playing in a popup /
 *                   Download / Add to playlist / Share / Open in browser / Mark as watched /
 *                   Show channel details
 *   History:        the same, with Delete inserted after the start-here block
 *
 * The two conditionals are the source's own: the popup entry only when the item is not
 * audio-only (there is no video to float), Mark as watched only when it is not live (a running
 * broadcast has no end to have been watched to), and Show channel details only when the row
 * carries an uploader url.
 */
export class StreamMenuTarget {
  serviceId: number = 0;
  url: string = '';
  title: string = '';
  uploader: string = '';
  uploaderUrl: string = '';
  audioOnly: boolean = false;
  live: boolean = false;
}

/** What the host screen does for each entry. Share and Open in browser are the same everywhere. */
export class StreamMenuHandlers {
  onEnqueue: () => void = (): void => unboundDialogAction('enqueue');
  onEnqueueNext: () => void = (): void => unboundDialogAction('enqueue_next');
  onBackground: () => void = (): void => unboundDialogAction('start_here_on_background');
  onPopup: () => void = (): void => unboundDialogAction('start_here_on_popup');
  onDownload: () => void = (): void => unboundDialogAction('download');
  onAddToPlaylist: () => void = (): void => unboundDialogAction('add_to_playlist');
  onMarkAsWatched: () => void = (): void => unboundDialogAction('mark_as_watched');
  onShowChannelDetails: () => void = (): void => unboundDialogAction('show_channel_details');
  /**
   * Entries that belong to one screen alone. The source puts them straight after the start-here
   * block - History's Delete sits fourth on the reference, before Download.
   */
  afterStartHere: DialogAction[] = [];
}

export function buildStreamMenuActions(target: StreamMenuTarget,
  handlers: StreamMenuHandlers): DialogAction[] {
  const actions: DialogAction[] = [];
  // InfoItemDialog.Builder.addEnqueueEntriesIfNeeded(): the enqueue entries exist only while a
  // player is actually running - there is nothing to append to otherwise. Measured on the
  // reference, the same media.ccc.de kiosk row: EIGHT entries with nothing playing, NINE with a
  // talk playing, the extra one being Enqueue at the head.
  const queue: PlayQueue | null = currentPlayQueue.getValue();
  if (queue !== null) {
    actions.push(new DialogAction($r('app.string.enqueue'), 'enqueue', handlers.onEnqueue));
    // ENQUEUE_NEXT only when something is queued after the playing item - otherwise it would be
    // the same as Enqueue.
    if (queue.getIndex() < queue.size() - 1) {
      actions.push(new DialogAction($r('app.string.enqueue_next_stream'), 'enqueue_next',
        handlers.onEnqueueNext));
    }
  }
  actions.push(new DialogAction($r('app.string.start_here_on_background'),
    'start_here_on_background', handlers.onBackground));
  if (!target.audioOnly) {
    actions.push(new DialogAction($r('app.string.start_here_on_popup'), 'start_here_on_popup',
      handlers.onPopup));
  }
  for (const extra of handlers.afterStartHere) {
    actions.push(extra);
  }
  actions.push(new DialogAction($r('app.string.download'), 'download', handlers.onDownload));
  actions.push(new DialogAction($r('app.string.add_to_playlist'), 'add_to_playlist',
    handlers.onAddToPlaylist));
  actions.push(new DialogAction($r('app.string.share'), 'share', (): void => {
    ServiceLocator.get().share.shareText(target.title, target.url);
  }));
  actions.push(new DialogAction($r('app.string.open_in_browser'), 'open_in_browser', (): void => {
    ServiceLocator.get().share.openUrlInBrowser(target.url);
  }));
  // addPlayWithKodiEntryIfNeeded(): KoreUtils.shouldShowPlayWithKodi(context, serviceId).
  if (readPref(show_play_with_kodi_key, false) && target.serviceId === YOUTUBE_SERVICE_ID) {
    actions.push(new DialogAction($r('app.string.play_with_kodi_title'), 'play_with_kodi',
      (): void => {
        playWithKore();
      }));
  }
  // addMarkAsWatchedEntryIfNeeded(): only while watch history is on, and never for a live stream.
  if (!target.live && readPref(enable_watch_history_key, true)) {
    actions.push(new DialogAction($r('app.string.mark_as_watched'), 'mark_as_watched',
      handlers.onMarkAsWatched));
  }
  if (target.uploaderUrl.length > 0) {
    actions.push(new DialogAction($r('app.string.show_channel_details'), 'show_channel_details',
      handlers.onShowChannelDetails));
  }
  return actions;
}

const YOUTUBE_SERVICE_ID: number = 0;

function readPref(key: string, defValue: boolean): boolean {
  try {
    return AppPreferences.instance().getBooleanSync(key, defValue);
  } catch (err) {
    return defValue;
  }
}

/** Logs an entry that has not been bound yet, so an action is never a silent no-op. */
export function unboundDialogAction(name: string): void {
  hilog.debug(0x0000, 'NewPipe', 'InfoItemDialog: %{public}s not bound', name);
}

/** @color/light_ripple_color - the pressed state of ?attr/selectableItemBackground. */
@Styles
function infoItemRowPressed() {
  .backgroundColor($r('app.color.ripple'))
}

@CustomDialog
export struct InfoItemDialog {
  controller?: CustomDialogController;
  /* S7 — @Link, not a plain member: every host builds its CustomDialogController in a field
   * initializer, so a by-value argument would freeze the empty title and zero rows captured at
   * construction and showInfoItemDialog()'s later assignments would never reach the dialog. */
  @Link title: string;
  @Link actions: DialogAction[];

  build() {
    Column() {
      Text(this.title)
        .id('info_item_dialog_title')
        .width('100%')
        .fontSize(DIALOG_TITLE_SIZE)
        .fontColor(COLOR_ON_SURFACE)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .padding({ left: DIALOG_GUTTER, right: DIALOG_GUTTER, top: 20, bottom: 12 })

      ForEach(this.actions, (action: DialogAction) => {
        Text(action.label)
          .id(action.idSlug)
          .width('100%')
          .height(DIALOG_ROW_HEIGHT)
          .fontSize(DIALOG_BODY_SIZE)
          .fontColor(COLOR_ON_SURFACE)
          .align(Alignment.Start)
          .padding({ left: DIALOG_GUTTER, right: DIALOG_GUTTER })
          // A setItems row ripples on press (?attr/selectableItemBackground): a grey ground,
          // not the shrink ClickEffectLevel draws.
          .stateStyles({ pressed: infoItemRowPressed })
          .onClick(() => {
            this.controller?.close();
            action.run();
          })
      }, (action: DialogAction) => action.idSlug)
    }
    .width('100%')
    .padding({ bottom: 8 })
    .backgroundColor($r('app.color.dialog_background'))
    .borderRadius(DIALOG_RADIUS)
  }
}
