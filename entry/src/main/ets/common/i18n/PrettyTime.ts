/*
 * Port of org.ocpsoft.prettytime 5.0.8.Final (vendored at input/source/prettytime) - the part
 * NewPipe uses: PrettyTime.formatUnrounded(date) and removeUnit(Decade.class), which produce
 * the "3 days ago" line on every stream row and every comment
 * (Localization.relativeTime / relativeTimeOrTextual, 3 call sites, i.e. every list screen).
 *
 * WHAT IS PORTED AND WHAT IS NOT, and why:
 *   - PrettyTime's UNIT SELECTION is the library's actual behaviour and is transcribed exactly:
 *     the twelve units in their registration order, each unit's millisPerUnit and maxQuantity
 *     verbatim from units/*.java, calculateDuration()'s "does this unit encompass the duration"
 *     walk, DurationImpl.getQuantityRounded()'s 50%-tolerance rounding, and removeUnit(). That
 *     is what makes `removeUnit(Decade)` mean something: without it a 12-year-old video reads
 *     "1 decade ago" instead of "12 years ago", which is exactly why NewPipe calls it and why a
 *     bare Intl.RelativeTimeFormat cannot reproduce this.
 *   - The i18n RESOURCE BUNDLES (org.ocpsoft.prettytime.i18n.Resources_*, ~100 locales of
 *     singular/plural/prefix/suffix strings) are NOT transcribed: rendering a (quantity, unit)
 *     pair in the user's language is a platform capability (CLAUDE.md Rule 10), and the SDK's
 *     own CLDR data covers every locale the app ships. SimpleTimeFormat's pattern machinery
 *     (%n/%u/%s, singular vs plural, past/future prefix and suffix) is what Intl does natively.
 */

import { intl } from '@kit.LocalizationKit';

/** The units PrettyTime registers, in registration order (PrettyTime.initTimeUnits). */
export enum TimeUnitKind {
  JUST_NOW,
  MILLISECOND,
  SECOND,
  MINUTE,
  HOUR,
  DAY,
  WEEK,
  MONTH,
  YEAR,
  DECADE,
  CENTURY,
  MILLENNIUM
}

/**
 * Port of ResourcesTimeUnit + units/*.java. `relativeUnit` / `relativeFactor` replace the
 * resource-bundle name: they say how the unit is expressed to Intl.RelativeTimeFormat, whose
 * vocabulary has no decade/century/millennium (they become 10 / 100 / 1000 years).
 */
export class TimeUnit {
  readonly kind: TimeUnitKind;
  readonly millisPerUnit: number;
  /** 0 means "derive it from the next unit", exactly as calculateDuration() does. */
  readonly maxQuantity: number;
  readonly relativeUnit: string;
  readonly relativeFactor: number;

  constructor(kind: TimeUnitKind, millisPerUnit: number, maxQuantity: number,
    relativeUnit: string, relativeFactor: number) {
    this.kind = kind;
    this.millisPerUnit = millisPerUnit;
    this.maxQuantity = maxQuantity;
    this.relativeUnit = relativeUnit;
    this.relativeFactor = relativeFactor;
  }
}

/** millisPerUnit / maxQuantity are verbatim from prettytime's units/*.java. */
const DEFAULT_UNITS: TimeUnit[] = [
  new TimeUnit(TimeUnitKind.JUST_NOW, 1, 1000 * 60, 'second', 1),
  new TimeUnit(TimeUnitKind.MILLISECOND, 1, 0, 'second', 0.001),
  new TimeUnit(TimeUnitKind.SECOND, 1000, 0, 'second', 1),
  new TimeUnit(TimeUnitKind.MINUTE, 1000 * 60, 0, 'minute', 1),
  new TimeUnit(TimeUnitKind.HOUR, 1000 * 60 * 60, 0, 'hour', 1),
  new TimeUnit(TimeUnitKind.DAY, 1000 * 60 * 60 * 24, 0, 'day', 1),
  new TimeUnit(TimeUnitKind.WEEK, 1000 * 60 * 60 * 24 * 7, 0, 'week', 1),
  new TimeUnit(TimeUnitKind.MONTH, 2629743830, 0, 'month', 1),
  new TimeUnit(TimeUnitKind.YEAR, 2629743830 * 12, 0, 'year', 1),
  new TimeUnit(TimeUnitKind.DECADE, 315569259747, 0, 'year', 10),
  new TimeUnit(TimeUnitKind.CENTURY, 3155692597470, 0, 'year', 100),
  new TimeUnit(TimeUnitKind.MILLENNIUM, 31556926000000, 0, 'year', 1000)
];

/** SimpleTimeFormat.roundingTolerance. */
const ROUNDING_TOLERANCE: number = 50;

/** Port of Duration / DurationImpl. */
export class Duration {
  readonly quantity: number;
  readonly delta: number;
  readonly unit: TimeUnit;

  constructor(quantity: number, delta: number, unit: TimeUnit) {
    this.quantity = quantity;
    this.delta = delta;
    this.unit = unit;
  }

  isInPast(): boolean {
    return this.quantity < 0;
  }

  isInFuture(): boolean {
    return !this.isInPast();
  }

