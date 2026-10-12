/*
 * Port of org.schabi.newpipe.extractor.NewPipe (NewPipeExtractor v0.26.5).
 *
 * DEVIATION, deliberate: Java reads the service list straight from ServiceList, whose static
 * initialiser constructs every service. Doing that here would make NewPipe import the whole
 * wave-C service tree, and those services import Extractor which imports NewPipe again — an
 * ES-module cycle that is resolved at *init* time and would leave NewPipe half-built. So the
 * service list is registered instead: ServiceList calls registerServices() once, on import.
 * Everything else is the source, verbatim.
 */

import { Downloader } from '../downloader/Downloader';
import { Localization } from '../downloader/Localization';
import { ExtractionException } from '../exceptions/Exceptions';
import { ContentCountry } from '../localization/ContentCountry';
import { ExtractorLogger } from './ExtractorLogger';
import { LinkType, StreamingService } from './StreamingService';

const TAG: string = 'NewPipe';

export class NewPipe {
  private static downloader: Downloader | null = null;
  private static preferredLocalization: Localization | null = null;
  private static preferredContentCountry: ContentCountry | null = null;
  private static services: StreamingService[] = [];

  static init(d: Downloader, l: Localization = Localization.DEFAULT,
    c: ContentCountry | null = null): void {
    const country: ContentCountry = c !== null
      ? c
      : (l.getCountryCode().length === 0
        ? ContentCountry.DEFAULT : new ContentCountry(l.getCountryCode()));
    ExtractorLogger.d(TAG, 'Initializing with downloader={}, localization={}, country={}',
      [d, l, country]);
    NewPipe.downloader = d;
    NewPipe.preferredLocalization = l;
    NewPipe.preferredContentCountry = country;
  }

  static getDownloader(): Downloader | null {
    return NewPipe.downloader;
  }

  /* //////////////////////////////////////////////////////////////////////////
  // Utils
  ////////////////////////////////////////////////////////////////////////// */

  /** Stands in for ServiceList's static initialiser; see the deviation note above. */
  static registerServices(services: StreamingService[]): void {
    NewPipe.services = services;
  }

  static getServices(): StreamingService[] {
    return NewPipe.services;
  }

  static getService(serviceId: number): StreamingService {
    for (const service of NewPipe.services) {
      if (service.getServiceId() === serviceId) {
        return service;
      }
    }
    throw new ExtractionException('There\'s no service with the id = "' + serviceId + '"');
  }

  static getServiceByName(serviceName: string): StreamingService {
    for (const service of NewPipe.services) {
      if (service.getServiceInfo().getName() === serviceName) {
        return service;
      }
    }
    throw new ExtractionException('There\'s no service with the name = "' + serviceName + '"');
  }

  static getServiceByUrl(url: string): StreamingService {
    for (const service of NewPipe.services) {
      if (service.getLinkTypeByUrl(url) !== LinkType.NONE) {
        return service;
      }
    }
    throw new ExtractionException('No service can handle the url = "' + url + '"');
  }

  /* //////////////////////////////////////////////////////////////////////////
  // Localization
  ////////////////////////////////////////////////////////////////////////// */

  static setupLocalization(thePreferredLocalization: Localization,
    thePreferredContentCountry: ContentCountry | null = null): void {
    NewPipe.preferredLocalization = thePreferredLocalization;

    if (thePreferredContentCountry !== null) {
      NewPipe.preferredContentCountry = thePreferredContentCountry;
    } else {
      NewPipe.preferredContentCountry = thePreferredLocalization.getCountryCode().length === 0
        ? ContentCountry.DEFAULT
        : new ContentCountry(thePreferredLocalization.getCountryCode());
    }
  }

  static getPreferredLocalization(): Localization {
    return NewPipe.preferredLocalization === null
      ? Localization.DEFAULT : NewPipe.preferredLocalization;
  }

  static setPreferredLocalization(preferredLocalization: Localization): void {
    NewPipe.preferredLocalization = preferredLocalization;
  }

  static getPreferredContentCountry(): ContentCountry {
    return NewPipe.preferredContentCountry === null
      ? ContentCountry.DEFAULT : NewPipe.preferredContentCountry;
  }

  static setPreferredContentCountry(preferredContentCountry: ContentCountry): void {
    NewPipe.preferredContentCountry = preferredContentCountry;
  }
}
