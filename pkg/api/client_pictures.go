package api

import (
	"crypto/sha256"
	"encoding/hex"
	"io"
	"mime/multipart"

	"github.com/mayswind/ezbookkeeping/pkg/core"
	"github.com/mayswind/ezbookkeeping/pkg/datastore"
	"github.com/mayswind/ezbookkeeping/pkg/errs"
	"github.com/mayswind/ezbookkeeping/pkg/models"
)

func (a *TransactionPicturesApi) uploadPictureIdempotent(c *core.WebContext, info *models.TransactionPictureInfo, file multipart.File, uploadId string) (any, *errs.Error) {
	if !nativeOAuthSessionPattern.MatchString(uploadId) {
		return nil, errs.ErrParameterInvalid
	}
	hash := sha256.New()
	_, _ = hash.Write([]byte(info.PictureExtension + "\x00"))
	if _, err := io.Copy(hash, file); err != nil {
		return nil, errs.ErrOperationFailed
	}
	if _, err := file.Seek(0, io.SeekStart); err != nil {
		return nil, errs.ErrOperationFailed
	}
	receipt := &models.SyncPictureReceipt{Uid: info.Uid, UploadId: uploadId, ContentHash: hex.EncodeToString(hash.Sum(nil))}
	db := datastore.Container.UserDataStore.Choose(info.Uid)
	err := db.WithSyncTransaction(c, info.Uid, func(scope *datastore.SyncTransactionScope) error {
		previous, _ := c.Get(datastore.SyncSessionContextKey)
		c.Set(datastore.SyncSessionContextKey, scope)
		defer c.Set(datastore.SyncSessionContextKey, previous)
		old := &models.SyncPictureReceipt{}
		found, err := scope.Session.Where("uid=? AND upload_id=?", info.Uid, uploadId).Get(old)
		if err != nil {
			return err
		}
		if found {
			if old.ContentHash != receipt.ContentHash {
				return errs.ErrRepeatedRequest
			}
			info, err = a.pictures.GetPictureInfoByPictureId(c, info.Uid, old.PictureId)
			return err
		}
		if err = a.pictures.UploadPicture(c, info, file); err != nil {
			return err
		}
		receipt.PictureId = info.PictureId
		_, err = scope.Session.Insert(receipt)
		return err
	})
	if err != nil {
		return nil, errs.Or(err, errs.ErrOperationFailed)
	}
	return a.GetTransactionPictureInfoResponse(info), nil
}
