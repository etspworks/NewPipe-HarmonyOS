/*
 * Port of shared/src/commonMain/kotlin/net/newpipe/app/model/Library.kt (inside
 * AboutLibraries.kt) - one library entry of the AboutLibraries BOM.
 *
 * `@SerialName("uniqueId")` on `id` is preserved: the JSON key stays `uniqueId`.
 */

import { Developer, RawDeveloper } from './Developer';

/** Raw JSON shape of one `libraries[]` entry in the AboutLibraries BOM. */
export interface RawLibrary {
  uniqueId?: string;
  name?: string;
  developers?: RawDeveloper[];
  licenses?: string[];
  website?: string;
}

export class Library {
  /** `@SerialName("uniqueId")` in the source. */
  id: string = '';
  name: string = '';
  developers: Developer[] = [];
  /** SPDX ids referencing License entries. */
  licenses: string[] = [];
  /** `null` in the source when the library declares no website. */
  website: string | null = null;

  static fromRaw(raw: RawLibrary): Library {
    const out: Library = new Library();
    out.id = raw.uniqueId === undefined ? '' : raw.uniqueId;
    out.name = raw.name === undefined ? '' : raw.name;
    out.developers = Developer.listFromRaw(raw.developers);
    out.licenses = raw.licenses === undefined ? [] : raw.licenses;
    out.website = raw.website === undefined ? null : raw.website;
    return out;
  }
}
