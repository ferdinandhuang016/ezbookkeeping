import { describe, expect, test } from 'vitest';

import { convertGCJ02ToWGS84 } from '@/core/coordinate.ts';

describe('coordinate conversion', () => {
    test('converts mainland GCJ-02 coordinates to WGS84', () => {
        const coordinate = convertGCJ02ToWGS84({
            latitude: 39.908823,
            longitude: 116.39747
        });

        expect(coordinate.latitude).toBeCloseTo(39.90742, 4);
        expect(coordinate.longitude).toBeCloseTo(116.39123, 4);
    });

    test('keeps coordinates outside mainland China unchanged', () => {
        expect(convertGCJ02ToWGS84({
            latitude: 51.5074,
            longitude: -0.1278
        })).toEqual({
            latitude: 51.5074,
            longitude: -0.1278
        });
    });
});
