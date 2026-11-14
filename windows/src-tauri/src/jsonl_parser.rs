use anyhow::Result;
use regex::Regex;
use serde_json::Value;
use std::path::Path;
use tokio::io::{AsyncBufReadExt, BufReader};

#[derive(Debug, Clone)]
pub struct SessionMetadata {
    pub session_id: String,
    pub first_prompt: Option<String>,
    pub project_path: Option<String>,
    pub git_branch: Option<String>,
    pub message_count: usize,
}

/// Extract session metadata from a .jsonl file.
/// Returns None if the file has no messages.
pub async fn extract_metadata(file_path: &str) -> Result<Option<SessionMetadata>> {
    let path = Path::new(file_path);
    if !path.exists() {
        return Ok(None);
    }

    let session_id = path
        .file_stem()
        .and_then(|s| s.to_str())
        .unwrap_or("")
        .to_string();

    let file = tokio::fs::File::open(path).await?;
    let reader = BufReader::new(file);
    let mut lines = reader.lines();

    let mut meta = SessionMetadata {
        session_id,
        first_prompt: None,
        project_path: None,
        git_branch: None,
        message_count: 0,
    };
    let mut found_first_user = false;

    while let Some(line) = lines.next_line().await? {
        if line.is_empty() || !line.contains("\"type\"") {
            continue;
        }
        let obj: Value = match serde_json::from_str(&line) {
            Ok(v) => v,
            Err(_) => continue,
        };

        let msg_type = obj["type"].as_str().unwrap_or("");

        if meta.project_path.is_none() {
            if let Some(cwd) = obj["cwd"].as_str() {
                meta.project_path = Some(cwd.to_string());
            }
        }
        if meta.git_branch.is_none() {
            if let Some(branch) = obj["gitBranch"].as_str() {
                meta.git_branch = Some(branch.to_string());
            }
        }

        if msg_type == "user" || msg_type == "assistant" {
            meta.message_count += 1;
        }

        if msg_type == "user" && !found_first_user {
            found_first_user = true;
            meta.first_prompt = extract_text_content(&obj);
        }

        // Early exit once we have enough data
        if meta.message_count >= 5 && found_first_user {
            break;
        }
    }

    if meta.message_count == 0 {
        return Ok(None);
    }
    Ok(Some(meta))
}

fn extract_text_content(obj: &Value) -> Option<String> {
    let message = obj.get("message")?;
    let content = message.get("content")?;

    if let Some(text) = content.as_str() {
        return Some(text.to_string());
    }

    if let Some(blocks) = content.as_array() {
        let texts: Vec<&str> = blocks
            .iter()
            .filter(|b| b["type"].as_str() == Some("text"))
            .filter_map(|b| b["text"].as_str())
            .collect();
        let joined = texts.join("\n");
        if !joined.is_empty() {
            return Some(joined);
        }
    }

    None
}

/// Decode a Claude projects directory name to a filesystem path.
/// e.g., "-Users-rchaves-Projects-remote-langwatch" → "/Users/rchaves/Projects/remote/langwatch"
pub fn decode_directory_name(name: &str) -> String {
    let mut result = name.to_string();
    if result.starts_with('-') {
        result = format!("/{}", &result[1..]);
    }
    result.replace('-', "/")
}

/// Extract branches pushed from a session JSONL.
pub async fn extract_pushed_branches(
    file_path: &str,
    start_offset: Option<u64>,
) -> Result<Vec<String>> {
    let path = Path::new(file_path);
    if !path.exists() {
        return Ok(vec![]);
    }

    let push_re = Regex::new(r"git\s+push\s+(?:-\S+\s+)*(?:origin|upstream)\s+(\S+)")?;
    let checkout_re = Regex::new(r"git\s+checkout\s+-[bB]\s+(\S+)")?;
    let switch_re = Regex::new(r"git\s+switch\s+(?:-c|--create)\s+(\S+)")?;
    let worktree_re = Regex::new(r"git\s+worktree\s+add\s+\S+\s+-b\s+(\S+)")?;

    let file = tokio::fs::File::open(path).await?;
    let reader = BufReader::new(file);
    let mut lines = reader.lines();

    let mut branches = std::collections::HashSet::new();

    // If start_offset is set, skip that many bytes
    // (Simplified: we just scan all lines; incremental scanning is a nice-to-have)
    let _ = start_offset;

    while let Some(line) = lines.next_line().await? {
        if line.is_empty() || !line.contains("\"tool_use\"") {
            continue;
        }
        let obj: Value = match serde_json::from_str(&line) {
            Ok(v) => v,
            Err(_) => continue,
        };

        let content = match obj["message"]["content"].as_array() {
            Some(c) => c,
            None => continue,
        };

        for block in content {
            if block["type"].as_str() != Some("tool_use") {
                continue;
            }
            if block["name"].as_str() != Some("Bash") {
                continue;
            }
            let command = match block["input"]["command"].as_str() {
                Some(c) => c,
                None => continue,
            };

            for cap in push_re.captures_iter(command) {
                let b = &cap[1];
                if b != "main" && b != "master" && !b.starts_with('-') {
                    branches.insert(b.to_string());
                }
            }
            for cap in checkout_re.captures_iter(command) {
                let b = &cap[1];
                if b != "main" && b != "master" && !b.starts_with('-') {
                    branches.insert(b.to_string());
                }
            }
            for cap in switch_re.captures_iter(command) {
                let b = &cap[1];
                if b != "main" && b != "master" && !b.starts_with('-') {
                    branches.insert(b.to_string());
                }
            }
            for cap in worktree_re.captures_iter(command) {
                let b = &cap[1];
                if b != "main" && b != "master" && !b.starts_with('-') {
                    branches.insert(b.to_string());
                }
            }
        }
    }

    let mut result: Vec<String> = branches.into_iter().collect();
    result.sort();
    Ok(result)
}

