/*
 * PORT of com.nononsenseapps:filepicker 5.0.0 (TeamNewPipe fork), Rule 11.
 * `port_com_nononsenseapps_filepicker_via_com_github_teamnewpipe_nononsense_filepicker`.
 *
 * PORT THE BEHAVIOUR, NOT THE FILE TREE (the plan's own words). The picker CHROME - the activity,
 * the RecyclerView, the loaders - is replaced by `@kit.CoreFileKit` DocumentViewPicker
 * (svc_file_access), which is the HarmonyOS way to let a user choose a file and the only one that
 * needs no storage permission (contract section 2.4). What must survive is NewPipe's own subclass,
 * `FilePickerActivityHelper.CustomFilePickerFragment`, because the app relies on five behaviours
 * the system picker does not have. All five live in this module; the page that renders them is
 * `pages/CustomFilePickerPage.ets` (Phase 3):
 *
 *   1. enlarged row text - the page renders each row at `file_picker_items_text_size`
 *      (FilePickerActivityHelper.java:86-97). ITEM_TEXT_SIZE_RESOURCE below names the dimension.
 *   2. hidden directories ARE shown, hidden files are not (isItemVisible, :114-120).
 *   3. an empty new-file name is rejected with "Filename cannot be empty" and the confirm does
 *      not go through (onClickOk, :100-112) - validateNewFileName().
 *   4. Back stops at the chosen root: goUp() until isBackTop(), which never escapes above the
 *      start path (or the storage root) or above '/' (:47-56, :122-138).
 *   5. the list scrolls to top after each load (onLoadFinished, :140-145) - the page resets its
 *      scroller whenever listDirectory() returns.
 *
 * The sorting and base visibility rules come from the vendored library itself
 * (FilePickerFragment.compareFiles / isItemVisible, AbstractFilePickerFragment.isItemVisible).
 */

import { fileIo } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';

/** AbstractFilePickerFragment.MODE_*, verbatim. */
export enum FilePickerMode {
  FILE = 0,
  DIR = 1,
  FILE_AND_DIR = 2,
  NEW_FILE = 3
}

/** The dimension the rows are drawn at; behaviour 1. */
export const ITEM_TEXT_SIZE_RESOURCE: string = 'file_picker_items_text_size';

/** The message behaviour 3 shows; the migrated `<string name="file_name_empty_error">`. */
export const FILE_NAME_EMPTY_ERROR_RESOURCE: string = 'file_name_empty_error';

/** One row of the picker list. */
export class PickerEntry {
  path: string = '';
  name: string = '';
  isDirectory: boolean = false;
  isHidden: boolean = false;

  constructor(path: string, name: string, isDirectory: boolean, isHidden: boolean) {
    this.path = path;
    this.name = name;
    this.isDirectory = isDirectory;
    this.isHidden = isHidden;
  }
}

function baseName(path: string): string {
  const cleaned: string = path.length > 1 && path.endsWith('/')
    ? path.substring(0, path.length - 1)
    : path;
  const slash: number = cleaned.lastIndexOf('/');
  return slash < 0 ? cleaned : cleaned.substring(slash + 1);
}

/** Port of AbstractFilePickerFragment.getParent(from): never above '/'. */
export function parentOf(path: string): string {
  if (path === '/' || path.length === 0) {
    return '/';
  }
  const cleaned: string = path.endsWith('/') ? path.substring(0, path.length - 1) : path;
  const slash: number = cleaned.lastIndexOf('/');
  if (slash <= 0) {
    return '/';
  }
  return cleaned.substring(0, slash);
}

/**
 * Port of FilePickerFragment.compareFiles(lhs, rhs): directories before files, then by name,
 * case-insensitively.
 */
export function compareEntries(lhs: PickerEntry, rhs: PickerEntry): number {
  if (lhs.isDirectory && !rhs.isDirectory) {
    return -1;
  }
  if (rhs.isDirectory && !lhs.isDirectory) {
    return 1;
  }
  const a: string = lhs.name.toLowerCase();
  const b: string = rhs.name.toLowerCase();
  if (a < b) {
    return -1;
  }
  if (a > b) {
    return 1;
  }
  return 0;
}

