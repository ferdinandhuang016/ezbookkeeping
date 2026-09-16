import { describe, expect, it, vi } from 'vitest';

import { Transaction } from '@/models/transaction.ts';

describe('transaction location name', () => {
    it('serializes and clears the location name with its coordinates', () => {
        const transaction = Transaction.createNewTransaction(2, 1, 'UTC', 0);

        transaction.setGeoLocation({ latitude: 39.9, longitude: 116.3 }, 'Office');

        expect(transaction.geoLocationName).toBe('Office');
        expect(transaction.toCreateRequest('session').geoLocationName).toBe('Office');

        transaction.removeGeoLocation();

        expect(transaction.geoLocationName).toBe('');
        expect(transaction.toCreateRequest('session').geoLocationName).toBe('');
    });
});

describe('AMap location name', () => {
    it('prefers a POI name and falls back to the formatted address', async () => {
        Object.defineProperty(globalThis, 'window', {
            configurable: true,
            value: { location: { pathname: '/' } }
        });
        const { getAmapLocationName } = await import('@/lib/map/amap.ts');

        expect(getAmapLocationName({
            pois: [{ name: 'Coffee Shop' }],
            formattedAddress: '1 Main Street'
        })).toBe('Coffee Shop');
        expect(getAmapLocationName({ formattedAddress: '1 Main Street' })).toBe('1 Main Street');
    });

    it('reports dragged coordinates before reverse geocoding completes', async () => {
        const handlers: Record<string, (event: unknown) => void> = {};
        const marker = {
            on: vi.fn((event: string, callback: (event: unknown) => void) => { handlers[event] = callback; }),
            getPosition: vi.fn(),
            setPosition: vi.fn(),
        };
        const map = {
            on: vi.fn(),
            add: vi.fn(),
        };
        class LngLat {
            public constructor(private readonly longitude: number, private readonly latitude: number) {}
            public getLat(): number { return this.latitude; }
            public getLng(): number { return this.longitude; }
        }
        const { AmapMapInstance, AmapMapProvider } = await import('@/lib/map/amap.ts');
        AmapMapProvider.AMap = {
            Map: vi.fn(function MapStub() { return map; }),
            Marker: vi.fn(function MarkerStub() { return marker; }),
            LngLat,
            convertFrom: vi.fn((point: LngLat, _source: string, callback: (status: string, result: unknown) => void) => {
                callback('complete', { info: 'ok', locations: [point] });
            }),
        };
        const moved = vi.fn();
        const instance = new AmapMapInstance({});
        instance.initMapInstance({} as HTMLElement, {
            initCenter: { latitude: 39.9, longitude: 116.3 },
            zoomLevel: 14,
            text: { zoomIn: '+', zoomOut: '-' },
            markerDraggable: true,
            onMarkerMove: moved,
        });
        instance.setMapCenterMarker({ latitude: 39.9, longitude: 116.3 });

        handlers['dragend']!({ lnglat: new LngLat(116.4, 39.91) });

        expect(moved).toHaveBeenCalledTimes(1);
        expect(moved).toHaveBeenCalledWith({
            latitude: expect.any(Number),
            longitude: expect.any(Number),
        });
    });
});
