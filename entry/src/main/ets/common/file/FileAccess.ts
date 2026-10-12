/*
 * svc_file_access - port of app/src/main/java/org/schabi/newpipe/streams/io/
 * StoredFileHelper.java + StoredDirectoryHelper.java.
 *
 * Substitution (phase2-logic-contract.md section 2.4, self-signed-capabilities.md): HarmonyOS has
 * no WRITE_EXTERNAL_STORAGE analogue and no persisted SAF tree URI. Every user-visible read or
 * write is a URI the user handed us through `@kit.CoreFileKit` DocumentViewPicker; app-private
 * data lives in the sandbox (context.filesDir / cacheDir). No storage permission is requested and
 * none exists to request.
 *
 * What that changes vs the source:
 *   - `isDirect()` (a raw java.io.File path) and the SAF/`DocumentFile` split collapse into one
 *     kind of handle: a URI that `@ohos.file.fs` opens directly.
 *   - `takePersistableUriPermission` has no analogue. A picked directory URI stays usable for
 *     the session and is re-picked when it is no longer readable, which is what
 *     `invalidate()` + `StoredDirectory.exists()` drive here.
 *
 * Rule 8: every file descriptor opened here is closed in `finally`.
 */

import { common } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import { fileIo } from '@kit.CoreFileKit';
import { picker } from '@kit.CoreFileKit';
import fileShare from '@ohos.fileshare';
import statvfs from '@ohos.file.statvfs';

/** StoredFileHelper.DEFAULT_MIME, verbatim. */
export const DEFAULT_MIME: string = 'application/octet-stream';

/**
 * The syscap fileShare's persistPermission / activatePermission are gated on.
 *
 * Exported so a host test can pin the gate: the mistake this is guarding against is checking the
 * DEVICE CLASS instead, which canPickDirectory() used to do and documents at length.
 */
export const PERSIST_SYSCAP: string =
  'SystemCapability.FileManagement.AppFileService.FolderAuthorization';

/** DownloadManager.TAG_AUDIO / TAG_VIDEO, the storage tags of the source. */
export const TAG_AUDIO: string = 'audio';
export const TAG_VIDEO: string = 'video';

function lastPathSegment(uri: string): string {
  const cleaned: string = uri.endsWith('/') ? uri.substring(0, uri.length - 1) : uri;
  const slash: number = cleaned.lastIndexOf('/');
  return slash < 0 ? cleaned : cleaned.substring(slash + 1);
}

function joinPath(parent: string, child: string): string {
  return parent.endsWith('/') ? `${parent}${child}` : `${parent}/${child}`;
}

/** The directory half of a file URI, i.e. the inverse of joinPath(). Empty when there is none. */
function parentPath(uri: string): string {
  const cleaned: string = uri.endsWith('/') ? uri.substring(0, uri.length - 1) : uri;
  const slash: number = cleaned.lastIndexOf('/');
  return slash < 0 ? '' : cleaned.substring(0, slash);
}

/**
 * Port of StoredFileHelper: one file the app may read or write, addressed by URI.
 * `srcName` / `srcType` are kept exactly as the source keeps them, so a handle that has been
 * invalidated still remembers what it pointed at and can be recreated.
 */
export class StoredFile {
  /** The file URI. Empty once the handle has been invalidated. */
  source: string = '';
  /** The URI of the directory this file was created in, when it came from one. */
  sourceTree: string = '';
  srcName: string = '';
  srcType: string = DEFAULT_MIME;
  /** StoredFileHelper.getTag(): 'audio' or 'video' for downloads, '' elsewhere. */
  tag: string = '';
  /**
   * Whether this handle's grant has been persisted with fileShare.persistPermission(), which is
   * what lets it be opened in a LATER process. Serialised with the mission so a restart knows;
   * an old record without the field reads as false, which is the pre-existing behaviour.
   */
  persisted: boolean = false;

