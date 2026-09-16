import type { TypeAndName } from '@/core/base.ts';

export interface Coordinate {
    latitude: number;
    longitude: number;
}

export enum CoordinateDisplayOrder {
    LatitudeLongitude = 0,
    LongitudeLatitude = 1
}

export enum CoordinateDisplayFormat {
    DecimalDegrees = 0,
    DecimalMinutes = 1,
    DegreesMinutesSeconds = 2
}

export enum CoordinateDirectionFormat {
    Signed = 0,
    Directional = 1
}

export class CoordinateDisplayType implements TypeAndName {
    private static readonly allInstances: CoordinateDisplayType[] = [];
    private static readonly allInstancesByType: Record<number, CoordinateDisplayType> = {};

    public static readonly SystemDefaultType: number = 0;
    public static readonly LatitudeLongitudeDecimalDegrees = new CoordinateDisplayType(1, 'Latitude Longitude D.D°', CoordinateDisplayOrder.LatitudeLongitude, CoordinateDisplayFormat.DecimalDegrees, CoordinateDirectionFormat.Signed);
    public static readonly LongitudeLatitudeDecimalDegrees = new CoordinateDisplayType(2, 'Longitude Latitude D.D°', CoordinateDisplayOrder.LongitudeLatitude, CoordinateDisplayFormat.DecimalDegrees, CoordinateDirectionFormat.Signed);
    public static readonly LatitudeLongitudeDecimalMinutes = new CoordinateDisplayType(3, 'Latitude Longitude D°M.M\'', CoordinateDisplayOrder.LatitudeLongitude, CoordinateDisplayFormat.DecimalMinutes, CoordinateDirectionFormat.Directional);
    public static readonly LongitudeLatitudeDecimalMinutes = new CoordinateDisplayType(4, 'Longitude Latitude D°M.M\'', CoordinateDisplayOrder.LongitudeLatitude, CoordinateDisplayFormat.DecimalMinutes, CoordinateDirectionFormat.Directional);
    public static readonly LatitudeLongitudeDegreesMinutesSeconds = new CoordinateDisplayType(5, 'Latitude Longitude D°M\'S"', CoordinateDisplayOrder.LatitudeLongitude, CoordinateDisplayFormat.DegreesMinutesSeconds, CoordinateDirectionFormat.Directional);
    public static readonly LongitudeLatitudeDegreesMinutesSeconds = new CoordinateDisplayType(6, 'Longitude Latitude D°M\'S"', CoordinateDisplayOrder.LongitudeLatitude, CoordinateDisplayFormat.DegreesMinutesSeconds, CoordinateDirectionFormat.Directional);

    public static readonly Default = CoordinateDisplayType.LatitudeLongitudeDecimalDegrees;

    public readonly type: number;
    public readonly name: string;
    public readonly displayOrder: CoordinateDisplayOrder;
    public readonly displayFormat: CoordinateDisplayFormat;
    public readonly directionFormat: CoordinateDirectionFormat;

    private constructor(type: number, name: string, displayOrder: CoordinateDisplayOrder, displayFormat: CoordinateDisplayFormat, directionFormat: CoordinateDirectionFormat) {
        this.type = type;
        this.name = name;
        this.displayOrder = displayOrder;
        this.displayFormat = displayFormat;
        this.directionFormat = directionFormat;

        CoordinateDisplayType.allInstances.push(this);
        CoordinateDisplayType.allInstancesByType[type] = this;
    }

    public static values(): CoordinateDisplayType[] {
        return CoordinateDisplayType.allInstances;
    }

    public static valueOf(type: number): CoordinateDisplayType | undefined {
        return CoordinateDisplayType.allInstancesByType[type];
    }
}

export function getNormalizedCoordinate(value: Coordinate): Coordinate {
    if (!value) {
        return value;
    }

    const normalizedLatitude = Math.max(-90, Math.min(90, value.latitude));
    const normalizedLongitude = ((value.longitude + 180) % 360 + 360) % 360 - 180;

    return {
        latitude: normalizedLatitude,
        longitude: normalizedLongitude
    };
}

const GCJ02_ELLIPSOID_SEMI_MAJOR_AXIS: number = 6378245.0;
const GCJ02_ELLIPSOID_ECCENTRICITY_SQUARED: number = 0.006693421622965943;

// AMap returns GCJ-02 coordinates in mainland China, while transaction
// coordinates are stored as WGS84 so every configured map provider can use them.
export function convertGCJ02ToWGS84(value: Coordinate): Coordinate {
    if (value.longitude < 72.004 || value.longitude > 137.8347 || value.latitude < 0.8293 || value.latitude > 55.8271) {
        return { ...value };
    }

    const longitudeOffset = value.longitude - 105.0;
    const latitudeOffset = value.latitude - 35.0;
    let latitudeDelta = -100.0 + 2.0 * longitudeOffset + 3.0 * latitudeOffset + 0.2 * latitudeOffset * latitudeOffset
        + 0.1 * longitudeOffset * latitudeOffset + 0.2 * Math.sqrt(Math.abs(longitudeOffset));
    let longitudeDelta = 300.0 + longitudeOffset + 2.0 * latitudeOffset + 0.1 * longitudeOffset * longitudeOffset
        + 0.1 * longitudeOffset * latitudeOffset + 0.1 * Math.sqrt(Math.abs(longitudeOffset));

    latitudeDelta += (20.0 * Math.sin(6.0 * longitudeOffset * Math.PI) + 20.0 * Math.sin(2.0 * longitudeOffset * Math.PI)) * 2.0 / 3.0;
    latitudeDelta += (20.0 * Math.sin(latitudeOffset * Math.PI) + 40.0 * Math.sin(latitudeOffset / 3.0 * Math.PI)) * 2.0 / 3.0;
    latitudeDelta += (160.0 * Math.sin(latitudeOffset / 12.0 * Math.PI) + 320 * Math.sin(latitudeOffset * Math.PI / 30.0)) * 2.0 / 3.0;
    longitudeDelta += (20.0 * Math.sin(6.0 * longitudeOffset * Math.PI) + 20.0 * Math.sin(2.0 * longitudeOffset * Math.PI)) * 2.0 / 3.0;
    longitudeDelta += (20.0 * Math.sin(longitudeOffset * Math.PI) + 40.0 * Math.sin(longitudeOffset / 3.0 * Math.PI)) * 2.0 / 3.0;
    longitudeDelta += (150.0 * Math.sin(longitudeOffset / 12.0 * Math.PI) + 300.0 * Math.sin(longitudeOffset / 30.0 * Math.PI)) * 2.0 / 3.0;

    const radianLatitude = value.latitude / 180.0 * Math.PI;
    let magic = Math.sin(radianLatitude);
    magic = 1 - GCJ02_ELLIPSOID_ECCENTRICITY_SQUARED * magic * magic;
    const squareRootMagic = Math.sqrt(magic);
    latitudeDelta = latitudeDelta * 180.0 / ((GCJ02_ELLIPSOID_SEMI_MAJOR_AXIS * (1 - GCJ02_ELLIPSOID_ECCENTRICITY_SQUARED)) / (magic * squareRootMagic) * Math.PI);
    longitudeDelta = longitudeDelta * 180.0 / (GCJ02_ELLIPSOID_SEMI_MAJOR_AXIS / squareRootMagic * Math.cos(radianLatitude) * Math.PI);

    return getNormalizedCoordinate({
        latitude: value.latitude - latitudeDelta,
        longitude: value.longitude - longitudeDelta
    });
}
