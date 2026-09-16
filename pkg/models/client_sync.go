package models

import "encoding/json"

// SyncLedgerState is also the per-user database write lock. Its cursor is advanced
// while that lock is held, so no reader can skip a transaction that commits later.
type SyncLedgerState struct {
	Uid         int64 `xorm:"PK"`
	Generation  int64 `xorm:"NOT NULL"`
	Cursor      int64 `xorm:"NOT NULL"`
	Guard       int64 `xorm:"NOT NULL"`
	Initialized bool  `xorm:"NOT NULL"`
}

// SyncRecord retains the latest public projection, including deletion markers.
type SyncRecord struct {
	Uid      int64  `xorm:"PK"`
	Entity   string `xorm:"PK VARCHAR(16)"`
	EntityId int64  `xorm:"PK"`
	Version  int64  `xorm:"NOT NULL"`
	Deleted  bool   `xorm:"NOT NULL"`
	Data     string `xorm:"TEXT"`
}

// SyncChange retains immutable changes; it is never truncated by ledger clearing.
type SyncChange struct {
	Uid      int64  `xorm:"PK"`
	Cursor   int64  `xorm:"PK"`
	Entity   string `xorm:"VARCHAR(16) NOT NULL"`
	EntityId int64  `xorm:"NOT NULL"`
	Version  int64  `xorm:"NOT NULL"`
	Deleted  bool   `xorm:"NOT NULL"`
	Data     string `xorm:"TEXT"`
}

// SyncOperationReceipt is committed with the business write. OperationKey is the
// SHA-256 of deviceId and operationId, keeping compound indexes portable.
type SyncOperationReceipt struct {
	Uid          int64  `xorm:"PK"`
	OperationKey string `xorm:"PK VARCHAR(64)"`
	RequestHash  string `xorm:"VARCHAR(64) NOT NULL"`
	Response     string `xorm:"TEXT NOT NULL"`
}

type SyncPushRequest struct {
	DeviceId      string          `json:"deviceId" binding:"required,min=16,max=128"`
	OperationId   string          `json:"operationId" binding:"required,min=16,max=128"`
	Generation    int64           `json:"generation,string" binding:"required,min=1"`
	BaseVersion   int64           `json:"baseVersion,string" binding:"min=0"`
	Action        string          `json:"action" binding:"required,oneof=create modify delete"`
	TransactionId int64           `json:"transactionId,string"`
	Data          json.RawMessage `json:"data"`
}

type SyncErrorResponse struct {
	Code    int32  `json:"code"`
	Message string `json:"message"`
}

type SyncPushResponse struct {
	Status      string             `json:"status"`
	Generation  int64              `json:"generation,string"`
	Version     int64              `json:"version,string"`
	Transaction json.RawMessage    `json:"transaction,omitempty"`
	Accounts    []json.RawMessage  `json:"accounts,omitempty"`
	Error       *SyncErrorResponse `json:"error,omitempty"`
	Reason      string             `json:"reason,omitempty"`
}

// NativeOAuthSession holds only hashed app credentials and a short-lived callback token.
type NativeOAuthSession struct {
	SessionId       string `xorm:"PK VARCHAR(128)"`
	CodeChallenge   string `xorm:"VARCHAR(64) NOT NULL"`
	OAuthRemark     string `xorm:"VARCHAR(512)"`
	CodeHash        string `xorm:"VARCHAR(64) INDEX(IDX_native_oauth_code_hash)"`
	Result          string `xorm:"TEXT"`
	ExpiresUnixTime int64  `xorm:"NOT NULL"`
	Consumed        bool   `xorm:"NOT NULL"`
}

type SyncPictureReceipt struct {
	Uid         int64  `xorm:"PK"`
	UploadId    string `xorm:"PK VARCHAR(128)"`
	ContentHash string `xorm:"VARCHAR(64) NOT NULL"`
	PictureId   int64  `xorm:"NOT NULL"`
}
