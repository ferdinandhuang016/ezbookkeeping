import { ref, computed } from 'vue';

import { useI18n } from '@/locales/helpers.ts';

import { useUserStore } from '@/stores/user.ts';
import { useExchangeRatesStore } from '@/stores/exchangeRates.ts';

import type { BigDecimal } from '@/core/numeral.ts';
import type { TextualYearMonthDay } from '@/core/datetime.ts';
import { TRANSACTION_MIN_AMOUNT, TRANSACTION_MAX_AMOUNT } from '@/consts/transaction.ts';

import type {
    LatestExchangeRate,
    LatestExchangeRateResponse,
    LocalizedLatestExchangeRate
} from '@/models/exchange_rate.ts';

import {
    BIG_DECIMAL_ZERO,
    getExchangedAmountByRate
} from '@/lib/numeral.ts';

import {
    getCurrentUnixTime,
    parseDateTimeFromUnixTime,
    parseDateTimeFromUnixTimeWithBrowserTimezone
} from '@/lib/datetime.ts';

export function useExchangeRatesPageBase() {
    const { getAllDisplayExchangeRates, formatDateTimeToLongDate, parseAmountFromWesternArabicNumerals } = useI18n();

    const userStore = useUserStore();
    const exchangeRatesStore = useExchangeRatesStore();

    const baseCurrency = ref<string>(userStore.currentUserDefaultCurrency);
    const baseAmount = ref<number>(100);
    const currentDate = parseDateTimeFromUnixTimeWithBrowserTimezone(getCurrentUnixTime()).getGregorianCalendarYearDashMonthDashDay();
    const exchangeRatesDate = ref<TextualYearMonthDay>(currentDate);
    const historicalExchangeRatesData = ref<LatestExchangeRateResponse>();

    const defaultCurrency = computed<string>(() => userStore.currentUserDefaultCurrency);
    const isCurrentExchangeRatesDate = computed<boolean>(() => exchangeRatesDate.value === currentDate);
    const exchangeRatesData = computed<LatestExchangeRateResponse | undefined>(() => isCurrentExchangeRatesDate.value
        ? exchangeRatesStore.latestExchangeRates.data
        : historicalExchangeRatesData.value);
    const isUserCustomExchangeRates = computed<boolean>(() => exchangeRatesData.value?.dataSource === 'user_custom');

    const exchangeRatesDataUpdateTime = computed<string>(() => {
        if (!exchangeRatesData.value?.updateTime) {
            return '';
        }

        const exchangeRatesLastUpdateTime = parseDateTimeFromUnixTime(exchangeRatesData.value.updateTime);
        return formatDateTimeToLongDate(exchangeRatesLastUpdateTime);
    });

    const availableExchangeRates = computed<LocalizedLatestExchangeRate[]>(() => {
        return getAllDisplayExchangeRates(exchangeRatesData.value);
    });
    const exchangeRateMap = computed<Record<string, LatestExchangeRate>>(() => {
        const ret: Record<string, LatestExchangeRate> = {};

        for (const exchangeRate of exchangeRatesData.value?.exchangeRates ?? []) {
            ret[exchangeRate.currency] = exchangeRate;
        }

        return ret;
    });

    function getConvertedAmount(baseAmount: BigDecimal, fromExchangeRate?: LatestExchangeRate | LocalizedLatestExchangeRate, toExchangeRate?: LatestExchangeRate | LocalizedLatestExchangeRate): BigDecimal | '' | null {
        if (!fromExchangeRate || !toExchangeRate) {
            return '';
        }

        if (!baseAmount) {
            return BIG_DECIMAL_ZERO;
        }

        return getExchangedAmountByRate(baseAmount, fromExchangeRate.rate, toExchangeRate.rate);
    }

    function setAsBaseline(currency: string, amount: string): void {
        baseCurrency.value = currency;
        baseAmount.value = parseAmountFromWesternArabicNumerals(amount);

        if (baseAmount.value < TRANSACTION_MIN_AMOUNT) {
            baseAmount.value = TRANSACTION_MIN_AMOUNT;
        } else if (baseAmount.value > TRANSACTION_MAX_AMOUNT) {
            baseAmount.value = TRANSACTION_MAX_AMOUNT;
        }
    }

    return {
        // states
        baseCurrency,
        baseAmount,
        exchangeRatesDate,
        historicalExchangeRatesData,
        // computed states
        defaultCurrency,
        isCurrentExchangeRatesDate,
        exchangeRatesData,
        isUserCustomExchangeRates,
        exchangeRatesDataUpdateTime,
        availableExchangeRates,
        exchangeRateMap,
        // functions
        getConvertedAmount,
        setAsBaseline
    };
}
