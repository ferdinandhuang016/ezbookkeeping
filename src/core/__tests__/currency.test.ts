import { describe, expect, it } from 'vitest';

import { getEffectiveCurrencyCodes } from '@/core/currency.ts';

describe('getEffectiveCurrencyCodes', () => {
	it('keeps enabled, default, and existing account currencies', () => {
		expect(getEffectiveCurrencyCodes(
			{ CNY: false, EUR: true, USD: false },
			'CNY',
			['---', 'USD']
		)).toEqual(new Set(['CNY', 'EUR', 'USD']));
	});

	it('uses the new-user CNY and USD defaults supplied by settings', () => {
		expect(getEffectiveCurrencyCodes(
			{ CNY: true, USD: true },
			'',
			[]
		)).toEqual(new Set(['CNY', 'USD']));
	});
});
