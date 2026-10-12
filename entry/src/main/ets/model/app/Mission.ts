/*
 * Port of app/src/main/java/us/shandian/giga/get/Mission.java - the base of every download
 * mission, pending or finished.
 *
 * Java serialization does not survive the migration (architecture.persistence): missions are
 * persisted as JSON (see DownloadMission.toJson / fromJson and common/download/DownloadManager.ts),
 * so `serialVersionUID` has no analogue and the `transient` markers become "not written to JSON".
 */

import { StoredFile } from '../../common/file/FileAccess';

/** The JSON shape shared by every persisted mission. */
export interface MissionJson {
  source: string;
  length: number;
  timestamp: number;
  kind: string;
  storageUri: string;
  storageName: string;
  storageType: string;
  storageTag: string;
  storageTree: string;
  /**
   * Whether the picked URI's grant was persisted (T-0183b). Optional so a record written before
   * this field existed still parses; absent reads as false, the pre-existing behaviour.
   */
  storagePersisted?: boolean;
}

export abstract class Mission {
  /** Source url of the resource. */
  source: string = '';

  /** Length of the current resource. */
  length: number = 0;

  /** Creation timestamp (and maybe unique identifier). */
  timestamp: number = 0;

  /**
   * Pre-defined content type. A single char in the source ('v' video, 'a' audio, 's' subtitle);
   * ArkTS has no char type, so it is a one-character string.
   */
  kind: string = '';

  /** The downloaded file. */
  storage: StoredFile | null = null;

  /** `transient` in the source: indicates this mission is deleted whatever is stored. */
  deleted: boolean = false;

  getTimestamp(): number {
    return this.timestamp;
  }

  /**
   * Delete the downloaded file.
   * @returns true if and only if the file is successfully deleted, otherwise false.
   */
  delete(): boolean {
    const file: StoredFile | null = this.storage;
    if (file !== null) {
      return file.delete();
    }
    return true;
  }

  toString(): string {
    const file: StoredFile | null = this.storage;
    const name: string = file === null ? '' : file.toString();
    return `[${new Date(this.timestamp).toString()}] ${name}`;
  }

  /** Fills the shared half of the JSON record. */
  protected writeMissionJson(out: MissionJson): void {
    const file: StoredFile | null = this.storage;
    out.source = this.source;
    out.length = this.length;
    out.timestamp = this.timestamp;
    out.kind = this.kind;
    out.storageUri = file === null ? '' : file.source;
    out.storageName = file === null ? '' : file.srcName;
    out.storageType = file === null ? '' : file.srcType;
    out.storageTag = file === null ? '' : file.tag;
    out.storageTree = file === null ? '' : file.sourceTree;
    out.storagePersisted = file !== null && file.persisted;
  }

  /** Reads the shared half of the JSON record back. */
  protected readMissionJson(raw: MissionJson): void {
    this.source = raw.source;
    this.length = raw.length;
    this.timestamp = raw.timestamp;
    this.kind = raw.kind;
    const restored: StoredFile | null = raw.storageUri.length === 0 && raw.storageName.length === 0
      ? null
      : new StoredFile(raw.storageUri, raw.storageName, raw.storageType, raw.storageTag,
        raw.storageTree);
    if (restored !== null) {
      restored.persisted = raw.storagePersisted === true;
    }
    this.storage = restored;
  }
}