/// How much of a transcript's tail `latest_timestamp` reads before giving up.
const LATEST_TIMESTAMP_MAX_BYTES: u64 = 2 * 1024 * 1024;

/// The newest conversation record `"timestamp"` in the transcript's tail.
///
/// Claude Code appends records without a timestamp while a session sits idle
/// (`last-prompt`, `ai-title`, `mode`, `permission-mode`, `session-owner`,
/// `atis-latch`). Those bump the file's mtime, so mtime alone makes an idle
/// session look active and moves its card. This reads backwards from the end
/// and returns the first timestamped record it finds. It returns `None` when
/// there is none within the last 2 MB, and callers fall back to mtime.
/// Port of `JsonlParser.extractLatestTimestamp` (macOS).
pub fn latest_timestamp(file_path: &str) -> Option<chrono::DateTime<chrono::Utc>> {
    use std::io::{Read, Seek, SeekFrom};

    let mut file = std::fs::File::open(file_path).ok()?;
    let len = file.metadata().ok()?.len();
    let floor = len.saturating_sub(LATEST_TIMESTAMP_MAX_BYTES);
    const CHUNK: u64 = 64 * 1024;

    let mut end = len;
    // Bytes after the last newline seen so far: the start of a line that
    // continues past the chunk we just read.
    let mut carry: Vec<u8> = Vec::new();
    while end > floor {
        let start = end.saturating_sub(CHUNK).max(floor);
        let mut buf = vec![0u8; (end - start) as usize];
        file.seek(SeekFrom::Start(start)).ok()?;
        file.read_exact(&mut buf).ok()?;
        buf.extend_from_slice(&carry);

        // Every complete line in `buf` except the first (which may be cut
        // off at `start`), newest first.
        let mut lines: Vec<&[u8]> = buf.split(|b| *b == b'\n').collect();
        let head = if start > floor { Some(lines.remove(0)) } else { None };
        for line in lines.iter().rev() {
            if let Some(ts) = timestamp_of(line) {
                return Some(ts);
            }
        }
        carry = head.map(|h| h.to_vec()).unwrap_or_default();
        end = start;
    }
    None
}

fn timestamp_of(line: &[u8]) -> Option<chrono::DateTime<chrono::Utc>> {
    let text = std::str::from_utf8(line).ok()?;
    if !text.contains("\"timestamp\"") {
        return None;
    }
    let obj: Value = serde_json::from_str(text).ok()?;
    let raw = obj.get("timestamp")?.as_str()?;
    chrono::DateTime::parse_from_rfc3339(raw)
        .ok()
        .map(|d| d.with_timezone(&chrono::Utc))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;

    fn write_temp(name: &str, body: &str) -> String {
        let dir = std::env::temp_dir().join(format!("kc-jsonl-{}-{}", name, std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("s.jsonl");
        let mut f = std::fs::File::create(&path).unwrap();
        f.write_all(body.as_bytes()).unwrap();
        path.to_string_lossy().to_string()
    }

    #[test]
    fn latest_timestamp_ignores_trailing_bookkeeping() {
        let body = [
            r#"{"type":"user","sessionId":"b1","timestamp":"2026-11-12T08:15:30.123Z","message":{"content":"Earlier prompt"}}"#,
            r#"{"type":"assistant","sessionId":"b1","timestamp":"2026-11-12T08:16:00.000Z","message":{"content":[{"type":"text","text":"Done."}]}}"#,
            r#"{"type":"last-prompt","lastPrompt":"Earlier prompt","sessionId":"b1"}"#,
            r#"{"type":"ai-title","aiTitle":"Some title","sessionId":"b1"}"#,
            r#"{"type":"mode","mode":"default","sessionId":"b1"}"#,
            r#"{"type":"permission-mode","permissionMode":"default","sessionId":"b1"}"#,
            r#"{"type":"session-owner","owner":"user","sessionId":"b1"}"#,
            r#"{"type":"atis-latch","latch":true,"sessionId":"b1"}"#,
        ]
        .join("\n")
            + "\n";
        let path = write_temp("bookkeeping", &body);
        let expected = chrono::DateTime::parse_from_rfc3339("2026-11-12T08:16:00.000Z").unwrap();
        assert_eq!(latest_timestamp(&path), Some(expected.with_timezone(&chrono::Utc)));
    }

    #[test]
    fn latest_timestamp_reads_lines_that_span_chunks() {
        // A timestamped record longer than one 64 KB chunk, then bookkeeping.
        let big = "x".repeat(150 * 1024);
        let body = format!(
            "{{\"type\":\"assistant\",\"timestamp\":\"2026-11-12T09:00:00Z\",\"message\":{{\"content\":\"{big}\"}}}}\n{{\"type\":\"mode\",\"mode\":\"default\"}}\n"
        );
        let path = write_temp("span", &body);
        let expected = chrono::DateTime::parse_from_rfc3339("2026-11-12T09:00:00Z").unwrap();
        assert_eq!(latest_timestamp(&path), Some(expected.with_timezone(&chrono::Utc)));
    }

    #[test]
    fn latest_timestamp_none_without_timestamps() {
        let path = write_temp("none", "{\"type\":\"mode\"}\n");
        assert_eq!(latest_timestamp(&path), None);
    }
}
