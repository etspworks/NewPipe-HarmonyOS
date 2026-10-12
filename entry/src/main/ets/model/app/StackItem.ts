/*
 * Port of app/src/main/java/org/schabi/newpipe/fragments/detail/StackItem.java - one entry of
 * the video-detail "navigation history" stack.
 */

import { PlayQueue } from './PlayQueue';

export class StackItem {
  private readonly serviceId: number;
  private url: string;
  private title: string;
  private playQueue: PlayQueue;

  constructor(serviceId: number, url: string, title: string, playQueue: PlayQueue) {
    this.serviceId = serviceId;
    this.url = url;
    this.title = title;
    this.playQueue = playQueue;
  }

  setUrl(url: string): void {
    this.url = url;
  }

  setPlayQueue(queue: PlayQueue): void {
    this.playQueue = queue;
  }

  getServiceId(): number {
    return this.serviceId;
  }

  getTitle(): string {
    return this.title;
  }

  setTitle(title: string): void {
    this.title = title;
  }

  getUrl(): string {
    return this.url;
  }

  getPlayQueue(): PlayQueue {
    return this.playQueue;
  }

  toString(): string {
    return `${this.getServiceId()}:${this.getUrl()} > ${this.getTitle()}`;
  }
}
