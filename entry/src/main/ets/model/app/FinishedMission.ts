/*
 * Port of app/src/main/java/us/shandian/giga/get/FinishedMission.java - a download that
 * completed and now only exists as a row in the finished-missions store.
 */

import { Mission, MissionJson } from './Mission';
import { DownloadMission } from './DownloadMission';

export class FinishedMission extends Mission {
  /** Port of FinishedMission(DownloadMission): copies exactly the five fields the source copies. */
  static fromDownloadMission(mission: DownloadMission): FinishedMission {
    const out: FinishedMission = new FinishedMission();
    out.source = mission.source;
    out.length = mission.length;
    out.timestamp = mission.timestamp;
    out.kind = mission.kind;
    out.storage = mission.storage;
    return out;
  }

  toJson(): MissionJson {
    const out: MissionJson = {
      source: '', length: 0, timestamp: 0, kind: '',
      storageUri: '', storageName: '', storageType: '', storageTag: '', storageTree: ''
    };
    this.writeMissionJson(out);
    return out;
  }

  static fromJson(raw: MissionJson): FinishedMission {
    const out: FinishedMission = new FinishedMission();
    out.readMissionJson(raw);
    return out;
  }
}
