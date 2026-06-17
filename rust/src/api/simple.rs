use crate::api::classifiers::classify_intent;
use crate::api::schema::{Reminder, FolderColor};
use flutter_rust_bridge::frb;
use once_cell::sync::Lazy;
use rusqlite::{Connection, params};
use std::sync::Mutex;
use chrono::Utc;
use crate::frb_generated::StreamSink;

static DB_CONN: Lazy<Mutex<Option<Connection>>> = Lazy::new(|| Mutex::new(None));
static STREAM_SINK: Lazy<Mutex<Option<StreamSink<Vec<Reminder>>>>> = Lazy::new(|| Mutex::new(None));

#[frb(sync)]
pub fn init_db(path: String) {
    let mut conn_lock = DB_CONN.lock().unwrap();
    if conn_lock.is_none() {
        let conn = Connection::open(path).expect("Failed to open database");
        conn.execute(
            "CREATE TABLE IF NOT EXISTS reminders (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                context TEXT NOT NULL,
                folder TEXT NOT NULL,
                importance INTEGER NOT NULL,
                date_of_creation INTEGER NOT NULL
            )",
            [],
        ).expect("Failed to create table reminders");

        conn.execute(
            "CREATE TABLE IF NOT EXISTS folder_colors (
                folder TEXT PRIMARY KEY,
                color TEXT NOT NULL
            )",
            [],
        ).expect("Failed to create table folder_colors");

        // Simple migrations for new columns, ignoring errors if they already exist
        let _ = conn.execute("ALTER TABLE reminders ADD COLUMN attachment_path TEXT", []);
        let _ = conn.execute("ALTER TABLE reminders ADD COLUMN is_pinned INTEGER NOT NULL DEFAULT 0", []);
        *conn_lock = Some(conn);
    }
}

pub fn get_reminder_stream(sink: StreamSink<Vec<Reminder>>) {
    {
        let mut sink_lock = STREAM_SINK.lock().unwrap();
        *sink_lock = Some(sink);
    }
    
    // Send initial data
    if let Some(reminders) = fetch_all_reminders() {
        notify_stream(reminders);
    }
}

fn fetch_all_reminders() -> Option<Vec<Reminder>> {
    let conn_lock = DB_CONN.lock().unwrap();
    if let Some(conn) = conn_lock.as_ref() {
        let mut stmt = conn.prepare("SELECT id, context, folder, importance, date_of_creation, attachment_path, is_pinned FROM reminders ORDER BY date_of_creation DESC").unwrap();
        let reminder_iter = stmt.query_map([], |row| {
            let is_pinned_int: i64 = row.get(6).unwrap_or(0);
            Ok(Reminder {
                id: Some(row.get(0)?),
                context: row.get(1)?,
                folder: row.get(2)?,
                importance: row.get(3)?,
                date_of_creation: row.get(4)?,
                attachment_path: row.get(5)?,
                is_pinned: is_pinned_int != 0,
            })
        }).unwrap();

        let mut reminders = Vec::new();
        for r in reminder_iter {
            reminders.push(r.unwrap());
        }
        return Some(reminders);
    }
    None
}

#[frb(sync)]
pub fn get_folder_colors() -> Vec<FolderColor> {
    let conn_lock = DB_CONN.lock().unwrap();
    if let Some(conn) = conn_lock.as_ref() {
        let mut stmt = conn.prepare("SELECT folder, color FROM folder_colors").unwrap();
        let color_iter = stmt.query_map([], |row| {
            Ok(FolderColor {
                folder: row.get(0)?,
                color: row.get(1)?,
            })
        }).unwrap();

        let mut colors = Vec::new();
        for c in color_iter {
            colors.push(c.unwrap());
        }
        return colors;
    }
    Vec::new()
}

#[frb(sync)]
pub fn update_folder_color(folder: String, color: String) {
    let conn_lock = DB_CONN.lock().unwrap();
    if let Some(conn) = conn_lock.as_ref() {
        conn.execute(
            "INSERT OR REPLACE INTO folder_colors (folder, color) VALUES (?1, ?2)",
            params![folder, color],
        ).expect("Failed to update folder color");
    }
}

fn notify_stream(reminders: Vec<Reminder>) {
    let sink_lock = STREAM_SINK.lock().unwrap();
    if let Some(sink) = sink_lock.as_ref() {
        let _ = sink.add(reminders);
    }
}

#[frb(sync)]
pub fn add_reminder(context: String, importance: u32, attachment_path: Option<String>) {
    let folder = classify_intent(&context);
    let date_of_creation = Utc::now().timestamp();

    let conn_lock = DB_CONN.lock().unwrap();
    if let Some(conn) = conn_lock.as_ref() {
        conn.execute(
            "INSERT INTO reminders (context, folder, importance, date_of_creation, attachment_path) VALUES (?1, ?2, ?3, ?4, ?5)",
            params![context, folder, importance, date_of_creation, attachment_path],
        ).expect("Failed to insert reminder");
    }
    drop(conn_lock); // Release lock before notifying

    if let Some(reminders) = fetch_all_reminders() {
        notify_stream(reminders);
    }
}

#[frb(sync)]
pub fn delete_reminder(id: i64) {
    let conn_lock = DB_CONN.lock().unwrap();
    if let Some(conn) = conn_lock.as_ref() {
        conn.execute(
            "DELETE FROM reminders WHERE id = ?1",
            params![id],
        ).expect("Failed to delete reminder");
    }
    drop(conn_lock); // Release lock before notifying

    if let Some(reminders) = fetch_all_reminders() {
        notify_stream(reminders);
    }
}

#[frb(sync)]
pub fn pin_reminder(id: i64, pinned: bool) {
    let conn_lock = DB_CONN.lock().unwrap();
    if let Some(conn) = conn_lock.as_ref() {
        conn.execute(
            "UPDATE reminders SET is_pinned = ?1 WHERE id = ?2",
            params![pinned as i64, id],
        ).expect("Failed to update pin state");
    }
    drop(conn_lock); // Release lock before notifying

    if let Some(reminders) = fetch_all_reminders() {
        notify_stream(reminders);
    }
}

#[frb(sync)]
pub fn update_reminder_context(id: i64, context: String) {
    let conn_lock = DB_CONN.lock().unwrap();
    if let Some(conn) = conn_lock.as_ref() {
        conn.execute(
            "UPDATE reminders SET context = ?1 WHERE id = ?2",
            params![context, id],
        ).expect("Failed to update reminder context");
    }
    drop(conn_lock); // Release lock before notifying

    if let Some(reminders) = fetch_all_reminders() {
        notify_stream(reminders);
    }
}

#[frb(init)]
pub fn init_app() {
    flutter_rust_bridge::setup_default_user_utils();
}

#[frb(sync)]
pub fn audit_project(project_text: String) -> String {
    crate::api::critic::run_audit(project_text)
}

