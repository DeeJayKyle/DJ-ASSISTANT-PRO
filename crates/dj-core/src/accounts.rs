//! Local accounts: several people (or several libraries) on one computer, with
//! no sign-in. Each account has its own catalogue — library folders, crates,
//! sets, settings, analysis — in its own SQLite file. Nothing leaves the
//! computer and there are no passwords.
//!
//! This module only writes inside the app's data folder: `accounts.json`
//! (written to a temporary file, then renamed) and, when an account is
//! removed, that account's catalogue files. Music files are never touched.
//!
//! Layout:
//! ```text
//! <data>/accounts.json
//! <data>/catalogue.sqlite3            the first account, if it existed before accounts
//! <data>/accounts/<id>/catalogue.sqlite3
//! ```
use crate::api::{arg, App};
use crate::db::now_ms;
use crate::error::{invalid, Error, Result};
use crate::online::{Online, Secrets};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};

/// The account that owns a catalogue created before accounts existed.
pub const LEGACY_ID: &str = "main";
const COLORS: &[&str] = &[
    "#3ee6c4", "#7aa2ff", "#ffb547", "#ff7aa8", "#b38cff", "#5cd1ff", "#9be15d", "#ff8a5c",
];

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct Account {
    pub id: String,
    pub name: String,
    pub color: String,
    pub created_at: i64,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
struct Book {
    accounts: Vec<Account>,
    last: Option<String>,
}

struct Current {
    id: String,
    app: Arc<App>,
}

/// Owns the list of accounts and the catalogue of the one in use.
pub struct Session {
    base: PathBuf,
    online: Arc<dyn Online>,
    secrets: Arc<dyn Secrets>,
    book: Mutex<Book>,
    current: Mutex<Option<Current>>,
}

fn clean_name(name: &str) -> Result<String> {
    let n: String = name.split_whitespace().collect::<Vec<_>>().join(" ");
    if n.is_empty() {
        return invalid("give the account a name");
    }
    if n.chars().count() > 40 {
        return invalid("keep the name under 40 characters");
    }
    if n.chars().any(|c| c.is_control()) {
        return invalid("the name contains characters that can't be used");
    }
    Ok(n)
}

fn lock<T>(m: &Mutex<T>) -> std::sync::MutexGuard<'_, T> {
    m.lock().unwrap_or_else(|e| e.into_inner())
}

impl Session {
    /// Opens the accounts in `base` (the app data folder). A catalogue made
    /// before accounts existed becomes the first account. The last account
    /// used is opened again; with no accounts, commands other than the
    /// account ones fail until one is created.
    pub fn open(base: &Path, online: Arc<dyn Online>, secrets: Arc<dyn Secrets>) -> Result<Self> {
        std::fs::create_dir_all(base)?;
        let s = Session {
            base: base.to_path_buf(),
            online,
            secrets,
            book: Mutex::new(Book::default()),
            current: Mutex::new(None),
        };
        let mut book = s.read_book()?;
        if book.accounts.is_empty() && base.join("catalogue.sqlite3").exists() {
            book.accounts.push(Account {
                id: LEGACY_ID.into(),
                name: "My library".into(),
                color: COLORS[0].into(),
                created_at: now_ms(),
            });
            book.last = Some(LEGACY_ID.into());
            s.write_book(&book)?;
        }
        let last = book
            .last
            .clone()
            .filter(|id| book.accounts.iter().any(|a| &a.id == id))
            .or_else(|| book.accounts.first().map(|a| a.id.clone()));
        *lock(&s.book) = book;
        if let Some(id) = last {
            s.switch(&id)?;
        }
        Ok(s)
    }

    fn book_path(&self) -> PathBuf {
        self.base.join("accounts.json")
    }

    fn read_book(&self) -> Result<Book> {
        match std::fs::read_to_string(self.book_path()) {
            Ok(t) => serde_json::from_str(&t).map_err(|e| Error::Invalid(format!("accounts.json is damaged ({e}); restore it from a backup or delete it to start again"))),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(Book::default()),
            Err(e) => Err(e.into()),
        }
    }

    fn write_book(&self, book: &Book) -> Result<()> {
        let tmp = self.base.join("accounts.json.tmp");
        std::fs::write(&tmp, serde_json::to_vec_pretty(book)?)?;
        std::fs::rename(&tmp, self.book_path())?;
        Ok(())
    }

    /// Where an account's catalogue lives.
    pub fn catalogue_path(&self, id: &str) -> PathBuf {
        if id == LEGACY_ID {
            self.base.join("catalogue.sqlite3")
        } else {
            self.base
                .join("accounts")
                .join(id)
                .join("catalogue.sqlite3")
        }
    }

    /// The catalogue in use, if an account is open.
    pub fn app(&self) -> Option<Arc<App>> {
        lock(&self.current).as_ref().map(|c| c.app.clone())
    }

