// eslint-disable-next-line @typescript-eslint/ban-ts-comment
// @ts-nocheck
import { convertGCJ02ToWGS84, type Coordinate } from '@/core/coordinate.ts';
import type { MapProvider, MapInstance, MapCreateOptions, MapInstanceInitOptions, MapLocation } from './base.ts';

import { isFunction, isArray } from '@/lib/common.ts';
import { asyncLoadAssets } from '@/lib/misc.ts';
import services from '@/lib/services.ts';
import {
    getAmapSecurityVerificationMethod,
    getAmapApiExternalProxyUrl,
    getAmapApplicationSecret
} from '@/lib/server_settings.ts';
import logger from '@/lib/logger.ts';

export class AmapMapProvider implements MapProvider {
    // https://lbs.amap.com/api/javascript-api-v2/documentation
    public static AMap: unknown = null;

    public getWebsite(): string {
        return 'https://www.amap.com';
    }

    public isSupportGetGeoLocationByClick(): boolean {
        return false;
    }

    // eslint-disable-next-line @typescript-eslint/no-unused-vars
    public asyncLoadAssets(language?: string): Promise<unknown> {
        if (AmapMapProvider.AMap) {
            return Promise.resolve();
        }

        if (!window._AMapSecurityConfig) {
            const amapSecurityConfig = {};

            if (getAmapSecurityVerificationMethod() === 'internal_proxy') {
                amapSecurityConfig.serviceHost = services.generateAmapApiInternalProxyUrl();
            } else if (getAmapSecurityVerificationMethod() === 'external_proxy') {
                amapSecurityConfig.serviceHost = getAmapApiExternalProxyUrl();
            } else if (getAmapSecurityVerificationMethod() === 'plain_text') {
                amapSecurityConfig.securityJsCode = getAmapApplicationSecret();
            }

            window._AMapSecurityConfig = amapSecurityConfig;
        }

        if (!window.onAMapCallback) {
            window.onAMapCallback = () => {
                AmapMapProvider.AMap = window.AMap;
            };
        }

        return asyncLoadAssets('js', services.generateAmapJavascriptUrl('onAMapCallback'));
    }

    public createMapInstance(options: MapCreateOptions): MapInstance | null {
        return new AmapMapInstance(options);
    }
}

export function getAmapLocationName(result: unknown): string | undefined {
    const value = result as Record<string, unknown> | null;
    const pois = value?.pois as Array<Record<string, unknown>> | undefined;
    const candidates = [ value?.poiName, pois?.[0]?.name, value?.formattedAddress ];

    for (const candidate of candidates) {
        if (typeof candidate === 'string' && candidate.trim()) {
            return candidate.trim().substring(0, 255);
        }
    }

    return undefined;
}

function getAmapLocationNameByPosition(position: unknown): Promise<string | undefined> {
    const AMap = AmapMapProvider.AMap;

    if (!AMap?.Geocoder) {
        return Promise.resolve(undefined);
    }

    return new Promise(resolve => {
        new AMap.Geocoder().getAddress(position, (status, result) => {
            if (status !== 'complete' || result?.info !== 'OK') {
                resolve(undefined);
                return;
            }

            resolve(getAmapLocationName(result.regeocode));
        });
    });
}

export function getAmapCurrentGeoLocation(): Promise<MapLocation> {
    const provider = new AmapMapProvider();

    return provider.asyncLoadAssets().then(() => new Promise((resolve, reject) => {
        const AMap = AmapMapProvider.AMap;

        if (!AMap?.Geolocation) {
            reject(new Error('AMap geolocation is unavailable'));
            return;
        }

        const geolocation = new AMap.Geolocation({
            enableHighAccuracy: true,
            timeout: 20000,
            needAddress: true,
            extensions: 'all'
        });

        geolocation.getCurrentPosition((status, result) => {
            const position = result?.position;
            const latitude = position?.getLat?.() ?? position?.lat;
            const longitude = position?.getLng?.() ?? position?.lng;

            if (status !== 'complete' || !Number.isFinite(latitude) || !Number.isFinite(longitude)) {
                reject(result || new Error('AMap geolocation failed'));
                return;
            }

            resolve({
                ...convertGCJ02ToWGS84({ latitude, longitude }),
                name: getAmapLocationName(result)
            });
        });
    }));
}