  constructor(source: string = '', name: string = '', mime: string = DEFAULT_MIME,
    tag: string = '', sourceTree: string = '') {
    this.source = source;
    this.srcName = name.length > 0 ? name : lastPathSegment(source);
    this.srcType = mime.length > 0 ? mime : DEFAULT_MIME;
    this.tag = tag;
    this.sourceTree = sourceTree;
  }

  getUri(): string {
    return this.source;
  }

  getName(): string {
    return this.srcName;
  }

  getType(): string {
    return this.srcType;
  }

  getTag(): string {
    return this.tag;
  }

  /** Port of isInvalid(): the handle no longer points anywhere. */
  isInvalid(): boolean {
    return this.source.length === 0;
  }

  /** Port of invalidate(): forget where this pointed, keep the name and mime. */
  invalidate(): void {
    this.source = '';
  }

  /**
   * Port of existsAsFile().
   *
   * `source` is whatever handed the file over, and for anything the USER picked that is a document
   * URI from DocumentViewPicker, not a sandbox path. `accessSync` and `statSync` take a path: given
   * a URI they fail, so this returned false for every picked file and DownloadMission.
   * hasInvalidStorage() judged the storage invalid before a byte was transferred.
   *
   * Open it instead, and stat the DESCRIPTOR. That is what canWrite() below has always done with
   * this same field, and the export path proved it on device: FileAccess.writeText() opens the
   * picker's URI with openSync and writes to it.
   */
  existsAsFile(): boolean {
    if (this.isInvalid()) {
      return false;
    }
    let file: fileIo.File | null = null;
    try {
      file = fileIo.openSync(this.source, fileIo.OpenMode.READ_ONLY);
      return fileIo.statSync(file.fd).isFile();
    } catch (err) {
      // A URI DocumentViewPicker handed back from save() is granted for WRITING. Opening it
      // READ_ONLY is refused even though the file is right there, and that refusal is not "the
      // file is gone": read it as gone and hasInvalidStorage() is true for every download the
      // user ever confirmed, which is what stopped every mission before a byte moved. canWrite()
      // opens the same URI in the mode the grant actually covers - the mode the transfer itself
      // uses - so it answers the question the source was asking.
      return this.canWrite();
    } finally {
      if (file !== null) {
        fileIo.closeSync(file);
      }
    }
  }

  /** Port of canWrite(). */
  canWrite(): boolean {
    if (this.isInvalid()) {
      return false;
    }
    let file: fileIo.File | null = null;
    try {
      file = fileIo.openSync(this.source, fileIo.OpenMode.WRITE_ONLY);
      return true;
    } catch (err) {
      return false;
    } finally {
      if (file !== null) {
        fileIo.closeSync(file);
      }
    }
  }

  /**
   * Whether a failed open of this handle MEANS the file is gone.
   *
   * Two kinds of handle answer honestly across processes: a plain sandbox path, and a document
   * URI whose grant was persisted with fileShare.persistPermission() and re-activated in this
   * process (FileAccess.activateUris()). An UNpersisted picked URI does not - its grant dies with
   * the picking process, so in a later one it refuses to open while the file sits untouched on
   * disk, and the failure is about the grant rather than the file.
   *
   * The upgrade path this used to only name is now taken; see FileAccess.persistUri().
   */
  isVerifiable(): boolean {
    return this.source.startsWith('/') || this.persisted;
  }

  /**
   * Port of length(). `statSync` given a PATH is the same path-vs-URI split existsAsFile()
   * documents above: a picked document URI fails it with 13900002, so this reported 0 bytes for
   * every user-picked file. Stat the DESCRIPTOR instead, which is what existsAsFile() does.
   */
  length(): number {
    if (this.isInvalid()) {
      return 0;
    }
    let file: fileIo.File | null = null;
    try {
      file = fileIo.openSync(this.source, fileIo.OpenMode.READ_ONLY);
      return fileIo.statSync(file.fd).size;
    } catch (err) {
      return 0;
    } finally {
      if (file !== null) {
        fileIo.closeSync(file);
      }
    }
  }

