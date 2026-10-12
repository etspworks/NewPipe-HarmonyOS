/*
 * Port of shared/src/commonMain/kotlin/net/newpipe/app/model/License.kt - a license shown to
 * the user on the About / Licences screen.
 */

/** Raw JSON shape of one license entry. */
export interface RawLicense {
  name?: string;
  spdxID?: string;
  website?: string;
}

export class License {
  name: string = '';
  spdxID: string = '';
  /** `null` in the source when the license carries no website. */
  website: string | null = null;

  constructor(name: string = '', spdxID: string = '', website: string | null = null) {
    this.name = name;
    this.spdxID = spdxID;
    this.website = website;
  }

  static fromRaw(raw: RawLicense): License {
    const out: License = new License();
    out.name = raw.name === undefined ? '' : raw.name;
    out.spdxID = raw.spdxID === undefined ? '' : raw.spdxID;
    out.website = raw.website === undefined ? null : raw.website;
    return out;
  }

  static parseList(json: string): License[] {
    const raws: RawLicense[] = JSON.parse(json) as RawLicense[];
    const out: License[] = [];
    for (const raw of raws) {
      out.push(License.fromRaw(raw));
    }
    return out;
  }
}
