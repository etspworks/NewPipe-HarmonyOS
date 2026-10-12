/*
 * Port of org.schabi.newpipe.database.subscription.NotificationMode (NewPipe app).
 * An @IntDef in the source, so the stored values are the integers below.
 */
export enum NotificationMode {
  DISABLED = 0,
  /** Other values are reserved for the future, exactly as in the source. */
  ENABLED = 1
}
