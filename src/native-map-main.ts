// The Android client embeds only this map surface. Business UI remains native.
import { createMapInstance, initMapProvider, isSupportGetGeoLocationByClick } from '@/lib/map/index.ts';
import type { MapInstance, MapLocation } from '@/lib/map/base.ts';
import type { Coordinate } from '@/core/coordinate.ts';
import services from '@/lib/services.ts';
import { getBasePath } from '@/lib/web.ts';

interface NativeMapOptions {
    token: string;
    language: string;
    coordinate?: Coordinate;
    readOnly: boolean;
    zoomIn: string;
    zoomOut: string;
}
declare global {
    interface Window {
        EbkMap?: { postMessage(message: string): void };
        configureNativeMap?: (options: NativeMapOptions) => void;
        setNativeCoordinate?: (coordinate: Coordinate) => void;
        setNativeClickEnabled?: (enabled: boolean) => void;
    }
}
let map: MapInstance | null = null;
let configured = false;
let clickEnabled = false;
let latestCoordinate: Coordinate | undefined;
window.setNativeClickEnabled = enabled => { clickEnabled = enabled === true; };
function valid(value?: Coordinate): value is Coordinate {
    return !!value && Number.isFinite(value.latitude) && Number.isFinite(value.longitude) && Math.abs(value.latitude) <= 90 && Math.abs(value.longitude) <= 180;
}
function send(value: object): void { window.EbkMap?.postMessage(JSON.stringify(value)); }
window.setNativeCoordinate = coordinate => {
    if (!valid(coordinate)) return;
    latestCoordinate = coordinate;
    if (!map?.inited) return;
    map.setMapCenterTo(coordinate, map.getDefaultZoomLevel());
    map.setMapCenterMarker(coordinate);
};
window.configureNativeMap = options => {
    if (configured || !window.EbkMap || !options || typeof options.token !== 'string') return;
    configured = true;
    if (!latestCoordinate && valid(options.coordinate)) latestCoordinate = options.coordinate;
    // Ephemeral credentials are used only for the existing same-origin proxy.
    // Never write native tokens to browser localStorage/sessionStorage.
    const proxyUrl = (layer: string, provider: string, language: string): string => `${getBasePath()}/proxy/map/${layer}/{z}/{x}/{y}.png?provider=${encodeURIComponent(provider)}&token=${encodeURIComponent(options.token)}&language=${encodeURIComponent(language)}`;
    services.generateMapProxyTileImageUrl = (provider, language) => proxyUrl('tile', provider, language);
    services.generateMapProxyAnnotationImageUrl = (provider, language) => proxyUrl('annotation', provider, language);
    initMapProvider(options.language);
    const started = Date.now();
    const timer = window.setInterval(() => {
        try {
            if (!map?.dependencyLoaded) map = createMapInstance({ enableZoomControl: true });
            if (!map || !map.dependencyLoaded) {
                if (Date.now() - started > 30000) {
                    window.clearInterval(timer);
                    send({ type: 'error', message: 'Map could not be loaded' });
                }
                return;
            }
            window.clearInterval(timer);
            const coordinate = latestCoordinate || { latitude: 0, longitude: 0 };
            map.initMapInstance(document.getElementById('map') as HTMLElement, {
                language: options.language,
                initCenter: coordinate,
                zoomLevel: latestCoordinate ? map.getDefaultZoomLevel() : map.getMinZoomLevel(),
                text: { zoomIn: options.zoomIn, zoomOut: options.zoomOut },
                markerDraggable: !options.readOnly,
                onMarkerMove: (position: MapLocation) => {
                    if (options.readOnly || !valid(position)) return;
                    latestCoordinate = position;
                    send({ type: 'coordinate', latitude: position.latitude, longitude: position.longitude, name: position.name ?? '' });
                },
                onClick: position => {
                    if (options.readOnly || !clickEnabled || !isSupportGetGeoLocationByClick() || !valid(position)) return;
                    map?.setMapCenterMarker(position);
                    send({ type: 'coordinate', latitude: position.latitude, longitude: position.longitude });
                }
            });
            if (latestCoordinate) window.setNativeCoordinate?.(latestCoordinate);
            send({ type: 'ready' });
        } catch (error) {
            window.clearInterval(timer);
            send({ type: 'error', message: error instanceof Error ? error.message : 'Map could not be loaded' });
        }
    }, 100);
};
