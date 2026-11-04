//! DJ Assistant core library.
//!
//! This crate is deliberately free of networking dependencies. It reads music
//! files and stores everything it learns in its own SQLite catalogue. The only
//! module that can change a music file is `safe_write` (opt-in, previewed,
//! backed up, verified and reversible).
#![allow(clippy::type_complexity, clippy::too_many_arguments)]
pub mod accounts;
pub mod analysis;
pub mod analysis_store;
pub mod api;
pub mod api_v1;
pub mod assistant;
pub mod crates;
pub mod db;
pub mod discovery;
pub mod docs;
pub mod duplicates;
pub mod error;
pub mod export;
pub mod gig;
pub mod gigpack;
pub mod health;
pub mod jobs;
pub mod library;
pub mod media;
pub mod metadata;
pub mod online;
pub mod paths;
pub mod profile;
pub mod quick;
pub mod rules;
pub mod safe_write;
pub mod scanner;
pub mod serato;
pub mod sets;
pub mod suggest;
pub mod templates;
pub mod text;
pub mod video;
pub mod watcher;

pub use api::App;
pub use error::{Error, Result};
