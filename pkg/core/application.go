package core

import "fmt"

// ApplicationName represents the application name
const ApplicationName = "Danggui Expense"

// Version, CommitHash and BuildTime are set at build
var (
	Version    string
	CommitHash string
	BuildTime  string
)

func GetOutgoingUserAgent() string {
	if Version == "" {
		return "DangguiExpense"
	}

	return fmt.Sprintf("DangguiExpense/%s", Version)
}
