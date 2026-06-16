//go:build ios || android
// +build ios android

package main

import (
	"log"
)

// Mobile-specific background download manager instance
var backgroundDownloadMgr *BackgroundDownloadManager

// InitializeBackgroundDownloads initializes the background download manager
func InitializeBackgroundDownloads() bool {
	if engine == nil {
		log.Println("[Background] Download engine not initialized")
		return false
	}

	backgroundDownloadMgr = NewBackgroundDownloadManager(engine)
	log.Println("[Background] Background download manager initialized")
	return true
}

// ResumeAllBackgroundDownloads resumes all paused downloads
func ResumeAllBackgroundDownloads() bool {
	if backgroundDownloadMgr == nil {
		log.Println("[Background] Manager not initialized")
		return false
	}

	if err := backgroundDownloadMgr.ResumeBackgroundDownloads(); err != nil {
		log.Printf("[Background] Resume failed: %v", err)
		return false
	}

	return true
}

// IsDownloadActiveBackground checks if downloads are active
func IsDownloadActiveBackground() bool {
	if backgroundDownloadMgr == nil {
		return false
	}

	return backgroundDownloadMgr.IsDownloadActive()
}

// GetActiveTaskCountBackground returns count of active tasks
func GetActiveTaskCountBackground() int {
	if backgroundDownloadMgr == nil {
		return 0
	}

	return backgroundDownloadMgr.GetActiveTasksCount()
}

// PauseAllDownloadsBackground pauses all active downloads
func PauseAllDownloadsBackground() bool {
	if backgroundDownloadMgr == nil {
		log.Println("[Background] Manager not initialized")
		return false
	}

	if err := backgroundDownloadMgr.PauseAllDownloads(); err != nil {
		log.Printf("[Background] Pause failed: %v", err)
		return false
	}

	return true
}
