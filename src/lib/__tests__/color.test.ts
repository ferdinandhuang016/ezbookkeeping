import { describe, expect, it } from 'vitest';

import { getContrastTextColor, getContrastIconColor } from '@/lib/color.ts';

describe('getContrastTextColor', () => {
    it('returns black for a light background', () => {
        expect(getContrastTextColor('edddcd')).toBe('000000');
    });

    it('returns white for a dark background', () => {
        expect(getContrastTextColor('112233')).toBe('ffffff');
    });
});

describe('getContrastIconColor', () => {
    it('uses a translucent white icon for the default light background', () => {
        expect(getContrastIconColor('d43f3f')).toBe('ffffff99');
    });

    it('uses the same readable icon treatment for the default dark background', () => {
        expect(getContrastIconColor('a92f2f')).toBe('ffffff99');
    });
});