    pub fn current_id(&self) -> Option<String> {
        lock(&self.current).as_ref().map(|c| c.id.clone())
    }

    pub fn accounts(&self) -> Vec<Account> {
        lock(&self.book).accounts.clone()
    }

    fn ensure_idle(&self) -> Result<()> {
        if let Some(app) = self.app() {
            if app.busy() {
                return Err(Error::Busy("a scan, analysis or copy is still running in this account; wait for it to finish or cancel it first".into()));
            }
        }
        Ok(())
    }

    pub fn switch(&self, id: &str) -> Result<Account> {
        let acct = lock(&self.book)
            .accounts
            .iter()
            .find(|a| a.id == id)
            .cloned();
        let Some(acct) = acct else {
            return Err(Error::NotFound("that account no longer exists".into()));
        };
        if self.current_id().as_deref() == Some(id) {
            return Ok(acct);
        }
        self.ensure_idle()?;
        let path = self.catalogue_path(id);
        if let Some(dir) = path.parent() {
            std::fs::create_dir_all(dir)?;
        }
        // Close the old catalogue before opening the new one.
        *lock(&self.current) = None;
        let app = App::open_with(&path, self.online.clone(), self.secrets.clone())?;
        *lock(&self.current) = Some(Current {
            id: id.to_string(),
            app: Arc::new(app),
        });
        let mut book = lock(&self.book);
        book.last = Some(id.to_string());
        let snapshot = book.clone();
        drop(book);
        self.write_book(&snapshot)?;
        Ok(acct)
    }

    pub fn create(&self, name: &str) -> Result<Account> {
        let name = clean_name(name)?;
        let acct = {
            let mut book = lock(&self.book);
            if book
                .accounts
                .iter()
                .any(|a| a.name.to_lowercase() == name.to_lowercase())
            {
                return invalid(format!("there is already an account called “{name}”"));
            }
            if book.accounts.len() >= 50 {
                return invalid("that's a lot of accounts — remove one first");
            }
            let id = crate::scanner::new_uid(&name)[..12].to_string();
            let acct = Account {
                id,
                name,
                color: COLORS[book.accounts.len() % COLORS.len()].into(),
                created_at: now_ms(),
            };
            book.accounts.push(acct.clone());
            let snapshot = book.clone();
            drop(book);
            self.write_book(&snapshot)?;
            acct
        };
        self.switch(&acct.id)?;
        Ok(acct)
    }

    pub fn rename(&self, id: &str, name: &str) -> Result<Account> {
        let name = clean_name(name)?;
        let mut book = lock(&self.book);
        if book
            .accounts
            .iter()
            .any(|a| a.id != id && a.name.to_lowercase() == name.to_lowercase())
        {
            return invalid(format!("there is already an account called “{name}”"));
        }
        let Some(a) = book.accounts.iter_mut().find(|a| a.id == id) else {
            return Err(Error::NotFound("that account no longer exists".into()));
        };
        a.name = name;
        let out = a.clone();
        let snapshot = book.clone();
        drop(book);
        self.write_book(&snapshot)?;
        Ok(out)
    }

    /// Removes an account and its catalogue (crates, sets, edits, analysis).
    /// Music files are not touched; backups made by the tag writer are kept.
    pub fn delete(&self, id: &str) -> Result<Value> {
        let accounts = self.accounts();
        if !accounts.iter().any(|a| a.id == id) {
            return Err(Error::NotFound("that account no longer exists".into()));
        }
        if accounts.len() == 1 {
            return invalid("this is the only account; create another one before removing it");
        }
        if self.current_id().as_deref() == Some(id) {
            self.ensure_idle()?;
            let other = accounts.iter().find(|a| a.id != id).unwrap().id.clone();
            self.switch(&other)?;
        }
        let path = self.catalogue_path(id);
        for suffix in ["", "-wal", "-shm"] {
            let p = PathBuf::from(format!("{}{suffix}", path.display()));
            match std::fs::remove_file(&p) {
                Ok(()) => {}
                Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
                Err(e) => return Err(e.into()),
            }
        }
        let dir = path.parent().map(|p| p.to_path_buf()).unwrap_or_default();
        let kept_backups = dir.join("backups").is_dir();
        if id != LEGACY_ID {
            // Only succeeds when nothing else (such as tag-write backups) is left.
            let _ = std::fs::remove_dir(&dir);
        }
        let mut book = lock(&self.book);
        book.accounts.retain(|a| a.id != id);
        let snapshot = book.clone();
        drop(book);
        self.write_book(&snapshot)?;
        Ok(
            json!({"deleted": true, "kept_backups": if kept_backups { Some(dir.join("backups").to_string_lossy().to_string()) } else { None }}),
        )
    }

    fn summary(&self) -> Value {
        json!({"accounts": self.accounts(), "current": self.current_id()})
    }

