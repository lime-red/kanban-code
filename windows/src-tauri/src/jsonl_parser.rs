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

        // First real user prompt. Claude Code writes local slash commands
        // (`/login`, `/clear`) as user messages wrapped in metadata tags,
        // plus an `isMeta` caveat; none of those is what the user asked.
        if msg_type == "user" && !found_first_user && !is_metadata_message(&obj) {
            let text = extract_text_content(&obj).map(|t| strip_metadata_tags(&t).trim().to_string());
            if text.as_deref() != Some("") {
                found_first_user = true;
                meta.first_prompt = text;
            }
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

/// Tags Claude Code wraps around local slash commands and their output.
const METADATA_TAGS: [&str; 5] = [
    "local-command-caveat",
    "command-name",
    "command-message",
    "command-args",
    "local-command-stdout",
];

/// Remove every metadata tag pair (and its contents) from a message.
pub fn strip_metadata_tags(text: &str) -> String {
    let mut out = text.to_string();
    for tag in METADATA_TAGS {
        let open = format!("<{tag}>");
        let close = format!("</{tag}>");
        while let Some(start) = out.find(&open) {
            let Some(rel_end) = out[start..].find(&close) else { break };
            let end = start + rel_end + close.len();
            out.replace_range(start..end, "");
        }
    }
    out
}

/// Inner text of the first `<tag>...</tag>` pair, trimmed; empty if absent.
pub fn tag_content(text: &str, tag: &str) -> String {
    let open = format!("<{tag}>");
    let close = format!("</{tag}>");
    let Some(start) = text.find(&open).map(|i| i + open.len()) else { return String::new() };
    let Some(len) = text[start..].find(&close) else { return String::new() };
    text[start..start + len].trim().to_string()
}

/// How a local slash command reads in History: `/clear`, `/review main.rs`,
/// or the command followed by whatever the user typed alongside it.
/// None when the text holds no `<command-name>`.
pub fn local_command_display(text: &str) -> Option<String> {
    let command = tag_content(text, "command-name");
    if command.is_empty() {
        return None;
    }
    let args = tag_content(text, "command-args");
    if !args.is_empty() {
        return Some(format!("{command} {args}"));
    }
    let message = tag_content(text, "command-message");
    if !message.is_empty() && message != command.trim_start_matches('/') {
        return Some(format!("{command}\n\n{message}"));
    }
    let rest = strip_metadata_tags(text).trim().to_string();
    if !rest.is_empty() {
        return Some(format!("{command}\n\n{rest}"));
    }
    Some(command)
}

/// True when a user message is Claude Code bookkeeping rather than a
/// prompt: an `isMeta` caveat, or text made only of metadata tags.
pub fn is_metadata_message(obj: &Value) -> bool {
    if obj["isMeta"].as_bool() == Some(true) {
        return true;
    }
    match extract_text_content(obj) {
        Some(text) if !text.is_empty() => strip_metadata_tags(&text).trim().is_empty(),
        _ => false,
    }
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

    #[tokio::test]
    async fn first_prompt_skips_local_command_metadata() {
        // Shape of a Claude Code 2.1 transcript that opens with `/clear`.
        let body = [
            r#"{"type":"user","message":{"role":"user","content":"<local-command-caveat>The command below was run directly in Claude Code, not sent to you as a request.</local-command-caveat>"},"isMeta":true,"cwd":"C:\\Users\\dev\\code\\kc_test space","sessionId":"c1"}"#,
            r#"{"type":"user","message":{"role":"user","content":"<command-name>/clear</command-name>\n            <command-message>clear</command-message>\n            <command-args></command-args>"},"sessionId":"c1"}"#,
            r#"{"type":"user","message":{"role":"user","content":"<local-command-stdout></local-command-stdout>"},"sessionId":"c1"}"#,
            r#"{"type":"user","message":{"role":"user","content":"Reply with only the word \"afterclear\""},"sessionId":"c1"}"#,
            r#"{"type":"assistant","message":{"content":[{"type":"text","text":"afterclear"}]},"sessionId":"c1"}"#,
        ]
        .join("\n")
            + "\n";
        let path = write_temp("caveat", &body);
        let meta = extract_metadata(&path).await.unwrap().unwrap();
        assert_eq!(meta.first_prompt.as_deref(), Some("Reply with only the word \"afterclear\""));
        assert_eq!(meta.project_path.as_deref(), Some("C:\\Users\\dev\\code\\kc_test space"));
    }

    #[tokio::test]
    async fn first_prompt_none_when_session_only_ran_commands() {
        let body = [
            r#"{"type":"user","message":{"content":"<local-command-caveat>caveat</local-command-caveat>"},"isMeta":true}"#,
            r#"{"type":"user","message":{"content":"<command-name>/exit</command-name>\n<command-message>exit</command-message>\n<command-args></command-args>"}}"#,
            r#"{"type":"user","message":{"content":"<local-command-stdout>Catch you later!</local-command-stdout>"}}"#,
        ]
        .join("\n")
            + "\n";
        let path = write_temp("cmdonly", &body);
        let meta = extract_metadata(&path).await.unwrap().unwrap();
        assert_eq!(meta.first_prompt, None);
    }

    #[test]
    fn strip_metadata_keeps_text_around_tags() {
        assert_eq!(
            strip_metadata_tags("<command-name>/review</command-name> please look at main.rs").trim(),
            "please look at main.rs"
        );
        assert_eq!(strip_metadata_tags("<command-name>unclosed"), "<command-name>unclosed");
    }
}
