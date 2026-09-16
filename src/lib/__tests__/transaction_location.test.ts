import { describe, expect, it } from 'vitest';

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
});