  /**
   * Port of create(): recreate the file if it is gone. Returns false when there is nothing to
   * recreate it from (no remembered directory), which is what drives DownloadManager.tryRecover
   * into asking the user to pick a save path again.
   */
  create(): boolean {
    if (!this.isInvalid() && this.existsAsFile()) {
      return true;
    }
    if (this.sourceTree.length === 0 || this.srcName.length === 0) {
      return false;
    }
    const target: string = joinPath(this.sourceTree, this.srcName);
    let file: fileIo.File | null = null;
    try {
      file = fileIo.openSync(target, fileIo.OpenMode.CREATE | fileIo.OpenMode.READ_WRITE);
      this.source = target;
      return true;
    } catch (err) {
      return false;
    } finally {
      if (file !== null) {
        fileIo.closeSync(file);
      }
    }
  }

  /**
   * Port of truncate(). `truncateSync` takes a path OR an fd, never a URI, so given the URI
   * DocumentViewPicker hands back this threw 13900002 "No such file or directory" - the throw the
   * export surfaced as "Exporting database and settings: No such file or directory", because
   * exportDatabase() truncates the target before it copies the zip over it. Open the URI and
   * truncate the descriptor. Like the source's version this still throws when it genuinely fails;
   * the caller is the one that decides what that means.
   */
  truncate(): void {
    if (this.isInvalid()) {
      return;
    }
    let file: fileIo.File | null = null;
    try {
      file = fileIo.openSync(this.source, fileIo.OpenMode.WRITE_ONLY);
      fileIo.truncateSync(file.fd, 0);
    } finally {
      if (file !== null) {
        fileIo.closeSync(file);
      }
    }
  }

  /** Port of delete(): true when the file is gone afterwards. */
  delete(): boolean {
    if (this.isInvalid()) {
      return true;
    }
    try {
      fileIo.unlinkSync(this.source);
      return true;
    } catch (err) {
      return !this.existsAsFile();
    }
  }

  /** Port of equals(StoredFileHelper): same URI, or same name under the same directory. */
  equalsFile(other: StoredFile | null): boolean {
    if (other === null) {
      return false;
    }
    if (this.source.length > 0 && this.source === other.source) {
      return true;
    }
    return this.sourceTree.length > 0 && this.sourceTree === other.sourceTree
      && this.srcName === other.srcName;
  }

  toString(): string {
    return this.isInvalid() ? this.srcName : this.source;
  }
}

/** Port of StoredDirectoryHelper: the download save path the user picked. */
export class StoredDirectory {
  uri: string = '';
  tag: string = '';

  constructor(uri: string = '', tag: string = '') {
    this.uri = uri;
    this.tag = tag;
  }

  getUri(): string {
    return this.uri;
  }

  getTag(): string {
    return this.tag;
  }

  /** Port of isInvalidSafStorage(): no directory was ever picked. */
  isInvalid(): boolean {
    return this.uri.length === 0;
  }

  /** Port of exists(). */
  exists(): boolean {
    if (this.isInvalid()) {
      return false;
    }
    try {
      return fileIo.accessSync(this.uri) && fileIo.statSync(this.uri).isDirectory();
    } catch (err) {
      return false;
    }
  }

  /** Port of mkdirs(). */
  mkdirs(): boolean {
    if (this.isInvalid()) {
      return false;
    }
    if (this.exists()) {
      return true;
    }
    try {
      fileIo.mkdirSync(this.uri, true);
      return true;
    } catch (err) {
      return false;
    }
  }

  /** Port of canWrite(). */
  canWrite(): boolean {
    return this.exists();
  }

  /** Port of getFreeStorageSpace(). */
  getFreeStorageSpace(): number {
    if (this.isInvalid()) {
      return 0;
    }
    try {
      return statvfs.getFreeSizeSync(this.uri);
    } catch (err) {
      return 0;
    }
  }

