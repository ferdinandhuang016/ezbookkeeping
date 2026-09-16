import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import type { MapInstanceInitOptions } from '@/lib/map/base.ts';

const fixtures = vi.hoisted(() => ({
    map: {
        dependencyLoaded: false,
        inited: false,
        initMapInstance: vi.fn<(_: HTMLElement, options: MapInstanceInitOptions) => void>(),
        getDefaultZoomLevel: () => 12,
        getMinZoomLevel: () => 1,
        setMapCenterTo: vi.fn(),
        setMapCenterMarker: vi.fn(),
    },
    postMessage: vi.fn(),
    initMapProvider: vi.fn(),
    provider: 'amap',
    amapKey: '',
}));
vi.mock('@/lib/map/index.ts', () => ({
    createMapInstance: () => fixtures.map,
    initMapProvider: fixtures.initMapProvider,
    isSupportGetGeoLocationByClick: () => true,
}));
vi.mock('@/lib/server_settings.ts', () => ({
    getMapProvider: () => fixtures.provider,
    getAmapApplicationKey: () => fixtures.amapKey,
}));
vi.mock('@/lib/services.ts', () => ({ default: {} }));
vi.mock('@/lib/web.ts', () => ({ getBasePath: () => '/books' }));

describe('native coordinate bridge ordering', () => {
    beforeEach(async () => {
        vi.resetModules();
        vi.useFakeTimers();
        fixtures.map.dependencyLoaded = false;
        fixtures.map.inited = false;
        fixtures.postMessage.mockClear();
        fixtures.initMapProvider.mockClear();
        fixtures.provider = 'amap';
        fixtures.amapKey = '';
        fixtures.map.initMapInstance.mockImplementation(() => { fixtures.map.inited = true; });
        vi.stubGlobal('window', { EbkMap: { postMessage: fixtures.postMessage }, setInterval, clearInterval });
        vi.stubGlobal('document', { getElementById: () => ({}) });
        await import('./native-map-main.ts');
    });
    afterEach(() => {
        vi.useRealTimers();
        vi.unstubAllGlobals();
    });
    it('keeps the latest GPS update until provider dependencies are ready', () => {
        window.configureNativeMap?.({ token: 'fixture', language: 'en', readOnly: false, coordinate: { latitude: 1, longitude: 2 }, zoomIn: '+', zoomOut: '-' });
        expect(fixtures.initMapProvider).toHaveBeenCalledWith('en', 'openstreetmap');
        window.setNativeCoordinate?.({ latitude: 22.3, longitude: 114.2 });
        vi.advanceTimersByTime(200);
        expect(fixtures.map.initMapInstance).not.toHaveBeenCalled();
        window.setNativeCoordinate?.({ latitude: 22.4, longitude: 114.3 });
        fixtures.map.dependencyLoaded = true;
        vi.advanceTimersByTime(100);
        expect(fixtures.map.initMapInstance.mock.calls[0]?.[1].initCenter).toEqual({ latitude: 22.4, longitude: 114.3 });
        expect(fixtures.map.setMapCenterTo).toHaveBeenLastCalledWith({ latitude: 22.4, longitude: 114.3 }, 12);
        expect(fixtures.map.setMapCenterMarker).toHaveBeenLastCalledWith({ latitude: 22.4, longitude: 114.3 });
    });
    it('applies later coordinates immediately and ignores invalid updates', () => {
        window.configureNativeMap?.({ token: 'fixture', language: 'en', readOnly: false, zoomIn: '+', zoomOut: '-' });
        fixtures.map.dependencyLoaded = true;
        vi.advanceTimersByTime(100);
        expect(fixtures.map.initMapInstance.mock.calls[0]?.[1].zoomLevel).toBe(1);
        window.setNativeCoordinate?.({ latitude: 5, longitude: 6 });
        window.setNativeCoordinate?.({ latitude: Number.NaN, longitude: 6 });
        window.setNativeCoordinate?.({ latitude: 100, longitude: 6 });
        expect(fixtures.map.setMapCenterMarker).toHaveBeenCalledTimes(1);
        expect(fixtures.map.setMapCenterMarker).toHaveBeenLastCalledWith({ latitude: 5, longitude: 6 });
    });
    it('preserves read-only bridge restrictions even after click mode is requested', () => {
        window.configureNativeMap?.({ token: 'fixture', language: 'en', readOnly: true, zoomIn: '+', zoomOut: '-' });
        fixtures.map.dependencyLoaded = true;
        vi.advanceTimersByTime(100);
        window.setNativeClickEnabled?.(true);
        fixtures.postMessage.mockClear();
        fixtures.map.initMapInstance.mock.calls[0]?.[1].onClick?.({ latitude: 5, longitude: 6 });
        expect(fixtures.postMessage).not.toHaveBeenCalled();
    });
    it('falls back when an external map SDK does not become ready', () => {
        fixtures.provider = 'amap';
        fixtures.amapKey = 'configured';
        window.configureNativeMap?.({ token: 'fixture', language: 'en', readOnly: false, zoomIn: '+', zoomOut: '-' });
        expect(fixtures.initMapProvider).toHaveBeenCalledWith('en', 'amap');
        vi.advanceTimersByTime(8100);
        expect(fixtures.initMapProvider).toHaveBeenLastCalledWith('en', 'openstreetmap');
        expect(fixtures.postMessage).not.toHaveBeenCalledWith(expect.stringContaining('error'));
    });
});
