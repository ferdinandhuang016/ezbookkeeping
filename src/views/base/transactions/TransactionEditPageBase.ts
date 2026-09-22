import { ref, computed, watch } from 'vue';

import { useI18n } from '@/locales/helpers.ts';

import { useSettingsStore } from '@/stores/setting.ts';
import { useUserStore } from '@/stores/user.ts';
import { useAccountsStore } from '@/stores/account.ts';
import { useTransactionCategoriesStore } from '@/stores/transactionCategory.ts';
import { useTransactionTagsStore } from '@/stores/transactionTag.ts';
import { useTransactionsStore } from '@/stores/transaction.ts';
import { useExchangeRatesStore } from '@/stores/exchangeRates.ts';

import type { BigDecimal, NumeralSystem } from '@/core/numeral.ts';
import type { WeekDayValue } from '@/core/datetime.ts';
import type { LocalizedTimezoneInfo } from '@/core/timezone.ts';
import type { LocalizedCurrencyInfo } from '@/core/currency.ts';
import { getEffectiveCurrencyCodes } from '@/core/currency.ts';
import { AccountCategory } from '@/core/account.ts';
import { ImageUploadQualityType } from '@/core/image.ts';
import { TransactionType, TransactionQuickAddButtonActionType } from '@/core/transaction.ts';
import { TemplateType } from '@/core/template.ts';
import { DISPLAY_HIDDEN_AMOUNT } from '@/consts/numeral.ts';
import { TRANSACTION_MAX_PICTURE_COUNT, TRANSACTION_MAX_COMMENT_LENGTH, TRANSACTION_COMMENT_HINT_MIN_LENGTH } from '@/consts/transaction.ts';

import { Account, type CategorizedAccountWithDisplayBalance } from '@/models/account.ts';
import type { TransactionCategory } from '@/models/transaction_category.ts';
import type { TransactionTag } from '@/models/transaction_tag.ts';
import type { TransactionPictureInfoBasicResponse } from '@/models/transaction_picture_info.ts';
import { Transaction } from '@/models/transaction.ts';
import { TransactionTemplate } from '@/models/transaction_template.ts';
import type { RecognizedTransactionResponse } from '@/models/large_language_model.ts';

import {
    isArray,
    isDefined
} from '@/lib/common.ts';

import {
    parseBigDecimal,
    getExchangedAmountByRate,
    getAmountWithDecimalNumberCount
} from '@/lib/numeral.ts';
import { getCurrencyFraction } from '@/lib/currency.ts';

import {
    getUtcOffsetByUtcOffsetMinutes,
    getTimezoneOffsetMinutes,
    getSameDateTimeWithCurrentTimezone,
    parseDateTimeFromUnixTimeWithBrowserTimezone,
    getDayFirstDateTimeBySpecifiedUnixTime,
    getCurrentUnixTime
} from '@/lib/datetime.ts';

import {
    type SetTransactionOptions,
    setTransactionModelByTransaction
} from '@/lib/transaction.ts';

export enum TransactionEditPageType {
    Transaction = 'transaction',
    Template = 'template'
}

export enum TransactionEditPageMode {
    Add = 'add',
    Edit = 'edit',
    View = 'view'
}

export enum GeoLocationStatus {
    Getting = 'getting',
    Success = 'success',
    Error = 'error'
}

export enum AfterSaveAction {
    GoBack = 'goBack',
    StayWithNewTransaction = 'stayWithNewTransaction',
    StayWithCurrentTransaction = 'stayWithCurrentTransaction'
}

