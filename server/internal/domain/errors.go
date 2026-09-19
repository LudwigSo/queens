package domain

import "fmt"

// Error codes. The client localises them, so the wire carries the key and its
// positional parameters, never prose: the server has no locale and must not grow
// a copy of the translation table.
//
// The first five are reused verbatim from the offline stub; the rest are new and
// need rows in queens/i18n/strings.csv (en, de).
const (
	CodeNicknameLength = "ERR_NICKNAME_LENGTH"
	CodeFriendCodeFmt  = "ERR_FRIEND_CODE_FORMAT"
	CodeFriendOwnCode  = "ERR_FRIEND_OWN_CODE"
	CodeFriendAlready  = "ERR_FRIEND_ALREADY"
	CodeFriendUnknown  = "ERR_FRIEND_UNKNOWN"

	CodeServer          = "ERR_SERVER"
	CodeUnauthorized    = "ERR_UNAUTHORIZED"
	CodeBanned          = "ERR_BANNED"
	CodeBadRequest      = "ERR_BAD_REQUEST"
	CodeRateLimited     = "ERR_RATE_LIMITED"
	CodeIDTaken         = "ERR_ID_TAKEN"
	CodeNicknameInvalid = "ERR_NICKNAME_INVALID"
	CodeLevelUnknown    = "ERR_LEVEL_UNKNOWN"
	CodeLevelLocked     = "ERR_LEVEL_LOCKED"
	CodeSessionInvalid  = "ERR_SESSION_INVALID"
	CodeSessionExpired  = "ERR_SESSION_EXPIRED"
	CodeSessionUsed     = "ERR_SESSION_USED"
	CodeSessionMismatch = "ERR_SESSION_MISMATCH"
	CodeResultInvalid   = "ERR_RESULT_INVALID"
	CodeFriendCodeUnkn  = "ERR_FRIEND_CODE_UNKNOWN"
	CodeFriendLimit     = "ERR_FRIEND_LIMIT"
)

// CodedError is what every service returns on a rejection. The API layer turns
// it into an RFC 9457 problem document; nothing else needs to know about HTTP.
type CodedError struct {
	Status int
	Code   string
	Params []any
	// Detail is English and for developers only. It never reaches a player.
	Detail string
}

func (e *CodedError) Error() string {
	if e.Detail != "" {
		return fmt.Sprintf("%s (%d): %s", e.Code, e.Status, e.Detail)
	}
	return fmt.Sprintf("%s (%d)", e.Code, e.Status)
}

// Err builds a CodedError. Params are positional and are substituted into the
// localised string on the client.
func Err(status int, code string, params ...any) *CodedError {
	if params == nil {
		params = []any{}
	}
	return &CodedError{Status: status, Code: code, Params: params}
}

// Errf adds a developer-facing detail.
func Errf(status int, code, detail string, params ...any) *CodedError {
	e := Err(status, code, params...)
	e.Detail = detail
	return e
}