  /** Port of findFile(filename): the URI of a child by name, or null. */
  findFile(filename: string): string | null {
    if (this.isInvalid()) {
      return null;
    }
    const candidate: string = joinPath(this.uri, filename);
    try {
      return fileIo.accessSync(candidate) ? candidate : null;
    } catch (err) {
      return null;
    }
  }

  /** Port of createFile(filename, mime). */
  createFile(filename: string, mime: string): StoredFile | null {
    if (this.isInvalid()) {
      return null;
    }
    const target: string = joinPath(this.uri, filename);
    let file: fileIo.File | null = null;
    try {
      file = fileIo.openSync(target, fileIo.OpenMode.CREATE | fileIo.OpenMode.READ_WRITE);
      return new StoredFile(target, filename, mime, this.tag, this.uri);
    } catch (err) {
      return null;
    } finally {
      if (file !== null) {
        fileIo.closeSync(file);
      }
    }
  }

  /**
   * Port of createUniqueFile(name, mime): appends " (1)", " (2)", ... before the extension until
   * the name is free, exactly as the source does.
   */
  createUniqueFile(name: string, mime: string): StoredFile | null {
    if (this.findFile(name) === null) {
      return this.createFile(name, mime);
    }

    const dot: number = name.lastIndexOf('.');
    const stem: string = dot > 0 ? name.substring(0, dot) : name;
    const ext: string = dot > 0 ? name.substring(dot) : '';

    for (let i: number = 1; i < 1000; i++) {
      const candidate: string = `${stem} (${i})${ext}`;
      if (this.findFile(candidate) === null) {
        return this.createFile(candidate, mime);
      }
    }
    return null;
  }
}

/**
 * svc_file_access. The only door to the file system in this app: the sandbox for app-private
 * data, DocumentViewPicker for anything the user sees.
 */
export class FileAccess {
  private context: common.UIAbilityContext | null = null;

  /** Called once from EntryAbility through ServiceLocator. */
  init(context: common.UIAbilityContext): void {
    this.context = context;
  }

  private requireContext(): common.UIAbilityContext {
    const ctx: common.UIAbilityContext | null = this.context;
    if (ctx === null) {
      throw new Error('FileAccess used before ServiceLocator.init()');
    }
    return ctx;
  }

  /* //////////////////////////////////////////////////////////////////////////
  // Sandbox (app-private) - no picker, no permission
  ////////////////////////////////////////////////////////////////////////// */

  filesDir(): string {
    return this.requireContext().filesDir;
  }

  cacheDir(): string {
    return this.requireContext().cacheDir;
  }

  /** Creates `<filesDir>/<name>` if it does not exist and returns its path. */
  ensureAppDir(name: string): string {
    const dir: string = joinPath(this.filesDir(), name);
    if (!fileIo.accessSync(dir)) {
      fileIo.mkdirSync(dir, true);
    }
    return dir;
  }

  /**
   * Port of Utility.readFromFile, as text. Returns null when the file is missing/unreadable.
   *
   * `accessSync` and `readTextSync` both take a PATH only, so handed the document URI a picker
   * returned they failed with 13900002 and every user-picked file read as unreadable - which is
   * what stopped "Import subscriptions" on the file the user had just chosen. `openSync` is the
   * one call that resolves a URI as well as a path, so the read goes through the descriptor, the
   * same shape SubscriptionManager.readTextFile() already uses for picked files.
   */
  readText(path: string): string | null {
    let file: fileIo.File | null = null;
    try {
      file = fileIo.openSync(path, fileIo.OpenMode.READ_ONLY);
      const size: number = fileIo.statSync(file.fd).size;
      if (size === 0) {
        return '';
      }
      const buffer: ArrayBuffer = new ArrayBuffer(size);
      const read: number = fileIo.readSync(file.fd, buffer);
      return util.TextDecoder.create('utf-8').decodeToString(new Uint8Array(buffer, 0, read));
    } catch (err) {
      return null;
    } finally {
      if (file !== null) {
        fileIo.closeSync(file);
      }
    }
  }