export function useTransactionEditPageBase(type: TransactionEditPageType, initMode?: TransactionEditPageMode, transactionDefaultType?: number) {
    const {
        tt,
        getAllTimezones,
        getAllCurrencies,
        getCurrentNumeralSystemType,
        getTimezoneDifferenceDisplayText,
        formatAmountToLocalizedNumeralsWithCurrency,
        formatNumberToLocalizedNumerals,
        getCategorizedAccountsWithDisplayBalance
    } = useI18n();

    const settingsStore = useSettingsStore();
    const userStore = useUserStore();
    const accountsStore = useAccountsStore();
    const transactionCategoriesStore = useTransactionCategoriesStore();
    const transactionTagsStore = useTransactionTagsStore();
    const transactionsStore = useTransactionsStore();
    const exchangeRatesStore = useExchangeRatesStore();

    const isSupportGeoLocation: boolean = !!navigator.geolocation;

    const mode = ref<TransactionEditPageMode>(initMode ?? TransactionEditPageMode.Add);
    const editId = ref<string | null>(null);
    const addByTemplateId = ref<string | null>(null);
    const duplicateFromId = ref<string | null>(null);

    const clientSessionId = ref<string>('');
    const loading = ref<boolean>(true);
    const recognizing = ref<boolean>(false);
    const submitting = ref<boolean>(false);
    const submitted = ref<boolean>(false);
    const uploadingPicture = ref<boolean>(false);
    const geoLocationStatus = ref<GeoLocationStatus | null>(null);
    const setGeoLocationByClickMap = ref<boolean>(false);

    const transaction = ref<Transaction | TransactionTemplate>(createNewTransactionModel(transactionDefaultType));

    const numeralSystem = computed<NumeralSystem>(() => getCurrentNumeralSystemType());
    const currentTimezoneOffsetMinutes = computed<number>(() => getTimezoneOffsetMinutes(transaction.value.time));
    const showAccountBalance = computed<boolean>(() => settingsStore.appSettings.showAccountBalance);
    const customAccountCategoryOrder = computed<string>(() => settingsStore.appSettings.accountCategoryOrders);
    const defaultCurrency = computed<string>(() => userStore.currentUserDefaultCurrency);
    const defaultAccountId = computed<string>(() => userStore.currentUserDefaultAccountId);
    const firstDayOfWeek = computed<WeekDayValue>(() => userStore.currentUserFirstDayOfWeek);
    const coordinateDisplayType = computed<number>(() => userStore.currentUserCoordinateDisplayType);
    const imageUploadQualityType = computed<ImageUploadQualityType>(() => ImageUploadQualityType.valueOf(settingsStore.appSettings.transactionPictureQuality) ?? ImageUploadQualityType.Default);

    const allTimezones = computed<LocalizedTimezoneInfo[]>(() => {
        if (type === TransactionEditPageType.Template && transaction.value instanceof TransactionTemplate) {
            return getAllTimezones(getCurrentUnixTime(), true);
        } else {
            return getAllTimezones(transaction.value.time, true)
        }
    });
    const allAccounts = computed<Account[]>(() => accountsStore.allPlainAccounts);
    const allVisibleAccounts = computed<Account[]>(() => accountsStore.allVisiblePlainAccounts);
    const allAccountsMap = computed<Record<string, Account>>(() => accountsStore.allAccountsMap);
    const effectiveCurrencies = computed<LocalizedCurrencyInfo[]>(() => {
        const effectiveCurrencyCodes = getEffectiveCurrencyCodes(
            settingsStore.appSettings.enabledCurrencies,
            defaultCurrency.value,
            allAccounts.value.map(account => account.currency)
        );

        if (transaction.value instanceof Transaction && transaction.value.originalCurrency) {
            effectiveCurrencyCodes.add(transaction.value.originalCurrency);
        }

        return getAllCurrencies().filter(currency => effectiveCurrencyCodes.has(currency.currencyCode));
    });
    const selectableAccountCurrencies = computed<LocalizedCurrencyInfo[]>(() => {
        const accountCurrencies = new Set(allVisibleAccounts.value.map(account => account.currency));
        return effectiveCurrencies.value.filter(currency => accountCurrencies.has(currency.currencyCode));
    });
    const allVisibleCategorizedAccounts = computed<CategorizedAccountWithDisplayBalance[]>(() => getCategorizedAccountsWithDisplayBalance(allVisibleAccounts.value, showAccountBalance.value, customAccountCategoryOrder.value));
    const allCategories = computed<Record<number, TransactionCategory[]>>(() => transactionCategoriesStore.allTransactionCategories);
    const allCategoriesMap = computed<Record<string, TransactionCategory>>(() => transactionCategoriesStore.allTransactionCategoriesMap);
    const allTagsMap = computed<Record<string, TransactionTag>>(() => transactionTagsStore.allTransactionTagsMap);
    const firstVisibleAccountId = computed<string | undefined>(() => allVisibleAccounts.value && allVisibleAccounts.value[0] ? allVisibleAccounts.value[0].id : undefined);

    const hasVisibleExpenseCategories = computed<boolean>(() => transactionCategoriesStore.hasVisibleExpenseCategories);
    const hasVisibleIncomeCategories = computed<boolean>(() => transactionCategoriesStore.hasVisibleIncomeCategories);
    const hasVisibleTransferCategories = computed<boolean>(() => transactionCategoriesStore.hasVisibleTransferCategories);

    const canAddTransactionPicture = computed<boolean>(() => {
        if (type !== TransactionEditPageType.Transaction || (mode.value !== TransactionEditPageMode.Add && mode.value !== TransactionEditPageMode.Edit)) {
            return false;
        }

        return !isArray(transaction.value.pictures) || transaction.value.pictures.length < TRANSACTION_MAX_PICTURE_COUNT;
    });

    const title = computed<string>(() => {
        if (type === TransactionEditPageType.Transaction) {
            if (mode.value === TransactionEditPageMode.Add) {
                return 'Add Transaction';
            } else if (mode.value === TransactionEditPageMode.Edit) {
                return 'Edit Transaction';
            } else {
                return 'Transaction Detail';
            }
        } else if (type === TransactionEditPageType.Template && (transaction.value as TransactionTemplate).templateType === TemplateType.Normal.type) {
            if (mode.value === TransactionEditPageMode.Add) {
                return 'Add Transaction Template';
            } else if (mode.value === TransactionEditPageMode.Edit) {
                return 'Edit Transaction Template';
            }
        } else if (type === TransactionEditPageType.Template && (transaction.value as TransactionTemplate).templateType === TemplateType.Schedule.type) {
            if (mode.value === TransactionEditPageMode.Add) {
                return 'Add Scheduled Transaction';
            } else if (mode.value === TransactionEditPageMode.Edit) {
                return 'Edit Scheduled Transaction';
            }
        }

        return '';
    });

    const saveButtonTitle = computed<string>(() => {
        if (mode.value === TransactionEditPageMode.Add) {
            return 'Add';
        } else {
            return 'Save';
        }
    });

    const quickSaveButtonTitle = computed<string>(() => {
        if (mode.value === TransactionEditPageMode.Add) {
            const quickAddActionType = TransactionQuickAddButtonActionType.valueOf(settingsStore.appSettings.quickAddButtonActionInMobileTransactionEditPage);

            if (quickAddActionType && quickAddActionType.type !== TransactionQuickAddButtonActionType.OpenMenu.type) {
                return quickAddActionType.name;
            } else {
                return 'Add';
            }
        } else {
            return 'Save';
        }
    });

    const cancelButtonTitle = computed<string>(() => {
        if (mode.value === TransactionEditPageMode.View) {
            return 'Close';
        } else {
            return 'Cancel';
        }
    });

    const sourceAmountName = computed<string>(() => {
        if (transaction.value.type === TransactionType.Expense) {
            return 'Expense Amount';
        } else if (transaction.value.type === TransactionType.Income) {
            return 'Income Amount';
        } else if (transaction.value.type === TransactionType.Transfer) {
            return 'Transfer Out Amount';
        } else {
            return 'Amount';
        }
    });

    const sourceAmountTitle = computed<string>(() => {
        if (transaction.value instanceof Transaction && transaction.value.originalCurrency) {
            return tt('Account Amount');
        }

        const sourceAccount = allAccountsMap.value[transaction.value.sourceAccountId];
        const amountName = tt(sourceAmountName.value);

        if (!sourceAccount || sourceAccount.currency === defaultCurrency.value || !transaction.value.sourceAmount || transaction.value.hideAmount) {
            return amountName;
        }

        const fromExchangeRate = exchangeRatesStore.latestExchangeRateMap[sourceAccount.currency];
        const toExchangeRate = exchangeRatesStore.latestExchangeRateMap[defaultCurrency.value];

        if (!fromExchangeRate || !fromExchangeRate.rate || !toExchangeRate || !toExchangeRate.rate) {
            return amountName;
        }

        let amountInDefaultCurrency = getExchangedAmountByRate(parseBigDecimal(transaction.value.sourceAmount), fromExchangeRate.rate, toExchangeRate.rate);

        if (!amountInDefaultCurrency) {
            return amountName;
        }

        amountInDefaultCurrency = amountInDefaultCurrency.truncate();

        const displayAmountInDefaultCurrency = getDisplayAmount(amountInDefaultCurrency, transaction.value.hideAmount, defaultCurrency.value);
        return amountName + ` (${displayAmountInDefaultCurrency})`;
    });

    const sourceAccountTitle = computed<string>(() => {
        if (transaction.value.type === TransactionType.Expense || transaction.value.type === TransactionType.Income) {
            return 'Account';
        } else if (transaction.value.type === TransactionType.Transfer) {
            return 'Source Account';
        } else {
            return 'Account';
        }
    });

    const sourceAccountName = computed<string>(() => {
        if (transaction.value.sourceAccountId) {
            return Account.findAccountNameById(allAccounts.value, transaction.value.sourceAccountId) || '';
        } else {
            return tt('None');
        }
    });

    const destinationAccountName = computed<string>(() => {
        if (transaction.value.destinationAccountId) {
            return Account.findAccountNameById(allAccounts.value, transaction.value.destinationAccountId) || '';
        } else {
            return tt('None');
        }
    });

    const sourceAccountCurrency = computed<string>(() => {
        const sourceAccount = allAccountsMap.value[transaction.value.sourceAccountId];

        if (sourceAccount) {
            return sourceAccount.currency;
        }

        return defaultCurrency.value;
    });

    const isMultiCurrencyCreditCardTransaction = computed<boolean>(() => {
        const sourceAccount = allAccountsMap.value[transaction.value.sourceAccountId];
        return type === TransactionEditPageType.Transaction &&
            transaction.value instanceof Transaction &&
            (transaction.value.type === TransactionType.Expense || transaction.value.type === TransactionType.Income) &&
            !!sourceAccount && sourceAccount.category === AccountCategory.CreditCard.type;
    });

    const sourceAccountCurrencySelection = computed<string>({
        get: () => sourceAccountCurrency.value,
        set: (currency: string) => {
            const sourceAccount = allAccountsMap.value[transaction.value.sourceAccountId];
            const compatibleAccounts = allVisibleAccounts.value.filter(account => account.currency === currency);

            if (!compatibleAccounts.length) {
                return;
            }

            const selectedAccount = compatibleAccounts.find(account => sourceAccount && account.category === sourceAccount.category) ??
                compatibleAccounts.find(account => account.id === defaultAccountId.value) ?? compatibleAccounts[0];
            transaction.value.sourceAccountId = selectedAccount!.id;
        }
    });

    const transactionDisplayTimezone = computed<string>(() => {
        const utcOffset = numeralSystem.value.replaceWesternArabicDigitsToLocalizedDigits(getUtcOffsetByUtcOffsetMinutes(transaction.value.utcOffset));
        return `UTC${utcOffset}`;
    });

    const transactionTimezoneTimeDifference = computed<string>(() => {
        return getTimezoneDifferenceDisplayText(transaction.value.time, transaction.value.utcOffset);
    });

    const geoLocationStatusInfo = computed<string>(() => {
        if (geoLocationStatus.value === GeoLocationStatus.Success) {
            return '';
        } else if (geoLocationStatus.value === GeoLocationStatus.Getting) {
            return tt('Getting Location...');
        } else {
            return tt('No Location');
        }
    });

    const transactionDescriptionTitle = computed<string>(() => {
        if (!transaction.value.comment || transaction.value.comment.length < TRANSACTION_COMMENT_HINT_MIN_LENGTH) {
            return tt('Description');
        }

        if (transaction.value.comment.length > TRANSACTION_MAX_COMMENT_LENGTH) {
            return tt('Description') + ` (${tt('format.misc.charactersOverLimit', {
                count: formatNumberToLocalizedNumerals(transaction.value.comment.length - TRANSACTION_MAX_COMMENT_LENGTH)
            })})`;
        } else {
            return tt('Description') + ` (${tt('format.misc.charactersRemaining', {
                count: formatNumberToLocalizedNumerals(TRANSACTION_MAX_COMMENT_LENGTH - transaction.value.comment.length)
            })})`;
        }
    });

    const inputEmptyProblemMessage = computed<string | null>(() => {
        if (transaction.value.type === TransactionType.Expense) {
            if (!transaction.value.expenseCategoryId || transaction.value.expenseCategoryId === '') {
                return 'Transaction category cannot be blank';
            }

            if (!transaction.value.sourceAccountId || transaction.value.sourceAccountId === '') {
                return 'Transaction account cannot be blank';
            }
        } else if (transaction.value.type === TransactionType.Income) {
            if (!transaction.value.incomeCategoryId || transaction.value.incomeCategoryId === '') {
                return 'Transaction category cannot be blank';
            }

            if (!transaction.value.sourceAccountId || transaction.value.sourceAccountId === '') {
                return 'Transaction account cannot be blank';
            }
        } else if (transaction.value.type === TransactionType.Transfer) {
            if (!transaction.value.transferCategoryId || transaction.value.transferCategoryId === '') {
                return 'Transaction category cannot be blank';
            }

            if (!transaction.value.sourceAccountId || transaction.value.sourceAccountId === '') {
                return 'Source account cannot be blank';
            }

            if (!transaction.value.destinationAccountId || transaction.value.destinationAccountId === '') {
                return 'Destination account cannot be blank';
            }
        }

        if (type === TransactionEditPageType.Template && transaction.value instanceof TransactionTemplate) {
            if (!transaction.value.name) {
                return 'Template name cannot be blank';
            }
        }

        return null;
    });

    const inputIsEmpty = computed<boolean>(() => {
        return !!inputEmptyProblemMessage.value;
    });

    function getCurrentUnixTimeForNewTransaction(): number {
        return getSameDateTimeWithCurrentTimezone(parseDateTimeFromUnixTimeWithBrowserTimezone(getCurrentUnixTime())).getUnixTime();
    }

    function createNewTransactionModel(transactionType?: number): Transaction | TransactionTemplate {
        const now: number = getCurrentUnixTimeForNewTransaction();
        const currentTimezone: string = settingsStore.appSettings.timeZone;

        let defaultType: TransactionType = TransactionType.Expense;

        if (transactionType === TransactionType.Income) {
            defaultType = TransactionType.Income;
        } else if (transactionType === TransactionType.Transfer) {
            defaultType = TransactionType.Transfer;
        }

        let newTransaction: Transaction | TransactionTemplate = Transaction.createNewTransaction(defaultType, now, currentTimezone, getTimezoneOffsetMinutes(now, currentTimezone));

        if (type === TransactionEditPageType.Template) {
            newTransaction = TransactionTemplate.createNewTransactionTemplate(newTransaction);
        }

        return newTransaction;
    }

    function setTransactionModel(newTransaction: Transaction | null, options: SetTransactionOptions | undefined, setContextData: boolean): void {
        setTransactionModelByTransaction(
            transaction.value,
            newTransaction,
            allCategories.value,
            allCategoriesMap.value,
            allVisibleAccounts.value,
            allAccountsMap.value,
            allTagsMap.value,
            defaultAccountId.value,
            {
                time: options?.time,
                type: options?.type,
                categoryId: options?.categoryId,
                accountId: options?.accountId,
                destinationAccountId: options?.destinationAccountId,
                amount: options?.amount,
                destinationAmount: options?.destinationAmount,
                tagIds: options?.tagIds,
                comment: options?.comment
            },
            setContextData
        );
    }

    function updateTransactionModelFromRecognizedResponse(response: RecognizedTransactionResponse): void {
        const options: SetTransactionOptions = {
            type: response.type,
            time: response.time,
            categoryId: response.categoryId,
            accountId: response.sourceAccountId,
            destinationAccountId: response.destinationAccountId,
            amount: response.sourceAmount,
            destinationAmount: response.destinationAmount,
            tagIds: response.tagIds ? response.tagIds.join(',') : undefined,
            comment: response.comment
        };

        setTransactionModel(null, options, true);
    }

    function updateTransactionModelByAfterSaveAction(afterSaveAction: AfterSaveAction, initOptions?: SetTransactionOptions): void {
        if (afterSaveAction === AfterSaveAction.StayWithNewTransaction) {
            transaction.value = createNewTransactionModel(transactionDefaultType);
            setTransactionModel(null, initOptions, true);
            geoLocationStatus.value = null;
        } else if (afterSaveAction === AfterSaveAction.StayWithCurrentTransaction) {
            transaction.value.clearPictures();
        }
    }

    function updateTransactionTime(newTime: number): void {
        transaction.value.time = newTime;
        updateTransactionTimezone(transaction.value.timeZone ?? '');
    }

    function updateTransactionTimezone(timezoneName: string | null): void {
        const oldUtcOffset = transaction.value.utcOffset;

        if (!timezoneName) {
            timezoneName = ''
        }

        for (const timezone of allTimezones.value) {
            if (timezone.name === timezoneName) {
                transaction.value.timeZone = timezone.name;
                transaction.value.utcOffset = timezone.utcOffsetMinutes;
                break;
            }
        }

        transaction.value.time = transaction.value.time - (transaction.value.utcOffset - oldUtcOffset) * 60;
    }

    function swapTransactionData(): void {
        const oldSourceAccountId = transaction.value.sourceAccountId;
        transaction.value.sourceAccountId = transaction.value.destinationAccountId;
        transaction.value.destinationAccountId = oldSourceAccountId;
    }

    function getDisplayAmount(amount: BigDecimal, hideAmount: boolean, currencyCode: string): string {
        if (hideAmount) {
            return formatAmountToLocalizedNumeralsWithCurrency(DISPLAY_HIDDEN_AMOUNT, currencyCode);
        }

        return formatAmountToLocalizedNumeralsWithCurrency(amount, currencyCode);
    }

    function getTransactionPictureUrl(pictureInfo?: TransactionPictureInfoBasicResponse | null): string | undefined {
        return transactionsStore.getTransactionPictureUrl(pictureInfo);
    }

    let originalAmountConversionSequence = 0;

    async function updateAccountAmountFromOriginalAmount(): Promise<void> {
        const currentSequence = ++originalAmountConversionSequence;

        if (!isMultiCurrencyCreditCardTransaction.value || !(transaction.value instanceof Transaction)) {
            transaction.value.originalCurrency = '';
            transaction.value.originalAmount = 0;
            return;
        }

        const accountCurrency = sourceAccountCurrency.value;

        if (!transaction.value.originalCurrency || transaction.value.originalCurrency === accountCurrency) {
            transaction.value.originalCurrency = '';
            transaction.value.originalAmount = 0;
            return;
        }

        const amount = parseBigDecimal(transaction.value.originalAmount);
        const transactionDate = getDayFirstDateTimeBySpecifiedUnixTime(transaction.value.time, transaction.value.utcOffset).getGregorianCalendarYearDashMonthDashDay();
        const exchangeRatesData = await exchangeRatesStore.getHistoricalExchangeRates(transactionDate);

        if (currentSequence !== originalAmountConversionSequence || !exchangeRatesData) {
            return;
        }

        const convertedAmount = exchangeRatesStore.getExchangedAmountFromData(
            exchangeRatesData,
            amount,
            transaction.value.originalCurrency,
            accountCurrency
        );

        if (convertedAmount) {
            transaction.value.sourceAmount = convertedAmount.truncate().toSafeIntegerNumber();
        }
    }

    watch(() => transaction.value.sourceAmount, (newValue) => {
        if (mode.value === TransactionEditPageMode.View || loading.value) {
            return;
        }

        if (transaction.value.type !== TransactionType.Transfer) {
            transactionsStore.setTransactionSuitableDestinationAmount(transaction.value, newValue, newValue);
        }
    });

    watch(() => transaction.value.destinationAmount, (newValue) => {
        if (mode.value === TransactionEditPageMode.View || loading.value) {
            return;
        }

        if (transaction.value.type === TransactionType.Expense || transaction.value.type === TransactionType.Income) {
            transaction.value.sourceAmount = newValue;
        }
    });

    watch(() => [
        transaction.value instanceof Transaction ? transaction.value.originalCurrency : '',
        transaction.value instanceof Transaction ? transaction.value.originalAmount : 0,
        transaction.value.sourceAccountId,
        transaction.value.time
    ], () => {
        if (mode.value === TransactionEditPageMode.View || loading.value) {
            return;
        }

        updateAccountAmountFromOriginalAmount().catch(() => {});
    });

    let transferConversionSequence = 0;
    async function updateTransferDestinationAmount(): Promise<boolean> {
        const sequence = ++transferConversionSequence;
        const sourceAccount = allAccountsMap.value[transaction.value.sourceAccountId];
        const destinationAccount = allAccountsMap.value[transaction.value.destinationAccountId];
        if (!sourceAccount || !destinationAccount) {
            return false;
        }
        if (sourceAccount.currency === destinationAccount.currency) {
            transaction.value.destinationAmount = transaction.value.sourceAmount;
            return true;
        }
        transaction.value.destinationAmount = 0;
        const time = transaction.value.time || getCurrentUnixTime();
        const date = getDayFirstDateTimeBySpecifiedUnixTime(time, transaction.value.utcOffset).getGregorianCalendarYearDashMonthDashDay();
        let rates;
        try {
            rates = await exchangeRatesStore.getHistoricalExchangeRates(date);
        } catch {
            rates = null;
        }
        const today = getDayFirstDateTimeBySpecifiedUnixTime(getCurrentUnixTime(), transaction.value.utcOffset).getGregorianCalendarYearDashMonthDashDay();
        if (!rates && date === today) {
            rates = exchangeRatesStore.latestExchangeRates?.data;
        }
        if (sequence !== transferConversionSequence || !rates) {
            return false;
        }
        const converted = exchangeRatesStore.getExchangedAmountFromData(rates, parseBigDecimal(transaction.value.sourceAmount), sourceAccount.currency, destinationAccount.currency);
        const fraction = getCurrencyFraction(destinationAccount.currency);
        if (converted && isDefined(fraction)) {
            transaction.value.destinationAmount = getAmountWithDecimalNumberCount(converted.truncate(), fraction).toSafeIntegerNumber();
            return true;
        }
        return false;
    }

    async function prepareTransferDestinationAmount(): Promise<boolean> {
        if (transaction.value.type !== TransactionType.Transfer) {
            return true;
        }
        try {
            return await updateTransferDestinationAmount();
        } catch {
            return false;
        }
    }

    watch(() => [transaction.value.type, transaction.value.sourceAmount, transaction.value.sourceAccountId, transaction.value.destinationAccountId, transaction.value.time], () => {
        if (mode.value === TransactionEditPageMode.View || loading.value) {
            return;
        }
        if (transaction.value.type !== TransactionType.Transfer) {
            return;
        }
        updateTransferDestinationAmount().catch(() => {
            transaction.value.destinationAmount = 0;
        });
    });

    return {
        // constants
        isSupportGeoLocation,
        // states
        mode,
        editId,
        addByTemplateId,
        duplicateFromId,
        clientSessionId,
        loading,
        recognizing,
        submitting,
        submitted,
        uploadingPicture,
        geoLocationStatus,
        setGeoLocationByClickMap,
        transaction,
        // computed states
        numeralSystem,
        currentTimezoneOffsetMinutes,
        showAccountBalance,
        defaultCurrency,
        defaultAccountId,
        firstDayOfWeek,
        coordinateDisplayType,
        imageUploadQualityType,
        allTimezones,
        allAccounts,
        allVisibleAccounts,
        allAccountsMap,
        effectiveCurrencies,
        selectableAccountCurrencies,
        allVisibleCategorizedAccounts,
        allCategories,
        allCategoriesMap,
        allTagsMap,
        firstVisibleAccountId,
        hasVisibleExpenseCategories,
        hasVisibleIncomeCategories,
        hasVisibleTransferCategories,
        canAddTransactionPicture,
        title,
        saveButtonTitle,
        quickSaveButtonTitle,
        cancelButtonTitle,
        sourceAmountName,
        sourceAmountTitle,
        sourceAccountTitle,
        sourceAccountName,
        destinationAccountName,
        sourceAccountCurrency,
        isMultiCurrencyCreditCardTransaction,
        sourceAccountCurrencySelection,
        transactionDisplayTimezone,
        transactionTimezoneTimeDifference,
        geoLocationStatusInfo,
        transactionDescriptionTitle,
        inputEmptyProblemMessage,
        inputIsEmpty,
        // functions
        prepareTransferDestinationAmount,
        createNewTransactionModel,
        setTransactionModel,
        updateTransactionModelFromRecognizedResponse,
        updateTransactionModelByAfterSaveAction,
        updateTransactionTime,
        updateTransactionTimezone,
        swapTransactionData,
        getDisplayAmount,
        getTransactionPictureUrl
    }
}
