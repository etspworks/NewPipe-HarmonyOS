/*
 * svc_settings_backup - port of app/src/main/java/org/schabi/newpipe/settings/export/
 * ImportExportManager.kt + BackupFileLocator.kt (the "Export/Import database" settings action).
 *
 * JSON ONLY, both ways (the plan's `risk_legacy_serialized_prefs`):
 *
 *   - EXPORT writes a zip with exactly two entries: the database file and `preferences.json`.
 *     The source ALSO wrote `newpipe.settings`, a Java `ObjectOutputStream` dump of the whole
 *     preference map, and its own code calls that "vulnerable to injections" and deprecates it.
 *     Java serialization has no ArkTS analogue and re-creating one would be re-creating the
 *     vulnerability, so that entry is deliberately not written.
 *   - IMPORT reads `preferences.json` only. A backup that carries only the legacy
 *     `newpipe.settings` is reported as UNREADABLE, with a message naming the file and telling
 *     the user to re-export from a recent NewPipe. It is never guessed at, half-parsed, or
 *     silently treated as an empty settings set - a silent "success" that restores defaults is
 *     worse than an honest failure, because the user believes their settings came back.
 *
 * The zip itself is `@ohos.zlib`; the file the user picks comes from svc_file_access
 * (DocumentViewPicker), so no storage permission is involved (contract section 2.4).
 */

import zlib from '@ohos.zlib';
import { fileIo } from '@kit.CoreFileKit';
import { AppPreferences, PrefValue } from '../prefs/Preferences';
import { FileAccess, StoredFile } from '../file/FileAccess';
import { DATABASE_NAME } from '../../model/app/AppDatabase';

/** BackupFileLocator.FILE_NAME_DB, verbatim. */
export const FILE_NAME_DB: string = DATABASE_NAME;
/** BackupFileLocator.FILE_NAME_JSON_PREFS, verbatim. */
export const FILE_NAME_JSON_PREFS: string = 'preferences.json';
/** BackupFileLocator.FILE_NAME_SERIALIZED_PREFS - recognised on import, never written. */
export const FILE_NAME_SERIALIZED_PREFS: string = 'newpipe.settings';

/** Raised when a backup carries only the legacy Java-serialized preferences. */
export class LegacySerializedBackupError extends Error {
  constructor() {
    super(`This backup stores its settings only as ${FILE_NAME_SERIALIZED_PREFS}, a Java-serialized`
      + ` file this version cannot read. Its database was restored; re-export the settings from a`
      + ` recent NewPipe to bring them across.`);
    this.name = 'LegacySerializedBackupError';
  }
}

export class BackupRestore {
  private prefs: AppPreferences | null = null;
  private files: FileAccess | null = null;
  /** Path of the live database file - the persistence layer's store, resolved once at startup. */
  private databasePath: string = '';

  /** Called once from EntryAbility through ServiceLocator. */
  init(prefs: AppPreferences, files: FileAccess, databasePath: string): void {
    this.prefs = prefs;
    this.files = files;
    this.databasePath = databasePath;
  }

  private requirePrefs(): AppPreferences {
    const prefs: AppPreferences | null = this.prefs;
    if (prefs === null) {
      throw new Error('BackupRestore used before ServiceLocator.init()');
    }
    return prefs;
  }

  private requireFiles(): FileAccess {
    const files: FileAccess | null = this.files;
    if (files === null) {
      throw new Error('BackupRestore used before ServiceLocator.init()');
    }
    return files;
  }

  /** A clean scratch directory under the cache, removed and recreated on every use. */
  private stagingDir(name: string): string {
    const files: FileAccess = this.requireFiles();
    const dir: string = `${files.cacheDir()}/${name}`;
    try {
      if (fileIo.accessSync(dir)) {
        fileIo.rmdirSync(dir);
      }
    } catch (err) {
      // a leftover directory that cannot be removed is reused as-is
    }
    try {
      fileIo.mkdirSync(dir, true);
    } catch (err) {
      // already exists
    }
    return dir;
  }