  /** Port of DurationImpl.getQuantityRounded(): rounds up once the leftover passes tolerance%. */
  getQuantityRounded(tolerance: number): number {
    let quantity: number = Math.abs(this.quantity);
    if (this.delta !== 0) {
      const threshold: number = Math.abs((this.delta / this.unit.millisPerUnit) * 100);
      if (threshold > tolerance) {
        quantity = quantity + 1;
      }
    }
    return quantity;
  }
}

export class PrettyTime {
  private locale: string;
  private units: TimeUnit[] = DEFAULT_UNITS.slice();
  /** null means "now at call time", matching PrettyTime's null reference. */
  private reference: number | null = null;
  private alwaysFormat: intl.RelativeTimeFormat | null = null;
  private autoFormat: intl.RelativeTimeFormat | null = null;

  /** The source is `new PrettyTime(getAppLocale())`; the locale is always supplied. */
  constructor(locale: string) {
    this.locale = locale;
  }

  getLocale(): string {
    return this.locale;
  }

  setLocale(locale: string): PrettyTime {
    this.locale = locale;
    this.alwaysFormat = null;
    this.autoFormat = null;
    return this;
  }

  /** Epoch milliseconds to measure against; null restores "now". */
  setReference(epochMillis: number | null): PrettyTime {
    this.reference = epochMillis;
    return this;
  }

  getUnits(): TimeUnit[] {
    return this.units.slice();
  }

  /**
   * Port of removeUnit(Class): de-registers a unit so it is never selected. NewPipe removes
   * DECADE - "Do not use decades as YouTube doesn't either."
   */
  removeUnit(kind: TimeUnitKind): boolean {
    const remaining: TimeUnit[] = [];
    let removed: boolean = false;
    for (const unit of this.units) {
      if (unit.kind === kind) {
        removed = true;
      } else {
        remaining.push(unit);
      }
    }
    this.units = remaining;
    return removed;
  }

  /** Port of approximateDuration(Date). `then` is epoch milliseconds. */
  approximateDuration(then: number): Duration {
    const ref: number = this.reference === null ? Date.now() : this.reference;
    let difference: number = then - ref;
    if (difference === 0) {
      difference = 1;
    }
    return this.calculateDuration(difference);
  }

  /** Port of format(Date): the rounded form. */
  format(then: number): string {
    return this.render(this.approximateDuration(then), true);
  }

  /** Port of formatUnrounded(Date) - the one Localization.relativeTime() calls. */
  formatUnrounded(then: number): string {
    return this.render(this.approximateDuration(then), false);
  }

  /** Port of PrettyTime.calculateDuration(long). */
  private calculateDuration(difference: number): Duration {
    const absoluteDifference: number = Math.abs(difference);
    const localUnits: TimeUnit[] = this.units;

    for (let i: number = 0; i < localUnits.length; i++) {
      const unit: TimeUnit = localUnits[i];
      const millisPerUnit: number = Math.abs(unit.millisPerUnit);
      let quantity: number = Math.abs(unit.maxQuantity);
      const isLastUnit: boolean = i === localUnits.length - 1;

      if (quantity === 0 && !isLastUnit) {
        quantity = Math.trunc(localUnits[i + 1].millisPerUnit / unit.millisPerUnit);
      }

      if (millisPerUnit * quantity > absoluteDifference || isLastUnit) {
        if (millisPerUnit > absoluteDifference) {
          return new Duration(difference < 0 ? -1 : 1, 0, unit);
        }
        const unitQuantity: number = Math.trunc(difference / millisPerUnit);
        return new Duration(unitQuantity, difference - unitQuantity * millisPerUnit, unit);
      }
    }
    // unreachable while at least one unit is registered
    return new Duration(difference < 0 ? -1 : 1, 0, localUnits[localUnits.length - 1]);
  }

  /**
   * Replaces SimpleTimeFormat + the resource bundles: the past/future prefix and suffix, the
   * singular/plural name and the number formatting all come from the platform's CLDR data.
   */
  private render(duration: Duration, round: boolean): string {
    if (duration.unit.kind === TimeUnitKind.JUST_NOW) {
      // prettytime's "moments ago"; `numeric: auto` is what yields the locale's own "now".
      return this.formatter(true).format(0, 'second');
    }
    const magnitude: number = round
      ? duration.getQuantityRounded(ROUNDING_TOLERANCE)
      : Math.abs(duration.quantity);
    let scaled: number = magnitude * duration.unit.relativeFactor;
    if (duration.unit.relativeFactor < 1) {
      scaled = Math.round(scaled);
    }
    const signed: number = duration.isInPast() ? -scaled : scaled;
    return this.formatter(false).format(signed, duration.unit.relativeUnit);
  }

  private formatter(auto: boolean): intl.RelativeTimeFormat {
    if (auto) {
      let cached: intl.RelativeTimeFormat | null = this.autoFormat;
      if (cached === null) {
        const options: intl.RelativeTimeFormatInputOptions = { numeric: 'auto' };
        cached = new intl.RelativeTimeFormat(this.locale, options);
        this.autoFormat = cached;
      }
      return cached;
    }
    let cached: intl.RelativeTimeFormat | null = this.alwaysFormat;
    if (cached === null) {
      const options: intl.RelativeTimeFormatInputOptions = { numeric: 'always' };
      cached = new intl.RelativeTimeFormat(this.locale, options);
      this.alwaysFormat = cached;
    }
    return cached;
  }
}