  /** Port of Utility.writeToFile: truncating write of the whole content. */
  writeText(path: string, content: string): boolean {
    let file: fileIo.File | null = null;
    try {
      file = fileIo.openSync(path,
        fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
      fileIo.writeSync(file.fd, content);
      return true;
    } catch (err) {
      return false;
    } finally {
      if (file !== null) {
        fileIo.closeSync(file);
      }
    }
  }

  /**
   * Copy one whole file onto another, where EITHER end may be a document URI.
   *
   * `fileIo.copyFileSync` takes a path or an fd and a document URI is neither, so a copy with a
   * picked file at one end failed with 13900002 - the export's "copy the staged zip over the file
   * you chose" and the import's "read the backup you chose" are both that copy. `openSync`
   * resolves a URI, so both ends go through a descriptor and copyFileSync gets two fds. The
   * destination is opened TRUNC, because a whole-file copy that leaves a longer file's tail behind
   * is the corruption the source's own truncate-first comment is about.
   */
  copyFile(from: string, to: string): void {
    let src: fileIo.File | null = null;
    let dest: fileIo.File | null = null;
    try {
      src = fileIo.openSync(from, fileIo.OpenMode.READ_ONLY);
      dest = fileIo.openSync(to,
        fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
      fileIo.copyFileSync(src.fd, dest.fd);
    } finally {
      if (src !== null) {
        fileIo.closeSync(src);
      }
      if (dest !== null) {
        fileIo.closeSync(dest);
      }
    }
  }

  /** Names of the entries directly under `dir`, or an empty array. */
  listNames(dir: string): string[] {
    try {
      return fileIo.accessSync(dir) ? fileIo.listFileSync(dir) : [];
    } catch (err) {
      return [];
    }
  }

  deleteQuietly(path: string): void {
    try {
      if (fileIo.accessSync(path)) {
        fileIo.unlinkSync(path);
      }
    } catch (err) {
      // deleting a file that is already gone is the success case
    }
  }

  /* //////////////////////////////////////////////////////////////////////////
  // User-visible files - DocumentViewPicker
  ////////////////////////////////////////////////////////////////////////// */

  /**
   * Port of the MODE_NEW_FILE / ACTION_CREATE_DOCUMENT path. Returns the StoredFile the user
   * chose, or null if they cancelled.
   */
  async pickFileToSave(suggestedName: string, mime: string, tag: string = ''): Promise<StoredFile | null> {
    const options: picker.DocumentSaveOptions = new picker.DocumentSaveOptions();
    options.newFileNames = [suggestedName];
    const documentPicker: picker.DocumentViewPicker =
      new picker.DocumentViewPicker(this.requireContext());
    const uris: string[] = await documentPicker.save(options);
    if (uris.length === 0) {
      return null;
    }
    // The tree and the name come out of the URI the picker returned, never out of the SUGGESTION:
    // the picker is free to hand back a de-duplicated name ('clip (1).mp4'), and StoredFile.
    // create() rebuilds the file as joinPath(sourceTree, srcName). Seeded with the suggestion
    // that join names a DIFFERENT file, so a recovered mission would write over the wrong one.
    // Taken from the URI the join is exactly the URI again.
    //
    // Leaving sourceTree empty - which is what this did - also made create() return false
    // unconditionally (sourceTree.length === 0), so no mission could ever be recovered.
    const uri: string = uris[0];
    // T-0183b: take the persistable grant immediately, the way the source takes it right after
    // ACTION_CREATE_DOCUMENT returns. Failure is not fatal - the handle still works in this
    // process, it just will not survive a restart, which is where this app was before. The
    // RESULT has to be carried onto the handle: isVerifiable() reads that flag, and a grant that
    // was taken but not recorded is the same as one that was never taken.
    const persisted: boolean = await this.persistUri(uri);
    const name: string = lastPathSegment(uri);
    const stored: StoredFile = new StoredFile(uri, name.length === 0 ? suggestedName : name,
      mime, tag, parentPath(uri));
    stored.persisted = persisted;
    return stored;
  }

  /**
   * Port of the MODE_FILE / ACTION_OPEN_DOCUMENT path.
   * @param suffixes e.g. ['.zip', '.json'] - the source filters the import picker the same way.
   */
  async pickFileToOpen(suffixes: string[] = []): Promise<StoredFile | null> {
    const options: picker.DocumentSelectOptions = new picker.DocumentSelectOptions();
    options.maxSelectNumber = 1;
    if (suffixes.length > 0) {
      options.fileSuffixFilters = suffixes;
    }
    const documentPicker: picker.DocumentViewPicker =
      new picker.DocumentViewPicker(this.requireContext());
    const uris: string[] = await documentPicker.select(options);
    if (uris.length === 0) {
      return null;
    }
    const opened: StoredFile = new StoredFile(uris[0], '', DEFAULT_MIME);
    opened.persisted = await this.persistUri(uris[0]);
    return opened;
  }

  /**
   * Whether DocumentViewPicker can hand back a DIRECTORY on THIS device.
   *
   * `DocumentSelectOptions.selectMode` and the whole `DocumentSelectMode` enum are gated on
   * SystemCapability.FileManagement.UserFileService.FolderSelection. Ask the device for that
   * syscap rather than inferring it from the device class: `deviceInfo.deviceType === '2in1'`
   * happened to give the right answer here, but it is a guess about which profiles declare the
   * capability, and it would be wrong the day a phone profile gains it.
   *
   * Measured on the port handset (phone, OpenHarmony-6.1.1.120, API 24):
   * `canIUse(...FolderSelection)` is **false**, and `select()` with selectMode = FOLDER returns an
   * empty result with `resCode is -1` - the picker starts and closes again without a window.
   * Callers MUST check this and fall back to NewPipe's own MODE_DIR picker, which is the other
   * half of StoredDirectoryHelper.getPicker() and is ported in pages/CustomFilePickerFragmentPage.
   * See docs/qa/evidence/fix-T-0183/probe.txt.
   */
  /**
   * Whether this device can persist a picked URI's grant across processes.
   *
   * Ask the syscap, never the device class - canPickDirectory() below documents why. The phone
   * profile does declare FolderAuthorization, but a build may still run somewhere that does not.
   */
  canPersistUris(): boolean {
    return canIUse(PERSIST_SYSCAP);
  }

  /**
   * Port of takePersistableUriPermission(uri, FLAG_GRANT_READ|WRITE_URI_PERMISSION).
   *
   * Without this a document URI from DocumentViewPicker is usable only in the process that picked
   * it; in the next one it refuses to open while the file sits untouched on disk, which is what
   * StoredFile.isVerifiable() has been working around. Returns false when the platform will not
   * persist it - callers keep today's behaviour.
   *
   * ohos.permission.FILE_ACCESS_PERSIST is what makes this legal, it is system_grant, and it is
   * granted on the port handset (docs/qa/evidence/fix-T-0183b/probe2.txt).
   */
  async persistUri(uri: string): Promise<boolean> {
    if (uri.length === 0 || !this.canPersistUris()) {
      return false;
    }
    try {
      const policy: fileShare.PolicyInfo = {
        uri: uri,
        operationMode: fileShare.OperationMode.READ_MODE | fileShare.OperationMode.WRITE_MODE
      };
      await fileShare.persistPermission([policy]);
      return true;
    } catch (err) {
      return false;
    }
  }

  /**
   * Re-arms persisted URIs in THIS process. Must run before anything decides a file is gone - see
   * DownloadManager.loadFinishedMissions(). Failures are per-URI and never fatal: a URI the user
   * has since revoked simply stays unverifiable, which is the pre-existing behaviour.
   */
  async activateUris(uris: string[]): Promise<void> {
    if (uris.length === 0 || !this.canPersistUris()) {
      return;
    }
    const policies: fileShare.PolicyInfo[] = [];
    for (const uri of uris) {
      if (uri.length === 0) {
        continue;
      }
      policies.push({
        uri: uri,
        operationMode: fileShare.OperationMode.READ_MODE | fileShare.OperationMode.WRITE_MODE
      });
    }
    if (policies.length === 0) {
      return;
    }
    try {
      await fileShare.activatePermission(policies);
    } catch (err) {
      // Partial failure is reported per-policy by the platform; nothing here can act on it, and
      // an unactivated URI degrades to exactly the old behaviour.
    }
  }

  canPickDirectory(): boolean {
    return canIUse('SystemCapability.FileManagement.UserFileService.FolderSelection');
  }

  /**
   * The app's directory inside the device's PUBLIC Download folder, created if it is missing.
   *
   * Where the system folder picker does not exist, the in-app picker is all that is left - and it
   * used to open on `context.filesDir`, the app sandbox (`/data/storage/el2/base/haps/entry/files`,
   * one entry: `pending_downloads`). Nothing there is reachable from Files, so a download saved
   * through it was a download the user could not open (T-0183/T-0186).
   *
   * `DocumentViewPicker.save()` in `DocumentPickerMode.DOWNLOAD` is the sanctioned way to that
   * folder: it shows **no picker screen**, it needs no permission, and it returns
   * `file://docs/storage/Users/<user>/Download/<bundle>`. Strip the `file://docs` authority and the
   * remainder is a real path that plain `fileIo` can list and write - measured both before and
   * after the call, so the access is not a per-call grant. The uri itself is NOT usable with
   * fileIo (`13900002`), which is why only the path is kept.
   *
   * Returns '' when the platform will not give it up; callers fall back to the sandbox.
   *
   * Re-measured on 2026-10-02 WITH ohos.permission.READ_WRITE_DOWNLOAD_DIRECTORY declared and in
   * the installed bundle (docs/qa/evidence/fix-T-0183b/probe2.txt): the public Download directory
   * still answers 13900001, and the request for that permission answers authResults=2 - "the
   * request is invalid" - rather than being granted or denied. The grant does not widen this
   * app's view, so Download/<bundle> is the ceiling and the in-app picker stays rooted there.
   * This is now measured WITH the permission, not without it; the earlier note was not.
   */
  async publicDownloadDir(): Promise<string> {
    try {
      const options: picker.DocumentSaveOptions = new picker.DocumentSaveOptions();
      options.pickerMode = picker.DocumentPickerMode.DOWNLOAD;
      const uris: string[] =
        await new picker.DocumentViewPicker(this.requireContext()).save(options);
      if (uris.length === 0) {
        return '';
      }
      const prefix: string = 'file://docs';
      const path: string =
        uris[0].startsWith(prefix) ? uris[0].substring(prefix.length) : uris[0];
      if (!path.startsWith('/')) {
        return '';
      }
      if (!fileIo.accessSync(path)) {
        fileIo.mkdirSync(path, true);
      }
      return path;
    } catch (err) {
      // No public folder on this platform: the caller keeps the sandbox it had.
      return '';
    }
  }

  /**
   * Port of StoredDirectoryHelper.getPicker() / the download-path setting: let the user choose
   * the directory downloads are saved into. 2-in-1 devices only - guard with canPickDirectory().
   */
  async pickDirectory(tag: string): Promise<StoredDirectory | null> {
    const options: picker.DocumentSelectOptions = new picker.DocumentSelectOptions();
    options.selectMode = picker.DocumentSelectMode.FOLDER;
    options.maxSelectNumber = 1;
    const documentPicker: picker.DocumentViewPicker =
      new picker.DocumentViewPicker(this.requireContext());
    const uris: string[] = await documentPicker.select(options);
    if (uris.length === 0) {
      return null;
    }
    return new StoredDirectory(uris[0], tag);
  }
}
