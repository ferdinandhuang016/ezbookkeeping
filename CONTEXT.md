# ezBookkeeping

The shared language for recording account balances and transactions that may originate in a different currency from the account in which they are posted.

## Language

**Account Currency**:
The currency in which an account balance, credit limit, and reconciliation amount are measured.
_Avoid_: Transaction currency, display currency

**Account Amount**:
The amount posted to an account and included in its balance, expressed in the account currency.
_Avoid_: Converted amount, settlement amount

**Original Currency**:
The currency in which a transaction was originally presented before it was posted to an account.
_Avoid_: Foreign currency, source currency

**Original Amount**:
The transaction amount expressed in the original currency.
_Avoid_: Foreign amount, merchant amount

**Enabled Currency**:
A currency offered for new user selections. Disabling it does not alter existing accounts or transactions.
_Avoid_: Supported currency, active currency

**Effective Currency**:
A currency that must remain selectable because it is enabled, is the user's default, or is already used by an account.
_Avoid_: Available currency