    /// The single entry point for the UI: account commands here, everything
    /// else goes to the open account's catalogue.
    pub fn dispatch(&self, cmd: &str, args: Value) -> Result<Value> {
        match cmd {
            "accounts" => Ok(self.summary()),
            "account_create" => {
                self.create(&arg::<String>(&args, "name")?)?;
                Ok(self.summary())
            }
            "account_switch" => {
                self.switch(&arg::<String>(&args, "id")?)?;
                Ok(self.summary())
            }
            "account_rename" => {
                self.rename(&arg::<String>(&args, "id")?, &arg::<String>(&args, "name")?)?;
                Ok(self.summary())
            }
            "account_delete" => {
                let r = self.delete(&arg::<String>(&args, "id")?)?;
                let mut s = self.summary();
                s["kept_backups"] = r["kept_backups"].clone();
                Ok(s)
            }
            _ => match self.app() {
                Some(app) => app.dispatch(cmd, args),
                None => invalid("create an account first"),
            },
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::online::{MemorySecrets, NoOnline};

    fn session(dir: &Path) -> Session {
        Session::open(dir, Arc::new(NoOnline), Arc::new(MemorySecrets::default())).unwrap()
    }

    #[test]
    fn accounts_keep_separate_catalogues() {
        let tmp = tempfile::tempdir().unwrap();
        let s = session(tmp.path());
        assert!(
            s.dispatch("stats", json!({})).is_err(),
            "nothing works before an account exists"
        );
        let a = s.create("Herbie").unwrap();
        s.dispatch("set_setting", json!({"key": "theme", "value": "light"}))
            .unwrap();
        s.dispatch(
            "create_crate",
            json!({"input": {"name": "Wedding", "kind": "manual"}}),
        )
        .unwrap();
        let b = s.create("Guest DJ").unwrap();
        assert_eq!(s.current_id().unwrap(), b.id);
        assert_eq!(
            s.dispatch("list_crates", json!({}))
                .unwrap()
                .as_array()
                .unwrap()
                .len(),
            0
        );
        assert_eq!(
            s.dispatch("get_settings", json!({})).unwrap()["theme"],
            "dark"
        );
        s.switch(&a.id).unwrap();
        assert_eq!(
            s.dispatch("list_crates", json!({}))
                .unwrap()
                .as_array()
                .unwrap()
                .len(),
            1
        );
        assert_eq!(
            s.dispatch("get_settings", json!({})).unwrap()["theme"],
            "light"
        );

        // Reopening remembers the last account used.
        drop(s);
        let s = session(tmp.path());
        assert_eq!(s.current_id().unwrap(), a.id);
        assert_eq!(s.accounts().len(), 2);
    }

    #[test]
    fn names_are_checked_and_unique() {
        let tmp = tempfile::tempdir().unwrap();
        let s = session(tmp.path());
        assert!(s.create("   ").is_err());
        assert!(s.create(&"x".repeat(41)).is_err());
        let a = s.create("  Herbie   K ").unwrap();
        assert_eq!(a.name, "Herbie K");
        assert!(s.create("herbie k").is_err());
        let b = s.create("Kyle").unwrap();
        assert!(s.rename(&b.id, "HERBIE K").is_err());
        assert_eq!(s.rename(&b.id, "Kyle B").unwrap().name, "Kyle B");
    }

    #[test]
    fn removing_an_account_removes_only_its_catalogue() {
        let tmp = tempfile::tempdir().unwrap();
        let s = session(tmp.path());
        let a = s.create("A").unwrap();
        assert!(
            s.delete(&a.id).is_err(),
            "the only account can't be removed"
        );
        let b = s.create("B").unwrap();
        let b_path = s.catalogue_path(&b.id);
        assert!(b_path.exists());
        s.delete(&b.id).unwrap();
        assert_eq!(
            s.current_id().unwrap(),
            a.id,
            "switches away from a removed account"
        );
        assert!(!b_path.exists());
        assert!(!b_path.parent().unwrap().exists());
        assert!(s.catalogue_path(&a.id).exists());
        assert_eq!(s.accounts().len(), 1);
    }

    #[test]
    fn an_existing_catalogue_becomes_the_first_account() {
        let tmp = tempfile::tempdir().unwrap();
        {
            let app = App::open(&tmp.path().join("catalogue.sqlite3")).unwrap();
            app.dispatch(
                "create_crate",
                json!({"input": {"name": "Old crate", "kind": "manual"}}),
            )
            .unwrap();
        }
        let s = session(tmp.path());
        assert_eq!(s.current_id().as_deref(), Some(LEGACY_ID));
        assert_eq!(s.accounts()[0].name, "My library");
        assert_eq!(
            s.dispatch("list_crates", json!({})).unwrap()[0]["name"],
            "Old crate"
        );
    }
}