/**
 * Port of CustomFilePickerFragment.isItemVisible(file) over the library's two-level rule:
 *   - NewPipe's override: a HIDDEN DIRECTORY is always visible.
 *   - FilePickerFragment: any other hidden item is not, unless showHiddenItems is on.
 *   - AbstractFilePickerFragment: a directory is always visible; a file only in a mode that can
 *     select files (FILE, FILE_AND_DIR, or NEW_FILE when an existing file may be replaced).
 */
export function isItemVisible(entry: PickerEntry, mode: FilePickerMode,
  showHiddenItems: boolean, allowExistingFile: boolean): boolean {
  // NewPipe's override: hidden directories are shown, so a user can reach e.g. /.NewPipe
  if (entry.isDirectory && entry.isHidden) {
    return true;
  }
  if (!showHiddenItems && entry.isHidden) {
    return false;
  }
  return entry.isDirectory
    || mode === FilePickerMode.FILE
    || mode === FilePickerMode.FILE_AND_DIR
    || (mode === FilePickerMode.NEW_FILE && allowExistingFile);
}

/**
 * The ceiling getBackTop() answers with, as pure string work so it can be checked without a
 * device: the sandbox root when the start path is inside it, otherwise the public
 * `Download/<bundle>` root when the start path is inside THAT, and only then the start path.
 */
export function backTopOf(startPath: string, sandboxRoot: string, publicRootMarker: string): string {
  if (sandboxRoot.length > 0 && startPath.includes(sandboxRoot)) {
    return sandboxRoot;
  }
  if (publicRootMarker.length > 0) {
    const at: number = startPath.indexOf(publicRootMarker);
    if (at >= 0) {
      return startPath.substring(0, at + publicRootMarker.length);
    }
  }
  return startPath;
}

/**
 * A path as the user should read it: the public `Download/<bundle>` root becomes
 * `<Downloads> › <app name>` and every folder under it follows with the same separator, so the
 * settings rows and the picker title show folder names instead of the raw
 * `/storage/Users/currentUser/Download/com.hmos.mobile` system path. Anything outside that root
 * is returned unchanged. Pure string work, checkable without a device.
 */
export function friendlyPathOf(path: string, publicRootMarker: string, downloadsLabel: string,
  appLabel: string): string {
  const at: number = publicRootMarker.length > 0 ? path.indexOf(publicRootMarker) : -1;
  if (at < 0) {
    return path;
  }
  const rest: string = path.substring(at + publicRootMarker.length);
  if (rest.length > 0 && !rest.startsWith('/')) {
    return path;  // `/Download/<bundle>foo` is a sibling, not inside the root
  }
  const parts: string[] = [downloadsLabel, appLabel];
  for (const segment of rest.split('/')) {
    if (segment.length > 0) {
      parts.push(segment);
    }
  }
  return parts.join(' \u203a ');
}

export class FilePicker {
  private context: common.UIAbilityContext | null = null;

  mode: FilePickerMode = FilePickerMode.FILE;
  allowMultiple: boolean = false;
  allowCreateDir: boolean = false;
  allowExistingFile: boolean = true;
  singleClick: boolean = false;
  showHiddenItems: boolean = false;

  /** The path the picker was opened at; behaviour 4 never goes above it. */
  startPath: string = '/';
  /** The directory currently listed. */
  currentPath: string = '/';

  /**
   * The tail of the one public root this platform grants - `/Download/<bundle>`. getBackTop()
   * uses it to find that root inside a start path; empty until init() has a context.
   */
  publicRootMarker: string = '';

  /** Called once from EntryAbility through ServiceLocator. */
  init(context: common.UIAbilityContext): void {
    this.context = context;
    // the source's default start path is external storage; the sandbox root is its analogue
    this.startPath = context.filesDir;
    this.currentPath = context.filesDir;
    this.publicRootMarker = `/Download/${context.abilityInfo.bundleName}`;
  }

  /** Port of setArgs(startPath, mode, allowMultiple, allowCreateDir, allowExistingFile, singleClick). */
  setArgs(startPath: string, mode: FilePickerMode, allowMultiple: boolean,
    allowCreateDir: boolean, allowExistingFile: boolean, singleClick: boolean): void {
    this.startPath = startPath.length > 0 ? startPath : this.startPath;
    this.currentPath = this.startPath;
    this.mode = mode;
    this.allowMultiple = allowMultiple;
    this.allowCreateDir = allowCreateDir;
    this.allowExistingFile = allowExistingFile;
    this.singleClick = singleClick;
  }

