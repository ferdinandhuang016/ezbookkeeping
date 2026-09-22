import { isEnableDebug } from './settings.ts';

function logDebug(msg: string, obj?: unknown): void {
    if (isEnableDebug()) {
        if (obj) {
            console.debug('[Danggui Expense Debug] ' + msg, obj);
        } else {
            console.debug('[Danggui Expense Debug] ' + msg);
        }
    }
}

function logInfo(msg: string, obj?: unknown): void {
    if (obj) {
        console.info('[Danggui Expense Info] ' + msg, obj);
    } else {
        console.info('[Danggui Expense Info] ' + msg);
    }
}

function logWarn(msg: string, obj?: unknown): void {
    if (obj) {
        console.warn('[Danggui Expense Warn] ' + msg, obj);
    } else {
        console.warn('[Danggui Expense Warn] ' + msg);
    }
}

function logError(msg: string, obj?: unknown): void {
    if (obj) {
        console.error('[Danggui Expense Error] ' + msg, obj);
    } else {
        console.error('[Danggui Expense Error] ' + msg);
    }
}

export default {
    debug: logDebug,
    info: logInfo,
    warn: logWarn,
    error: logError
};
