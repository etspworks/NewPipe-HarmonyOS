/*
 * Port of shared/src/commonMain/kotlin/net/newpipe/app/model/Developer.kt (inside
 * AboutLibraries.kt) - one developer entry of the AboutLibraries BOM.
 *
 * kotlinx.serialization becomes plain JSON.parse here: this is app-level JSON, not the
 * extractor's (phase2-logic-contract.md section 8).
 */

/** Raw JSON shape of one `developers[]` entry in the AboutLibraries BOM. */
export interface RawDeveloper {
  name?: string;
  organisationUrl?: string;
}

export class Developer {
  name: string = '';
  /** `null` in the source when the developer has no organisation URL. */
  organisationUrl: string | null = null;

  constructor(name: string = '', organisationUrl: string | null = null) {
    this.name = name;
    this.organisationUrl = organisationUrl;
  }

  static fromRaw(raw: RawDeveloper): Developer {
    const out: Developer = new Developer();
    out.name = raw.name === undefined ? '' : raw.name;
    out.organisationUrl = raw.organisationUrl === undefined ? null : raw.organisationUrl;
    return out;
  }

  static listFromRaw(raws: RawDeveloper[] | undefined): Developer[] {
    const out: Developer[] = [];
    if (raws === undefined) {
      return out;
    }
    for (const raw of raws) {
      out.push(Developer.fromRaw(raw));
    }
    return out;
  }
}