  /**
   * Port of exportDatabase(preferences, file): writes the backup zip to the file the user picked.
   * The source truncates the target first "otherwise the file will retain part of the previous
   * content and be corrupted"; here the staging zip is built fresh and copied over the whole
   * target, which has the same effect.
   */
  async exportDatabase(target: StoredFile): Promise<void> {
    const staging: string = this.stagingDir('backup-export');
    const zipPath: string = `${this.requireFiles().cacheDir()}/NewPipeData.zip`;

    try {
      // the database
      if (this.databasePath.length > 0 && fileIo.accessSync(this.databasePath)) {
        fileIo.copyFileSync(this.databasePath, `${staging}/${FILE_NAME_DB}`);
      }

      // the JSON preferences
      const all: Map<string, PrefValue> = this.requirePrefs().getAll();
      const record: Record<string, PrefValue> = {};
      all.forEach((value: PrefValue, key: string): void => {
        record[key] = value;
      });
      this.requireFiles().writeText(`${staging}/${FILE_NAME_JSON_PREFS}`, JSON.stringify(record));

      // NOTE: the legacy newpipe.settings entry is deliberately NOT written - see the header

      this.requireFiles().deleteQuietly(zipPath);
      const options: zlib.Options = { level: zlib.CompressLevel.COMPRESS_LEVEL_DEFAULT_COMPRESSION };
      await zlib.compressFile(staging, zipPath, options);

      target.truncate();
      // NOT fileIo.copyFileSync(zipPath, target.getUri()): `target` is the document URI the save
      // picker returned and copyFileSync takes a path or an fd, so that call failed with 13900002
      // "No such file or directory" and the whole export reported it. FileAccess.copyFile() opens
      // both ends and copies descriptor to descriptor.
      this.requireFiles().copyFile(zipPath, target.getUri());
    } finally {
      this.requireFiles().deleteQuietly(zipPath);
      try {
        fileIo.rmdirSync(staging);
      } catch (err) {
        // the staging directory is in the cache; leaving it costs nothing
      }
    }
  }

  /** Port of exportHasJsonPrefs(zipFile): whether a backup carries readable settings. */
  async backupHasJsonPrefs(source: StoredFile): Promise<boolean> {
    const staging: string = await this.extract(source);
    try {
      return fileIo.accessSync(`${staging}/${FILE_NAME_JSON_PREFS}`);
    } finally {
      try {
        fileIo.rmdirSync(staging);
      } catch (err) {
        // cache directory
      }
    }
  }

  /**
   * Port of extractDb(file) + loadJsonPrefs(zipFile, preferences), in that order: the database is
   * restored first, then the settings replace the current ones wholesale (`editor.clear()` then
   * put every entry, as the source does).
   *
   * Throws LegacySerializedBackupError when the backup has only the Java-serialized settings.
   * The database is still restored in that case, which is why the error says so.
   */
  async importDatabase(source: StoredFile): Promise<void> {
    const staging: string = await this.extract(source);
    try {
      // the database
      const dbEntry: string = `${staging}/${FILE_NAME_DB}`;
      if (fileIo.accessSync(dbEntry) && this.databasePath.length > 0) {
        // the source also deletes the -journal / -wal / -shm siblings of the replaced database
        this.requireFiles().deleteQuietly(`${this.databasePath}-journal`);
        this.requireFiles().deleteQuietly(`${this.databasePath}-wal`);
        this.requireFiles().deleteQuietly(`${this.databasePath}-shm`);
        fileIo.copyFileSync(dbEntry, this.databasePath);
      }

      // the settings
      const jsonEntry: string = `${staging}/${FILE_NAME_JSON_PREFS}`;
      if (!fileIo.accessSync(jsonEntry)) {
        if (fileIo.accessSync(`${staging}/${FILE_NAME_SERIALIZED_PREFS}`)) {
          throw new LegacySerializedBackupError();
        }
        throw new Error(`Backup does not contain ${FILE_NAME_JSON_PREFS}`);
      }

      const json: string | null = this.requireFiles().readText(jsonEntry);
      if (json === null) {
        throw new Error(`Could not read ${FILE_NAME_JSON_PREFS} from the backup`);
      }
      const record: Record<string, PrefValue> = JSON.parse(json) as Record<string, PrefValue>;

      const prefs: AppPreferences = this.requirePrefs();
      prefs.clear();
      for (const key of Object.keys(record)) {
        prefs.put(key, record[key]);
      }
      // the source throws if commit() fails; flush is awaited for the same reason
      await prefs.flush();
    } finally {
      try {
        fileIo.rmdirSync(staging);
      } catch (err) {
        // cache directory
      }
    }
  }

  /**
   * Unpacks the picked backup into a fresh staging directory and returns its path.
   *
   * `zlib.decompressFile` documents `inFile` as a PATH, and the backup the user picked is a
   * document URI - the same split that broke the export. Stage a copy in the cache through
   * FileAccess.copyFile(), which resolves the URI, and unpack that.
   */
  private async extract(source: StoredFile): Promise<string> {
    const staging: string = this.stagingDir('backup-import');
    const local: string = `${this.requireFiles().cacheDir()}/NewPipeData-import.zip`;
    this.requireFiles().deleteQuietly(local);
    this.requireFiles().copyFile(source.getUri(), local);
    try {
      await zlib.decompressFile(local, staging);
    } finally {
      this.requireFiles().deleteQuietly(local);
    }
    return staging;
  }
}
