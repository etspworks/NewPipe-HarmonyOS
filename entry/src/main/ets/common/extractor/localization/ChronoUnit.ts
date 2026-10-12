/*
 * The java.time.temporal.ChronoUnit members the timeago parser uses, plus the two LocalDateTime
 * operations it performs on them. ArkTS has no java.time, so a point in time is a Date (an
 * instant) and the calendar arithmetic below is done in the device's own zone, which is where
 * LocalDateTime.now() puts it in the source.
 */

export enum ChronoUnit {
  SECONDS,
  MINUTES,
  HOURS,
  DAYS,
  WEEKS,
  MONTHS,
  YEARS
}

/** Port of ChronoUnit.isDateBased(): true from DAYS upwards. */
export function isDateBased(unit: ChronoUnit): boolean {
  return unit === ChronoUnit.DAYS || unit === ChronoUnit.WEEKS
    || unit === ChronoUnit.MONTHS || unit === ChronoUnit.YEARS;
}

/** Port of LocalDateTime.minus(amount, unit). */
export function minus(from: Date, amount: number, unit: ChronoUnit): Date {
  const result: Date = new Date(from.getTime());
  if (unit === ChronoUnit.SECONDS) {
    result.setTime(result.getTime() - amount * 1000);
  } else if (unit === ChronoUnit.MINUTES) {
    result.setTime(result.getTime() - amount * 60000);
  } else if (unit === ChronoUnit.HOURS) {
    result.setTime(result.getTime() - amount * 3600000);
  } else if (unit === ChronoUnit.DAYS) {
    result.setDate(result.getDate() - amount);
  } else if (unit === ChronoUnit.WEEKS) {
    result.setDate(result.getDate() - amount * 7);
  } else if (unit === ChronoUnit.MONTHS) {
    result.setMonth(result.getMonth() - amount);
  } else {
    result.setFullYear(result.getFullYear() - amount);
  }
  return result;
}

/** Port of LocalDateTime.truncatedTo(ChronoUnit.DAYS): midnight of the same local day. */
export function truncatedToDays(from: Date): Date {
  const result: Date = new Date(from.getTime());
  result.setHours(0, 0, 0, 0);
  return result;
}
