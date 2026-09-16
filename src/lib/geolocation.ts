import type { MapLocation } from '@/lib/map/base.ts';

import { getAmapApplicationKey, getMapProvider } from '@/lib/server_settings.ts';
import { getAmapCurrentGeoLocation } from '@/lib/map/amap.ts';

export function isCurrentGeoLocationSupported(): boolean {
    return (getMapProvider() === 'amap' && !!getAmapApplicationKey()) || !!navigator.geolocation;
}

export function getCurrentGeoLocation(): Promise<MapLocation> {
    if (getMapProvider() === 'amap' && getAmapApplicationKey()) {
        return getAmapCurrentGeoLocation();
    }

    return new Promise((resolve, reject) => {
        if (!navigator.geolocation) {
            reject(new Error('Browser geolocation is unavailable'));
            return;
        }

        navigator.geolocation.getCurrentPosition(position => {
            if (!position?.coords) {
                reject(new Error('Current position is unavailable'));
                return;
            }

            resolve({
                latitude: position.coords.latitude,
                longitude: position.coords.longitude
            });
        }, reject, {
            enableHighAccuracy: true,
            timeout: 20000
        });
    });
}
