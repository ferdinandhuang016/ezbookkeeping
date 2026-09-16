package api

import (
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"net/url"
	"regexp"
	"time"

	"xorm.io/xorm"

	"github.com/mayswind/ezbookkeeping/pkg/core"
	"github.com/mayswind/ezbookkeeping/pkg/datastore"
	"github.com/mayswind/ezbookkeeping/pkg/errs"
	"github.com/mayswind/ezbookkeeping/pkg/models"
	"github.com/mayswind/ezbookkeeping/pkg/utils"
)

const nativeOAuthContextKey = "ezbookkeeping.nativeOAuth.session"
const nativeOAuthCallback = "net.ezbookkeeping.app://oauth2/callback"

var nativeOAuthSessionPattern = regexp.MustCompile(`^[A-Za-z0-9_-]{16,128}$`)
var nativeOAuthVerifierPattern = regexp.MustCompile(`^[A-Za-z0-9._~-]{43,128}$`)

func nativeOAuthDatabase() *datastore.Database { return datastore.Container.UserStore.Choose(0) }

func (a *OAuth2AuthenticationApi) NativeStartHandler(c *core.WebContext) (string, *errs.Error) {
	var req struct {
		ClientSessionId string `form:"client_session_id" binding:"required"`
		CodeChallenge   string `form:"code_challenge" binding:"required"`
	}
	if c.ShouldBindQuery(&req) != nil || !nativeOAuthSessionPattern.MatchString(req.ClientSessionId) {
		return "", errs.ErrParameterInvalid
	}
	challenge, err := base64.RawURLEncoding.DecodeString(req.CodeChallenge)
	if err != nil || len(challenge) != sha256.Size || len(req.CodeChallenge) != 43 {
		return "", errs.ErrParameterInvalid
	}
	session := &models.NativeOAuthSession{SessionId: req.ClientSessionId, CodeChallenge: req.CodeChallenge, ExpiresUnixTime: time.Now().Add(a.CurrentConfig().OAuth2StateExpiredTimeDuration).Unix()}
	err = nativeOAuthDatabase().DoTransaction(c, func(sess *xorm.Session) error { _, err := sess.Insert(session); return err })
	if err != nil {
		return "", errs.Or(err, errs.ErrRepeatedRequest)
	}
	c.Set(nativeOAuthContextKey, req.ClientSessionId)
	query := c.Request.URL.Query()
	query.Set("platform", "native")
	query.Del("token")
	c.Request.URL.RawQuery = query.Encode()
	return a.LoginHandler(c)
}

// NativeExchangeHandler uses the app's SHA-256 verifier so another app that
// intercepts a custom-scheme callback cannot redeem the one-time result.
func (a *OAuth2AuthenticationApi) NativeExchangeHandler(c *core.WebContext) (any, *errs.Error) {
	var req struct {
		Code         string `json:"code" binding:"required,len=43"`
		CodeVerifier string `json:"codeVerifier" binding:"required"`
	}
	if c.ShouldBindJSON(&req) != nil || !nativeOAuthVerifierPattern.MatchString(req.CodeVerifier) {
		return nil, errs.ErrParameterInvalid
	}
	hash := sha256.Sum256([]byte(req.Code))
	challenge := sha256.Sum256([]byte(req.CodeVerifier))
	codeHash := hex.EncodeToString(hash[:])
	codeChallenge := base64.RawURLEncoding.EncodeToString(challenge[:])
	var result json.RawMessage
	err := nativeOAuthDatabase().DoTransaction(c, func(sess *xorm.Session) error {
		var session models.NativeOAuthSession
		found, err := sess.Where("code_hash=? AND consumed=? AND expires_unix_time>?", codeHash, false, time.Now().Unix()).Get(&session)
		if err != nil {
			return err
		}
		if !found || session.Result == "" || subtle.ConstantTimeCompare([]byte(session.CodeChallenge), []byte(codeChallenge)) != 1 {
			return errs.ErrInvalidOAuth2Callback
		}
		result = json.RawMessage(session.Result)
		update := &models.NativeOAuthSession{Consumed: true, Result: "", OAuthRemark: ""}
		count, err := sess.Where("session_id=? AND consumed=? AND expires_unix_time>?", session.SessionId, false, time.Now().Unix()).Cols("consumed", "result", "o_auth_remark").Update(update)
		if err != nil {
			return err
		}
		if count != 1 {
			return errs.ErrInvalidOAuth2Callback
		}
		return nil
	})
	if err != nil {
		return nil, errs.Or(err, errs.ErrOperationFailed)
	}
	return result, nil
}

