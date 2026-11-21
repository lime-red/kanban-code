use anyhow::Result;
use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::jsonl_parser;
use tokio::io::{AsyncBufReadExt, BufReader};

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ContentBlock {
    pub kind: String,
    pub text: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Turn {
    pub index: usize,
    pub role: String,
    pub text_preview: String,
    pub timestamp: Option<String>,
    pub content_blocks: Vec<ContentBlock>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TranscriptPage {
    pub turns: Vec<Turn>,
    pub total_turns: usize,
    pub has_more: bool,
    pub next_offset: usize,
}

const PAGE_SIZE: usize = 20;

/// Read conversation turns from a JSONL file with pagination.
pub async fn read_transcript(file_path: &str, offset: usize) -> Result<TranscriptPage> {
    let path = std::path::Path::new(file_path);
    if !path.exists() {
        return Ok(TranscriptPage {
            turns: vec![],
            total_turns: 0,
            has_more: false,
            next_offset: 0,
        });
    }

    let file = tokio::fs::File::open(path).await?;
    let reader = BufReader::new(file);
    let mut lines = reader.lines();

    let mut all_turns: Vec<Turn> = Vec::new();
    let mut turn_index = 0;

    while let Some(line) = lines.next_line().await? {
        if line.is_empty() {
            continue;
        }
        let obj: Value = match serde_json::from_str(&line) {
            Ok(v) => v,
            Err(_) => continue,
        };

        let Some((role, content_blocks)) = turn_parts(&obj) else { continue };
        let timestamp = obj["timestamp"].as_str().map(|s| s.to_string());
        let text_preview: String = content_blocks
            .iter()
            .filter(|b| b.kind == "text")
            .map(|b| b.text.as_str())
            .collect::<Vec<_>>()
            .join(" ")
            .chars()
            .take(200)
            .collect();

        all_turns.push(Turn {
            index: turn_index,
            role,
            text_preview,
            timestamp,
            content_blocks,
        });
        turn_index += 1;
    }

    let total_turns = all_turns.len();
    let page: Vec<Turn> = all_turns
        .into_iter()
        .skip(offset)
        .take(PAGE_SIZE)
        .collect();
    let has_more = offset + PAGE_SIZE < total_turns;

    Ok(TranscriptPage {
        total_turns,
        has_more,
        next_offset: if has_more { offset + PAGE_SIZE } else { total_turns },
        turns: page,
    })
}

/// Search all turns for a query string (case-insensitive).
/// Returns indices of matching turns.
pub async fn search_transcript_turns(file_path: &str, query: &str) -> Result<Vec<usize>> {
    let path = std::path::Path::new(file_path);
    if !path.exists() {
        return Ok(vec![]);
    }

    let q = query.to_lowercase();
    let file = tokio::fs::File::open(path).await?;
    let reader = BufReader::new(file);
    let mut lines = reader.lines();
    let mut matches = Vec::new();
    let mut turn_index = 0;

    while let Some(line) = lines.next_line().await? {
        if line.is_empty() {
            continue;
        }
        let obj: Value = match serde_json::from_str(&line) {
            Ok(v) => v,
            Err(_) => continue,
        };

        let Some((_, blocks)) = turn_parts(&obj) else { continue };
        let has_match = blocks.iter().any(|b| b.text.to_lowercase().contains(&q));

        if has_match {
            matches.push(turn_index);
        }
        turn_index += 1;
    }

    Ok(matches)
}

/// Return the concatenated `text` content of the most recent `assistant`
/// turn in the JSONL, trimmed and capped at `max_chars` characters so it fits
/// in an OS notification body. None if the file is missing, empty, or has no
/// assistant turn yet. Ignores tool_use/tool_result/thinking blocks.
pub async fn read_last_assistant_message(file_path: &str, max_chars: usize) -> Option<String> {
    let path = std::path::Path::new(file_path);
    if !path.exists() {
        return None;
    }
    let file = tokio::fs::File::open(path).await.ok()?;
    let reader = BufReader::new(file);
    let mut lines = reader.lines();
    let mut last: Option<String> = None;
    while let Ok(Some(line)) = lines.next_line().await {
        if line.is_empty() {
            continue;
        }
        let obj: Value = match serde_json::from_str(&line) {
            Ok(v) => v,
            Err(_) => continue,
        };
        if obj["type"].as_str() != Some("assistant") {
            continue;
        }
        let text: String = parse_content_blocks(&obj)
            .into_iter()
            .filter(|b| b.kind == "text")
            .map(|b| b.text)
            .collect::<Vec<_>>()
            .join(" ");
        let trimmed = text.trim();
        if !trimmed.is_empty() {
            last = Some(trimmed.to_string());
        }
    }
    last.map(|s| {
        let mut out: String = s.chars().take(max_chars).collect();
        if s.chars().count() > max_chars {
            out.push('…');
        }
        out
    })
}

/// The role and blocks a JSONL line shows as in History, or None for lines
/// that are not a turn. Claude Code records local slash commands as user
/// messages wrapped in metadata tags: the `isMeta` caveat is hidden, the
/// command reads as `/clear`, and its output reads as a reply.
fn turn_parts(obj: &Value) -> Option<(String, Vec<ContentBlock>)> {
    let msg_type = obj["type"].as_str().unwrap_or("");
    if msg_type == "assistant" {
        return Some((msg_type.to_string(), parse_content_blocks(obj)));
    }
    if msg_type != "user" || obj["isMeta"].as_bool() == Some(true) {
        return None;
    }
    let mut blocks = parse_content_blocks(obj);
    let mut role = "user";
    for block in blocks.iter_mut().filter(|b| b.kind == "text") {
        if let Some(display) = jsonl_parser::local_command_display(&block.text) {
            block.text = display;
        } else if block.text.contains("<local-command-stdout>") {
            block.text = jsonl_parser::tag_content(&block.text, "local-command-stdout");
            role = "assistant";
        }
    }
    if role == "assistant" && blocks.iter().all(|b| b.text.is_empty()) {
        return None; // a command with no output, e.g. `/clear`
    }
    Some((role.to_string(), blocks))
}

fn parse_content_blocks(obj: &Value) -> Vec<ContentBlock> {
    let mut blocks = Vec::new();
    let content = match obj["message"]["content"].as_array() {
        Some(c) => c,
        None => {
            // Content might be a plain string
            if let Some(text) = obj["message"]["content"].as_str() {
                blocks.push(ContentBlock {
                    kind: "text".to_string(),
                    text: text.to_string(),
                });
            }
            return blocks;
        }
    };

    for block in content {
        let kind = block["type"].as_str().unwrap_or("text");
        match kind {
            "text" => {
                let text = block["text"].as_str().unwrap_or("").to_string();
                blocks.push(ContentBlock {
                    kind: "text".to_string(),
                    text,
                });
            }
            "tool_use" => {
                let name = block["name"].as_str().unwrap_or("tool");
                let input = block["input"].to_string();
                blocks.push(ContentBlock {
                    kind: "tool_use".to_string(),
                    text: format!("{}: {}", name, input),
                });
            }
            "tool_result" => {
                let content_text = block["content"]
                    .as_str()
                    .or_else(|| block["content"][0]["text"].as_str())
                    .unwrap_or("")
                    .to_string();
                blocks.push(ContentBlock {
                    kind: "tool_result".to_string(),
                    text: content_text,
                });
            }
            "thinking" => {
                blocks.push(ContentBlock {
                    kind: "thinking".to_string(),
                    text: block["thinking"].as_str().unwrap_or("").to_string(),
                });
            }
            _ => {}
        }
    }

    blocks
}

#[cfg(test)]
mod tests {
    use super::*;

    fn turn_of(line: &str) -> Option<(String, Vec<ContentBlock>)> {
        turn_parts(&serde_json::from_str(line).unwrap())
    }

    #[test]
    fn hides_caveat_and_shows_command_name() {
        assert!(turn_of(r#"{"type":"user","isMeta":true,"message":{"content":"<local-command-caveat>x</local-command-caveat>"}}"#).is_none());
        let (role, blocks) = turn_of(
            r#"{"type":"user","message":{"content":"<command-name>/clear</command-name>\n            <command-message>clear</command-message>\n            <command-args></command-args>"}}"#,
        )
        .unwrap();
        assert_eq!(role, "user");
        assert_eq!(blocks[0].text, "/clear");
    }

    #[test]
    fn command_output_reads_as_reply_and_empty_output_is_hidden() {
        let (role, blocks) = turn_of(r#"{"type":"user","message":{"content":"<local-command-stdout>Catch you later!</local-command-stdout>"}}"#).unwrap();
        assert_eq!(role, "assistant");
        assert_eq!(blocks[0].text, "Catch you later!");
        assert!(turn_of(r#"{"type":"user","message":{"content":"<local-command-stdout></local-command-stdout>"}}"#).is_none());
    }

    #[test]
    fn command_args_and_plain_prompts_pass_through() {
        let (_, blocks) = turn_of(r#"{"type":"user","message":{"content":"<command-name>/model</command-name><command-message>model</command-message><command-args>opus</command-args>"}}"#).unwrap();
        assert_eq!(blocks[0].text, "/model opus");
        let (role, blocks) = turn_of(r#"{"type":"user","message":{"content":"Fix the bug"}}"#).unwrap();
        assert_eq!((role.as_str(), blocks[0].text.as_str()), ("user", "Fix the bug"));
        assert!(turn_of(r#"{"type":"mode","mode":"default"}"#).is_none());
    }
}
