#[derive(Debug, Clone)]
pub struct Reminder {
    pub id: Option<i64>,
    pub context: String,
    pub folder: String,
    pub importance: u32,
    pub date_of_creation: i64,
    pub attachment_path: Option<String>,
    pub is_pinned: bool,
}

pub struct FolderColor {
    pub folder: String,
    pub color: String,
}