export class AmapMapInstance implements MapInstance {
    public dependencyLoaded: boolean = false;
    public inited: boolean = false;

    private readonly defaultZoomLevel: number = 14;
    private readonly minZoomLevel: number = 2;
    private readonly maxZoomLevel: number = 19;

    private readonly mapCreateOptions: MapCreateOptions;
    private amapInstance: unknown = null;
    private amapToolbar: unknown = null;
    private amapCenterPosition: unknown = null;
    private amapCenterMarker: unknown | null;
    private mapInitOptions: MapInstanceInitOptions | null = null;
    private markerMoveSequence: number = 0;

    public constructor(options: MapCreateOptions) {
        this.dependencyLoaded = !!AmapMapProvider.AMap;
        this.mapCreateOptions = options;
    }

    public initMapInstance(mapContainer: HTMLElement, options: MapInstanceInitOptions): void {
        if (!AmapMapProvider.AMap) {
            return;
        }

        const AMap = AmapMapProvider.AMap;
        this.mapInitOptions = options;
        const amapInstance = new AMap.Map(mapContainer, {
            zoom: options.zoomLevel,
            center: [ options.initCenter.longitude, options.initCenter.latitude ],
            zooms: [ 1, 19 ],
            jogEnable: false
        });

        if (this.mapCreateOptions.enableZoomControl) {
            this.amapToolbar = new AMap.ToolBar({
                position: 'LT'
            });
            amapInstance.addControl(this.amapToolbar);
        }

        amapInstance.on('click', function(e) {
            if (options.onClick) {
                options.onClick({
                    latitude: e.lnglat.lat,
                    longitude: e.lnglat.lng
                });
            }
        });

        amapInstance.on('zoomend', function() {
            if (options.onZoomChange && isFunction(amapInstance.getZoom)) {
                options.onZoomChange(amapInstance.getZoom());
            }
        });

        this.amapInstance = amapInstance;
        this.inited = true;
    }

    public getDefaultZoomLevel(): number {
        return this.defaultZoomLevel;
    }

    public getMinZoomLevel(): number {
        if (!this.amapInstance || !isFunction(this.amapInstance.getZooms)) {
            return this.minZoomLevel;
        }

        const zooms = this.amapInstance.getZooms();

        if (!zooms || !isArray(zooms) || zooms.length !== 2) {
            return this.minZoomLevel;
        }

        return zooms[0];
    }

    public getMaxZoomLevel(): number {
        if (!this.amapInstance || !isFunction(this.amapInstance.getZooms)) {
            return this.maxZoomLevel;
        }

        const zooms = this.amapInstance.getZooms();

        if (!zooms || !isArray(zooms) || zooms.length !== 2) {
            return this.maxZoomLevel;
        }

        return zooms[1];
    }

    public getZoomLevel(): number {
        if (!this.amapInstance || !isFunction(this.amapInstance.getZoom)) {
            return this.defaultZoomLevel;
        }

        return this.amapInstance?.getZoom() ?? this.defaultZoomLevel;
    }

    public setMapCenterTo(center: Coordinate, zoomLevel: number): void {
        if (!AmapMapProvider.AMap || !this.amapInstance) {
            return;
        }

        const AMap = AmapMapProvider.AMap;

        if (this.amapCenterPosition
            && this.amapCenterPosition.originalLongitude === center.longitude
            && this.amapCenterPosition.originalLatitude === center.latitude
            && this.amapCenterPosition.convertedLongitude
            && this.amapCenterPosition.convertedLatitude
        ) {
            this.amapInstance.setZoomAndCenter(zoomLevel, new AMap.LngLat(this.amapCenterPosition.convertedLongitude, this.amapCenterPosition.convertedLatitude));
            return;
        }

        this.amapCenterPosition = {
            originalLongitude: center.longitude,
            originalLatitude: center.latitude,
            convertedLongitude: null,
            convertedLatitude: null
        };

        const centerPoint = new AMap.LngLat(center.longitude, center.latitude);

        AMap.convertFrom(centerPoint, 'gps', (status, result) => {
            let convertedCenterPoint = centerPoint;

            if (result.info !== 'ok' || !result.locations) {
                logger.warn('amap geo position convert failed');
            } else {
                convertedCenterPoint = result.locations[0];
                this.amapCenterPosition.convertedLongitude = convertedCenterPoint.getLng();
                this.amapCenterPosition.convertedLatitude = convertedCenterPoint.getLat();
            }

            this.amapInstance.setZoomAndCenter(zoomLevel, convertedCenterPoint);
        });
    }

