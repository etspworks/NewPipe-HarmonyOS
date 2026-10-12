/*
 * Copyright (C) The NewPipe Authors
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program.  If not, see <https://www.gnu.org/licenses/>.
 */

/**
 * ThemeHelper.setTheme(context, serviceId) in the source swaps the whole Activity theme when the
 * drawer selects a service, so every `?attr/colorPrimary` follows it: YouTube red, SoundCloud
 * orange, media.ccc.de blue, PeerTube orange-red, Bandcamp teal. A HarmonyOS page has no Activity
 * theme to swap, so the ported screens each named the YouTube colour directly and the header
 * stayed red whichever service was active. Read colorPrimary through here instead.
 *
 * The id argument is the service id the screen already observes - `mainSelectedServiceId` in
 * AppStorage, which MainActivityPage writes on every drawer selection. Taking it as a parameter
 * (rather than reading AppStorage in here) is what keeps the caller's `@StorageProp` in the
 * dependency graph, so the band repaints when the service changes.
 */
export function servicePrimaryColor(serviceId: number): Resource {
  // ServiceList's order, which is what the source's ThemeHelper switch keys on. $r() needs a
  // string literal, so this is a switch over literals rather than a name built from the id.
  // The names are the semantic tokens, not the light_* palette members: each resolves to the
  // service's light_*_primary_color in base/ and its dark_*_primary_color in dark/.
  switch (serviceId) {
    case 1:
      return $r('app.color.primary_soundcloud');
    case 2:
      return $r('app.color.primary_media_ccc');
    case 3:
      return $r('app.color.primary_peertube');
    case 4:
      return $r('app.color.primary_bandcamp');
    default:
      return $r('app.color.primary');
  }
}

/**
 * The scrim behind every dialog: an AlertDialog's backgroundDimAmount 0.6, measured on the
 * reference device as the same RGB 95 over the #EEEEEE window. ArkUI's own default mask is far
 * lighter, so every CustomDialogController passes this.
 */
export const DIALOG_MASK_COLOR: string = '#99000000';
