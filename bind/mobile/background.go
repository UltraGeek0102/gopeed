package main

import (
	"fmt"
	"log"

	"github.com/GopeedLab/gopeed/pkg/download"
)

// BackgroundDownloadManager manages background download operations for mobile platforms
type BackgroundDownloadManager struct {
	engine *download.Engine
}

// NewBackgroundDownloadManager creates a new background download manager
func NewBackgroundDownloadManager(engine *download.Engine) *BackgroundDownloadManager {
	return &BackgroundDownloadManager{
		engine: engine,
	}
}

// ResumeBackgroundDownloads resumes all paused downloads in the background
func (b *BackgroundDownloadManager) ResumeBackgroundDownloads() error {
	if b.engine == nil {
		return fmt.Errorf("download engine not initialized")
	}

	tasks := b.engine.GetTasks()
	if len(tasks) == 0 {
		log.Println("[Background] No tasks to resume")
		return nil
	}

	resumedCount := 0
	for _, task := range tasks {
		// Resume paused tasks
		if task.Status == download.StatusPaused {
			if err := b.engine.Continue(task.ID); err != nil {
				log.Printf("[Background] Failed to continue task %s: %v", task.ID, err)
				continue
			}
			resumedCount++
			log.Printf("[Background] Resumed task: %s", task.ID)
		}
	}

	log.Printf("[Background] Resumed %d downloads", resumedCount)
	return nil
}

// IsDownloadActive checks if any downloads are currently active
func (b *BackgroundDownloadManager) IsDownloadActive() bool {
	if b.engine == nil {
		return false
	}

	tasks := b.engine.GetTasks()
	for _, task := range tasks {
		if task.Status == download.StatusDownloading {
			log.Printf("[Background] Active download found: %s", task.ID)
			return true
		}
	}

	return false
}

// GetActiveTasksCount returns the count of active download tasks
func (b *BackgroundDownloadManager) GetActiveTasksCount() int {
	if b.engine == nil {
		return 0
	}

	tasks := b.engine.GetTasks()
	count := 0
	for _, task := range tasks {
		if task.Status == download.StatusDownloading || task.Status == download.StatusPaused {
			count++
		}
	}

	return count
}

// GetPausedTasksCount returns the count of paused download tasks
func (b *BackgroundDownloadManager) GetPausedTasksCount() int {
	if b.engine == nil {
		return 0
	}

	tasks := b.engine.GetTasks()
	count := 0
	for _, task := range tasks {
		if task.Status == download.StatusPaused {
			count++
		}
	}

	return count
}

// PauseAllDownloads pauses all active downloads
func (b *BackgroundDownloadManager) PauseAllDownloads() error {
	if b.engine == nil {
		return fmt.Errorf("download engine not initialized")
	}

	tasks := b.engine.GetTasks()
	pausedCount := 0

	for _, task := range tasks {
		if task.Status == download.StatusDownloading {
			if err := b.engine.Pause(task.ID); err != nil {
				log.Printf("[Background] Failed to pause task %s: %v", task.ID, err)
				continue
			}
			pausedCount++
			log.Printf("[Background] Paused task: %s", task.ID)
		}
	}

	log.Printf("[Background] Paused %d downloads", pausedCount)
	return nil
}