    public setMapCenterMarker(position: Coordinate): void {
        if (!AmapMapProvider.AMap || !this.amapInstance) {
            return;
        }

        const AMap = AmapMapProvider.AMap;

        if (this.amapCenterPosition
            && this.amapCenterPosition.originalLongitude === position.longitude
            && this.amapCenterPosition.originalLatitude === position.latitude
            && this.amapCenterPosition.convertedLongitude
            && this.amapCenterPosition.convertedLatitude
        ) {
            this.setMaker(new AMap.LngLat(this.amapCenterPosition.convertedLongitude, this.amapCenterPosition.convertedLatitude));
            return;
        }

        const markerPoint = new AMap.LngLat(position.longitude, position.latitude);

        AMap.convertFrom(markerPoint, 'gps', (status, result) => {
            let convertedMarkPoint = markerPoint;

            if (result.info !== 'ok' || !result.locations) {
                logger.warn('amap geo position convert failed');
            } else {
                convertedMarkPoint = result.locations[0];
            }

            this.setMaker(convertedMarkPoint);
        });
    }

    public removeMapCenterMarker(): void {
        if (!this.amapInstance || !this.amapCenterMarker) {
            return;
        }

        this.amapInstance.remove(this.amapCenterMarker);
        this.amapCenterMarker = null;
    }

    public setMapCenterMarkerDraggable(draggable: boolean): void {
        if (!this.mapInitOptions) {
            return;
        }

        this.mapInitOptions = {
            ...this.mapInitOptions,
            markerDraggable: draggable
        };
        this.amapCenterMarker?.setDraggable?.(draggable);
        this.amapCenterMarker?.setCursor?.(draggable ? 'move' : 'default');
    }

    public zoomIn(): void {
        if (!this.amapInstance) {
            return;
        }

        this.amapInstance.zoomIn();
    }

    public zoomOut(): void {
        if (!this.amapInstance) {
            return;
        }

        this.amapInstance.zoomOut();
    }

    private setMaker(point: unknown): void {
        if (!AmapMapProvider.AMap || !this.amapInstance) {
            return;
        }

        const AMap = AmapMapProvider.AMap;

        if (!this.amapCenterMarker) {
            this.amapCenterMarker = new AMap.Marker({
                position: point,
                draggable: this.mapInitOptions?.markerDraggable === true,
                cursor: this.mapInitOptions?.markerDraggable === true ? 'move' : 'default'
            });
            this.amapCenterMarker.on('dragend', event => this.onMarkerMove(event?.lnglat ?? this.amapCenterMarker?.getPosition?.()));
            this.amapInstance.add(this.amapCenterMarker);
        } else {
            this.amapCenterMarker.setPosition(point);
        }
    }

    private onMarkerMove(point: unknown): void {
        const latitude = point?.getLat?.() ?? point?.lat;
        const longitude = point?.getLng?.() ?? point?.lng;

        if (!this.mapInitOptions?.onMarkerMove || !Number.isFinite(latitude) || !Number.isFinite(longitude)) {
            return;
        }

        const sequence = ++this.markerMoveSequence;
        const coordinate = convertGCJ02ToWGS84({ latitude, longitude });

        this.mapInitOptions.onMarkerMove({ ...coordinate });

        getAmapLocationNameByPosition(point).then(name => {
            if (sequence !== this.markerMoveSequence || !name) {
                return;
            }

            this.mapInitOptions?.onMarkerMove?.({ ...coordinate, name });
        });
    }
}
