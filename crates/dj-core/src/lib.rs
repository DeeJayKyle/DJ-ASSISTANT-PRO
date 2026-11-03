//! DJ Assistant core library.
//!
//! This crate is deliberately free of networking dependencies. It reads music
//! files (never writes them) and stores everything it learns in its own
//! SQLite catalogue.
pub mod api;
pub mod assistant;
pub mod crates;
pub mod db;
pub mod duplicates;
pub mod error;
pub mod health;
pub mod library;
pub mod metadata;
pub mod paths;
pub mod rules;
pub mod scanner;
pub mod text;

pub use api::App;
pub use error::{Error, Result};
