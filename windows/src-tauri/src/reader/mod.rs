//! Windows reading integration — the counterpart of macOS
//! `Yapper/Services/AccessibilityReader.swift`.
//!
//! Mirrors the Mac app's two-path design:
//!
//! **`read_selection()` — universal.** Works in any app the moment the user
//! highlights text. Two strategies, same order as the Swift original:
//!   1. UI Automation: `TextPattern.GetSelection()` on the focused element.
//!   2. Fallback: synthesize Ctrl+C via `SendInput`, poll the clipboard for a
//!      change, capture it, then restore the prior clipboard contents.
//!
//! **`read_latest()` — per-app adapters (the auto-magic).** UIA tree-walking
//! tuned per app, porting the marker strategies from the Swift reader:
//!   - Claude desktop (Electron → Chromium exposes a UIA tree): "Copy" /
//!     "Copy message" buttons after the last "Claude responded:" heading.
//!   - ChatGPT desktop: equivalent copy-button markers.
//!   - Browsers on AI sites: same tab-gating idea as `ConversationWatcher`.
//! Each adapter presses the copy control and captures the clipboard (with
//! save/restore), exactly like the Mac implementation.
//!
//! ── Status ──────────────────────────────────────────────────────────────
//! Skeleton. UIA calls require a Windows environment to develop against and
//! cannot be meaningfully written blind from macOS — element trees must be
//! inspected live (Accessibility Insights for Windows is the AX-inspector
//! equivalent). Implement on the Windows VM in Phase 3.

#![allow(dead_code)] // skeleton until the UIA implementation lands

pub struct ReadResult {
    pub text: String,
    /// Human-readable name of the app the text came from (for history).
    pub source_app: String,
}

#[derive(Debug, thiserror::Error)]
pub enum ReadError {
    #[error("no focused window")]
    NoFrontApp,
    #[error("nothing is selected")]
    NoSelection,
    #[error("this app needs a reader adapter")]
    Unsupported,
    #[error("reading isn't wired up yet — this lands in Phase 3")]
    NotImplemented,
}

/// Read the user's current selection from the focused app.
/// Port of `AccessibilityReader.readSelection()`.
///
/// Returns [`ReadError::NotImplemented`] until Phase 3 lands. It is reachable
/// from a global hotkey, so it reports rather than panics: a `todo!()` here
/// would take the whole app down the first time someone pressed the key.
pub fn read_selection() -> Result<ReadResult, ReadError> {
    Err(ReadError::NotImplemented)
}

/// Read the latest assistant message from the focused app via its adapter.
/// Port of `AccessibilityReader.readLatest()`.
pub fn read_latest() -> Result<ReadResult, ReadError> {
    Err(ReadError::NotImplemented)
}