func (a *OAuth2AuthenticationApi) nativeRemark(c *core.WebContext, sessionId string) (bool, string) {
	var session models.NativeOAuthSession
	found, err := nativeOAuthDatabase().NewSession(c).Where("session_id=? AND consumed=? AND expires_unix_time>?", sessionId, false, time.Now().Unix()).Get(&session)
	if err != nil || !found {
		return false, ""
	}
	return true, session.OAuthRemark
}

func (a *OAuth2AuthenticationApi) saveNativeRemark(c *core.WebContext, sessionId, remark string) error {
	return nativeOAuthDatabase().DoTransaction(c, func(sess *xorm.Session) error {
		count, err := sess.Where("session_id=? AND consumed=? AND expires_unix_time>?", sessionId, false, time.Now().Unix()).Cols("o_auth_remark").Update(&models.NativeOAuthSession{OAuthRemark: remark})
		if err != nil {
			return err
		}
		if count != 1 {
			return errs.ErrInvalidOAuth2State
		}
		return nil
	})
}

func (a *OAuth2AuthenticationApi) consumeNativeRemark(c *core.WebContext, sessionId, remark string) error {
	return nativeOAuthDatabase().DoTransaction(c, func(sess *xorm.Session) error {
		count, err := sess.Where("session_id=? AND o_auth_remark=? AND consumed=? AND expires_unix_time>?", sessionId, remark, false, time.Now().Unix()).Cols("o_auth_remark").Update(&models.NativeOAuthSession{OAuthRemark: ""})
		if err != nil {
			return err
		}
		if count != 1 {
			return errs.ErrInvalidOAuth2State
		}
		return nil
	})
}

func (a *OAuth2AuthenticationApi) redirectToNativeCallback(c *core.WebContext, value any) (string, *errs.Error) {
	sessionId, _ := c.Get(nativeOAuthContextKey)
	if sessionId == nil {
		return "", errs.ErrInvalidOAuth2State
	}
	bytes := make([]byte, 32)
	if _, err := rand.Read(bytes); err != nil {
		return "", errs.ErrSystemError
	}
	code := base64.RawURLEncoding.EncodeToString(bytes)
	hash := sha256.Sum256([]byte(code))
	data, err := json.Marshal(value)
	if err != nil {
		return "", errs.ErrOperationFailed
	}
	err = nativeOAuthDatabase().DoTransaction(c, func(sess *xorm.Session) error {
		update := &models.NativeOAuthSession{CodeHash: hex.EncodeToString(hash[:]), Result: string(data), ExpiresUnixTime: time.Now().Add(2 * time.Minute).Unix()}
		count, err := sess.Where("session_id=? AND consumed=? AND expires_unix_time>? AND code_hash=?", sessionId, false, time.Now().Unix(), "").Cols("code_hash", "result", "expires_unix_time").Update(update)
		if err != nil {
			return err
		}
		if count != 1 {
			return errs.ErrInvalidOAuth2Callback
		}
		return nil
	})
	if err != nil {
		return "", errs.Or(err, errs.ErrOperationFailed)
	}
	return nativeOAuthCallback + "?code=" + url.QueryEscape(code) + "&state=" + url.QueryEscape(sessionId.(string)), nil
}

func nativeOAuthError(err *errs.Error) any {
	return map[string]any{"error": models.SyncErrorResponse{Code: err.Code(), Message: utils.GetDisplayErrorMessage(err)}}
}
