/*
 * Port of org.schabi.newpipe.extractor.localization.DateWrapper (NewPipeExtractor v0.26.5).
 *
 * Java distinguishes Instant / OffsetDateTime / LocalDateTime; ArkTS has one Date, which IS an
 * instant, so the five constructors collapse into one and the three getters return the same
 * point in time — the difference in Java was only which zone it was rendered in, and rendering
 * happens in the UI here.
 */

import { ParsingException } from '../exceptions/Exceptions';

export class DateWrapper {
  private readonly instant: Date;
  private readonly approximation: boolean;

  constructor(instant: Date, isApproximation: boolean = false) {
    this.instant = instant;
    this.approximation = isApproximation;
  }

  getInstant(): Date {
    return this.instant;
  }

  /** The same instant; Java rendered it at UTC, the UI does the rendering here. */
  offsetDateTime(): Date {
    return this.instant;
  }

  /** The same instant; Date's local getters already use the device's zone. */
  getLocalDateTime(): Date {
    return this.instant;
  }

  isApproximation(): boolean {
    return this.approximation;
  }

  toString(): string {
    return 'DateWrapper{instant=' + this.instant.toISOString()
      + ', isApproximation=' + this.approximation + '}';
  }

  /** Port of fromOffsetDateTime(): an ISO-8601 date carrying an offset, or null for null input. */
  static fromOffsetDateTime(date: string | null): DateWrapper | null {
    if (date === null) {
      return null;
    }
    const parsed: Date = new Date(date);
    if (Number.isNaN(parsed.getTime())) {
      throw new ParsingException('Could not parse date: "' + date + '"');
    }
    return new DateWrapper(parsed);
  }

  /** Port of fromInstant(): an ISO-8601 instant (`...Z`), or null for null input. */
  static fromInstant(date: string | null): DateWrapper | null {
    if (date === null) {
      return null;
    }
    const parsed: Date = new Date(date);
    if (Number.isNaN(parsed.getTime())) {
      throw new ParsingException('Could not parse date: "' + date + '"');
    }
    return new DateWrapper(parsed);
  }
}