  /**
   * Behaviour 4, port of getBackTop(): the highest directory Back may reach. The source returns
   * the EXTERNAL STORAGE ROOT when the start path is inside it - the root of the tree the start
   * path lives in, never the start path itself. This platform grants two such roots: the app
   * sandbox (`context.filesDir`) and `Download/<bundle>` (FileAccess.publicDownloadDir()).
   *
   * T-0183/T-0186: the port used the START PATH as the ceiling for anything outside the sandbox,
   * so a row that already held a deep folder reopened there with an empty list, no siblings and a
   * Back that left the picker - "the page that opens is not one where you can select a file".
   */
  getBackTop(): string {
    const ctx: common.UIAbilityContext | null = this.context;
    const root: string = ctx === null ? '/' : ctx.filesDir;
    return backTopOf(this.startPath, root, this.publicRootMarker);
  }

  /** Behaviour 4, port of isBackTop(): Back leaves the picker rather than going higher. */
  isBackTop(): boolean {
    return this.currentPath === this.getBackTop() || this.currentPath === '/';
  }

  /** Port of goUp(): one level, never past the back top. */
  goUp(): void {
    if (this.isBackTop()) {
      return;
    }
    this.currentPath = parentOf(this.currentPath);
  }

  /** friendlyPathOf() with this device's labels; the raw path until init() has a context. */
  displayPath(path: string): string {
    const ctx: common.UIAbilityContext | null = this.context;
    if (ctx === null) {
      return path;
    }
    try {
      return friendlyPathOf(path, this.publicRootMarker,
        ctx.resourceManager.getStringByNameSync('downloads'),
        ctx.resourceManager.getStringByNameSync('app_name'));
    } catch (err) {
      return path;
    }
  }

  /** Enters a directory the user tapped. */
  goTo(path: string): void {
    this.currentPath = path;
  }

  /**
   * Lists the current directory: visible entries only, sorted directories-first.
   * Behaviour 5: the page scrolls back to the top whenever this returns.
   */
  listDirectory(): PickerEntry[] {
    const out: PickerEntry[] = [];
    let names: string[] = [];
    try {
      names = fileIo.listFileSync(this.currentPath);
    } catch (err) {
      return out;
    }

    for (const name of names) {
      const path: string = this.currentPath.endsWith('/')
        ? `${this.currentPath}${name}`
        : `${this.currentPath}/${name}`;
      let isDirectory: boolean = false;
      try {
        isDirectory = fileIo.statSync(path).isDirectory();
      } catch (err) {
        continue;
      }
      const entry: PickerEntry =
        new PickerEntry(path, baseName(path), isDirectory, name.startsWith('.'));
      if (isItemVisible(entry, this.mode, this.showHiddenItems, this.allowExistingFile)) {
        out.push(entry);
      }
    }

    out.sort(compareEntries);
    return out;
  }

  /**
   * Behaviour 3, port of onClickOk(view): in MODE_NEW_FILE an empty name is refused and the
   * confirm does not go through. Returns the resource name of the error to show, or null when
   * the name is acceptable.
   */
  validateNewFileName(newFileName: string): string | null {
    if (this.mode === FilePickerMode.NEW_FILE && newFileName.trim().length === 0) {
      return FILE_NAME_EMPTY_ERROR_RESOURCE;
    }
    return null;
  }

  /** Port of allowCreateDir: makes a new directory under the current one. */
  createDirectory(name: string): string | null {
    if (!this.allowCreateDir || name.trim().length === 0) {
      return null;
    }
    const path: string = this.currentPath.endsWith('/')
      ? `${this.currentPath}${name}`
      : `${this.currentPath}/${name}`;
    try {
      fileIo.mkdirSync(path, true);
      return path;
    } catch (err) {
      return null;
    }
  }

  /** Port of isOwnFileUri(context, uri): whether a URI points inside this app's own sandbox. */
  isOwnFileUri(uri: string): boolean {
    const ctx: common.UIAbilityContext | null = this.context;
    if (ctx === null) {
      return false;
    }
    return uri.includes(ctx.filesDir) || uri.includes(ctx.cacheDir);
  }
}
