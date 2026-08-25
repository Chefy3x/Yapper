//! Portable playback pipeline — Rust ports of the Swift services in
//! `Yapper/Services/`. Behavior must stay identical to the macOS app; the
//! golden tests in each module pin the shared contract, so a change on either
//! side that alters observable behavior should fail tests on both.

pub mod elevenlabs;
pub mod openai;
pub mod player;
pub mod segmentation;
pub mod synthesizer;
pub mod text_cleaner;
pub mod timeline;
